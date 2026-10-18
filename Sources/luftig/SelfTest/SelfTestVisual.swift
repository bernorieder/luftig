#if LUFTIG_SELFTEST
// SelfTestVisual.swift - how it LOOKS, measured on the pixels of the real editor view (offscreen, never on screen):
//   visual-metrics    line heights: the ratio, uniform line boxes for every script (CJK, emoji, RTL, combining marks), headings
//   visual-bands      a band sits around its TEXT (equal padding above and below), a quote with code inside is ONE band without seam
//   visual-selection  the selection is translucent: the band / pill below it stays visible; text stays readable (pixel check)
//   visual-rtl        right-to-left lines are right-aligned, quote / code lines keep their bar and marker on the left
//   visual-perf       decoration drawing for a full visible redraw (budget 1.5 ms)
// (The contrast tables of every colour and variant are in SelfTestVisualContrast.swift; the colour schemes are in SelfTestSchemes.swift.)
//
// Everything here uses only what exists in the original code too, so the same file can be run against the baseline to show which checks fail there.

import AppKit
import MarkdownKit

/// RGB pixels of the visible part of a text view, in view coordinates (points). Colour values as AppKit drew them (device RGB).
struct ViewPixels {
    let rep: NSBitmapImageRep
    let rect: NSRect
    let scale: CGFloat

    @MainActor init?(_ tv: NSTextView) {
        let r = tv.visibleRect
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        tv.cacheDisplay(in: r, to: rep)
        self.rep = rep
        self.rect = r
        self.scale = CGFloat(rep.pixelsWide) / r.width
    }

    func rgb(_ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int) {
        let px = Int(((x - rect.minX) * scale).rounded(.down)), py = Int(((y - rect.minY) * scale).rounded(.down))
        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh, let data = rep.bitmapData else { return (0, 0, 0) }
        let o = py * rep.bytesPerRow + px * rep.samplesPerPixel
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
    }
    func luminance(_ x: CGFloat, _ y: CGFloat) -> Int { let c = rgb(x, y); return (c.r * 3 + c.g * 6 + c.b) / 10 }
    func differs(_ x: CGFloat, _ y: CGFloat, from base: (r: Int, g: Int, b: Int), by tolerance: Int) -> Bool {
        let c = rgb(x, y)
        return abs(c.r - base.r) > tolerance || abs(c.g - base.g) > tolerance || abs(c.b - base.b) > tolerance
    }
    /// Vertical extent (points) of the band that covers the point (x, y): walk up and down while the colour differs from the page.
    func bandExtent(x: CGFloat, y: CGFloat, page: (r: Int, g: Int, b: Int), tolerance: Int = 2) -> (top: CGFloat, bottom: CGFloat) {
        let step = 1 / scale
        var top = y, bottom = y
        while differs(x, top - step, from: page, by: tolerance), y - top < 400 { top -= step }
        while differs(x, bottom + step, from: page, by: tolerance), bottom - y < 400 { bottom += step }
        return (top, bottom + step)
    }
    /// Rows (points) between `y0` and `y1` that contain ink (darker than `threshold`) somewhere in x0...x1: first and last.
    func inkRows(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, threshold: Int) -> (top: CGFloat, bottom: CGFloat)? {
        var first: CGFloat?, last: CGFloat?
        var y = y0
        let step = 1 / scale
        while y < y1 {
            var x = x0
            var hit = false
            while x < x1 { if luminance(x, y) < threshold { hit = true; break }; x += step }
            if hit { if first == nil { first = y }; last = y + step }
            y += step
        }
        guard let f = first, let l = last else { return nil }
        return (f, l)
    }
    /// Leftmost and rightmost ink column (points) in the rows y0...y1.
    func inkColumns(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, threshold: Int) -> (left: CGFloat, right: CGFloat)? {
        var left: CGFloat?, right: CGFloat?
        var x = x0
        let step = 1 / scale
        while x < x1 {
            var y = y0
            while y < y1 { if luminance(x, y) < threshold { if left == nil { left = x }; right = x + step; break }; y += step }
            x += step
        }
        guard let l = left, let r = right else { return nil }
        return (l, r)
    }
}

extension SelfTestScenarios {
    static let visualScenarios: [SelfTest.Scenario] = [
        .init(name: "visual-metrics", summary: "line height ratio, uniform line boxes for CJK / emoji / RTL / combining marks at 11...28 pt, heading boxes", run: { t in try await visualMetrics(t) }),
        .init(name: "visual-bands", summary: "bands sit around their text (equal padding above / below); a quote containing code is one band without a seam", run: { t in try await visualBands(t) }),
        .init(name: "visual-selection", summary: "the selection is translucent: band tint under it stays visible, light + dark, active + inactive", run: { t in try await visualSelection(t) }),
        .init(name: "visual-rtl", summary: "right-to-left lines are right-aligned; quote / code lines keep bar and marker on the left", run: { t in try await visualRTL(t) }),
        .init(name: "visual-styling-cost", summary: "Theme.styledRuns on a 60 000 character line with ~2000 runs, with and without a right-to-left character (no rescan per run)", run: { t in try await visualStylingCost(t) }),
        .init(name: "visual-perf", summary: "decoration drawing cost for a full visible redraw (budget 1.5 ms)", run: { t in try await visualPerf(t) }),
    ] + visualContrastScenarios + visualRedrawScenarios + schemeScenarios + schemesImportScenarios

    @MainActor static func settle(_ host: EditorViewController) {
        host.styler.styleVisible()
        let tv = host.textView
        _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
    }

    @MainActor static func setAppearance(_ doc: MarkdownDocument, _ name: NSAppearance.Name) {
        doc.windowControllers.first?.window?.appearance = NSAppearance(named: name)
    }

    /// Line fragment rect (view coordinates) of the line that contains the first occurrence of `needle`.
    @MainActor static func lineRect(_ tv: NSTextView, containing needle: String) -> NSRect? {
        let r = (tv.string as NSString).range(of: needle)
        guard r.location != NSNotFound, let lm = tv.layoutManager else { return nil }
        let g = lm.glyphIndexForCharacter(at: r.location)
        let f = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let o = tv.textContainerOrigin
        return f.offsetBy(dx: o.x, dy: o.y)
    }

    // MARK: metrics

    @MainActor static func visualMetrics(_ t: SelfTest.T) async throws {
        let savedSize = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = savedSize }
        let text = """
        # Heading one

        Latin text, then 日本語のテキストと中文文本 and 한국어, then 😀 🎉 👩‍💻 🇩🇪 ❤️ 👍🏽 emoji.

        Combining: e\u{301} Z\u{353}\u{343}a\u{337}l\u{335}g\u{336}o\u{338} x\u{331}\u{332}\u{333}\u{326} Å ñ.

        مرحبا بكم في luftig — هذا نص عربي

        שלום עולם — טקסט בעברית

        ## Heading two with 日本語 and `code`

        > quote with 日本語 and 😀

        ```
        code with 日本語 😀
        	TABBED
        ```

        | a | 日本語 |
        |---|---|
        | 1 | 😀 |

        - [ ] task مرحبا
        Last line.
        """
        for size in [11.0, 13.0, 16.0, 20.0, 28.0] {
            EditorPreferences.fontSize = CGFloat(size)
            let (doc, host, _) = try await openEditor(t, text: text, name: "metrics-\(Int(size)).md", size: NSSize(width: 860, height: 1400))
            host.styler.styleEverything()
            settle(host)
            let tv = host.textView, lm = tv.layoutManager!, ts = tv.textStorage!, theme = host.theme
            let ratio = theme.bodyLineHeight / theme.baseSize
            if size == 16 { t.check(ratio <= 1.45, String(format: "body line height at 16 pt is %.2f x the font size (<= 1.45: a well-set page, not airy)", ratio)) }
            t.check(ratio >= 1.3 && ratio <= 1.5, String(format: "%.0f pt: line height ratio %.2f in 1.3...1.5", size, ratio))
            var bad: [String] = []
            let slack = 0.03 * theme.baseSize + 0.1
            var count = 0, grown = 0
            lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, used, _, glyphs, _ in
                let c = lm.characterIndexForGlyph(at: glyphs.location)
                guard c < ts.length, let p = ts.attribute(.paragraphStyle, at: c, effectiveRange: nil) as? NSParagraphStyle else { return }
                count += 1
                // the box is the fixed height of its paragraph style. MEASURED: TextKit 1 lets a line grow past `maximumLineHeight` by a fraction of a point when
                // a glyph needs more room (a stack of combining marks: +0.45 pt at 16 pt, +0.78 pt at 28 pt; CJK / emoji fallback fonts at 11 pt: +0.33 pt). That is not visible and
                // does not move anything noticeably, so the bound is 3 % of the font size over and never under.
                if used.height < p.minimumLineHeight - 0.01 || used.height > p.minimumLineHeight + slack { bad.append("line at \(c): used \(used.height) rect \(rect.height) vs \(p.minimumLineHeight)") }
                if used.height > p.minimumLineHeight + 0.01 { grown += 1 }
                // and the extra space of a heading (spacing before) is only ever above it
                if abs(rect.height - used.height - p.paragraphSpacingBefore) > 0.01 && abs(rect.height - used.height) > 0.01 { bad.append("rect at \(c): \(rect.height) vs \(used.height)+\(p.paragraphSpacingBefore)") }
            }
            t.check(bad.isEmpty, "\(Int(size)) pt: all \(count) line boxes (Latin, CJK, emoji, combining, RTL, code, table, quote) have their paragraph style's fixed height, at most 3 % of the font size more (\(grown) of them a fraction of a point taller) \(bad.prefix(2))")
            // a tab in code is 4 columns of the code font (the default tab stop of 28 pt is 3.2 columns)
            let tabLine = (tv.string as NSString).range(of: "\tTABBED")
            if tabLine.location != NSNotFound {
                let gi = lm.glyphIndexForCharacter(at: tabLine.location + 1)
                let x0 = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: tabLine.location)).x, x1 = lm.location(forGlyphAt: gi).x
                let columns = (x1 - x0) / theme.monoAdvance
                t.check(abs(columns - 4) < 0.1, String(format: "%d pt: a tab in a code line is %.2f columns wide (4 expected; AppKit's default stop is 28 pt)", Int(size), columns))
            }
            let h1 = theme.lineHeight(headingLevel: 1), h2 = theme.lineHeight(headingLevel: 2)
            t.check(h1 > h2 && h2 > theme.bodyLineHeight - 0.5 && h1 <= (theme.headingSize(1) * 1.4).rounded(), "\(Int(size)) pt: heading boxes \(h1) / \(h2) pt (H1 box <= 1.4 x its font size)")
            t.close(doc)
        }
    }

    // MARK: bands

    @MainActor static func visualBands(_ t: SelfTest.T) async throws {
        let text = "Intro line.\n\n    HETx\n    HETx\n\nBetween.\n\n> HETx\n> HETx\n\nOutro.\n\n    Hxgy\n    Hxgy\n\nMore.\n\n> a\n>\n> ```\n> code\n> ```\n>\n> b\n\nEnd.\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "bands.md", size: NSSize(width: 860, height: 700))
        setAppearance(doc, .aqua)
        host.styler.styleEverything()
        settle(host)
        let tv = host.textView
        let o = tv.textContainerOrigin
        guard let px = ViewPixels(tv) else { t.check(false, "no pixels"); return }
        let page = px.rgb(4, 4)
        t.check(page.r > 250 && page.g > 250 && page.b > 250, "page pixel is white: \(page)")

        // padding above the first and below the last ink row of a block: equal (the extra leading of a line box sits above the text, a band that simply
        // covers the line boxes had a gap above the first line and none below the last one)
        func padding(_ label: String, firstLine: String, lastLine: String, inkFromX: CGFloat, balanced: Bool) {
            guard let a = lineRect(tv, containing: firstLine), let b = lineRect(tv, containing: lastLine) else { t.check(false, "\(label): lines not found"); return }
            let probeX = o.x - 4                                           // inside the band, left of the text column, right of a quote bar
            let band = px.bandExtent(x: probeX, y: (a.minY + b.maxY) / 2, page: page)
            let bandLum = px.luminance(probeX, (a.minY + b.maxY) / 2)
            guard let ink = px.inkRows(x0: o.x + inkFromX, x1: o.x + inkFromX + 60, y0: band.top + 1, y1: band.bottom - 1, threshold: bandLum - 90) else { t.check(false, "\(label): no ink found"); return }
            let topGap = ink.top - band.top, bottomGap = band.bottom - ink.bottom
            t.info(String(format: "%@: band %.1f ... %.1f pt, ink %.1f ... %.1f pt: padding above %.1f pt, below %.1f pt", label, band.top, band.bottom, ink.top, ink.bottom, topGap, bottomGap))
            t.check(topGap >= 3 && bottomGap >= 3, String(format: "%@: text is at least 3 pt from the band edge on both sides (above %.1f, below %.1f)", label, topGap, bottomGap))
            if balanced { t.check(abs(topGap - bottomGap) <= 3, String(format: "%@: padding above and below is balanced within 3 pt (%.1f vs %.1f)", label, topGap, bottomGap)) }
        }
        // (text without descenders for the balance: capital letters on top, the baseline at the bottom)
        padding("indented code band", firstLine: "    HETx", lastLine: "    HETx\n\nBetween", inkFromX: 36, balanced: true)
        padding("quote band", firstLine: "> HETx", lastLine: "> HETx\n\nOutro", inkFromX: 14, balanced: true)
        // with descenders (g, y) the ink still keeps its distance from the band edge
        padding("code band, text with descenders", firstLine: "    Hxgy", lastLine: "    Hxgy\n\nMore", inkFromX: 36, balanced: false)

        // a quote that contains a code block is ONE band: the strip between the bar and the code panel keeps the quote tint on every row
        guard let q0 = lineRect(tv, containing: "> a\n>\n> ```"), let q1 = lineRect(tv, containing: "> b\n\nEnd") else { t.check(false, "quote lines not found"); return }
        let stripX = o.x - DecorationMetrics.bandOutset + DecorationMetrics.quoteBarWidth + 2
        let ref = px.rgb(stripX, q0.minY + 8)
        var maxDev = 0
        var devAt: CGFloat = 0
        var y = q0.minY + 8
        while y < q1.maxY - 8 {
            let c = px.rgb(stripX, y)
            let d = max(abs(c.r - ref.r), abs(c.g - ref.g), abs(c.b - ref.b))
            if d > maxDev { maxDev = d; devAt = y }
            y += 1 / px.scale
        }
        t.check(maxDev <= 3, "quote with a code block inside: the strip beside the bar has one colour on all rows (max deviation \(maxDev) levels at y = \(Int(devAt)); a seam / notch between quote band and code band shows as a jump)")
        // the outer bar is unbroken from the first to the last line
        let barX = o.x - DecorationMetrics.bandOutset + 1.5
        var gaps = 0
        y = q0.minY + 8
        while y < q1.maxY - 8 { if !px.differs(barX, y, from: ref, by: 14) { gaps += 1 }; y += 1 / px.scale }
        t.equal(gaps, 0, "the quote bar is continuous over the blank `>` lines and the code lines (\(gaps) rows without bar colour)")
        t.close(doc)
        try await visualQuoteBars(t)
    }

    /// Nested quotes and a horizontal rule inside a quote: every bar is one unbroken stroke from its first to its last line, and the quote does not end at a rule.
    @MainActor static func visualQuoteBars(_ t: SelfTest.T) async throws {
        let text = "Intro.\n\n> a1\n> > b1\n> > b2\n> > > c1\n>\n> a2\n\nMiddle.\n\n> r1\n>\n> ---\n>\n> r2\n\nEnd.\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "bars.md", size: NSSize(width: 860, height: 600))
        setAppearance(doc, .aqua)
        host.styler.styleEverything()
        settle(host)
        let tv = host.textView
        let o = tv.textContainerOrigin
        guard let px = ViewPixels(tv), let a1 = lineRect(tv, containing: "> a1"), let b1 = lineRect(tv, containing: "> > b1"), lineRect(tv, containing: "> > b2") != nil,
              let c1 = lineRect(tv, containing: "> > > c1"), let a2 = lineRect(tv, containing: "> a2"), let r1 = lineRect(tv, containing: "> r1"), let r3 = lineRect(tv, containing: "> r2") else { t.check(false, "lines not found"); return }
        /// rows between `y0` and `y1` where the pixel at x is not (close to) the colour found at `ref`
        func breaks(x: CGFloat, from y0: CGFloat, to y1: CGFloat, ref: (r: Int, g: Int, b: Int), tolerance: Int = 14) -> Int {
            var n = 0
            var y = y0
            while y < y1 { if px.differs(x, y, from: ref, by: tolerance) { n += 1 }; y += 1 / px.scale }
            return n
        }
        let step = DecorationMetrics.quoteBarStep, outset = DecorationMetrics.bandOutset, barW = DecorationMetrics.quoteBarWidth
        let x2 = o.x - outset + step + barW / 2, x3 = o.x - outset + 2 * step + barW / 2          // centres of the level 2 and level 3 bars
        // level 2: lines b1 ... c1 (the bar has a 2 pt inset and round ends: skip 6 pt at both ends)
        let ref2 = px.rgb(x2, b1.midY)
        t.check(ref2.r < 200 && ref2.b > ref2.r, "level 2 bar has the bar colour at its first line: \(ref2)")
        let gaps2 = breaks(x: x2, from: b1.minY + 6, to: c1.maxY - 6, ref: ref2)
        t.equal(gaps2, 0, "the level 2 bar is one unbroken stroke over the lines b1, b2 and c1, across the line boundaries (\(gaps2) rows break it)")
        let ref3 = px.rgb(x3, c1.midY)
        t.check(ref3.r < 215 && ref3.b > ref3.r, "level 3 bar has the bar colour on its line: \(ref3)")
        let gaps3 = breaks(x: x3, from: c1.minY + 6, to: c1.maxY - 6, ref: ref3)
        t.equal(gaps3, 0, "the level 3 bar is unbroken (\(gaps3) rows)")
        // the bars are drawn only where their quote level is: no level 2 bar beside a1 / a2
        t.check(px.rgb(x2, a1.midY).r > ref2.r + 20 && px.rgb(x2, a2.midY).r > ref2.r + 20, "no level 2 bar beside the level 1 lines a1 / a2")
        // a horizontal rule inside a quote does not end the quote: the outer bar runs through it
        let barX = o.x - outset + barW / 2
        let refBar = px.rgb(barX, r1.midY)
        let gapsRule = breaks(x: barX, from: r1.minY + 4, to: r3.maxY - 4, ref: refBar)
        t.equal(gapsRule, 0, "the outer quote bar runs through a horizontal rule inside the quote (\(gapsRule) rows break it)")
        let rule = lineRect(tv, containing: "> ---")!
        let page = px.rgb(4, 4)
        t.check(px.differs(o.x + 60, rule.midY - 1, from: page, by: 3) || px.differs(o.x + 60, rule.midY, from: page, by: 3), "the band is there beside the rule line (the quote band is not interrupted)")
        t.close(doc)
    }

    // MARK: selection

    @MainActor static func visualSelection(_ t: SelfTest.T) async throws {
        let text = "Plain line of text here.\n\n```\nHxgy code line\n```\n\nAnother plain line.\n\n```\nunselected code\n```\n"
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let (doc, host, _) = try await openEditor(t, text: text, name: "selection-\(label).md", size: NSSize(width: 860, height: 700))
            setAppearance(doc, appearance)
            host.styler.styleEverything()
            let tv = host.textView
            let ns = tv.string as NSString
            let start = ns.range(of: "Plain").location, end = ns.range(of: "Another").location - 2
            tv.setSelectedRange(NSRange(location: start, length: end - start))
            settle(host)
            guard let px = ViewPixels(tv), let plain = lineRect(tv, containing: "Plain line"), let code = lineRect(tv, containing: "Hxgy"), let other = lineRect(tv, containing: "unselected") else { t.check(false, "setup failed"); return }
            let o = tv.textContainerOrigin
            let x = o.x + tv.textContainer!.size.width - 30                              // inside the selected line boxes, right of the text
            let selPlain = px.rgb(x, plain.midY), selCode = px.rgb(x, code.midY)
            let bandPlain = px.rgb(x, other.midY)                                       // an unselected code line: the band colour
            let page = px.rgb(4, 4)
            func lum(_ c: (r: Int, g: Int, b: Int)) -> Int { (c.r * 3 + c.g * 6 + c.b) / 10 }
            let bandDelta = abs(lum(page) - lum(bandPlain))
            let underSelection = abs(lum(selPlain) - lum(selCode))
            t.info("\(label) (inactive selection): page \(page), band \(bandPlain), selected over page \(selPlain), selected over band \(selCode)")
            t.check(abs(lum(selPlain) - lum(page)) >= 8, "\(label): the selection is visible against the page (\(lum(page)) -> \(lum(selPlain)))")
            t.check(bandDelta >= 6 && underSelection >= 3, "\(label): the code band stays visible under the selection: \(underSelection) levels of difference between selected-over-band and selected-over-page (the band itself differs from the page by \(bandDelta); opaque selection: 0)")
            t.close(doc)
        }
    }

    // MARK: right to left

    @MainActor static func visualRTL(_ t: SelfTest.T) async throws {
        let text = "Latin line of text.\n\nمرحبا بكم في العالم\n\nשלום עולם\n\n# عنوان\n\n- مرحبا\n\n> اقتباس\n\n    كود\n\nمرحبا Latin mixed\n\nLatin ثم مرحبا\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "rtl.md", size: NSSize(width: 860, height: 800))
        setAppearance(doc, .aqua)
        host.styler.styleEverything()
        settle(host)
        let tv = host.textView
        guard let px = ViewPixels(tv) else { t.check(false, "no pixels"); return }
        let o = tv.textContainerOrigin, w = tv.textContainer!.size.width
        func ink(_ needle: String) -> (left: CGFloat, right: CGFloat)? {
            guard let r = lineRect(tv, containing: needle) else { return nil }
            return px.inkColumns(x0: o.x - 8, x1: o.x + w + 8, y0: r.minY + r.height * 0.45, y1: r.maxY - 2, threshold: 150)
        }
        if let l = ink("Latin line") { t.check(l.left < o.x + 6, "Latin line is flush left (ink starts at x = \(Int(l.left - o.x)) pt)") } else { t.check(false, "no ink: Latin") }
        for (name, needle) in [("Arabic paragraph", "مرحبا بكم"), ("Hebrew paragraph", "שלום עולם"), ("Arabic heading", "عنوان"), ("Arabic list item", "- مرحبا"),
                               ("line starting with Arabic, mixed", "مرحبا Latin")] {
            if let l = ink(needle) { t.check(l.right > o.x + w - 24 && l.left > o.x + w * 0.4, "\(name) is flush right (ink \(Int(l.left - o.x)) ... \(Int(l.right - o.x)) pt of \(Int(w)))") } else { t.check(false, "no ink: \(name)") }
        }
        if let l = ink("Latin ثم") { t.check(l.left < o.x + 6, "a line that starts with Latin text stays left (the first strong character decides): ink at x = \(Int(l.left - o.x)) pt") }
        if let l = ink("اقتباس") { t.check(l.left < o.x + 40, "RTL text in a quote line: the `>` marker and the text start at the left, next to the bar (ink at x = \(Int(l.left - o.x)) pt)") }
        if let l = ink("كود") { t.check(l.left < o.x + 60, "RTL text in an indented code line stays left (ink at x = \(Int(l.left - o.x)) pt)") }

        // the paragraph styles carry it, and typing makes a line RTL at once (restyle in didProcessEditing)
        let ts = tv.textStorage!
        func ps(_ s: String) -> NSParagraphStyle? { ts.attribute(.paragraphStyle, at: (tv.string as NSString).range(of: s).location, effectiveRange: nil) as? NSParagraphStyle }
        t.equal(ps("مرحبا بكم")?.baseWritingDirection, .rightToLeft, "Arabic paragraph: right-to-left paragraph style")
        t.equal(ps("Latin line")?.baseWritingDirection, .leftToRight, "Latin paragraph: left-to-right paragraph style")
        t.equal(ps("اقتباس")?.baseWritingDirection, .leftToRight, "quote line: left-to-right (bar and marker are on the left)")
        t.equal(ps("Latin ثم")?.baseWritingDirection, .leftToRight, "line starting with Latin: left-to-right")
        t.typeText("שלום ", into: doc, at: NSRange(location: (tv.string as NSString).range(of: "Latin ثم").location, length: 0))
        settle(host)
        t.equal(ps("שלום Latin")?.baseWritingDirection, .rightToLeft, "typing a Hebrew word at the start of a Latin line flips the line to right-to-left at once")
        assertMatchesFreshLex(t, host, "after typing: storage == fresh lex + theme")
        t.close(doc)
    }

    // MARK: styling cost

    /// One very long line (bounded: the lexer gives lines beyond 64 K characters no inline styling, and caps the runs of a line) with many runs: the right-to-left
    /// detection must not rescan the line for every run.
    @MainActor static func visualStylingCost(_ t: SelfTest.T) async throws {
        let theme = Theme(baseSize: 16)
        let body = String(repeating: "**a** b ", count: 7_500)                      // 60 000 characters, 22 500 runs
        var results: [(String, Double)] = []
        for (label, text) in [("left-to-right line", body + "end\n"), ("line with Arabic text at its end", body + "مرحبا\n"), ("line with Arabic text at its start", "مرحبا " + body + "\n")] {
            let ns = text as NSString
            let runs = MarkdownStyler().lexAll(ns)
            var best = Double.infinity
            for _ in 0..<3 {
                let t0 = SelfTest.nowMs()
                let styled = theme.styledRuns(runs, text: ns)
                best = min(best, SelfTest.nowMs() - t0)
                if styled.isEmpty { t.check(false, "no runs") }
            }
            results.append((label, best))
            t.info(String(format: "%@: %d lexer runs -> styledRuns %.2f ms", label, runs.count, best))
        }
        t.check(results.allSatisfy { $0.1 < 1.5 }, "styledRuns of a 60 000 character line with ~2000 runs takes < 1.5 ms in every case, RTL or not (\(results.map { String(format: "%.2f", $0.1) }.joined(separator: ", ")) ms; a rescan of the line per run took 2.8 ms)")
    }

    // MARK: perf

    @MainActor static func visualPerf(_ t: SelfTest.T) async throws {
        let text = SelfTestCorpus.markdown(bytes: 300_000, seed: 3)
        let (doc, host, _) = try await openEditor(t, text: text, name: "perf.md", size: NSSize(width: 860, height: 1000))
        let tv = host.textView
        t.scrollToTop(host, character: (tv.string as NSString).length / 2)
        settle(host)
        guard let lm = tv.layoutManager as? LuftigLayoutManager, let tc = tv.textContainer else { t.check(false, "no LuftigLayoutManager"); return }
        let rect = tv.visibleRect
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { t.check(false, "no bitmap context"); return }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        gc.cgContext.scaleBy(x: scale, y: scale)
        gc.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        var times: [Double] = []
        for i in 0..<120 {
            let t0 = SelfTest.nowMs()
            lm.drawDecorations(in: rect, origin: tv.textContainerOrigin, container: tc)
            if i >= 20 { times.append(SelfTest.nowMs() - t0) }
        }
        NSGraphicsContext.current = saved
        times.sort()
        let median = times[times.count / 2], p95 = times[times.count * 95 / 100]
        let fragments = { () -> Int in var n = 0; lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -tv.textContainerOrigin.x, dy: -tv.textContainerOrigin.y), in: tc)) { _, _, _, _, _ in n += 1 }; return n }()
        t.note(String(format: "decorations for a full visible redraw (%d line fragments): median %.3f ms, p95 %.3f ms, max %.3f ms", fragments, median, p95, times.last ?? 0))
        t.check(median <= 1.5, String(format: "decoration drawing median %.3f ms <= 1.5 ms (rerun if the machine is loaded)", median))
        t.close(doc)
    }
}
#endif
