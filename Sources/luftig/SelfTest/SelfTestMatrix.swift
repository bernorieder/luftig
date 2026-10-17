#if LUFTIG_SELFTEST
// SelfTestMatrix.swift - what no single feature could see: the colour schemes, the fonts / line spacing / column width of the Settings window and the
// hanging list indent TOGETHER. Each feature was built and tested against the defaults of the other two; these scenarios run the existing pixel checks
// under non-default combinations and compare what the user sees in the Settings preview with what an editor shows.
//
//   matrix-visual   the pixel scenarios of the decorations that do not assume the default look (partial redraw == full draw, stale rows after an
//                   edit, the selection) under combinations of scheme x font x size x line spacing x column width. (`visual-bands` and the quote bar
//                   checks of `visual-bands` look for a WHITE page and the default bar colour: they stay default-scheme tests)
//   matrix-indent   hanging list indents (oracle, real layout, random edits) under the same combinations
//   matrix-preview  the Settings preview wraps and paints the sample text exactly as an editor of the same width does (layout and pixels)
//   matrix-print    Print... of a document prints dark text on white paper under a dark colour scheme (the app's appearance is forced to dark)

import AppKit
import CoreGraphics
import MarkdownKit

extension SelfTestScenarios {
    static let matrixScenarios: [SelfTest.Scenario] = [
        .init(name: "matrix-visual", summary: "decorations under scheme x font x size x line spacing x column width: partial redraw == full draw, no stale rows, bands, quote bars, selection", run: { t in try await matrixVisual(t) }),
        .init(name: "matrix-preview", summary: "the Settings preview == an editor of the same width: line fragments and pixels, for several schemes / fonts / spacings / columns", run: { t in try await matrixPreview(t) }),
        .init(name: "matrix-indent", summary: "hanging list indents under non-default fonts (serif, sans, faked bold / italic), fractional sizes and line spacing 1.1 ... 2.0: attributes, real layout, random edits", run: { t in try await matrixIndent(t) }),
        .init(name: "matrix-probe", summary: "(internal) the pixel scenarios of matrix-visual under ONE combination given on the command line: [--scheme id] [--body-font F] [--code-font F] [--font-size N] [--line-spacing X] [--column-width W] [--debug-strips] [--indent]",
              run: { t in try await matrixProbe(t) }, inAll: false),
        .init(name: "matrix-print", summary: "Print... of a document under a dark colour scheme (and a dark system appearance): dark text on a white page", run: { t in try await matrixPrint(t) }),
    ]

    /// One combination of everything the Settings window sets.
    struct MatrixCombo {
        var label: String
        var scheme: String
        var body: [String]            // candidate families in order of preference: the first installed one is used (nil / empty: the system font)
        var code: [String]
        var size: CGFloat
        var factor: CGFloat?
        var column: CGFloat
        /// A family that lacks the semibold / bold faces gets them faked with a stroke (`.strokeWidth`). AppKit draws a stroked glyph with an anti-aliased
        /// edge that a strip touching only that edge does not repaint (measured: a few pixels, 4-10 levels, nothing but glyph ink differs; with the stroke
        /// switched off the partial draw is pixel-identical): the partial-redraw equality is checked for the real faces only.
        var stroked = false
    }

    static let matrixCombos: [MatrixCombo] = [
        .init(label: "default scheme, system fonts, 16 pt, automatic spacing, 760", scheme: ColorSchemes.defaultID, body: [], code: [], size: 16, factor: nil, column: 760),
        .init(label: "dracula (dark), serif body + mono code, 17.5 pt, spacing 2.0, column 480", scheme: "dracula", body: ["Georgia", "Times", "Palatino"], code: ["Menlo", "Courier New"], size: 17.5, factor: 2.0, column: 480),
        .init(label: "solarized-light, sans body, 13.5 pt, spacing 1.1, column 1400", scheme: "solarized-light", body: ["Avenir Next", "Helvetica Neue"], code: ["Courier New", "Menlo"], size: 13.5, factor: 1.1, column: 1400),
        .init(label: "gruvbox-dark, serif body, 24 pt, spacing 1.6, column 600", scheme: "gruvbox-dark", body: ["Palatino", "Georgia"], code: ["Menlo"], size: 24, factor: 1.6, column: 600),
        .init(label: "catppuccin-latte, a family without italic and bold faces (synthetic), 15 pt, spacing 1.3", scheme: "catppuccin-latte", body: ["Papyrus", "Zapfino"], code: ["Monaco"], size: 15, factor: 1.3, column: 760, stroked: true),
    ]

    /// Makes the preferences the combination (the caller wraps this in `preservingSettings`).
    @MainActor static func applyMatrixCombo(_ c: MatrixCombo) {
        let P = EditorPreferences.self
        P.colorSchemeID = c.scheme
        P.bodyFontFamily = installedFamilies(c.body).first
        P.codeFontFamily = installedFamilies(c.code).first
        P.fontSize = c.size
        P.lineHeightFactor = c.factor
        P.columnWidth = c.column
        P.readableWidth = true
    }

    // MARK: matrix-indent

    /// The three hanging-indent scenarios (an independent oracle of the head indent from the stored fonts, the real layout of every continuation fragment, 2 x 1000
    /// random edits against a fresh lex) under every combination: the indent has to follow the family, the size and the spacing the user chose. (The layout
    /// scenario sets its own sizes; the others use the size of the combination.)
    @MainActor static func matrixIndent(_ t: SelfTest.T) async throws {
        for combo in matrixCombos {
            try await preservingSettings {
                applyMatrixCombo(combo)
                t.note("combination: \(combo.label)")
                try await indentAttrs(t)
                try await indentLayout(t)
                try await indentDiff(t)
            }
        }
    }

    // MARK: matrix-visual

    @MainActor static func matrixVisual(_ t: SelfTest.T) async throws {
        for combo in matrixCombos {
            try await preservingSettings {
                applyMatrixCombo(combo)
                t.note("combination: \(combo.label)")
                try await visualRedraw(t)
                if !combo.stroked { try await visualPartial(t) } else { t.note("partial redraw == full draw skipped: faked bold / semibold glyphs (stroke) have an edge a strip may not repaint") }
                try await visualSelection(t)
            }
        }
    }

    @MainActor static func matrixProbe(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            if let id = SelfTest.argument("scheme") { P.colorSchemeID = id }
            if let f = SelfTest.argument("body-font") { P.bodyFontFamily = f }
            if let f = SelfTest.argument("code-font") { P.codeFontFamily = f }
            if let v = SelfTest.argument("font-size").flatMap({ Double($0) }) { P.fontSize = CGFloat(v) }
            if let v = SelfTest.argument("line-spacing").flatMap({ Double($0) }) { P.lineHeightFactor = CGFloat(v) }
            if let v = SelfTest.argument("column-width").flatMap({ Double($0) }) { P.columnWidth = CGFloat(v) }
            t.note("probe: scheme \(P.colorSchemeID), body \(P.bodyFontFamily ?? "system"), code \(P.codeFontFamily ?? "system"), \(P.fontSize) pt, spacing \(P.lineHeightFactor.map { String(describing: $0) } ?? "automatic"), column \(P.columnWidth)")
            if SelfTest.flag("indent") { try await indentAttrs(t); try await indentLayout(t); return }
            try await visualRedraw(t)
            try await visualPartial(t)
        }
    }

    // MARK: matrix-preview

    @MainActor static func matrixPreview(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            SettingsWindowController.headless = true
            let controller = SettingsWindowController.shared
            controller.present()
            guard let window = controller.window else { t.check(false, "no settings window"); return }
            for combo in matrixCombos {
                applyMatrixCombo(combo)
                controller.syncFromPreferences()
                // the same appearance for both windows: the default scheme's colours follow it, a fixed scheme ignores it
                let dark = combo.scheme == "dracula" || combo.scheme == "gruvbox-dark"
                window.appearance = Palette.isSystemScheme ? NSAppearance(named: dark ? .darkAqua : .aqua) : nil
                window.contentView?.layoutSubtreeIfNeeded()
                let pv = controller.preview
                let previewTV = pv.textView
                let width = pv.scrollView.contentView.bounds.width, height = pv.scrollView.contentView.bounds.height
                _ = previewTV.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: width, height: 4000), in: previewTV.textContainer!)

                let (doc, host, _) = try await openEditor(t, text: SettingsPreview.sampleText, name: "matrix-preview.md", size: NSSize(width: width, height: height))
                if let w = doc.windowControllers.first?.window {
                    w.appearance = Palette.isSystemScheme ? NSAppearance(named: dark ? .darkAqua : .aqua) : nil
                    // a legacy scroller takes room from the content: widen the window until the editor's clip view is exactly as wide as the preview's
                    for _ in 0..<3 {
                        let delta = width - host.scrollView.contentView.bounds.width
                        if abs(delta) < 0.01 { break }
                        w.setContentSize(NSSize(width: w.contentView!.bounds.width + delta, height: height))
                        w.contentView?.layoutSubtreeIfNeeded()
                    }
                }
                host.styler.styleEverything()
                let tv = host.textView
                tv.scroll(.zero)
                settle(host)
                let label = combo.label
                t.check(abs(host.scrollView.contentView.bounds.width - width) < 0.01, "\(label): the editor's content is as wide as the preview's (\(host.scrollView.contentView.bounds.width) vs \(width) pt)")
                t.check(abs(tv.textContainer!.size.width - previewTV.textContainer!.size.width) < 0.01 && abs(tv.textContainerInset.width - previewTV.textContainerInset.width) < 0.01,
                        "\(label): same text container (\(tv.textContainer!.size.width) vs \(previewTV.textContainer!.size.width) pt, inset \(tv.textContainerInset.width) vs \(previewTV.textContainerInset.width))")

                // ---- line fragments: the same rectangles in the same places
                @MainActor func fragments(_ v: NSTextView) -> [(NSRect, NSRect, NSRange)] {
                    guard let lm = v.layoutManager, let tc = v.textContainer else { return [] }
                    lm.ensureLayout(for: tc)
                    var out: [(NSRect, NSRect, NSRange)] = []
                    lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, glyphs, _ in
                        out.append((rect, used, lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
                    }
                    return out
                }
                let a = fragments(previewTV), b = fragments(tv)
                var badFragment = ""
                if a.count == b.count {
                    for (x, y) in zip(a, b) where x.2 != y.2 || abs(x.0.minX - y.0.minX) > 0.01 || abs(x.0.minY - y.0.minY) > 0.01 || abs(x.0.width - y.0.width) > 0.01 || abs(x.0.height - y.0.height) > 0.01
                        || abs(x.1.minX - y.1.minX) > 0.01 || abs(x.1.width - y.1.width) > 0.01 {
                        badFragment = "chars \(NSStringFromRange(x.2)) vs \(NSStringFromRange(y.2)): preview \(NSStringFromRect(x.0)) / \(NSStringFromRect(x.1)), editor \(NSStringFromRect(y.0)) / \(NSStringFromRect(y.1))"
                        break
                    }
                }
                t.check(a.count == b.count && badFragment.isEmpty, "\(label): the preview has the line fragments of the editor (\(a.count) vs \(b.count))\(badFragment.isEmpty ? "" : ": " + badFragment)")

                // ---- pixels of the visible part of the text view
                let rect = NSRect(x: 0, y: 0, width: width, height: height)
                if let ra = previewTV.bitmapImageRepForCachingDisplay(in: rect), let rb = tv.bitmapImageRepForCachingDisplay(in: rect),
                   ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh {
                    previewTV.cacheDisplay(in: rect, to: ra)
                    tv.cacheDisplay(in: rect, to: rb)
                    var diff = 0, worst = 0
                    if let da = ra.bitmapData, let db = rb.bitmapData {
                        for row in 0..<ra.pixelsHigh {
                            let pa = da + row * ra.bytesPerRow, pb = db + row * rb.bytesPerRow
                            for i in 0..<(ra.pixelsWide * ra.samplesPerPixel) where pa[i] != pb[i] { diff += 1; worst = max(worst, abs(Int(pa[i]) - Int(pb[i]))) }
                        }
                    }
                    t.check(diff == 0, "\(label): the preview paints the same pixels as the editor (\(diff) differing samples, worst \(worst))")
                    if diff > 0, let d = SelfTest.argument("out") {
                        try? ra.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: d + "-preview-\(combo.scheme).png"))
                        try? rb.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: d + "-editor-\(combo.scheme).png"))
                    }
                } else {
                    t.check(false, "\(label): could not render both views at the same size")
                }
                t.close(doc)
            }
        }
    }

    // MARK: matrix-print

    /// Page 1 of a PDF as grey values (white paper under it), `scale` pixels per point.
    static func pdfPageLuminance(_ data: Data, scale: CGFloat = 1) -> (width: Int, height: Int, grey: [UInt8])? {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        var grey = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = grey.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            return true
        }
        return ok ? (w, h, grey) : nil
    }

    @MainActor static func matrixPrint(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let text = "# Printed heading\n\nBody text that is printed on paper, with `inline code` and a list:\n\n- one\n- two\n\n```\ncode block\n```\n"
            let (doc, _, _) = try await openEditor(t, text: text, name: "matrix-print.md")
            var cases: [(String, () -> Void)] = [
                ("default scheme, system appearance light", { Palette.apply(schemeID: ColorSchemes.defaultID); NSApp.appearance = nil }),
                ("dark colour scheme (dracula)", { Palette.apply(schemeID: "dracula") }),
                ("dark system appearance, default scheme", { Palette.apply(schemeID: ColorSchemes.defaultID); NSApp.appearance = NSAppearance(named: .darkAqua) }),
            ]
            cases.append(("light colour scheme (solarized-light) on a dark system", { Palette.apply(schemeID: "solarized-light") }))
            for (label, setup) in cases {
                setup()
                defer { Palette.apply(schemeID: ColorSchemes.defaultID); NSApp.appearance = nil }
                let pdfURL = t.url("matrix-print-\(abs(label.hashValue)).pdf")
                try? FileManager.default.removeItem(at: pdfURL)
                let op = try doc.printOperation(withSettings: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: pdfURL])
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                let ran = op.run()
                t.check(ran, "\(label): the print operation ran")
                guard let data = try? Data(contentsOf: pdfURL), let page = pdfPageLuminance(data) else { t.check(false, "\(label): no PDF came out"); continue }
                let n = page.grey.count
                let dark = page.grey.reduce(0) { $0 + ($1 < 110 ? 1 : 0) }
                let light = page.grey.reduce(0) { $0 + ($1 > 200 ? 1 : 0) }
                t.note(String(format: "%@: page %d x %d pt, %.1f %% light, %d ink pixels", label, page.width, page.height, 100 * Double(light) / Double(n), dark))
                t.check(Double(light) / Double(n) > 0.9, "\(label): the page is white (\(String(format: "%.1f", 100 * Double(light) / Double(n))) % light pixels)")
                t.check(dark > 100, "\(label): there is dark text on it (\(dark) ink pixels)")
            }
            t.close(doc)
        }
    }
}
#endif
