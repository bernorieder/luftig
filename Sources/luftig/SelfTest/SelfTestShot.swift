#if LUFTIG_SELFTEST
// SelfTestShot.swift - `shot-window` (ON SCREEN, not in `all`): a real window of the app with every pane shown, captured as the window server draws it
// (title bar, frame, shadow), for the README's screenshots. The window's appearance is forced per window, so the system setting is not touched.
//
//   luftig-SelfTest --selftest shot-window --input docs/showcase.md --out docs/screenshots/window-dark.png --appearance dark [--width 1240 --height 820]
//                   [--scroll-to-text "## Lists"] [--scheme id] --workdir=...

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension SelfTestScenarios {
    static let shotScenarios: [SelfTest.Scenario] = [
        .init(name: "shot-window", summary: "(ON SCREEN, tool) a PNG of a real window with every pane: --input f.md --out f.png [--appearance dark|light] [--width W --height H] [--scroll-to-text T] [--scheme id]", run: { t in try await shotWindow(t) }, inAll: false),
        .init(name: "scroll-probe", summary: "(ON SCREEN, tool) types and deletes in a real window and logs every movement of the view: --input f.md [--typewriter] [--line-spacing X] [--padding N] [--font-size N] [--at-text T] [--keys 'aaa<bs><bs><cr>'] [--pause-ms N]", run: { t in try await scrollProbe(t) }, inAll: false),
    ]

    /// Real window, real key events, real time between them (the display cycle runs): after every key the view's scroll position and the caret's line on screen
    /// are logged, and every move of the view while the caret's line did not change is reported. For the report "the text scrolls up or jumps to the middle while
    /// writing, particularly on Backspace".
    @MainActor static func scrollProbe(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest scroll-probe --input f.md [--typewriter] [--line-spacing X] [--padding N] [--font-size N] [--at-text T] [--keys 'aaa<bs><cr>'] [--pause-ms N]"); return }
        let keys = SelfTest.argument("keys") ?? "hello world<bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><bs><cr>new line<bs><bs><bs><bs><bs><bs><bs><bs><bs>"
        let pause = SelfTest.argument("pause-ms").flatMap { Double($0) } ?? 80
        try await preservingSettings {
            EditorPreferences.showOutline = true; EditorPreferences.showSyntaxBar = true; EditorPreferences.showWordCount = true
            if SelfTest.flag("typewriter") { EditorPreferences.typewriterMode = true }
            if let x = SelfTest.argument("line-spacing").flatMap({ Double($0) }) { EditorPreferences.lineHeightFactor = CGFloat(x) }
            if let n = SelfTest.argument("padding").flatMap({ Double($0) }) { EditorPreferences.padding = CGFloat(n) }
            if let n = SelfTest.argument("font-size").flatMap({ Double($0) }) { EditorPreferences.fontSize = CGFloat(n) }
            let text = try String(contentsOfFile: input, encoding: .utf8)
            let (doc, host, _) = try await openEditor(t, text: text, name: (input as NSString).lastPathComponent, size: NSSize(width: 1100, height: 760))
            defer { t.close(doc) }
            guard let w = doc.windowControllers.first?.window else { t.check(false, "no window"); return }
            w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let tv = host.textView, clip = host.scrollView.contentView, ns = tv.string as NSString
            var start = ns.length / 2
            if let needle = SelfTest.argument("at-text") { let r = ns.range(of: needle); if r.location != NSNotFound { start = r.location + r.length } }
            while start < ns.length && ns.character(at: start) != 0x0A { start += 1 }           // the end of that line
            host.styler.scroll(toCharacter: start)
            await t.spin(300)
            w.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: start, length: 0))
            await t.spin(500)
            @MainActor func caretY() -> CGFloat { (host.caretLineRect(at: tv.selectedRange().location)?.minY ?? -1) + tv.textContainerOrigin.y - clip.bounds.origin.y }
            @MainActor func caretLine() -> CGFloat { host.caretLineRect(at: tv.selectedRange().location)?.minY ?? -1 }
            t.note(String(format: "start: caret at %d, clip y %.0f, caret line at %.0f on screen (viewport %.0f), typewriter %@, spacing %@, inset %.0f", start, clip.bounds.origin.y, caretY(), clip.bounds.height, EditorPreferences.typewriterMode ? "on" : "off", EditorPreferences.lineHeightFactor.map { String(format: "%.2f", Double($0)) } ?? "auto", tv.textContainerInset.height))
            var i = keys.startIndex, n = 0, moves = 0, worst: CGFloat = 0
            while i < keys.endIndex {
                var label: String
                let y0 = clip.bounds.origin.y, line0 = caretLine(), screen0 = caretY()
                if keys[i...].hasPrefix("<bs>") { AuditEd.pressKey(host, AuditEd.Key.delete); label = "Backspace"; i = keys.index(i, offsetBy: 4) }
                else if keys[i...].hasPrefix("<cr>") { AuditEd.pressKey(host, AuditEd.Key.returnKey); label = "Return"; i = keys.index(i, offsetBy: 4) }
                else { let ch = keys[i]; AuditEd.press(host, String(ch), code: 0); label = "'\(ch)'"; i = keys.index(after: i) }
                n += 1
                await t.spin(pause)
                let dy = clip.bounds.origin.y - y0, sameLine = abs(caretLine() - line0) < 0.5
                let dScreen = caretY() - screen0
                if abs(dy) > 0.5 || abs(dScreen) > 0.5 {
                    if sameLine { moves += 1; worst = max(worst, abs(dScreen)) }
                    t.note(String(format: "#%d %@: view %+.0f pt, caret's line %+.0f pt on screen%@ (clip y %.0f, caret line y %.0f, frame h %.0f)", n, label, dy, dScreen, sameLine ? ", SAME line" : ", the line changed", clip.bounds.origin.y, caretLine(), tv.frame.height))
                }
            }
            await t.spin(800)
            t.note(String(format: "end: clip y %.0f, caret line at %.0f on screen; the view moved %d times while the caret's line did not change (worst %.0f pt) over %d keys", clip.bounds.origin.y, caretY(), moves, worst, n))
            t.check(moves == 0, "the view never moved while the caret's line stayed (\(moves) of \(n) keys, worst \(Int(worst)) pt)")
            w.orderOut(nil)
        }
    }

    @MainActor static func shotWindow(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input"), let out = SelfTest.argument("out") else { t.check(false, "usage: --selftest shot-window --input f.md --out f.png [--appearance dark|light] [--width W --height H]"); return }
        let width = SelfTest.argument("width").flatMap { Double($0) } ?? 1240, height = SelfTest.argument("height").flatMap { Double($0) } ?? 820
        try await preservingSettings {
            EditorPreferences.showOutline = true; EditorPreferences.showSyntaxBar = true; EditorPreferences.showWordCount = true; EditorPreferences.showReadingTime = true
            if let id = SelfTest.argument("scheme") { EditorPreferences.colorSchemeID = id }
            let text = try String(contentsOfFile: input, encoding: .utf8)
            let (doc, host, _) = try await openEditor(t, text: text, name: (input as NSString).lastPathComponent, size: NSSize(width: width, height: height))
            defer { t.close(doc) }
            guard let w = doc.windowControllers.first?.window else { t.check(false, "no window"); return }
            w.appearance = NSAppearance(named: SelfTest.argument("appearance") == "light" ? .aqua : .darkAqua)
            w.setContentSize(NSSize(width: width, height: height))
            w.center()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let needle = SelfTest.argument("scroll-to-text"), let r = Optional((host.textView.string as NSString).range(of: needle)), r.location != NSNotFound {
                if let e = OutlineScanner.headings(in: host.textView.string as NSString).first(where: { $0.location == r.location }) { host.jump(toOutlineEntry: e) }
                else { host.textView.scrollRangeToVisible(r) }
            }
            host.textView.setSelectedRange(NSRange(location: 0, length: 0))
            var waited = 0.0
            while host.chromeRefreshPending && waited < 3000 { await t.spin(20); waited += 20 }
            await t.spin(600)                                                       // a few display cycles: the window server has drawn it
            let id = CGWindowID(w.windowNumber)
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else { t.check(false, "the window could not be captured"); return }
            let url = URL(fileURLWithPath: out)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { t.check(false, "no destination"); return }
            CGImageDestinationAddImage(dest, image, nil)
            t.check(CGImageDestinationFinalize(dest), "wrote \(image.width) x \(image.height) px to \(out)")
            w.orderOut(nil)
        }
    }
}
#endif
