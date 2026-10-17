#if LUFTIG_SELFTEST
// SelfTestVisualContrast.swift - `visual-contrast`: every colour against every surface it can sit on, in all four palette variants
// (light, dark, and the two "Increase contrast" variants AppKit selects through the high-contrast appearances), the caret, the quote bar,
// the selection for every system accent colour, and colour-blind separability of the heading / link / code colours.
// Prints the worst margin of each group, then runs the same tables over every colour scheme (SelfTestSchemes.swift). Complements the `theme` scenario (which checks the normal palettes against the original 4 surfaces).

import AppKit

private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

extension SelfTestScenarios {
    static let visualContrastScenarios: [SelfTest.Scenario] = [
        .init(name: "visual-contrast", summary: "all text colours on all surfaces in 4 variants (incl. Increase contrast), caret, bar, selection per accent colour, colour-blind separation", run: { t in try await visualContrast(t) }),
    ]

    /// The system selection colour (`NSColor.selectedTextBackgroundColor`) for each accent colour, light / dark, as measured on macOS 27.0.1 by launching a
    /// process with `-AppleAccentColor N` (a per-process override: no system setting was changed). Blue is the default.
    static let systemSelectionColors: [(accent: String, light: (Double, Double, Double), dark: (Double, Double, Double))] = [
        ("blue", (179, 215, 255), (63, 99, 139)), ("purple", (223, 197, 224), (112, 87, 113)), ("pink", (253, 203, 226), (137, 87, 110)),
        ("red", (246, 196, 197), (139, 87, 89)), ("orange", (253, 218, 187), (137, 102, 71)), ("yellow", (255, 238, 190), (139, 122, 63)),
        ("green", (208, 234, 200), (92, 118, 84)),
        // Graphite cannot be forced per process (`-AppleAccentColor -1` is not accepted on the command line), so these two are ESTIMATES in the same range
        // as the measured ones (a neutral grey, a little lighter / darker than the blue); the check below holds with a wide margin.
        ("graphite (estimated)", (205, 205, 205), (98, 98, 98)),
    ]

    // MARK: colour-blindness simulation (Machado, Oliveira, Fernandes 2009, severity 1.0, applied in linear RGB)

    private static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func enc(_ v: Double) -> Double { let c = min(1, max(0, v)); return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    private static let cvdMatrices: [(name: String, m: [[Double]])] = [
        ("deuteranopia", [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]),
        ("protanopia", [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]),
        ("tritanopia", [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]),
    ]
    private static func simulate(_ c: RGBA, _ m: [[Double]]) -> RGBA {
        let l = [lin(c.r), lin(c.g), lin(c.b)]
        func row(_ i: Int) -> Double { enc(m[i][0] * l[0] + m[i][1] * l[1] + m[i][2] * l[2]) }
        return (row(0), row(1), row(2), c.a)
    }
    private static func lab(_ c: RGBA) -> (Double, Double, Double) {
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b, z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
    private static func deltaE(_ a: RGBA, _ b: RGBA) -> Double {
        let p = lab(a), q = lab(b)
        return sqrt(pow(p.0 - q.0, 2) + pow(p.1 - q.1, 2) + pow(p.2 - q.2, 2))
    }

    @MainActor static func visualContrast(_ t: SelfTest.T) async throws {
        typealias S = Palette.FullSurface
        let variants: [(String, NSAppearance.Name, PaletteVariant)] = [
            ("light", .aqua, .light), ("dark", .darkAqua, .dark),
            ("light + Increase contrast", .aqua, .lightHC), ("dark + Increase contrast", .darkAqua, .darkHC),
        ]
        defer { ContrastWatcher.shared.override = nil }
        for (name, appearanceName, variant) in variants {
            let appearance = NSAppearance(named: appearanceName)!
            let hc = variant.isHighContrast
            ContrastWatcher.shared.override = hc            // the system switch (AppKit exposes it as a global flag only)
            t.equal(Palette.variant(for: appearance).rawValue, variant.rawValue, "\(name): the appearance selects the \(variant) palette")
            func rgba(_ c: NSColor) -> RGBA { Contrast.rgba(c, appearance: appearance) }
            func over(_ top: NSColor, _ base: RGBA) -> RGBA { Contrast.over(rgba(top), base) }
            let bg = rgba(Palette.background)
            let quote = over(Palette.quoteBand, bg)
            let panel = over(Palette.panelBand, bg)
            let surfaces: [S: RGBA] = [
                .plain: bg, .code: over(Palette.codeBand, bg), .quote: quote,
                .nestedQuote: over(Palette.nestedBand, over(Palette.nestedBand, quote)),         // level 3: two panels on top of the quote tint
                .codeInQuote: over(Palette.codeBand, quote),
                .pill: over(Palette.inlinePill, bg), .pillInQuote: over(Palette.inlinePill, quote),
                .panel: panel, .tableHeader: over(Palette.tableHeaderBand, panel),
            ]
            t.info("[\(name)] page rgb(\(Int(bg.r * 255)), \(Int(bg.g * 255)), \(Int(bg.b * 255)))")
            var failures: [String] = []
            var worst: (String, Double, Double) = ("", 99, 0)       // name + surface, ratio, required
            var rows = 0
            for row in Palette.fullContrastTable {
                let need = hc ? row.minHC : row.min
                for s in row.on {
                    let ratio = Contrast.ratio(rgba(row.color), on: surfaces[s]!)
                    rows += 1
                    if ratio < need { failures.append(String(format: "%@ on %@ %.2f < %.1f", row.name, s.rawValue, ratio, need)) }
                    if ratio - need < worst.1 - worst.2 { worst = ("\(row.name) on \(s.rawValue)", ratio, need) }
                }
            }
            t.check(failures.isEmpty, "\(name): \(rows) text / surface pairs meet \(hc ? "7:1 text, 4.5:1 markers" : "4.5:1 text, 3:1 markers") \(failures.prefix(3))")
            t.info(String(format: "[%@] tightest pair: %@ at %.2f:1 (needs %.1f)", name, worst.0, worst.1, worst.2))

            // the caret (the accent) on the page and on every band
            let caret = rgba(Palette.accent)
            let caretWorst = [S.plain, .code, .quote, .nestedQuote, .codeInQuote, .panel, .tableHeader].map { (s: S) in (s, Contrast.ratio(caret, on: surfaces[s]!)) }.min { $0.1 < $1.1 }!
            t.check(caretWorst.1 >= 3, String(format: "%@: insertion point colour >= 3:1 on the page and every band (worst: %@ %.2f:1)", name, caretWorst.0.rawValue, caretWorst.1))
            // the quote bar against the quote tint it sits on (a graphical object: 3:1 with Increase contrast, 1.8:1 otherwise)
            let bar = Contrast.over(rgba(Palette.quoteBar), quote)
            let barRatio = Contrast.ratio(bar, on: quote)
            t.check(barRatio >= (hc ? 3 : 1.8), String(format: "%@: quote bar against the quote tint %.2f:1", name, barRatio))
            // Increase contrast also needs a boundary around the bands (the tint alone is not one)
            let border = rgba(Palette.bandBorder)
            t.check(hc ? border.a >= 0.3 : border.a == 0, "\(name): hairline around bands \(hc ? "present" : "absent") (alpha \(border.a))")

            // the selection: translucent system colour for every accent colour, over the page and the bands
            let alpha = Palette.selectionAlpha(variant)
            var selFailures: [String] = []
            var minBody = 99.0, minColour = 99.0, minMarker = 99.0
            for (accent, light, dark) in systemSelectionColors {
                let base = variant.isDark ? dark : light
                let sel: RGBA = (base.0 / 255, base.1 / 255, base.2 / 255, alpha)
                for s in [S.plain, .code, .quote] {
                    let eff = Contrast.over(sel, surfaces[s]!)
                    let body = Contrast.ratio(rgba(Palette.text), on: eff)
                    minBody = min(minBody, body)
                    if body < (hc ? 7 : 4.5) { selFailures.append(String(format: "%@/%@ body text %.2f", accent, s.rawValue, body)) }
                    for (n, c) in [("heading", Palette.heading), ("link", Palette.link), ("accent", Palette.accent), ("copper", Palette.copper), ("quote text", Palette.quoteText)] {
                        let r = Contrast.ratio(rgba(c), on: eff)
                        minColour = min(minColour, r)
                        if r < 3.0 { selFailures.append(String(format: "%@/%@ %@ %.2f", accent, s.rawValue, n, r)) }
                    }
                    let m = Contrast.ratio(rgba(Palette.marker), on: eff)
                    minMarker = min(minMarker, m)
                    if m < 1.9 { selFailures.append(String(format: "%@/%@ marker %.2f", accent, s.rawValue, m)) }
                }
                // the selection itself must stand out from the page, and the band must still show through it
                let onPage = Contrast.over(sel, bg), onBand = Contrast.over(sel, surfaces[.code]!)
                let delta = max(abs(onPage.r - onBand.r), abs(onPage.g - onBand.g), abs(onPage.b - onBand.b)) * 255
                let visible = Contrast.ratio(onPage, on: bg)
                if visible < 1.08 { selFailures.append(String(format: "%@ selection vs page %.2f:1", accent, visible)) }
                if delta < 3.0 { selFailures.append(String(format: "%@ band under selection %.1f levels", accent, delta)) }
            }
            t.check(selFailures.isEmpty, String(format: "%@: selection (alpha %.2f) over page / code band / quote band for all 8 accent colours: body text >= %@, coloured text >= 3:1, markers >= 1.9:1, selection visible against the page, band visible through it %@",
                                                 name, alpha, hc ? "7:1" : "4.5:1", Array(selFailures.prefix(3)) as NSArray))
            t.info(String(format: "[%@] selection worst case over 8 accents x 3 surfaces: body %.2f:1, coloured text %.2f:1, markers %.2f:1", name, minBody, minColour, minMarker))
        }

        // ---- colour-blind separability: the colours that carry meaning stay apart (CIE76 delta E) under the three dichromacies
        ContrastWatcher.shared.override = false
        for (name, appearanceName, _) in variants.prefix(2) {
            let appearance = NSAppearance(named: appearanceName)!
            let c = (text: Contrast.rgba(Palette.text, appearance: appearance), heading: Contrast.rgba(Palette.heading, appearance: appearance), link: Contrast.rgba(Palette.link, appearance: appearance),
                     copper: Contrast.rgba(Palette.copper, appearance: appearance), accent: Contrast.rgba(Palette.accent, appearance: appearance),
                     bg: Contrast.rgba(Palette.background, appearance: appearance))
            func flat(_ x: RGBA) -> RGBA { Contrast.over(x, c.bg) }
            var minLinkCopper = 999.0, minHeadingCopper = 999.0, minCopperText = 999.0, minHeadingLink = 999.0
            for (cvdName, m) in [("normal vision", nil)] + cvdMatrices.map({ ($0.name, Optional($0.m)) }) {
                func s(_ x: RGBA) -> RGBA { m.map { simulate(flat(x), $0) } ?? flat(x) }
                let lc = deltaE(s(c.link), s(c.copper)), hcp = deltaE(s(c.heading), s(c.copper)), ct = deltaE(s(c.copper), s(c.text)), hl = deltaE(s(c.heading), s(c.link))
                minLinkCopper = min(minLinkCopper, lc); minHeadingCopper = min(minHeadingCopper, hcp); minCopperText = min(minCopperText, ct); minHeadingLink = min(minHeadingLink, hl)
                t.info(String(format: "[%@ / %@] delta E: link-code %.0f, heading-code %.0f, code-text %.0f, heading-link %.0f", name, cvdName, lc, hcp, ct, hl))
            }
            t.check(minLinkCopper >= 40 && minHeadingCopper >= 40, String(format: "%@: link / heading colour vs code colour stay far apart for deuteranopia, protanopia, tritanopia (min delta E %.0f / %.0f)", name, minLinkCopper, minHeadingCopper))
            t.check(minCopperText >= 25, String(format: "%@: code colour vs body text delta E >= 25 under all three (%.0f)", name, minCopperText))
            // heading vs link: close in hue on purpose (one accent family); they differ by lightness here and by weight, size and underline in the text
            t.check(minHeadingLink >= 10, String(format: "%@: heading vs link delta E >= 10 under all three (%.0f); the real separation is size + weight vs underline", name, minHeadingLink))
        }

        // ---- every colour scheme x both variants of its kind x every surface, with the SAME thresholds (SelfTestSchemes.swift prints the table)
        try await schemesContrast(t)
    }
}
#endif
