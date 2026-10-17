#if LUFTIG_SELFTEST
// SelfTestIndentLayout.swift - hanging indents in the REAL layout (indent-layout): in a narrow window a long list item wraps, and the x origin of
// the first glyph of EACH continuation fragment equals the x of the first TEXT glyph after the marker on the first fragment (tolerance 0.5 pt).
// Measured with NSLayoutManager (line fragment rects + location(forGlyphAt:)) at 11 / 16 / 28 pt, in a document whose block of lists lies far below
// the first screen (so it is styled lazily, when it is scrolled to), and again after edits that change the prefix width (incremental restyle).
// Lines that are not lists (headings, paragraphs, plain quotes, code, tables, HTML, setext) must wrap exactly as before: continuation fragments start
// where the first fragment starts. Right-to-left lines are left alone (attribute check only).

import AppKit
import MarkdownKit

enum IndentLayoutSample {
    enum Kind { case parse, flat, rtl }

    static let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa"]
    static func long(_ n: Int, _ seed: Int = 0) -> String {
        var s = "", i = seed
        while s.count < n { s += (s.isEmpty ? "" : " ") + words[i % words.count]; i += 3 }
        return s + "."
    }

    /// The block of lines (all of them LONG: they wrap several times in a 400 pt window at 11 pt and many times at 28 pt).
    static var block: [(String, Kind)] {
        let l = long(300), m = long(140, 5)
        return [
            ("# Heading \(m)", .flat), ("", .flat),
            ("Plain paragraph. \(l)", .parse), ("", .flat),
            ("- Bullet \(l)", .parse), ("* Star \(l)", .parse), ("+ Plus \(l)", .parse),
            ("- **Bold start** then `inline code` and a [link](https://example.com/a/very/long/address) then \(l)", .parse),
            ("- ~~Struck~~ _italic_ ![img](a.png) `code` \(l)", .parse),
            ("  Continuation of a hard-wrapped item. \(l)", .parse),
            ("    - Nested four \(l)", .parse), ("  - Nested two \(l)", .parse), ("\t- Tab nested \(l)", .parse), ("\t\t- Two tabs \(l)", .parse), ("", .flat),
            ("1. One \(l)", .parse), ("2) Paren \(l)", .parse), ("9. Nine \(l)", .parse), ("10. Ten \(l)", .parse), ("99. Ninety nine \(l)", .parse),
            ("100. Hundred \(l)", .parse), ("999. Nine nine nine \(l)", .parse), ("", .flat),
            ("- [ ] Task \(l)", .parse), ("- [x] Done \(l)", .parse), ("  - [ ] Nested task \(l)", .parse), ("1. [ ] Ordered task \(l)", .parse),
            ("-   Three spaces \(l)", .parse), ("- - Two markers \(l)", .parse), ("", .flat),
            ("> - Quoted bullet \(l)", .parse), ("> 1. Quoted ordered \(l)", .parse), ("> > - Double \(l)", .parse), ("> > 1. Double ordered \(l)", .parse),
            ("> - [ ] Quoted task \(l)", .parse), (">   Quoted continuation \(l)", .parse), ("> Plain quote \(l)", .parse), ("> > Plain nested \(l)", .parse), ("", .flat),
            ("   Indented paragraph \(l)", .parse), ("", .flat),
            ("```", .flat), ("- code fence line that looks like a list item \(l)", .flat), ("  and this one is indented \(l)", .flat), ("```", .flat), ("", .flat),
            ("    - indented code \(l)", .flat), ("", .flat),
            ("| \(m) | b |", .flat), ("|---|---|", .flat), ("| - \(m) | 1. d |", .flat), ("", .flat),
            ("<div>", .flat), ("  <p>- html \(l)</p>", .flat), ("</div>", .flat), ("", .flat),
            ("Setext title \(m)", .flat), ("===========", .flat), ("", .flat),
            ("- # Heading in a list \(m)", .flat), ("", .flat),
            ("مرحبا بكم في luftig هذا نص عربي طويل من اليمين إلى اليسار مرحبا بكم في luftig هذا نص عربي طويل من اليمين إلى اليسار مرحبا بكم في luftig هذا نص عربي طويل", .rtl),
            ("- عنصر قائمة بالعربية طويل جدا من اليمين إلى اليسار عنصر قائمة بالعربية طويل جدا من اليمين إلى اليسار عنصر قائمة بالعربية طويل جدا", .rtl),
            ("", .flat), ("The last line.", .flat),
        ]
    }
}

extension SelfTestScenarios {

    struct IndentFragment { var chars: NSRange; var x: CGFloat }

    /// The line fragments of the source line `lr` with the x (in the container) of the first glyph of each. A fragment that only holds the line break is dropped.
    @MainActor static func indentFragments(_ lm: NSLayoutManager, _ lr: NSRange) -> [IndentFragment] {
        let gr = lm.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
        var out: [IndentFragment] = []
        lm.enumerateLineFragments(forGlyphRange: gr) { rect, _, _, glyphs, _ in
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            out.append(IndentFragment(chars: chars, x: rect.minX + lm.location(forGlyphAt: glyphs.location).x))
        }
        if out.count > 1, let last = out.last, last.chars.length == 1, let ts = lm.textStorage, (ts.string as NSString).character(at: last.chars.location) == 0x0A { out.removeLast() }
        return out
    }

    /// x of the glyph of character `index` (container coordinates).
    @MainActor static func indentGlyphX(_ lm: NSLayoutManager, _ index: Int) -> CGFloat {
        let g = lm.glyphIndexForCharacter(at: index)
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + lm.location(forGlyphAt: g).x
    }

    /// Checks every line of `block` (character range of the first line .. end of the last): returns the number of lines checked, of them hanging, and the failures.
    @MainActor static func indentCheckLayout(_ host: EditorViewController, block: NSRange, kinds: [IndentLayoutSample.Kind], tolerance: CGFloat = 0.5) -> (checked: Int, hanging: Int, wrapped: Int, failures: [String]) {
        let tv = host.textView
        guard let lm = tv.layoutManager, let ts = tv.textStorage else { return (0, 0, 0, ["no layout manager"]) }
        lm.ensureLayout(forCharacterRange: block)
        let ns = ts.string as NSString
        var checked = 0, hanging = 0, wrapped = 0
        var failures: [String] = []
        let lineRanges = IndentOracle.lines(of: ns.substring(with: block) as NSString).map { NSRange(location: $0.location + block.location, length: $0.length) }
        for (i, lr) in lineRanges.enumerated() where i < kinds.count {
            let kind = kinds[i]
            let text = ns.substring(with: NSRange(location: lr.location, length: max(0, lr.length - 1))) as NSString
            if text.length == 0 { continue }
            let frags = indentFragments(lm, lr)
            guard let first = frags.first else { failures.append("line \(i) \(text.substring(to: min(20, text.length)).debugDescription): no line fragment"); continue }
            checked += 1
            if frags.count > 1 { wrapped += 1 }
            let name = text.substring(to: min(22, text.length)).debugDescription
            let ps = ts.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle
            switch kind {
            case .rtl:
                if ps?.headIndent != ps?.firstLineHeadIndent { failures.append("line \(i) \(name): right-to-left line got a head indent \(ps?.headIndent ?? -1)") }
            case .flat:
                // not a list: continuation fragments start where the first fragment starts (x of its first glyph), as before
                for f in frags.dropFirst() where abs(f.x - first.x) > tolerance { failures.append("line \(i) \(name): fragment at \(f.chars.location) starts at x \(f.x), the line starts at \(first.x)") }
            case .parse:
                if let prefix = IndentOracle.prefixLength(text) {
                    hanging += 1
                    let start = lr.location + prefix
                    guard NSLocationInRange(start, first.chars) else { failures.append("line \(i) \(name): the text does not start on the first fragment"); continue }
                    let x0 = indentGlyphX(lm, start)
                    if frags.count < 2 { failures.append("line \(i) \(name): did not wrap (\(frags.count) fragment): the test is vacuous") }
                    for f in frags.dropFirst() where abs(f.x - x0) > tolerance { failures.append("line \(i) \(name): fragment at \(f.chars.location) starts at x \(String(format: "%.2f", f.x)), the text starts at \(String(format: "%.2f", x0)) (head indent \(ps?.headIndent ?? -1))") }
                } else {
                    for f in frags.dropFirst() where abs(f.x - first.x) > tolerance { failures.append("line \(i) \(name): fragment at \(f.chars.location) starts at x \(f.x), the line starts at \(first.x)") }
                }
            }
        }
        return (checked, hanging, wrapped, failures)
    }

    // MARK: indent-layout

    @MainActor static func indentLayout(_ t: SelfTest.T) async throws {
        let savedSize = EditorPreferences.fontSize, savedRW = EditorPreferences.readableWidth
        defer { EditorPreferences.fontSize = savedSize; EditorPreferences.readableWidth = savedRW }
        let block = IndentLayoutSample.block
        let blockText = block.map { $0.0 }.joined(separator: "\n") + "\n"
        let filler = (0..<300).map { "Filler paragraph \($0) before the block of lists, so that the block is styled lazily when it is scrolled to.\n" }.joined()
        for (width, size) in [(400.0, 11.0), (400.0, 16.0), (400.0, 28.0), (860.0, 16.0)] {
            EditorPreferences.fontSize = CGFloat(size)
            let label = "\(Int(width)) pt wide, \(Int(size)) pt"
            let (doc, host, _) = try await openEditor(t, text: filler + blockText, name: "indent-layout-\(Int(width))-\(Int(size)).md", size: NSSize(width: width, height: 700))
            let tv = host.textView
            let blockStart = (tv.string as NSString).range(of: "# Heading").location
            let blockRange = NSRange(location: blockStart, length: (tv.string as NSString).length - blockStart)
            t.check(!host.styler.styled.contains(integersIn: blockStart..<(blockStart + 200)), "\(label): the block of lists is NOT styled when the document opens (it is far below the first screen)")
            t.scrollToTop(host, character: blockStart)               // pre-styles the landing zone, scrolls
            await t.spin(5)
            t.check(host.styler.styled.contains(integersIn: blockStart..<(blockStart + 2000)), "\(label): the block is styled lazily when scrolled to")
            let r = indentCheckLayout(host, block: blockRange, kinds: block.map { $0.1 })
            t.check(r.failures.isEmpty, "\(label): \(r.checked) lines laid out, \(r.hanging) hanging lines, \(r.wrapped) wrapped: every continuation fragment starts where its text starts (+- 0.5 pt), other lines wrap as before \(r.failures.prefix(4))")
            t.check(r.hanging >= 30 && r.wrapped >= 40, "\(label): the sample is not vacuous (\(r.hanging) hanging lines, \(r.wrapped) wrapped lines)")
            if let m = AuditEd.visibleLayoutMismatch(host) { t.check(false, "\(label): the laid-out visible text differs from a fresh layout of a copy: \(m)") }
            else { t.check(true, "\(label): the laid-out visible text equals a fresh layout of a copy of the storage") }

            // incremental restyle: edits that change the prefix width; the line must hang by the NEW width at once
            if size == 16 && width == 400 {
                func verify(_ needle: String, _ what: String) {
                    let cur = tv.string as NSString
                    let r0 = cur.range(of: needle)
                    guard r0.location != NSNotFound else { t.check(false, "\(what): line not found"); return }
                    let lr = cur.lineRange(for: NSRange(location: r0.location, length: 0))
                    let text = cur.substring(with: NSRange(location: lr.location, length: lr.length - 1)) as NSString
                    guard let lm = tv.layoutManager, let prefix = IndentOracle.prefixLength(text) else { t.check(false, "\(what): not a hanging line any more"); return }
                    lm.ensureLayout(forCharacterRange: lr)
                    let frags = indentFragments(lm, lr)
                    let x0 = indentGlyphX(lm, lr.location + prefix)
                    t.check(frags.count >= 2 && frags.dropFirst().allSatisfy { abs($0.x - x0) <= 0.5 }, "\(what): \(frags.count) fragments, continuation x \(frags.dropFirst().map { String(format: "%.2f", $0.x) }) == text x \(String(format: "%.2f", x0))")
                }
                // 9. -> 10. -> 100.
                let nine = (tv.string as NSString).range(of: "9. Nine")
                t.typeText("10", into: doc, at: NSRange(location: nine.location, length: 1)); verify("10. Nine", "ordered 9 -> 10, typed")
                let ten = (tv.string as NSString).range(of: "10. Nine")
                t.typeText("100", into: doc, at: NSRange(location: ten.location, length: 2)); verify("100. Nine", "ordered 10 -> 100, typed")
                t.typeText("9", into: doc, at: NSRange(location: (tv.string as NSString).range(of: "100. Nine").location, length: 3)); verify("9. Nine", "ordered 100 -> 9, typed")
                // task marker toggled and added
                let task = (tv.string as NSString).range(of: "- [ ] Task")
                t.typeText("x", into: doc, at: NSRange(location: task.location + 3, length: 1)); verify("- [x] Task", "task marker [ ] -> [x], typed")
                let bullet = (tv.string as NSString).range(of: "- Bullet")
                t.typeText("[ ] ", into: doc, at: NSRange(location: bullet.location + 2, length: 0)); verify("- [ ] Bullet", "a task marker typed into a bullet")
                // nesting: a bullet becomes nested by typing two spaces, then a tab; a quote marker typed in front
                let star = (tv.string as NSString).range(of: "* Star")
                t.typeText("  ", into: doc, at: NSRange(location: star.location, length: 0)); verify("* Star", "bullet indented by two typed spaces")
                t.typeText("\t", into: doc, at: NSRange(location: star.location, length: 2)); verify("* Star", "... and by a typed tab instead of the two spaces")
                let plus = (tv.string as NSString).range(of: "+ Plus")
                t.typeText("> ", into: doc, at: NSRange(location: plus.location, length: 0)); verify("+ Plus", "a bullet quoted by a typed `> `")
                // a typed list marker turns a plain paragraph into a hanging item, deleting it turns it back
                let para = (tv.string as NSString).range(of: "Plain paragraph.")
                t.typeText("- ", into: doc, at: NSRange(location: para.location, length: 0)); verify("- Plain paragraph.", "a plain paragraph becomes a list item when `- ` is typed")
                t.typeText("", into: doc, at: NSRange(location: para.location, length: 2))
                let plainRange = (tv.string as NSString).lineRange(for: NSRange(location: para.location, length: 0))
                let pf = indentFragments(tv.layoutManager!, plainRange)
                t.check(pf.count >= 2 && pf.dropFirst().allSatisfy { abs($0.x - pf[0].x) <= 0.5 }, "... and back to a plain paragraph when it is deleted (continuation x \(pf.dropFirst().map { $0.x }) == \(pf.first?.x ?? -1))")
                await t.spin(5)
                host.styler.styleEverything()
                assertMatchesFreshLex(t, host, "\(label): whole document after the typed edits")
                if let m = AuditEd.visibleLayoutMismatch(host) { t.check(false, "\(label): after the edits the visible layout differs from a fresh layout: \(m)") }
                else { t.check(true, "\(label): after the edits the visible layout equals a fresh layout of a copy") }
            }
            // the font size changes while the document is open (a new Theme: new caches, everything restyled): the layout must follow
            if size == 16 && width == 400 {
                EditorPreferences.fontSize = 22
                await t.spin(10)
                t.scrollToTop(host, character: blockStart)
                host.styler.styleVisible()
                let r2 = indentCheckLayout(host, block: blockRange, kinds: block.map { $0.1 })
                t.check(r2.failures.isEmpty && r2.hanging >= 30, "\(label), then font size 22 while open: \(r2.hanging) hanging lines follow the new fonts \(r2.failures.prefix(3))")
                EditorPreferences.fontSize = 11
                await t.spin(10)
                t.scrollToTop(host, character: blockStart)
                host.styler.styleVisible()
                let r3 = indentCheckLayout(host, block: blockRange, kinds: block.map { $0.1 })
                t.check(r3.failures.isEmpty && r3.hanging >= 30, "\(label), then font size 11 while open: \(r3.hanging) hanging lines follow the new fonts \(r3.failures.prefix(3))")
            }
            t.close(doc)
        }
    }
}
#endif
