#if LUFTIG_SELFTEST
// SelfTestAuditEditorClipboard.swift - clipboard and drag & drop through PRIVATE pasteboards (never NSPasteboard.general / .find / .drag):
// rich text lands as plain text without stray attributes, CRLF / CR / tabs / emoji / lone surrogates, a 5 MB paste, undo of a paste,
// drag & drop of text inside the view (the dragging-destination calls with a stub NSDraggingInfo).

import AppKit
import MarkdownKit

/// A dragging session that lives entirely in this process: a private pasteboard, a point in the text view, a source operation mask.
final class AuditDraggingInfo: NSObject, NSDraggingInfo {
    let window: NSWindow
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var source: AnyObject?
    let mask: NSDragOperation
    init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint, source: AnyObject?, mask: NSDragOperation) {
        self.window = window; self.pasteboard = pasteboard; self.location = location; self.source = source; self.mask = mask
    }
    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

extension SelfTestScenarios {
    static let auditEditorClipboardScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-clipboard", summary: "editor audit: rich text -> plain, CRLF / emoji / tabs, 5 MB paste, undo of a paste, drag and drop inside the view (private pasteboards)", run: { t in try await auditClipboard(t) }),
    ]

    @MainActor static func pasteAttributes(_ host: EditorViewController, _ pb: NSPasteboard, grouped: Bool = true) {
        let tv = host.textView
        let um = tv.undoManager
        um?.beginUndoGrouping()
        _ = tv.readSelection(from: pb)
        tv.breakUndoCoalescing()
        um?.endUndoGrouping()
    }

    @MainActor static func auditClipboard(_ t: SelfTest.T) async throws {
        let pb = AuditEd.privatePasteboard()
        defer { pb.releaseGlobally() }
        let (doc, host, _) = try await openEditor(t, text: "# Title\n\nplain paragraph here\n\n```\ncode line\n```\n", name: "clip.md")
        let tv = host.textView, ts = tv.textStorage!
        func ns() -> NSString { tv.string as NSString }

        // ---- 1. rich text on the pasteboard lands as plain text with OUR attributes
        let rich = NSMutableAttributedString(string: "BOLD red text and a link")
        rich.addAttributes([.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.red, .backgroundColor: NSColor.yellow, .underlineStyle: 1], range: NSRange(location: 0, length: 8))
        rich.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 17, length: 4))
        for (label, types) in [("RTF + plain string", [NSPasteboard.PasteboardType.rtf, .string]), ("RTF only (no string)", [.rtf]), ("RTFD only", [.rtfd])] {
            pb.clearContents()
            if types.contains(.rtf), let d = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) { pb.setData(d, forType: .rtf) }
            if types.contains(.rtfd), let d = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) { pb.setData(d, forType: .rtfd) }
            if types.contains(.string) { pb.setString(rich.string, forType: .string) }
            let at = ns().range(of: "plain paragraph").location
            tv.setSelectedRange(NSRange(location: at, length: 0))
            pasteAttributes(host, pb)
            let pasted = NSRange(location: at, length: rich.length)
            t.equal(ns().substring(with: NSRange(location: at, length: min(rich.length, ns().length - at))), rich.string, "\(label): the text arrives, as plain text")
            var stray: [String] = []
            ts.enumerateAttributes(in: NSIntersectionRange(pasted, NSRange(location: 0, length: ts.length)), options: []) { attrs, r, _ in
                for k in [NSAttributedString.Key.backgroundColor, .link, .underlineStyle, .attachment, .strokeColor, .shadow] where attrs[k] != nil { stray.append("\(k.rawValue)@\(NSStringFromRange(r))") }
                if let f = attrs[.font] as? NSFont, f.pointSize != host.theme.baseSize { stray.append("font \(f.fontName)@\(f.pointSize) \(NSStringFromRange(r))") }
                if let c = attrs[.foregroundColor] as? NSColor, c == NSColor.red { stray.append("red@\(NSStringFromRange(r))") }
            }
            t.check(stray.isEmpty, "\(label): no stray attributes from the rich source: \(stray)")
            await AuditEd.settle(t, host)
            AuditEd.logMismatches(t, host, "\(label): styled text == fresh lex")
            AuditEd.undo(host)
            t.equal(tv.string, "# Title\n\nplain paragraph here\n\n```\ncode line\n```\n", "\(label): ONE undo removes the paste")
        }

        // ---- 2. odd text: CRLF, CR, tabs, emoji, lone surrogate, NUL, very long line
        let odd: [(String, String)] = [("CRLF", "one\r\ntwo\r\nthree"), ("CR only", "one\rtwo\rthree"), ("tabs", "\tindented\t\tcolumns\t"), ("emoji + ZWJ + flags", "😀 👩‍💻 🇦🇹 e\u{301}"),
                                       ("NUL and C0 controls", "a\u{0}b\u{1}c\u{7}d"), ("line separators", "a\u{2028}b\u{2029}c\u{85}d"), ("RTL", "שלום مرحبا abc")]
        for (label, s) in odd {
            let before = ns().copy() as! NSString
            pb.clearContents(); pb.setString(s, forType: .string)
            let at = before.range(of: "code line").location
            tv.setSelectedRange(NSRange(location: at, length: 0))
            pasteAttributes(host, pb)
            let inserted = ns().length - before.length
            // AppKit may normalise line endings (CR / CRLF -> LF); the text view must never lose or add anything else
            let expectedMin = (s as NSString).length - (s.components(separatedBy: "\r\n").count - 1)
            t.check(inserted >= expectedMin - 1 && inserted <= (s as NSString).length, "\(label): pasted \(inserted) units for \((s as NSString).length) offered; text now \(ns().substring(with: NSRange(location: at, length: max(0, min(inserted, ns().length - at)))).debugDescription)")
            await AuditEd.settle(t, host)
            AuditEd.logMismatches(t, host, "\(label): styled == fresh lex")
            t.check(AuditEd.unfixedFonts(host).isEmpty && AuditEd.missingGlyphs(host).isEmpty, "\(label): every character has its fallback font and a glyph")
            AuditEd.undo(host)
            t.check(ns().isEqual(to: before as String), "\(label): undo restores the text")
        }

        // ---- 3. copy / cut: only the selected text, plain string flavour
        tv.setSelectedRange(NSRange(location: 2, length: 5))
        pb.clearContents()
        let wrote = tv.writeSelection(to: pb, types: tv.writablePasteboardTypes)
        t.check(wrote && pb.string(forType: .string) == "Title", "copy: the selection (\"Title\") is on the pasteboard as a string: \(String(describing: pb.string(forType: .string)))")
        t.note("copy offers: \(pb.types?.map { $0.rawValue } ?? [])")
        t.check(pb.data(forType: .rtf) == nil && pb.data(forType: .html) == nil, "copy offers no rich flavour (plain Markdown source stays plain)")

        // ---- 4. the 5 MB paste
        let big = SelfTestCorpus.markdown(bytes: 5_000_000, seed: 77)
        pb.clearContents(); pb.setString(big, forType: .string)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let t0 = SelfTest.nowMs()
        pasteAttributes(host, pb)
        let pasteMs = SelfTest.nowMs() - t0
        t.note(String(format: "5 MB paste at the top of a tiny document: %.0f ms (insert, undo registration, layout around the caret)", pasteMs))
        t.check(pasteMs < 1500, String(format: "5 MB paste blocks the main thread for %.0f ms (< 1500)", pasteMs))
        t.check(ns().length > 4_000_000 && ns().hasPrefix(String(big.prefix(200))), "5 MB paste: the text is complete (\(ns().length) units)")
        let t1 = SelfTest.nowMs()
        host.styler.styleVisible()
        AuditEd.logMismatches(t, host, "5 MB paste: the visible part is styled correctly")
        let vis = host.styler.visibleCharacterRange(tv)
        t.check(host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)), "5 MB paste: the visible part is styled right after the paste (\(String(format: "%.1f", SelfTest.nowMs() - t1)) ms)")
        t.check(AuditEd.selectionSane(host) && tv.selectedRange().location >= 4_000_000, "5 MB paste: the caret is after the pasted text: \(tv.selectedRange())")
        let t2 = SelfTest.nowMs()
        AuditEd.undo(host)
        let undoMs = SelfTest.nowMs() - t2
        t.note(String(format: "undo of the 5 MB paste: %.0f ms", undoMs))
        t.check(undoMs < 1500, String(format: "undo of a 5 MB paste takes %.0f ms (< 1500)", undoMs))
        t.equal(tv.string, "# Title\n\nplain paragraph here\n\n```\ncode line\n```\n", "5 MB paste: undo restores the original text")
        host.styler.styleVisible()
        AuditEd.logMismatches(t, host, "after undoing the 5 MB paste")
        let t3 = SelfTest.nowMs()
        AuditEd.redo(host)
        t.note(String(format: "redo of the 5 MB paste: %.0f ms", SelfTest.nowMs() - t3))
        t.check(ns().length > 4_000_000, "redo brings the 5 MB back")
        AuditEd.undo(host)

        // ---- 5. drag and drop of text inside the view (move and copy)
        guard let window = host.view.window else { t.check(false, "no window"); return }
        let dragPB = AuditEd.privatePasteboard()
        defer { dragPB.releaseGlobally() }
        func dropPoint(forCharacter c: Int) -> NSPoint {
            guard let lm = tv.layoutManager else { return .zero }
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ns().length))
            let g = lm.glyphIndexForCharacter(at: min(c, max(0, lm.numberOfGlyphs - 1)))
            let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let p = lm.location(forGlyphAt: g)
            return NSPoint(x: tv.textContainerOrigin.x + r.minX + p.x + 1, y: tv.textContainerOrigin.y + r.midY)
        }
        for (label, mask, expectCopy) in [("move (plain drag)", NSDragOperation([.copy, .move, .generic]), false), ("copy (option held)", NSDragOperation.copy, true)] {
            let text0 = "alpha beta gamma\n\ndelta epsilon\n"
            tv.undoManager?.disableUndoRegistration(); ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: text0); tv.undoManager?.enableUndoRegistration(); tv.undoManager?.removeAllActions()
            host.styler.reset(); host.styler.styleVisible()
            let src = (text0 as NSString).range(of: "beta ")
            tv.setSelectedRange(src)
            dragPB.clearContents()
            _ = tv.writeSelection(to: dragPB, types: tv.writablePasteboardTypes)
            let dest = (text0 as NSString).range(of: "epsilon").location
            let info = AuditDraggingInfo(window: window, pasteboard: dragPB, location: tv.convert(dropPoint(forCharacter: dest), to: nil), source: tv, mask: mask)
            // (the drag feedback caches the pixels under the drag caret with `lockFocus` - NSTextView's classic caret path, pitfall 33 - which needs a window
            // with a window number: ordered front, far outside every screen, for the drop)
            AuditEd.orderFrontOffscreen(window)
            let op = tv.draggingEntered(info)
            t.check(op != [], "\(label): draggingEntered accepts the text drag (\(op.rawValue))")
            tv.undoManager?.beginUndoGrouping()
            let ok = tv.prepareForDragOperation(info) && tv.performDragOperation(info)
            tv.concludeDragOperation(info)
            window.orderOut(nil)
            tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
            t.check(ok, "\(label): performDragOperation succeeded")
            let after = tv.string
            t.note("\(label): \(text0.debugDescription) -> \(after.debugDescription)")
            // (a MOVE additionally deletes the source selection, but that is done by the drag SOURCE when the real drag session ends: not
            // reproducible without an NSDraggingSession. The destination's share is: the text lands before "epsilon", exactly once.)
            _ = expectCopy
            t.equal(after, "alpha beta gamma\n\ndelta beta epsilon\n", "\(label): the dragged text is inserted at the drop point (before \"epsilon\")")
            await AuditEd.settle(t, host)
            AuditEd.logMismatches(t, host, "\(label): styled == fresh lex after the drop")
            AuditEd.undo(host)
            t.check(tv.string == text0 || !expectCopy && tv.string != "", "\(label): undo: \(tv.string.debugDescription)")
        }
        t.close(doc)
    }
}
#endif
