#if LUFTIG_SELFTEST
// SelfTestRender.swift - `--selftest render`: a PNG of the REAL editor window (real document class, window, text view, lazy
// styler, decorations) for visual review, without ever putting a window on screen.
//
//   luftig-SelfTest --selftest render --input f.md --out f.png [--appearance dark|light] [--width 860 --height 1000]
//                   [--scroll-to-char N | --scroll-to-text TEXT] [--select A:B | --select-text FROM:TO] [--active-selection] [--font-size N] [--no-readable-width]
//                   [--conflict] [--type-first "text"] [--scheme ID] [--body-font F] [--code-font F] [--line-spacing X] [--column-width W]
//
// The input is COPIED to the work directory first (opening a document touches xattrs and could autosave): the original is
// never opened. `--conflict` reproduces the real "file changed on disk while you have unsaved edits" state (type, rewrite the
// file from outside, wait for the banner) so the banner can be reviewed too.

import AppKit

extension SelfTest {
    /// `--name value` or `--name=value` from the command line.
    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        if let a = args.first(where: { $0.hasPrefix("--\(name)=") }) { return String(a.dropFirst(name.count + 3)) }
        if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
        return nil
    }
    static func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--\(name)") }
    /// `--appearance light|dark`. With Increase contrast: `--increase-contrast` (the palette follows the system flag, see `ContrastWatcher`).
    static func appearanceName(_ s: String?) -> NSAppearance.Name { s == "dark" ? .darkAqua : .aqua }
}

extension SelfTest.T {

    /// Scroll so that character `location` is at the top of the viewport (after styling its surroundings).
    func scrollToTop(_ host: EditorViewController, character location: Int) {
        let tv = host.textView
        host.styler.prestyle(aroundCharacter: location)
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let len = (tv.string as NSString).length
        let loc = min(max(0, location), max(0, len - 1))
        lm.ensureLayout(forCharacterRange: NSRange(location: max(0, loc - 3000), length: min(len, loc + 6000) - max(0, loc - 3000)))
        let glyph = lm.glyphIndexForCharacter(at: loc)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let sv = host.scrollView
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + tv.textContainerOrigin.y - 4)))
        sv.reflectScrolledClipView(sv.contentView)
        host.styler.styleVisible()
        _ = tc
    }

    /// The visible part of a text view drawn strip by strip (every strip is its own `draw` with that dirty rect), stitched into one PNG.
    func renderStrippedPNG(_ tv: NSTextView, stripHeight: CGFloat) -> Data? {
        let vis = tv.visibleRect
        guard let full = tv.bitmapImageRepForCachingDisplay(in: vis), let fd = full.bitmapData else { return nil }
        let scale = CGFloat(full.pixelsWide) / vis.width
        var y = vis.minY
        while y < vis.maxY - 0.01 {
            let strip = NSRect(x: vis.minX, y: y, width: vis.width, height: min(stripHeight, vis.maxY - y))
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: strip), let sd = rep.bitmapData else { return nil }
            tv.cacheDisplay(in: strip, to: rep)
            let y0 = Int(((y - vis.minY) * scale).rounded())
            for r in 0..<rep.pixelsHigh where y0 + r < full.pixelsHigh {
                memcpy(fd + (y0 + r) * full.bytesPerRow, sd + r * rep.bytesPerRow, min(rep.bytesPerRow, full.bytesPerRow))
            }
            y += stripHeight
        }
        return full.representation(using: .png, properties: [:])
    }

    /// Renders the window's content view (banner + editor) to PNG data. Selection is drawn inactive-grey (the window is never key)
    /// unless the caller switched the text view to the active selection colours.
    func renderPNG(_ window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

extension SelfTestScenarios {
    static let renderScenarios: [SelfTest.Scenario] = [
        .init(name: "render", summary: "PNG of the real editor window: --input f.md --out f.png [--appearance dark|light] [--width W --height H] [--scroll-to-char N] ...",
              run: { t in try await render(t) }, inAll: false),
    ] + visualScenarios

    @MainActor static func render(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input"), let out = SelfTest.argument("out") else {
            t.check(false, "usage: --selftest render --input f.md --out f.png [--appearance dark|light] [--width W --height H] [--scroll-to-char N | --scroll-to-text TEXT] [--select A:B | --select-text FROM:TO] [--active-selection] [--font-size N] [--no-readable-width] [--conflict] [--scheme ID] [--body-font F] [--code-font F] [--line-spacing X] [--column-width W]")
            return
        }
        let width = Double(SelfTest.argument("width") ?? "") ?? 860, height = Double(SelfTest.argument("height") ?? "") ?? 1000
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let copy = t.write(data: data, to: "render-input.md")
        let savedSize = EditorPreferences.fontSize, savedReadable = EditorPreferences.readableWidth
        defer { EditorPreferences.fontSize = savedSize; EditorPreferences.readableWidth = savedReadable }
        // `--scheme ID`: render with a colour scheme (ColorSchemes.all lists the ids). A fixed scheme forces the light or dark appearance of the whole app,
        // so `--appearance` is ignored for it; the default scheme ("luftig") follows `--appearance` as always.
        let schemeID = SelfTest.argument("scheme")
        if let id = schemeID {
            if ColorSchemes.all.contains(where: { $0.id == id }) { Palette.apply(schemeID: id) } else { t.check(false, "--scheme: unknown scheme \(id.debugDescription); known: \(ColorSchemes.all.map { $0.id }.joined(separator: ", "))"); return }
        }
        defer { Palette.apply(schemeID: ColorSchemes.defaultID) }
        if let fs = SelfTest.argument("font-size"), let v = Double(fs) { EditorPreferences.fontSize = CGFloat(v) }
        if SelfTest.flag("no-readable-width") { EditorPreferences.readableWidth = false }
        if let p = SelfTest.argument("padding"), let v = Double(p) { EditorPreferences.padding = CGFloat(v) }      // --padding 0.5 ... 2
        // the Settings window's other controls (the runner starts from the defaults and a scenario puts back what it changed)
        let savedBody = EditorPreferences.bodyFontFamily, savedCode = EditorPreferences.codeFontFamily
        let savedSpacing = EditorPreferences.lineHeightFactor, savedColumn = EditorPreferences.columnWidth
        defer {
            EditorPreferences.bodyFontFamily = savedBody; EditorPreferences.codeFontFamily = savedCode
            EditorPreferences.lineHeightFactor = savedSpacing; EditorPreferences.columnWidth = savedColumn
        }
        if let f = SelfTest.argument("body-font") { EditorPreferences.bodyFontFamily = f }
        if let f = SelfTest.argument("code-font") { EditorPreferences.codeFontFamily = f }
        if let v = SelfTest.argument("line-spacing").flatMap({ Double($0) }) { EditorPreferences.lineHeightFactor = CGFloat(v) }
        if let v = SelfTest.argument("column-width").flatMap({ Double($0) }) { EditorPreferences.columnWidth = CGFloat(v) }

        let doc = try await t.open(copy, size: NSSize(width: width, height: height))
        guard let host = doc.host as? EditorViewController, let window = doc.windowControllers.first?.window else { t.check(false, "no editor"); return }
        window.appearance = Palette.isSystemScheme ? NSAppearance(named: SelfTest.appearanceName(SelfTest.argument("appearance"))) : nil
        if SelfTest.flag("increase-contrast") { ContrastWatcher.shared.override = true }
        defer { ContrastWatcher.shared.override = nil }
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.layoutSubtreeIfNeeded()
        let tv = host.textView

        if let first = SelfTest.argument("type-first") {
            t.typeText(first, into: doc, at: NSRange(location: 0, length: 0))
        }
        if SelfTest.flag("conflict") {
            // the real thing: unsaved edit in the first paragraph, then another tool rewrites that paragraph
            let s = tv.string as NSString
            let r = s.range(of: "\n\n")
            let firstPara = NSRange(location: 0, length: r.location == NSNotFound ? min(s.length, 40) : r.location)
            t.typeText("My unsaved rewrite of the first paragraph.", into: doc, at: firstPara)
            await t.sleep(30)
            let theirs = (try? String(contentsOf: copy, encoding: .utf8)) ?? ""
            let replaced = (theirs as NSString).replacingCharacters(in: NSRange(location: 0, length: min((theirs as NSString).length, firstPara.length)), with: "Another tool rewrote the same paragraph.")
            let tmp = copy.appendingPathExtension("tmp")
            try replaced.write(to: tmp, atomically: false, encoding: .utf8)
            await t.sh("mv \(t.q(tmp)) \(t.q(copy))")
            let ok = await t.waitFor(4000) { doc.syncState == .conflict }
            t.check(ok, "conflict state reached (banner: \(host.bannerText))")
        }
        if let loc = SelfTest.argument("scroll-to-char").flatMap({ Int($0) }) { t.scrollToTop(host, character: loc) }
        if let needle = SelfTest.argument("scroll-to-text") {                // the first occurrence of a piece of text (a heading), instead of a hand-counted offset
            let r = (tv.string as NSString).range(of: needle)
            if r.location == NSNotFound { t.check(false, "--scroll-to-text: \(needle.debugDescription) not found") } else { t.scrollToTop(host, character: r.location) }
        }
        if let pair = SelfTest.argument("select-text") {                      // "FROM:TO": from the start of the first FROM to the start of the first TO after it
            let parts = pair.components(separatedBy: ":")
            let s = tv.string as NSString
            let a = parts.count == 2 ? s.range(of: parts[0]) : NSRange(location: NSNotFound, length: 0)
            let b = a.location == NSNotFound ? a : s.range(of: parts[1], options: [], range: NSRange(location: a.location, length: s.length - a.location))
            if a.location == NSNotFound || b.location == NSNotFound { t.check(false, "--select-text: need FROM:TO, both present") }
            else { tv.setSelectedRange(NSRange(location: a.location, length: b.location - a.location)) }
        }
        if let sel = SelfTest.argument("select") {
            let p = sel.split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { tv.setSelectedRange(NSRange(location: p[0], length: p[1] - p[0])) }
        }
        if SelfTest.flag("active-selection") {
            // the offscreen window is never key: paint the selection the way a key window does (see LuftigLayoutManager.fillBackgroundRectArray)
            tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
            LuftigLayoutManager.simulateActiveSelection = true
        }
        defer { LuftigLayoutManager.simulateActiveSelection = false }
        host.styler.styleVisible()
        _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
        tv.needsDisplay = true
        // `--strip-height H`: the text view's visible part drawn in strips of H points, one `draw` call each, stitched together: what AppKit paints
        // while scrolling (only the newly exposed strip) and when the caret blinks. Without the option: one full draw of the whole window.
        let stripped = SelfTest.argument("strip-height").flatMap { Double($0) }.flatMap { t.renderStrippedPNG(tv, stripHeight: CGFloat($0)) }
        guard let png = stripped ?? t.renderPNG(window) else { t.check(false, "could not render"); return }
        try png.write(to: URL(fileURLWithPath: out))
        t.check(true, "rendered \(Int(width)) x \(Int(height)) pt (\(Palette.isSystemScheme ? (SelfTest.argument("appearance") ?? "light") : "scheme " + Palette.scheme.id)) -> \(out) (\(png.count / 1024) KB, \(host.styler.styled.count) styled units, scroll y \(Int(host.scrollView.contentView.bounds.origin.y)))")
        t.close(doc)
    }
}
#endif
