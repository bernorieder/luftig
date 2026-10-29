#if LUFTIG_SELFTEST
// SelfTestRoomBelow.swift - room-below: outside Typewriter Mode the text can be scrolled past its end, by 60 % of the window's height, so that the
// last line can sit in the middle of the window while one writes (ReadableColumnController.roomBelow, LuftigEditorTextView.insetOnlyBelow). The first
// line stays at the top; clicks, the caret and the decorations use the same origin as the glyphs; Typewriter Mode keeps its own (symmetric) insets.

import AppKit

extension SelfTestScenarios {
    static let roomBelowScenarios: [SelfTest.Scenario] = [
        .init(name: "room-below", summary: "the end of the text scrolls up to the middle of the window (60 % room below the last line), the first line stays at the top, clicks and the caret agree, Typewriter Mode unchanged", run: { t in try await roomBelow(t) }),
    ]

    @MainActor static func roomBelow(_ t: SelfTest.T) async throws {
        let typewriter = EditorPreferences.typewriterMode
        EditorPreferences.typewriterMode = false
        defer { EditorPreferences.typewriterMode = typewriter }
        let text = (1...80).map { "Paragraph \($0) of the text, long enough to be a line." }.joined(separator: "\n\n") + "\n\nThe last line.\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "room.md", size: NSSize(width: 900, height: 700))
        await t.spin(30)
        let tv = host.textView, clip = host.scrollView.contentView
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { t.check(false, "no layout"); return }
        lm.ensureLayout(for: tc)
        tv.sizeToFit()
        let used = lm.usedRect(for: tc).height
        let room = tv.frame.height - used
        t.equal(tv.textContainerOrigin.y, 0, "the first line is at the top (no room above it)")
        t.check(abs(room - clip.bounds.height * ReadableColumnController.roomBelowShare) < 2, "the text view holds 60 % of the window below the text (\(Int(room)) pt for a \(Int(clip.bounds.height)) pt window)")
        // scrolled to the very end: the last line sits a little above the middle
        clip.scroll(to: NSPoint(x: 0, y: tv.frame.height - clip.bounds.height))
        host.scrollView.reflectScrolledClipView(clip)
        host.styler.styleVisible()
        let last = (tv.string as NSString).range(of: "The last line.").location
        lm.ensureLayout(forCharacterRange: NSRange(location: last, length: 1))
        let lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: last), effectiveRange: nil)
        let lineY = lineRect.minY + tv.textContainerOrigin.y - clip.bounds.minY
        t.check(lineY > clip.bounds.height * 0.3 && lineY < clip.bounds.height * 0.5, "scrolled to the end: the last line is just above the middle of the window (\(Int(lineY)) of \(Int(clip.bounds.height)) pt)")
        // the glyphs, a click and the caret use the same origin
        let glyph = lm.glyphIndexForCharacter(at: last + 4)
        let gr = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        let point = NSPoint(x: gr.midX + tv.textContainerOrigin.x - 2, y: gr.midY + tv.textContainerOrigin.y)
        t.equal(tv.characterIndexForInsertion(at: point), last + 4, "a click on a character puts the caret at it")
        // typing at the end of a document scrolled there does not move the view
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 1, length: 0))
        let before = clip.bounds.minY
        t.typeText(" More.", into: doc, at: tv.selectedRange())
        await t.spin(20)
        t.check(abs(clip.bounds.minY - before) < 1, "typing at the end with the view scrolled there: the view stays (\(Int(before)) -> \(Int(clip.bounds.minY)))")
        // Typewriter Mode: its own symmetric insets; off again: the room below
        EditorPreferences.typewriterMode = true
        await t.spin(30)
        t.check(tv.textContainerOrigin.y > 100 && abs(tv.textContainerOrigin.y - tv.textContainerInset.height) < 0.5, "Typewriter Mode: room above the first line as before (\(Int(tv.textContainerOrigin.y)) pt)")
        EditorPreferences.typewriterMode = false
        await t.spin(30)
        t.equal(tv.textContainerOrigin.y, 0, "Typewriter Mode off: the first line at the top again")
        t.close(doc)
    }
}
#endif
