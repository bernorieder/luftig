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
        .init(name: "schemes-dump", summary: "(tool) every built-in scheme's colours as the editor uses them (after the legibility step; the default in light and dark), one JSON object per line: --out f.jsonl", run: { t in try await schemesDump(t) }, inAll: false),
        .init(name: "scroll-probe", summary: "(ON SCREEN, tool) types and deletes in a real window and logs every movement of the view: --input f.md [--typewriter] [--line-spacing X] [--padding N] [--font-size N] [--at-text T] [--keys 'aaa<bs><bs><cr>'] [--pause-ms N]", run: { t in try await scrollProbe(t) }, inAll: false),
    ]

    /// The colours of every built-in scheme for docs/site/schemes.svg (Scripts/make-schemes-svg.py): page, text, markers, headings, accent, links, inline code and
    /// its pill, the quote band and bar, all composited over the page (opaque hex).
    @MainActor static func schemesDump(_ t: SelfTest.T) async throws {
        guard let out = SelfTest.argument("out") else { t.check(false, "usage: --selftest schemes-dump --out f.jsonl"); return }
        let saved = EditorPreferences.colorSchemeID
        defer { Palette.apply(schemeID: saved) }
        typealias C = (r: Double, g: Double, b: Double, a: Double)
        func over(_ top: C, _ base: C) -> C { (top.r * top.a + base.r * (1 - top.a), top.g * top.a + base.g * (1 - top.a), top.b * top.a + base.b * (1 - top.a), 1) }
        func hex(_ c: C) -> String { String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        var entries: [(id: String, name: String, scheme: String, dark: Bool)] = [(ColorSchemes.defaultID, "luftig", ColorSchemes.defaultID, false), (ColorSchemes.defaultID + "-dark", "luftig (dark)", ColorSchemes.defaultID, true)]
        entries += SchemeSpec.all.map { ($0.id, $0.name, $0.id, $0.dark) }
        var lines: [String] = []
        for e in entries {
            Palette.apply(schemeID: e.scheme)
            let ap = NSAppearance(named: e.dark ? .darkAqua : .aqua)!
            func c(_ col: NSColor) -> C { let v = Contrast.rgba(col, appearance: ap); return (v.r, v.g, v.b, v.a) }
            let bg = over(c(Palette.background), (1, 1, 1, 1))
            let quote = over(c(Palette.quoteBand), bg)
            let fields: [(String, String)] = [
                ("bg", hex(bg)), ("text", hex(over(c(Palette.text), bg))), ("marker", hex(over(c(Palette.marker), bg))), ("heading", hex(over(c(Palette.heading), bg))),
                ("accent", hex(over(c(Palette.accent), bg))), ("link", hex(over(c(Palette.link), bg))), ("code", hex(over(c(Palette.copper), bg))),
                ("pill", hex(over(c(Palette.inlinePill), bg))), ("quote", hex(quote)), ("bar", hex(over(c(Palette.quoteBar), quote))),
                ("quoteText", hex(over(c(Palette.quoteText), quote))),
            ]
            let body = fields.map { "\"\($0.0)\": \"\($0.1)\"" }.joined(separator: ", ")
            lines.append("{\"id\": \"\(e.id)\", \"name\": \"\(e.name)\", \"dark\": \(e.dark), \(body)}")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        t.check(lines.count == entries.count, "wrote \(lines.count) schemes to \(out)")
    }

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
            // --trace: the call stack of the first scroll after each key (who moves the view)
            var traces: [String] = []
            var armed = false
            let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { _ in
                guard armed, SelfTest.flag("trace") else { return }
                armed = false
                let symbols = Thread.callStackSymbols.prefix(44).map { line -> String in
                    // "3   AppKit   0x000... -[NSClipView scrollToPoint:] + 123" -> "AppKit -[NSClipView scrollToPoint:]"
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 4 else { return line }
                    return parts[1] + " " + parts[3...].dropLast(2).joined(separator: " ")
                }
                traces.append(symbols.joined(separator: "\n        "))
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            var i = keys.startIndex, n = 0, moves = 0, worst: CGFloat = 0
            while i < keys.endIndex {
                var label: String
                let y0 = clip.bounds.origin.y, line0 = caretLine(), screen0 = caretY()
                armed = true; traces.removeAll()
                if keys[i...].hasPrefix("<bs>") { AuditEd.pressKey(host, AuditEd.Key.delete); label = "Backspace"; i = keys.index(i, offsetBy: 4) }
                else if keys[i...].hasPrefix("<cr>") { AuditEd.pressKey(host, AuditEd.Key.returnKey); label = "Return"; i = keys.index(i, offsetBy: 4) }
                else { let ch = keys[i]; AuditEd.press(host, String(ch), code: 0); label = "'\(ch)'"; i = keys.index(after: i) }
                n += 1
                await t.spin(pause)
                let dy = clip.bounds.origin.y - y0, sameLine = abs(caretLine() - line0) < 0.5
                if let tr = traces.last, abs(dy) > 0.5 { t.note("    trace of the first scroll after #\(n):\n        \(tr)"); traces.removeAll() }
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
