#if LUFTIG_SELFTEST
// SelfTestAuditEditorAppearance.swift - appearance and environment changes at RUNTIME: the same window switched light -> dark (and
// high contrast / vibrant) must look exactly like a window that was dark from the start (no stale cached colours, decorations palette
// resolved per appearance), font size at the extremes, readable-width toggle and live resizing while text is being styled.

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorAppearanceScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-appearance", summary: "editor audit: window.appearance switched at runtime == fresh window (pixel compare), high contrast / vibrant, font size 9...40, readable width + resize while styling", run: { t in try await auditAppearance(t) }),
    ]

    /// RGBA bytes of the window's content view (device pixels).
    @MainActor static func pixels(_ window: NSWindow) -> (w: Int, h: Int, data: [UInt8])? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, data)
    }

    /// Number of pixels that differ by more than `tolerance` in any channel, and the bounding box (in pixels) of the differences.
    static func pixelDiff(_ a: (w: Int, h: Int, data: [UInt8]), _ b: (w: Int, h: Int, data: [UInt8]), tolerance: Int = 2) -> (count: Int, box: String) {
        guard a.w == b.w, a.h == b.h else { return (-1, "size \(a.w)x\(a.h) vs \(b.w)x\(b.h)") }
        var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<a.h { for x in 0..<a.w {
            let i = (y * a.w + x) * 4
            if abs(Int(a.data[i]) - Int(b.data[i])) > tolerance || abs(Int(a.data[i + 1]) - Int(b.data[i + 1])) > tolerance || abs(Int(a.data[i + 2]) - Int(b.data[i + 2])) > tolerance {
                count += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        } }
        return (count, count == 0 ? "-" : "x \(minX)...\(maxX), y \(minY)...\(maxY)")
    }

    @MainActor static func auditAppearance(_ t: SelfTest.T) async throws {
        let showcase = SelfTestCorpus.markdown(bytes: 30_000, seed: 5) + "\n> quote with `inline code` and a [link](https://example.com)\n\n```swift\nlet x = 1 // code band\n```\n\n- [x] done\n- [ ] todo\n\n---\n"
        let size = NSSize(width: 860, height: 700)
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua), ("light, increased contrast", .accessibilityHighContrastAqua), ("dark, increased contrast", .accessibilityHighContrastDarkAqua), ("vibrant dark", .vibrantDark), ("vibrant light", .vibrantLight)]
        let (docA, a, _) = try await openEditor(t, text: showcase, name: "ap-a.md", size: size)
        guard let winA = docA.windowControllers.first?.window else { t.check(false, "no window"); return }
        // The window under test goes through ALL appearances in turn; for each one a FRESH document / window is created, put in that
        // appearance from the start and rendered: the two must be pixel-identical.
        var previous: (w: Int, h: Int, data: [UInt8])? = nil
        for (i, (label, name)) in appearances.enumerated() {
            winA.appearance = NSAppearance(named: name)
            a.styler.styleVisible()
            guard let pa = pixels(winA) else { t.check(false, "render failed"); continue }
            let (docB, b, _) = try await openEditor(t, text: showcase, name: "ap-b\(i).md", size: size)
            guard let winB = docB.windowControllers.first?.window else { continue }
            winB.appearance = NSAppearance(named: name)
            b.styler.styleVisible()
            guard let pb = pixels(winB) else { t.check(false, "render failed"); continue }
            let diff = pixelDiff(pa, pb)
            t.check(diff.count == 0, "\(label): the window switched at runtime is pixel-identical to a fresh window in that appearance (\(diff.count) pixels differ, \(diff.box))")
            if let prev = previous { let d2 = pixelDiff(prev, pa, tolerance: 0); t.check(d2.count > 1000 || label.contains("vibrant") || label.contains("increased"), "\(label): differs from the previous appearance (\(d2.count) px) - the switch is visible") }
            previous = pa
            // decoration palette resolves for the effective appearance of the text view
            let eff = a.textView.effectiveAppearance
            let isDark = eff.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let cols = DecorationDrawing.Colors(appearance: eff)
            // the code band is an OPAQUE colour: the translucent tint of the palette composited over the page colour of that appearance
            let ref = NSAppearance(named: isDark ? .darkAqua : .aqua)!
            let band = Contrast.rgba(Palette.codeBand, appearance: ref), page = Contrast.rgba(Palette.background, appearance: ref)
            let expectedRed = band.r * band.a + page.r * (1 - band.a)
            let got = NSColor(cgColor: cols.codeBand)?.usingColorSpace(.sRGB)
            t.check(got != nil && abs(Double(got!.redComponent) - expectedRed) < 0.01 && abs(Double(got!.alphaComponent) - 1) < 0.01, "\(label): decoration colours follow the text view's effective appearance (\(isDark ? "dark" : "light") palette)")
            // text colours of the styled runs resolve for the appearance (labelColor etc. are dynamic: compare with a fresh resolution)
            let ts = a.textView.textStorage!
            a.styler.styleEverything()
            let c = ts.attribute(.foregroundColor, at: (ts.string as NSString).range(of: "quote with").location, effectiveRange: nil) as? NSColor
            let resolved = c.map { Contrast.rgba($0, appearance: eff) }
            let expectedQuote = Contrast.rgba(Palette.quoteText, appearance: NSAppearance(named: isDark ? .darkAqua : .aqua)!)
            t.check(resolved != nil && abs(resolved!.r - expectedQuote.r) < 0.01, "\(label): quote text colour resolves to the \(isDark ? "dark" : "light") value (\(String(describing: resolved)) vs \(expectedQuote); attribute \(String(describing: c)); char at \((ts.string as NSString).range(of: "quote with").location))")
            t.close(docB)
        }
        // link underline colour keeps its dynamic behaviour (withAlphaComponent on a dynamic colour)
        let lightU = Contrast.rgba(Palette.linkUnderline, appearance: NSAppearance(named: .aqua)!), darkU = Contrast.rgba(Palette.linkUnderline, appearance: NSAppearance(named: .darkAqua)!)
        t.check(abs(lightU.b - darkU.b) > 0.05 || abs(lightU.r - darkU.r) > 0.05, "link underline colour differs between light and dark (still dynamic): light \(lightU) dark \(darkU)")
        winA.appearance = nil
        t.close(docA)

        // ---- font size at the extremes, repeatedly, with styled and unstyled text; the layout stays valid
        let saved = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = saved }
        let (docF, f, _) = try await openEditor(t, text: SelfTestCorpus.markdown(bytes: 400_000, seed: 12), name: "ap-f.md", size: size)
        t.scrollToTop(f, character: 150_000)
        var maxStep = 0.0
        for round in 0..<2 {
            for _ in 0..<40 { let t0 = SelfTest.nowMs(); f.luftigIncreaseFontSize(nil); maxStep = max(maxStep, SelfTest.nowMs() - t0) }
            t.equal(f.fontSize, EditorPreferences.fontSizeRange.upperBound, "round \(round): 40x Bigger stops at \(EditorPreferences.fontSizeRange.upperBound)")
            t.check(!f.validateMenuItem(NSMenuItem(title: "Bigger", action: #selector(EditorViewController.luftigIncreaseFontSize(_:)), keyEquivalent: "")), "round \(round): Bigger is disabled at the maximum")
            f.styler.styleVisible()
            AuditEd.logMismatches(t, f, "round \(round): at \(f.fontSize) pt, styled == fresh lex")
            t.check(AuditEd.visibleLayoutMismatch(f) == nil, "round \(round): at \(f.fontSize) pt the visible layout == fresh layout")
            for _ in 0..<40 { let t0 = SelfTest.nowMs(); f.luftigDecreaseFontSize(nil); maxStep = max(maxStep, SelfTest.nowMs() - t0) }
            t.equal(f.fontSize, EditorPreferences.fontSizeRange.lowerBound, "round \(round): 40x Smaller stops at \(EditorPreferences.fontSizeRange.lowerBound)")
            f.styler.styleVisible()
            AuditEd.logMismatches(t, f, "round \(round): at \(f.fontSize) pt, styled == fresh lex")
            t.check(AuditEd.visibleLayoutMismatch(f) == nil, "round \(round): at \(f.fontSize) pt the visible layout == fresh layout")
        }
        t.note(String(format: "slowest single font-size step in a 400 KB document: %.1f ms", maxStep))
        // text typed at the extreme sizes is styled with the new theme
        EditorPreferences.fontSize = EditorPreferences.fontSizeRange.upperBound
        t.typeText("# big heading\n", into: docF, at: NSRange(location: 0, length: 0))
        t.equal(t.fontOf(f.textView, at: 3)?.pointSize, f.theme.headingSize(1), "typed heading at \(f.fontSize) pt is H1 \(f.theme.headingSize(1)) pt")
        EditorPreferences.fontSize = saved

        // ---- readable width toggled and the window resized while there is unstyled text around
        let savedRW = EditorPreferences.readableWidth
        defer { EditorPreferences.readableWidth = savedRW }
        EditorPreferences.readableWidth = true
        guard let winF = docF.windowControllers.first?.window else { return }
        for step in 0..<30 {
            let w = CGFloat(380 + (step * 97) % 900)
            winF.setContentSize(NSSize(width: w, height: 400 + CGFloat(step % 5) * 120))
            if step % 3 == 0 { f.luftigToggleReadableWidth(nil) }
            if step % 7 == 0 { t.scrollToTop(f, character: (step * 13_001) % 390_000) }
            winF.contentView?.layoutSubtreeIfNeeded()
        }
        f.styler.styleVisible()
        AuditEd.logMismatches(t, f, "after 30 resizes / readable-width toggles: styled == fresh lex")
        t.check(AuditEd.visibleLayoutMismatch(f) == nil, "after 30 resizes / readable-width toggles: the visible layout == fresh layout")
        let inset = f.textView.textContainerInset.width
        t.check(inset >= DecorationMetrics.bandOutset + 1, "the text container inset (\(inset)) always leaves room for the decoration outset")
        t.close(docF)
    }
}
#endif
