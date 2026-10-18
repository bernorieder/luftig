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
    ]

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
