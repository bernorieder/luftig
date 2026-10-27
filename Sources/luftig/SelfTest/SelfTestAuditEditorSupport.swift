#if LUFTIG_SELFTEST
// SelfTestAuditEditorSupport.swift - helpers of the editor audit (SelfTestAuditEditor*.swift): real key events and responder-chain
// actions driven into the real text view, a differential oracle restricted to the STYLED part of the storage, private pasteboards.
//
// Nothing here touches NSPasteboard.general or the shared find pasteboard; no window is ever ordered front.

import AppKit
import MarkdownKit

enum AuditEd {
    /// A window with a window number but nothing on any screen: ordered front far outside every screen, so that AppKit code that needs a backing store
    /// (`lockFocus`: NSTextView's classic drag caret caches the pixels under it, pitfall 33) works in a test that never shows a window. `orderOut` afterwards.
    @MainActor static func orderFrontOffscreen(_ window: NSWindow) {
        let far = NSPoint(x: -40_000, y: -40_000)
        window.setFrameOrigin(far)
        window.orderFront(nil)
    }


    // MARK: keys

    enum Key {
        static let returnKey: UInt16 = 36, tab: UInt16 = 48, space: UInt16 = 49, delete: UInt16 = 51, escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117, home: UInt16 = 115, end: UInt16 = 119, pageUp: UInt16 = 116, pageDown: UInt16 = 121
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    /// The characters AppKit puts into a key event for a function key.
    static func functionKeyCharacter(_ code: UInt16) -> String {
        let u: Int
        switch code {
        case Key.left: u = NSLeftArrowFunctionKey
        case Key.right: u = NSRightArrowFunctionKey
        case Key.up: u = NSUpArrowFunctionKey
        case Key.down: u = NSDownArrowFunctionKey
        case Key.home: u = NSHomeFunctionKey
        case Key.end: u = NSEndFunctionKey
        case Key.pageUp: u = NSPageUpFunctionKey
        case Key.pageDown: u = NSPageDownFunctionKey
        case Key.forwardDelete: u = NSDeleteFunctionKey
        case Key.delete: u = 0x7F
        case Key.returnKey: u = 0x0D
        case Key.tab: u = 0x09
        case Key.escape: u = 0x1B
        default: return ""
        }
        return String(UnicodeScalar(UInt32(u))!)
    }

    static func keyEvent(_ window: NSWindow, characters: String, ignoring: String? = nil, code: UInt16, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                         isARepeat: false, keyCode: code)!
    }

    /// One key press through the real path: NSWindow.sendEvent -> first responder keyDown -> interpretKeyEvents -> insertText: / doCommandBySelector:
    /// (the window is never key and never visible: a keyDown still reaches the first responder). Wrapped in an undo group like the end of a
    /// real event cycle would close it.
    @MainActor static func press(_ host: EditorViewController, _ characters: String, code: UInt16 = 0, mods: NSEvent.ModifierFlags = []) {
        guard let window = host.view.window else { return }
        let tv = host.textView
        if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        let ev = keyEvent(window, characters: characters, code: code, mods: mods)
        let um = tv.undoManager
        um?.beginUndoGrouping()
        window.sendEvent(ev)
        tv.breakUndoCoalescing()
        um?.endUndoGrouping()
    }

    @MainActor static func pressKey(_ host: EditorViewController, _ code: UInt16, mods: NSEvent.ModifierFlags = []) {
        // Shift-Tab delivers NSBackTabCharacter (U+0019), not a tab
        let chars = (code == Key.tab && mods.contains(.shift)) ? "\u{19}" : functionKeyCharacter(code)
        press(host, chars, code: code, mods: mods)
    }

    @MainActor static func undo(_ host: EditorViewController) { host.textView.breakUndoCoalescing(); host.textView.undoManager?.undo() }
    @MainActor static func redo(_ host: EditorViewController) { host.textView.undoManager?.redo() }

    @MainActor static func type(_ host: EditorViewController, _ s: String) {
        for ch in s {
            if ch == "\n" { pressKey(host, Key.returnKey) } else if ch == "\t" { pressKey(host, Key.tab) } else { press(host, String(ch), code: 0) }
        }
    }

    /// A menu action routed through the responder chain starting at the window's first responder (NSApp.sendAction needs a key window).
    @MainActor @discardableResult static func perform(_ host: EditorViewController, _ action: Selector, tag: Int = 0, grouped: Bool = true) -> Bool {
        guard let window = host.view.window else { return false }
        let tv = host.textView
        if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        let item = NSMenuItem(title: "x", action: action, keyEquivalent: "")
        item.tag = tag
        let um = tv.undoManager
        if grouped { um?.beginUndoGrouping() }
        defer { if grouped { tv.breakUndoCoalescing(); um?.endUndoGrouping() } }
        var r: NSResponder? = window.firstResponder
        while let cur = r {
            if cur.responds(to: action) {
                if let v = cur as? NSUserInterfaceValidations, !v.validateUserInterfaceItem(item) { return false }
                _ = cur.perform(action, with: item)
                return true
            }
            r = cur.nextResponder
        }
        return false
    }

    // MARK: pasteboards

    /// A private, uniquely named pasteboard (never the general or the find pasteboard).
    static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("local.luftig.audit.\(UUID().uuidString)"))
    }

    // MARK: oracle restricted to the styled part

    struct Mismatch { var range: NSRange; var expected: String; var actual: String }

    /// Compares the attributes of every STYLED character (host.styler.styled, optionally intersected with `only`) with a fresh Theme +
    /// MarkdownStyler.lexAll of the current text. Unstyled text is allowed to look like anything (it is the base look).
    @MainActor static func styledMismatches(_ host: EditorViewController, only: NSRange? = nil, maxReport: Int = 3) -> (compared: Int, bad: Int, first: [Mismatch]) {
        guard let ts = host.textView.textStorage else { return (0, 0, []) }
        let text = ts.string as NSString
        let (expected, md) = StyleOracle.expectedRuns(text: text, settings: host.theme.settings, tableWidthLimit: host.provider.tables.widthLimit)       // the editor's own settings: fonts and line spacing are part of the look
        func lexStyle(at loc: Int) -> MDStyle {
            var lo = 0, hi = md.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if md[mid].range.location <= loc { lo = mid } else { hi = mid - 1 } }
            return md.isEmpty ? MDStyle() : md[lo].style
        }
        var styled = host.styler.styled
        if let only { styled = styled.intersection(IndexSet(integersIn: only.location..<NSMaxRange(only))) }
        var compared = 0, bad = 0
        var first: [Mismatch] = []
        // `expected` is ordered and covers the text: walk it with a binary search for each styled range
        for range in styled.rangeView {
            let win = NSRange(location: range.lowerBound, length: range.count)
            var lo = 0, hi = expected.count - 1
            while lo < hi { let mid = (lo + hi) / 2; if NSMaxRange(expected[mid].range) <= win.location { lo = mid + 1 } else { hi = mid } }
            var i = lo
            while i < expected.count && expected[i].range.location < NSMaxRange(win) {
                let run = expected[i]
                i += 1
                let r = NSIntersectionRange(run.range, win)
                if r.length == 0 { continue }
                compared += 1
                var pos = r.location
                var ok = true
                var badActual = TextAttributes()
                while pos < NSMaxRange(r) {
                    var eff = NSRange(location: 0, length: 0)
                    let a = ts.attributes(at: pos, longestEffectiveRange: &eff, in: NSRange(location: pos, length: NSMaxRange(r) - pos))
                    var nonASCII = false
                    for k in eff.location..<NSMaxRange(eff) where text.character(at: k) > 0x7F { nonASCII = true; break }
                    if !StyleOracle.attributesEqual(a, run.attributes, allowFontFallback: nonASCII) { ok = false; badActual = a; break }
                    pos = NSMaxRange(eff)
                    if eff.length == 0 { break }
                }
                if !ok {
                    bad += 1
                    if first.count < maxReport {
                        let sample = text.substring(with: NSRange(location: r.location, length: min(24, r.length))).debugDescription
                        first.append(Mismatch(range: r, expected: "\(lexStyle(at: r.location)) \(StyleOracle.describe(run.attributes))", actual: "\(StyleOracle.describe(badActual)) text=\(sample)"))
                    }
                }
            }
        }
        return (compared, bad, first)
    }

    @MainActor static func logMismatches(_ t: SelfTest.T, _ host: EditorViewController, _ label: String) {
        let r = styledMismatches(host)
        t.check(r.bad == 0, "\(label): \(r.compared) styled runs compared with a fresh lex, \(r.bad) differ \(r.first.map { "\(NSStringFromRange($0.range)) expected [\($0.expected)] actual [\($0.actual)]" })")
    }

    // MARK: font fallback oracle

    /// AppKit's attribute fixing replaces the font of text the font cannot render (CJK, emoji, ...) by a fallback font; text whose
    /// attributes were set AFTER the fixing pass keeps the base font and renders as MISSING GLYPHS (invisible text). A fresh NSTextStorage
    /// built from a copy of ours runs the fixing pass on init: afterwards every character must carry the same font as ours.
    /// Returns the first few ranges whose font differs (empty = every character carries the font AppKit would give it).
    @MainActor static func unfixedFonts(_ host: EditorViewController, maxReport: Int = 3) -> [String] {
        guard let ts = host.textView.textStorage else { return [] }
        let fixed = NSTextStorage(attributedString: NSAttributedString(attributedString: ts))
        fixed.fixAttributes(in: NSRange(location: 0, length: fixed.length))
        var out: [String] = []
        var pos = 0
        let len = ts.length
        let text = ts.string as NSString
        while pos < len && out.count < maxReport {
            var effA = NSRange(location: 0, length: 0), effB = NSRange(location: 0, length: 0)
            let a = ts.attribute(.font, at: pos, effectiveRange: &effA) as? NSFont
            let b = fixed.attribute(.font, at: pos, effectiveRange: &effB) as? NSFont
            let end = min(NSMaxRange(effA), NSMaxRange(effB))
            if a != b {
                out.append("\(NSStringFromRange(NSRange(location: pos, length: end - pos))) \(text.substring(with: NSRange(location: pos, length: min(12, end - pos))).debugDescription): font \(a?.fontName ?? "nil") but AppKit's fixing gives \(b?.fontName ?? "nil")")
            }
            pos = end
        }
        return out
    }

    // MARK: layout oracle

    struct Fragment: Equatable {
        var chars: NSRange; var rect: NSRect; var used: NSRect
        /// equal up to sub-point float noise
        func same(_ o: Fragment) -> Bool {
            func eq(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }
            return chars == o.chars && eq(rect.minX, o.rect.minX) && eq(rect.minY, o.rect.minY) && eq(rect.width, o.rect.width) && eq(rect.height, o.rect.height)
                && eq(used.minX, o.used.minX) && eq(used.minY, o.used.minY) && eq(used.width, o.used.width) && eq(used.height, o.used.height)
        }
    }

    static func fragments(_ lm: NSLayoutManager) -> [Fragment] {
        var out: [Fragment] = []
        let n = lm.numberOfGlyphs
        if n > 0 {
            lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: n)) { rect, used, _, glyphs, _ in
                out.append(Fragment(chars: lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect: rect, used: used))
            }
        }
        return out
    }

    /// The layout of the editor (everything laid out) must be a pure function of (attributed string, container width): compare every line
    /// fragment with a FRESH text system built from a copy of the attributed string. Catches stale layout after attribute churn.
    @MainActor static func layoutMismatch(_ host: EditorViewController, all: Bool = false) -> String? {
        let tv = host.textView
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage else { return nil }
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ts.length))
        let mine = fragments(lm)
        let copy = NSTextStorage(attributedString: NSAttributedString(attributedString: ts))
        copy.fixAttributes(in: NSRange(location: 0, length: copy.length))      // eager: the lazy pass can lose a race with glyph generation
        let flm = NSLayoutManager()
        copy.addLayoutManager(flm)
        let fc = NSTextContainer(size: tc.size)
        fc.lineFragmentPadding = tc.lineFragmentPadding
        flm.addTextContainer(fc)
        flm.ensureLayout(for: fc)
        let fresh = fragments(flm)
        if mine.count != fresh.count { return "fragment count \(mine.count) vs fresh \(fresh.count)" }
        if all { var bad: [String] = []; for i in 0..<mine.count where !mine[i].same(fresh[i]) { bad.append("#\(i) \(NSStringFromRange(mine[i].chars)) \((ts.string as NSString).substring(with: mine[i].chars).debugDescription) mine \(mine[i].used) fresh \(fresh[i].used)") }; return bad.isEmpty ? nil : "\(bad.count) fragments differ: \(bad.prefix(8))" }
        for i in 0..<mine.count where !mine[i].same(fresh[i]) {
            let s = (ts.string as NSString)
            let sample = s.substring(with: NSIntersectionRange(mine[i].chars, NSRange(location: 0, length: min(30, mine[i].chars.length)) )).debugDescription
            return "fragment \(i) \(sample): \(mine[i]) vs fresh \(fresh[i])"
        }
        let e1 = lm.extraLineFragmentRect, e2 = flm.extraLineFragmentRect
        // (the extra line fragment's height comes from the typing attributes, its origin is only meaningful when it exists)
        if e1.width > 0 && e2.width > 0 && e1.minY != e2.minY { return "extra line fragment \(e1) vs fresh \(e2)" }
        return nil
    }

    /// Like `layoutMismatch`, but for what a user can see: lay out the visible part (+- 40 lines of characters) the way the editor does and
    /// compare each of those line fragments (character range, height, width, used rect) with a fresh layout of a copy. Absolute y is not
    /// compared (non-contiguous layout estimates the height of unlaid-out text above the viewport).
    @MainActor static func visibleLayoutMismatch(_ host: EditorViewController, extra: Int = 3000) -> String? {
        let tv = host.textView
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage, ts.length > 0 else { return nil }
        let vis = host.styler.visibleCharacterRange(tv)
        let from = max(0, vis.location - extra), to = min(ts.length, NSMaxRange(vis) + extra)
        let range = NSRange(location: from, length: max(0, to - from))
        lm.ensureLayout(forCharacterRange: range)
        var mine: [Fragment] = []
        let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        lm.enumerateLineFragments(forGlyphRange: gr) { rect, used, _, glyphs, _ in
            mine.append(Fragment(chars: lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect: rect, used: used))
        }
        let copy = NSTextStorage(attributedString: NSAttributedString(attributedString: ts))
        copy.fixAttributes(in: NSRange(location: 0, length: copy.length))      // eager: the lazy pass can lose a race with glyph generation
        let flm = NSLayoutManager()
        copy.addLayoutManager(flm)
        let fc = NSTextContainer(size: tc.size)
        fc.lineFragmentPadding = tc.lineFragmentPadding
        flm.addTextContainer(fc)
        flm.ensureLayout(for: fc)
        var fresh: [Int: Fragment] = [:]
        for f in fragments(flm) { fresh[f.chars.location] = f }
        func eq(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }
        var bad: [String] = []
        for m in mine {
            guard let f = fresh[m.chars.location] else { bad.append("no fresh fragment at \(m.chars.location)"); continue }
            // The WIDTH of a line with emoji is not compared: the fresh layout of a COPY generates no glyph (id 0, zero width) for many emoji
            // where the real editor has the colour glyph (measured: 21 pt per emoji), so the oracle is wrong there, not the editor.
            // Missing glyphs of the real layout are checked on their own (`missingGlyphs`); everything else (CJK, Arabic, Hebrew, accents)
            // is compared strictly.
            var emoji = false
            let text0 = ts.string as NSString
            for k in m.chars.location..<NSMaxRange(m.chars) { let c = text0.character(at: k); if (c >= 0xD800 && c <= 0xDFFF) || (c >= 0x2190 && c <= 0x2BFF) || c == 0x200D || c == 0xFE0F { emoji = true; break } }
            if !(m.chars == f.chars && eq(m.rect.height, f.rect.height) && eq(m.rect.width, f.rect.width) && eq(m.used.height, f.used.height) && (emoji || (eq(m.used.minX, f.used.minX) && eq(m.used.width, f.used.width)))) {
                var detail = ""
                let text = ts.string as NSString
                for k in m.chars.location..<NSMaxRange(m.chars) where text.character(at: k) > 0x7F {
                    let fa = (ts.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.fontName ?? "nil"
                    let fb = (copy.attribute(.font, at: k, effectiveRange: nil) as? NSFont)?.fontName ?? "nil"
                    let gm = lm.cgGlyph(at: lm.glyphIndexForCharacter(at: k)), gf = flm.cgGlyph(at: flm.glyphIndexForCharacter(at: k))
                    detail += " [char \(k) U+\(String(text.character(at: k), radix: 16)) font mine \(fa) fresh \(fb) glyph mine \(gm) fresh \(gf)]"
                }
                bad.append("\(NSStringFromRange(m.chars)) \(text.substring(with: NSIntersectionRange(m.chars, NSRange(location: m.chars.location, length: min(40, m.chars.length)))).debugDescription) mine \(m.rect) used \(m.used) vs fresh \(f.rect) used \(f.used)\(detail)")
            }
        }
        if !bad.isEmpty && SelfTest.flag("audit-debug"), let m = mine.first(where: { x in fresh[x.chars.location].map { f in !(x.chars == f.chars && abs(x.used.minX - f.used.minX) < 0.05 && abs(x.used.width - f.used.width) < 0.05) } ?? true }) {
            out(dumpRuns(ts, m.chars, "REAL storage") + "\n" + dumpRuns(copy, m.chars, "COPY (fixAttributes)"))
        }
        return bad.isEmpty ? nil : "\(bad.count) of \(mine.count) visible fragments differ: \(bad.prefix(3))"
    }

    /// Debug aid (--audit-debug): every attribute run of `range` with its paragraph style, for the real storage and for the copy used as the oracle.
    static func dumpRuns(_ ts: NSTextStorage, _ range: NSRange, _ label: String) -> String {
        var out = "\(label):"
        var p = range.location
        let end = min(NSMaxRange(range), ts.length)
        while p < end {
            var eff = NSRange(location: 0, length: 0)
            let a = ts.attributes(at: p, longestEffectiveRange: &eff, in: NSRange(location: p, length: end - p))
            let f = a[.font] as? NSFont
            let ps = a[.paragraphStyle] as? NSParagraphStyle
            out += "\n   \(NSStringFromRange(eff)) \((ts.string as NSString).substring(with: NSRange(location: eff.location, length: min(8, eff.length))).debugDescription) font \(f?.fontName ?? "nil")@\(f?.pointSize ?? 0) para(first \(ps?.firstLineHeadIndent ?? -1) head \(ps?.headIndent ?? -1) tail \(ps?.tailIndent ?? -1) h \(ps?.minimumLineHeight ?? -1)/\(ps?.maximumLineHeight ?? -1) before \(ps?.paragraphSpacingBefore ?? -1) after \(ps?.paragraphSpacing ?? -1) spacing \(ps?.lineSpacing ?? -1) align \(ps?.alignment.rawValue ?? -1) dir \(ps?.baseWritingDirection.rawValue ?? -9)) kern \(a[.kern] as Any) keys \(a.keys.map { $0.rawValue }.sorted())"
            p = NSMaxRange(eff)
            if eff.length == 0 { break }
        }
        return out
    }

    /// Glyph validity of the REAL layout: every non-ASCII composed character sequence that is laid out (visible part +- `extra` units) must
    /// have a glyph (id != 0). A glyph id 0 is a MISSING glyph: the text is in the file but renders as nothing.
    @MainActor static func missingGlyphs(_ host: EditorViewController, extra: Int = 3000, maxReport: Int = 4) -> [String] {
        let tv = host.textView
        guard let lm = tv.layoutManager, let ts = tv.textStorage, ts.length > 0 else { return [] }
        let vis = host.styler.visibleCharacterRange(tv)
        let from = max(0, vis.location - extra), to = min(ts.length, NSMaxRange(vis) + extra)
        let range = NSRange(location: from, length: max(0, to - from))
        lm.ensureLayout(forCharacterRange: range)
        let text = ts.string as NSString
        var out: [String] = []
        var k = range.location
        while k < NSMaxRange(range) && out.count < maxReport {
            let seq = text.rangeOfComposedCharacterSequence(at: k)
            let c = text.character(at: seq.location)
            k = max(k + 1, NSMaxRange(seq))
            guard c > 0x7F, lm.isValidGlyphIndex(lm.glyphIndexForCharacter(at: seq.location)) else { continue }
            let scalar = Unicode.Scalar(c) ?? Unicode.Scalar(0x2423)!
            let cat = scalar.properties.generalCategory
            if c >= 0xD800 && c <= 0xDBFF { /* surrogate pair: a real code point, check below */ }
            else if [.format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator, .nonspacingMark, .enclosingMark, .spacingMark, .privateUse, .unassigned].contains(cat) { continue }
            let g = lm.cgGlyph(at: lm.glyphIndexForCharacter(at: seq.location))
            if g == 0 {
                let f = (ts.attribute(.font, at: seq.location, effectiveRange: nil) as? NSFont)?.fontName ?? "nil"
                out.append("\(NSStringFromRange(seq)) \(text.substring(with: seq).debugDescription) glyph 0 (font \(f))")
            }
        }
        return out
    }

    /// Settle like the run loop would between two events (scheduled stale-tail restyles), then fill the viewport.
    @MainActor static func settle(_ t: SelfTest.T, _ host: EditorViewController, ms: Double = 2) async {
        await t.spin(ms)
        host.styler.styleVisible()
    }

    /// Cheap structural sanity of the selection and the text view state.
    @MainActor static func selectionSane(_ host: EditorViewController) -> Bool {
        let tv = host.textView
        let len = (tv.string as NSString).length
        for v in tv.selectedRanges {
            let r = v.rangeValue
            if r.location == NSNotFound || NSMaxRange(r) > len { return false }
        }
        return !tv.selectedRanges.isEmpty
    }

    @MainActor static func ns(_ host: EditorViewController) -> NSString { host.textView.string as NSString }
}
#endif
