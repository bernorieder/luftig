#if LUFTIG_SELFTEST
// SelfTestAuditEditorIME.swift - input method composition (marked text) driven through NSTextInputClient (setMarkedText / unmarkText /
// insertText with a replacement range): during styling, with scrolling, with a font size change in the middle, and an external
// reload that arrives while the user is composing. A real input method / candidate window is NOT exercised (headless).

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorIMEScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-ime", summary: "editor audit: IME composition (setMarkedText / unmarkText / insertText) during styling, scrolling, font size change and an external reload", run: { t in try await auditIME(t) }),
    ]

    @MainActor static func auditIME(_ t: SelfTest.T) async throws {
        let base = "# Title\n\nfirst paragraph with text\n\n> quote line\n\n```\ncode\n```\n\nlast line\n"
        let (doc, host, _) = try await openEditor(t, text: base, name: "ime.md", size: NSSize(width: 860, height: 600))
        let tv = host.textView
        let um = tv.undoManager
        func ns() -> NSString { tv.string as NSString }
        func grouped(_ body: () -> Void) { um?.beginUndoGrouping(); body(); tv.breakUndoCoalescing(); um?.endUndoGrouping() }
        let none = NSRange(location: NSNotFound, length: 0)

        // ---- 1. a Japanese composition at the end of the heading: marked text keeps its own attributes while composing
        let headingEnd = ns().range(of: "Title").location + 5
        tv.setSelectedRange(NSRange(location: headingEnd, length: 0))
        let r0 = host.styler.editRestyles
        grouped { tv.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        grouped { tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: tv.markedRange()) }
        grouped { tv.setMarkedText("にほん", selectedRange: NSRange(location: 1, length: 1), replacementRange: tv.markedRange()) }   // selection INSIDE the marked text
        t.check(tv.hasMarkedText() && ns().substring(with: tv.markedRange()) == "にほん", "composing \"にほん\": marked range \(tv.markedRange())")
        t.equal(tv.selectedRange(), NSRange(location: tv.markedRange().location + 1, length: 1), "the selection inside the marked text is kept (\(tv.selectedRange()))")
        t.equal(host.styler.editRestyles, r0, "no restyle is applied while composing")
        // scrolling / styling requests during composition do nothing to the marked text
        host.styler.styleVisible()
        t.check(tv.hasMarkedText() && ns().substring(with: tv.markedRange()) == "にほん", "styleVisible() during composition leaves the marked text alone")
        grouped { tv.insertText("日本", replacementRange: tv.markedRange()) }            // commit (the candidate chosen)
        await t.spin(10)
        t.check(!tv.hasMarkedText(), "committed")
        t.equal(ns().substring(with: NSRange(location: headingEnd, length: 2)), "日本", "the committed text is in the document")
        t.equal(t.fontOf(tv, at: 3)?.pointSize, host.theme.headingSize(1), "after the commit the heading is styled again (H1 size)")
        AuditEd.logMismatches(t, host, "after the commit: styled == fresh lex")
        t.check(AuditEd.unfixedFonts(host).isEmpty && AuditEd.missingGlyphs(host).isEmpty, "the committed CJK text has its fallback font and renders (no missing glyphs)")
        t.check(AuditEd.visibleLayoutMismatch(host) == nil, "the visible layout == fresh layout after the commit")

        // ---- 2. composition that changes the block structure when committed: "```" typed through the IME at a line start
        let pos = ns().range(of: "last line").location
        tv.setSelectedRange(NSRange(location: pos, length: 0))
        grouped { tv.setMarkedText("```", selectedRange: NSRange(location: 3, length: 0), replacementRange: none) }
        grouped { tv.insertText("```\n", replacementRange: tv.markedRange()) }
        await t.spin(10)
        host.styler.styleVisible()
        AuditEd.logMismatches(t, host, "a fence committed through the IME opens a code block: styled == fresh lex")
        AuditEd.undo(host)
        t.equal(tv.string, ns().replacingCharacters(in: NSRange(location: 0, length: 0), with: "") as String, "(undo ran)")

        // ---- 3. composition, scroll away (far below), scroll back, commit
        let big = SelfTestCorpus.markdown(bytes: 300_000, seed: 14)
        let (doc2, h2, _) = try await openEditor(t, text: big, name: "ime2.md", size: NSSize(width: 860, height: 600))
        let tv2 = h2.textView
        t.scrollToTop(h2, character: 100_000)
        let loc = h2.styler.visibleCharacterRange(tv2).location + 40
        tv2.setSelectedRange(NSRange(location: loc, length: 0))
        grouped2(tv2) { tv2.setMarkedText("한국", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        t.scrollToTop(h2, character: 250_000)               // composition still active somewhere else
        t.scrollToTop(h2, character: 100_000)
        grouped2(tv2) { tv2.insertText("한국어", replacementRange: tv2.markedRange()) }
        await t.spin(10)
        h2.styler.styleVisible()
        AuditEd.logMismatches(t, h2, "composition + scrolling away and back + commit: styled == fresh lex")
        t.check(AuditEd.missingGlyphs(h2).isEmpty && AuditEd.unfixedFonts(h2).isEmpty, "the committed Hangul renders")
        let vis = h2.styler.visibleCharacterRange(tv2)
        t.check(h2.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)), "the visible part is styled after the commit")

        // ---- 4. a font size change in the middle of a composition
        let saved = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = saved }
        tv2.setSelectedRange(NSRange(location: loc + 20, length: 0))
        grouped2(tv2) { tv2.setMarkedText("あい", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let markedBefore = tv2.markedRange()
        EditorPreferences.fontSize = saved + 3
        t.check(tv2.hasMarkedText() && tv2.markedRange() == markedBefore && (tv2.string as NSString).substring(with: tv2.markedRange()) == "あい", "a font size change during composition keeps the marked text and its range (\(tv2.markedRange()))")
        grouped2(tv2) { tv2.insertText("愛", replacementRange: tv2.markedRange()) }
        await t.spin(10)
        h2.styler.styleVisible()
        AuditEd.logMismatches(t, h2, "composition + font size change + commit: styled == fresh lex")
        EditorPreferences.fontSize = saved
        t.close(doc2)

        t.close(doc)

        // ---- 5. an external change arrives while composing (clean document): the composition survives, nothing is lost
        let (doc3, h3, file3) = try await openEditor(t, text: base, name: "ime3.md", size: NSSize(width: 860, height: 600))
        let tv3 = h3.textView
        await t.sleep(1300)                                         // let the open settle (xattr echo)
        tv3.setSelectedRange(NSRange(location: (tv3.string as NSString).range(of: "first paragraph").location, length: 0))
        grouped2(tv3) { tv3.setMarkedText("さ", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        let reloads0 = doc3.stats.silentReloads
        let external = base + "appended by another program\n"
        let tmp = file3.appendingPathExtension("tmp")
        try? external.write(to: tmp, atomically: false, encoding: .utf8)
        await t.sh("mv \(t.q(tmp)) \(t.q(file3))")
        await t.sleep(700)
        t.check(tv3.hasMarkedText() && (tv3.string as NSString).substring(with: tv3.markedRange()) == "さ", "the external change did not cancel or disturb the composition (marked \(tv3.markedRange()))")
        grouped2(tv3) { tv3.insertText("さくら", replacementRange: tv3.markedRange()) }                // commit
        _ = await t.waitFor(4000) { tv3.string.contains("appended by another program") }
        await t.sleep(100)
        t.info("after the commit: syncState \(doc3.syncState), edited \(doc3.isDocumentEdited), reloads \(doc3.stats.silentReloads - reloads0); has さくら: \(tv3.string.contains("さくら")), has the appended line: \(tv3.string.contains("appended by another program"))")
        t.check(tv3.string.contains("さくら"), "the composed text is never lost to the reload")
        t.check(tv3.string.contains("appended by another program"), "the external change is applied once the composition is over (merged with the typed text)")
        t.check(UITrap.alerts.isEmpty, "no alert")
        AuditEd.logMismatches(t, h3, "after composition + external change: styled == fresh lex")
        t.check(AuditEd.unfixedFonts(h3).isEmpty && AuditEd.missingGlyphs(h3).isEmpty, "the composed text renders")
        t.close(doc3)
    }

    @MainActor static func grouped2(_ tv: NSTextView, _ body: () -> Void) {
        let um = tv.undoManager
        um?.beginUndoGrouping(); body(); tv.breakUndoCoalescing(); um?.endUndoGrouping()
    }
}
#endif
