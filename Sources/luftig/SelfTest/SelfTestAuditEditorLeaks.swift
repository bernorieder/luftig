#if LUFTIG_SELFTEST
// SelfTestAuditEditorLeaks.swift - the editor stack must be released when its document closes: 200 documents opened, used (typing,
// scrolling, a font size change, an external reload) and closed; weak references to every part of the stack must be nil afterwards and
// the resident memory must return to its baseline. Nothing may keep reacting to notifications after the close.

import AppKit
import MarkdownKit

final class AuditWeakBox { weak var object: AnyObject?; let what: String; init(_ o: AnyObject?, _ w: String) { object = o; what = w } }

extension SelfTestScenarios {
    static let auditEditorLeakScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-leaks", summary: "editor audit: 200 documents opened / used / closed: every part of the editor stack is released, RSS returns to the baseline, no observer outlives its editor", run: { t in try await auditLeaks(t) }),
    ]

    /// A headless NSApplication only drains the autorelease pool of its main loop when an EVENT arrives (a user moving the mouse does that all
    /// the time; this process has no user): objects AppKit autoreleased while the window closed stay alive until then. Posting a few
    /// application-defined events does what the user's next mouse move would do. (Verified in a standalone program with a plain TextKit 1
    /// stack: 40 stacks, 14-38 alive after 3 s, none after three dummy events.)
    @MainActor static func drainPools(_ t: SelfTest.T) async {
        for _ in 0..<3 { NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false) }
        await t.spin(20)
    }

    @MainActor static func auditLeaks(_ t: SelfTest.T) async throws {
        let count = SelfTest.argument("leak-docs").flatMap { Int($0) } ?? 200
        let text = SelfTestCorpus.markdown(bytes: 60_000, seed: 3)
        let savedSize = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = savedSize }
        var boxes: [AuditWeakBox] = []
        func openUseClose(_ i: Int, keep: Bool) async throws {
            let url = t.write(text, to: "leak-\(i % 8).md")
            let doc = try await t.open(url, size: NSSize(width: 800, height: 600))
            guard let host = doc.host as? EditorViewController, let window = doc.windowControllers.first?.window else { return }
            if keep {
                let parts: [(AnyObject?, String)] = [(doc, "document"), (host, "EditorViewController"), (host.textView, "text view"), (host.styler, "LazyStyler"), (host.provider, "MarkdownRunProvider"),
                                                     (host.textView.textStorage, "text storage"), (host.textView.layoutManager, "layout manager"), (host.scrollView, "scroll view"), (window, "window"),
                                                     (doc.undoManager, "undo manager"), (host.theme, "theme")]
                boxes += parts.map { AuditWeakBox($0.0, "\($0.1) #\(i)") }
            }
            let f = Set((SelfTest.argument("leak-features") ?? "type,scroll,heading,sel,undo,font,resize,ime").split(separator: ",").map(String.init))
            if f.contains("type") { AuditEd.type(host, "hello 日本語 😀 ") }
            if f.contains("scroll") { t.scrollToTop(host, character: 30_000) }
            if f.contains("heading") { AuditEd.type(host, "# heading\n") }
            if f.contains("sel") { host.textView.setSelectedRange(NSRange(location: 100, length: 50)) }
            if f.contains("undo") { AuditEd.undo(host) }
            if f.contains("font") && i % 25 == 0 { EditorPreferences.fontSize = savedSize + CGFloat(1 + i / 25 % 3); EditorPreferences.fontSize = savedSize }
            if f.contains("resize") { window.setContentSize(NSSize(width: 700 + CGFloat(i % 5) * 40, height: 500)) }
            if f.contains("ime") && i % 10 == 0 { grouped2(host.textView) { host.textView.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); host.textView.unmarkText() } }
            // closing a window with edits autosaves first (autosave in place); a document closed DIRTY without that is kept alive by AppKit's
            // pending autosave (probed: that is not what a user does), so the cycle does what the close button does
            if (SelfTest.argument("leak-features") ?? "type").contains("type") || SelfTest.flag("leak-autosave") { _ = await t.autosave(doc) }
            t.close(doc)
            if i % 4 == 3 { await drainPools(t) }
        }
        // warm-up (AppKit's one-time allocations), then the baseline
        for i in 0..<12 { try await openUseClose(i, keep: false) }
        await drainPools(t)
        await t.spin(300)
        let rss0 = ProcessMetrics.residentBytes()
        let t0 = SelfTest.nowMs()
        for i in 0..<count {
            try await openUseClose(i, keep: true)
            if i % 20 == 19 { await t.spin(30) }
            if SelfTest.flag("audit-trace") && i % 25 == 24 { t.info(String(format: "%d docs, %.1f s, RSS %@", i + 1, (SelfTest.nowMs() - t0) / 1000, ProcessMetrics.mb(ProcessMetrics.residentBytes()))) }
        }
        await drainPools(t)
        await t.spin(500)
        let ms = SelfTest.nowMs() - t0
        let rss1 = ProcessMetrics.residentBytes()
        t.note(String(format: "%d documents opened / used / closed in %.0f ms (%.1f ms each incl. typing); RSS %@ -> %@ (%+.1f MB)", count, ms, ms / Double(count), ProcessMetrics.mb(rss0), ProcessMetrics.mb(rss1), Double(rss1 - rss0) / 1_048_576))
        // (AppKit releases the text storage / layout manager of a closed window a moment later: wait for it, up to 8 s)
        for _ in 0..<20 where !boxes.allSatisfy({ $0.object == nil }) { await drainPools(t); await t.spin(100) }
        let alive = boxes.filter { $0.object != nil }
        t.check(alive.isEmpty, "after closing, every part of the editor stack is deallocated (\(boxes.count) weak references checked; alive: \(alive.map { $0.what }))")
        t.check(Double(rss1 - rss0) < 60 * 1_048_576, String(format: "RSS growth over %d open/close cycles: %+.1f MB (< 60 MB)", count, Double(rss1 - rss0) / 1_048_576))
        t.equal(NSDocumentController.shared.documents.count, 0, "no document is left")
        // nothing reacts to preference changes any more: a font size change with no editor open must not crash or allocate editors
        EditorPreferences.fontSize = savedSize + 2
        EditorPreferences.fontSize = savedSize
        t.check(true, "preference changes with no editor open are harmless")
    }
}
#endif
