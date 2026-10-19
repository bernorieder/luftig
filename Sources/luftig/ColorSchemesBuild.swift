import AppKit

// ColorSchemesBuild.swift - from the authentic palette of a theme (ColorSchemesData.swift) to the colours the editor uses.
//
//   1. ROLES.   Every Markdown role gets a BASE colour: the theme's colour for it, or a mix (in OKLab) of two of them (quote text = fg and comment halfway, ...).
//   2. TINTS.   The translucent decoration colours (code band, quote band and bar, nested quote, inline-code pill, table / front matter panel, header row, rule,
//               border) are the theme's own colours at the alphas of the default scheme (one table for every theme): fg for code / panel / header / rule, the accent for
//               quotes, the inline-code colour for pills. They are derived from the AUTHENTIC colours, so the surfaces text sits on do not move while text is adjusted.
//   3. SURFACES. page, code band, quote, nested quote, code in quote, pill, pill in quote, panel, table header (the opaque colours the tints give over the page)
//               and the selection over page / code band / quote, the two banners.
//   4. LEGIBILITY. The SAME thresholds as the default scheme's self-test: text >= 4.5:1, syntax markers >= 3:1 on every surface they can sit on; with "Increase
//               contrast" 7:1 and 4.5:1; the caret >= 3:1; coloured text >= 3:1 on the selection, body text >= 4.5 / 7:1 on it. A colour that fails is moved by
//               `ColorMath.fit`: same hue and chroma, the OKLCH lightness moved the least that satisfies every surface, towards white (dark schemes) or black
//               (light schemes). The Increase-contrast variant starts from the colour in use and is pushed further the same way until 7:1 / 4.5:1.
//   5. SELECTION. The theme's selection colour `Sel` (opaque, over the page) is painted as a TRANSLUCENT colour C at alpha a with  a*C + (1-a)*page == Sel: it looks like
//               the theme over the page, and bands and pills below it stay visible (the default scheme does the same with the system colour). The selection of a window that
//               is not key is the same colour desaturated and closer to the page. Both are weakened if even white / black text could not be legible on them.
//
// Deterministic: the same spec always gives the same colours (no randomness, no dependence on the system).

enum SchemeRole: Int, CaseIterable {
    case text, quoteText, struck, heading, headingMuted, accent, link, linkDestination, copper, codeText, frontMatter, html, marker, caret
}

/// A row of the contrast table: `role` must reach `min`:1 (`minHC`:1 with Increase contrast) on every listed surface. The self-test checks exactly these
/// rows for every scheme and variant; the builder fits each role to the union of its rows.
struct ContrastRule {
    let name: String
    let role: SchemeRole
    let min: Double
    let minHC: Double
    let on: [Palette.FullSurface]
}

extension ColorSchemes {
    static let contrastRules: [ContrastRule] = {
        typealias S = Palette.FullSurface
        let all = S.allCases
        return [
            ContrastRule(name: "body text", role: .text, min: 4.5, minHC: 7, on: [.plain, .code, .quote, .nestedQuote, .codeInQuote, .panel, .tableHeader]),
            ContrastRule(name: "quote text", role: .quoteText, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote]),
            ContrastRule(name: "strikethrough", role: .struck, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "heading", role: .heading, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote]),
            ContrastRule(name: "heading h5/h6", role: .headingMuted, min: 4.5, minHC: 7, on: [.plain, .quote]),
            ContrastRule(name: "accent / list marker / image", role: .accent, min: 4.5, minHC: 7, on: [.plain, .code, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "link", role: .link, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "link destination / unchecked task", role: .linkDestination, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "footnote label", role: .headingMuted, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "inline code / escape (copper)", role: .copper, min: 4.5, minHC: 7, on: [.plain, .pill, .pillInQuote, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "code text", role: .codeText, min: 4.5, minHC: 7, on: [.plain, .code, .codeInQuote]),
            ContrastRule(name: "front matter", role: .frontMatter, min: 4.5, minHC: 7, on: [.panel]),
            ContrastRule(name: "html / comment", role: .html, min: 4.5, minHC: 7, on: [.plain, .quote, .nestedQuote, .panel, .tableHeader]),
            ContrastRule(name: "syntax marker", role: .marker, min: 3.0, minHC: 4.5, on: all),
        ]
    }()

    /// Where the insertion point can be: on the page and on every band (>= 3:1, also with Increase contrast).
    static let caretSurfaces: [Palette.FullSurface] = [.plain, .code, .quote, .nestedQuote, .codeInQuote, .panel, .tableHeader]
    /// The selection must show the body text at 4.5:1 (7:1), coloured text at 3:1 and the markers at 1.9:1, over the page, a code band and a quote band;
    /// the selection against the page 1.08:1 at least.
    static let selectionTextMin = (normal: 4.5, highContrast: 7.0)
    static let selectionColouredMin = 3.0
    static let selectionMarkerMin = 1.9
    static let selectionVisibleMin = 1.08
    /// The selection colours of a scheme are made at least this visible against the page (a little more than the test demands: 1.08).
    static let selectionVisibleTarget = 1.22
}

enum SchemeBuilder {

    /// Alphas of the tints, per (dark, Increase contrast): the default scheme's values, so every theme is built the same way.
    private struct Alphas {
        let code, quote, bar, nested, pill, panel, header, rule, border: Double
        static func of(dark: Bool, hc: Bool) -> Alphas {
            switch (dark, hc) {
            case (false, false): return Alphas(code: 0.055, quote: 0.05, bar: 0.55, nested: 0.04, pill: 0.09, panel: 0.035, header: 0.075, rule: 0.26, border: 0)
            case (true, false): return Alphas(code: 0.085, quote: 0.085, bar: 0.65, nested: 0.06, pill: 0.15, panel: 0.05, header: 0.10, rule: 0.30, border: 0)
            case (false, true): return Alphas(code: 0.08, quote: 0.07, bar: 1.0, nested: 0.04, pill: 0.10, panel: 0.05, header: 0.08, rule: 0.60, border: 0.38)
            case (true, true): return Alphas(code: 0.09, quote: 0.09, bar: 1.0, nested: 0.05, pill: 0.14, panel: 0.06, header: 0.10, rule: 0.65, border: 0.42)
            }
        }
    }

    private typealias S = Palette.FullSurface

    /// Everything one variant (normal or Increase contrast) needs besides the text colours.
    private struct Variant {
        var tints: [String: (RGB, Double)] = [:]
        var surfaces: [S: RGB] = [:]
        var selection: (colour: RGB, alpha: Double) = (RGB(0, 0, 0), 0.5)
        var selectionSurfaces: [String: RGB] = [:]      // "page", "code", "quote": the selection over each
        var inactiveSurfaces: [String: RGB] = [:]       // the same for the selection of a window that is not key
        var note: String?
        var bannerWarning = RGB(0, 0, 0), bannerInfo = RGB(0, 0, 0)
        var colours: [SchemeRole: RGB] = [:]
        var barAlpha = 0.5
        var selectionInactive: (colour: RGB, alpha: Double) = (RGB(0, 0, 0), 0.15)
    }

    static func build(_ spec: SchemeSpec, info: ColorScheme) -> SchemeColors {
        let dark = spec.dark
        func c(_ h: UInt32) -> RGB { ColorMath.rgb(hex: h) }
        let bg = c(spec.bg), fg = c(spec.fg), comment = c(spec.comment), heading = c(spec.heading), accent = c(spec.accent)
        let link = c(spec.link), literal = c(spec.literal), warn = c(spec.warn), infoColour = c(spec.info), caret = c(spec.caret)
        let extreme = dark ? RGB(1, 1, 1) : RGB(0, 0, 0)
        var notes: [String] = []

        // ---- 1. roles: authentic base colours
        let base: [SchemeRole: RGB] = [
            .text: fg,
            .quoteText: ColorMath.mix(fg, comment, 0.5),
            .struck: ColorMath.mix(fg, comment, 0.75),
            .heading: heading,
            .headingMuted: ColorMath.mix(heading, fg, 0.4),
            .accent: accent,
            .link: link,
            .linkDestination: ColorMath.mix(fg, comment, 0.65),
            .copper: literal,
            .codeText: fg,
            .frontMatter: ColorMath.mix(fg, comment, 0.5),
            .html: ColorMath.mix(fg, comment, 0.85),
            .marker: comment,
            .caret: caret,
        ]

        // ---- the selection the theme shows over the page, made visible if the theme's is too faint
        var sel: RGB
        switch spec.selection {
        case .opaque(let h): sel = c(h)
        case .over(let h, let a): sel = ColorMath.over(c(h), a, bg)
        }
        sel = ColorMath.quantize(sel)
        var strengthened = 0
        while ColorMath.ratio(sel, bg) < ColorSchemes.selectionVisibleTarget && strengthened < 40 {
            sel = ColorMath.quantize(ColorMath.mix(sel, fg, 0.05)); strengthened += 1
        }
        if strengthened > 0 { notes.append("selection colour strengthened towards the text colour (\(strengthened) steps of 5 %) to be visible against the page: \(ColorMath.hex(sel))") }

        // ---- 2 + 3. tints and surfaces, normal and Increase contrast
        func makeVariant(hc: Bool) -> Variant {
            let a = Alphas.of(dark: dark, hc: hc)
            var v = Variant()
            let ruleInk = ColorMath.mix(fg, extreme, 0.6)
            v.tints = ["code": (fg, a.code), "quote": (accent, a.quote), "nested": (accent, a.nested), "pill": (literal, a.pill), "panel": (fg, a.panel),
                       "header": (fg, a.header), "rule": (ruleInk, a.rule), "border": (ruleInk, a.border)]
            func tint(_ k: String, over base: RGB) -> RGB { ColorMath.over(v.tints[k]!.0, v.tints[k]!.1, base) }
            let quote = tint("quote", over: bg), panel = tint("panel", over: bg)
            v.surfaces = [.plain: bg, .code: tint("code", over: bg), .quote: quote, .nestedQuote: tint("nested", over: tint("nested", over: quote)),
                          .codeInQuote: tint("code", over: quote), .pill: tint("pill", over: bg), .pillInQuote: tint("pill", over: quote),
                          .panel: panel, .tableHeader: tint("header", over: panel)]
            // the selection: a translucent paint colour C at alpha p with p*C + (1-p)*page == the theme's selection colour over the page, the smallest p >= 0.5 (0.55 with
            // Increase contrast) for which C is a valid colour. If the theme's selection is so strong that even the extreme text colour (white / black) could not reach 5.5:1
            // (8:1 with Increase contrast) on it over the page, a code band or a quote band, it is weakened towards the page in steps of 12 % (a selection must leave the text
            // legible, and stay at least as visible as the target).
            let extremeText = extreme
            let target = hc ? 8.0 : 5.5
            /// What the AUTHENTIC text colour must keep on the selection and the banners (normal variant): the 4.5:1 of the rule, or what it has on the page itself when that is less
            /// (Solarized Light's text is 4.1:1 on its page; it is adjusted for that, the selection must not make it worse). With Increase contrast the text is pushed to the extreme
            /// anyway: there the surfaces only have to leave room for it.
            let keepFg = hc ? 0.0 : min(4.5, ColorMath.ratio(fg, bg)) + 0.02
            func solvePaint(_ wanted: RGB, from p0: Double) -> (paint: RGB, alpha: Double) {
                var p = p0
                var paint = RGB(0, 0, 0)
                while true {
                    paint = (wanted - bg * (1 - p)) / p
                    let ok = paint.x >= -0.0001 && paint.x <= 1.0001 && paint.y >= -0.0001 && paint.y <= 1.0001 && paint.z >= -0.0001 && paint.z <= 1.0001
                    if ok || p >= 0.999 { break }
                    p = min(1, p + 0.05)
                }
                return (ColorMath.clamp01(paint), p)
            }
            func surfacesUnder(_ paint: RGB, _ p: Double) -> [String: RGB] {
                ["page": ColorMath.over(paint, p, v.surfaces[.plain]!), "code": ColorMath.over(paint, p, v.surfaces[.code]!), "quote": ColorMath.over(paint, p, v.surfaces[.quote]!)]
            }
            func worst(_ colour: RGB, _ surfaces: [String: RGB]) -> Double { surfaces.values.map { ColorMath.ratio(colour, $0) }.min() ?? 99 }
            var selV = sel
            var weakened = 0
            while true {
                let (paint, p) = solvePaint(selV, from: hc ? 0.55 : 0.5)
                v.selection = (paint, p)
                v.selectionSurfaces = surfacesUnder(paint, p)
                let next = ColorMath.quantize(ColorMath.mix(selV, bg, 0.12))
                if (worst(extremeText, v.selectionSurfaces) >= target && worst(fg, v.selectionSurfaces) >= keepFg) || weakened >= 12 || ColorMath.ratio(next, bg) < ColorSchemes.selectionVisibleTarget { break }    // never weaker than visible
                selV = next; weakened += 1
            }
            if weakened > 0 { v.note = "the selection colour is weakened towards the page (\(weakened) steps of 12 %, now \(ColorMath.hex(selV)) over the page) so that the text keeps its contrast on it" }
            // the selection of a window that is not key: the active one, desaturated to a third and 35 % closer to the page (a quieter, greyer version of the same colour)
            let (selL, selC, selH) = ColorMath.oklch(selV)
            let grey = ColorMath.rgb(L: selL, C: selC * 0.35, h: selH)
            var f = 0.65
            var quiet = ColorMath.mix(bg, grey, f)
            while ColorMath.ratio(quiet, bg) < 1.09 && f < 1 { f = min(1, f + 0.05); quiet = ColorMath.mix(bg, grey, f) }
            var (quietPaint, quietAlpha) = solvePaint(quiet, from: 0.5)
            while f > 0.45 && (worst(extremeText, surfacesUnder(quietPaint, quietAlpha)) < target || worst(fg, surfacesUnder(quietPaint, quietAlpha)) < keepFg) && ColorMath.ratio(ColorMath.mix(bg, grey, f - 0.05), bg) >= 1.09 {
                f -= 0.05
                quiet = ColorMath.mix(bg, grey, f)
                (quietPaint, quietAlpha) = solvePaint(quiet, from: 0.5)
            }
            v.selectionInactive = (quietPaint, quietAlpha)
            v.inactiveSurfaces = surfacesUnder(quietPaint, quietAlpha)
            // the banners: the theme's warm / blue colour over the page; lighter (down to 8 %) until the authentic text keeps its contrast on it and the extreme text colour reaches 9:1
            var warnAlpha = 0.24, infoAlpha = 0.20
            func bannerOK(_ colour: RGB, _ alpha: Double) -> Bool { let b = ColorMath.quantize(ColorMath.over(colour, alpha, bg)); return ColorMath.ratio(extremeText, b) >= 9 && ColorMath.ratio(fg, b) >= keepFg }
            while warnAlpha > 0.08 && !bannerOK(warn, warnAlpha) { warnAlpha -= 0.02 }
            while infoAlpha > 0.08 && !bannerOK(infoColour, infoAlpha) { infoAlpha -= 0.02 }
            v.bannerWarning = ColorMath.quantize(ColorMath.over(warn, warnAlpha, bg))
            v.bannerInfo = ColorMath.quantize(ColorMath.over(infoColour, infoAlpha, bg))
            return v
        }
        var normal = makeVariant(hc: false)
        var high = makeVariant(hc: true)

        // ---- 4. legibility: fit every role to the union of its rows (+ the selection, + the banners for the text)
        func needs(for role: SchemeRole, in v: Variant, hc: Bool) -> [ColorMath.Need] {
            var list: [ColorMath.Need] = []
            func add(_ surface: RGB, _ min: Double) { list.append(ColorMath.Need(surface: surface, min: min)) }
            switch role {
            case .caret:
                for s in ColorSchemes.caretSurfaces { add(v.surfaces[s]!, 3.0) }
            default:
                var seen = Set<S>()
                for rule in ColorSchemes.contrastRules where rule.role == role {
                    for s in rule.on where !seen.contains(s) { seen.insert(s); add(v.surfaces[s]!, hc ? rule.minHC : rule.min) }
                }
                if role == .frontMatter, !seen.contains(.plain) { add(v.surfaces[.plain]!, hc ? 7 : 4.5) }      // the `theme` scenario checks it on the page too
            }
            // on the selection
            switch role {
            case .text, .codeText:
                for k in ["page", "code", "quote"] {
                    add(v.selectionSurfaces[k]!, hc ? ColorSchemes.selectionTextMin.highContrast : ColorSchemes.selectionTextMin.normal)
                    add(v.inactiveSurfaces[k]!, hc ? ColorSchemes.selectionTextMin.highContrast : ColorSchemes.selectionTextMin.normal)
                }
            case .heading, .link, .accent, .copper, .quoteText:
                for k in ["page", "code", "quote"] { add(v.selectionSurfaces[k]!, ColorSchemes.selectionColouredMin) }
            case .marker:
                for k in ["page", "code", "quote"] { add(v.selectionSurfaces[k]!, ColorSchemes.selectionMarkerMin) }
            default: break
            }
            if role == .text { add(v.bannerWarning, hc ? 7 : 4.5); add(v.bannerInfo, hc ? 7 : 4.5) }
            return list
        }
        for role in SchemeRole.allCases {
            guard spec.adjustsForLegibility else { normal.colours[role] = base[role]!; high.colours[role] = base[role]!; continue }     // a custom scheme: the colours as picked
            let n = ColorMath.fit(base[role]!, needs: needs(for: role, in: normal, hc: false), towardsLight: dark)
            normal.colours[role] = n
            high.colours[role] = ColorMath.fit(n, needs: needs(for: role, in: high, hc: true), towardsLight: dark)
        }
        // the quote bar: the adjusted accent at the tint's alpha, raised until it stands out of the quote tint (1.8:1; 3:1 with Increase contrast)
        for hc in [false, true] {
            var v = hc ? high : normal
            let barColour = v.colours[.accent]!
            var alpha = Alphas.of(dark: dark, hc: hc).bar
            let quote = v.surfaces[.quote]!
            let need = hc ? 3.0 : 1.8
            while alpha < 1, ColorMath.ratio(ColorMath.over(barColour, alpha, quote), quote) < need { alpha = min(1, alpha + 0.05) }
            v.barAlpha = alpha
            if hc { high = v } else { normal = v }
        }

        // ---- NSColors
        func ns(_ c: RGB, _ alpha: Double = 1) -> NSColor { NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(alpha)) }
        /// One colour that is `n` normally and `h` with Increase contrast (a plain colour when both are the same).
        func fixed(_ n: RGB, _ h: RGB, nAlpha: Double = 1, hAlpha: Double = 1) -> NSColor {
            let nc = ns(n, nAlpha), hc = ns(h, hAlpha)
            if n == h && nAlpha == hAlpha { return nc }
            return NSColor(name: nil) { _ in ContrastWatcher.shared.increase ? hc : nc }
        }
        func role(_ r: SchemeRole) -> NSColor { fixed(normal.colours[r]!, high.colours[r]!) }
        func tint(_ k: String) -> NSColor { fixed(normal.tints[k]!.0, high.tints[k]!.0, nAlpha: normal.tints[k]!.1, hAlpha: high.tints[k]!.1) }

        let linkColour = role(.link)
        let headingMuted = role(.headingMuted), accentColour = role(.accent), linkDestination = role(.linkDestination), copperColour = role(.copper)
        let prose = SchemeColors.Prose(
            background: ns(bg), text: role(.text), quoteText: role(.quoteText), struck: role(.struck), heading: role(.heading), headingMuted: headingMuted,
            accent: accentColour, marker: role(.marker), link: linkColour, linkUnderline: fixed(normal.colours[.link]!, high.colours[.link]!, nAlpha: 0.5, hAlpha: 0.5),
            linkDestination: linkDestination, image: accentColour, footnote: headingMuted, escape: copperColour, copper: copperColour, codeText: role(.codeText),
            inlineCode: copperColour, codeLanguage: accentColour, listMarker: accentColour, taskUnchecked: linkDestination, tableText: role(.text),
            frontMatter: role(.frontMatter), html: role(.html))
        let decor = SchemeColors.Decor(
            codeBand: tint("code"), quoteBand: tint("quote"),
            quoteBar: fixed(normal.colours[.accent]!, high.colours[.accent]!, nAlpha: normal.barAlpha, hAlpha: high.barAlpha),
            nestedBand: tint("nested"), inlinePill: tint("pill"), panelBand: tint("panel"), tableHeaderBand: tint("header"), rule: tint("rule"), bandBorder: tint("border"))

        // selection fills by PaletteVariant.rawValue: light, dark, lightHC, darkHC (a fixed scheme only ever asks for its own kind; the other two repeat it)
        let selNormal = ns(normal.selection.colour, normal.selection.alpha), selHigh = ns(high.selection.colour, high.selection.alpha)
        let inNormal = ns(normal.selectionInactive.colour, normal.selectionInactive.alpha), inHigh = ns(high.selectionInactive.colour, high.selectionInactive.alpha)
        let selection = SchemeColors.Selection(active: [selNormal, selNormal, selHigh, selHigh], inactive: [inNormal, inNormal, inHigh, inHigh])
        let alphas: [CGFloat] = [CGFloat(normal.selection.alpha), CGFloat(normal.selection.alpha), CGFloat(high.selection.alpha), CGFloat(high.selection.alpha)]

        // ---- the report
        if let n = normal.note { notes.append(n + " (normal variant)") }
        if let n = high.note { notes.append(n + " (Increase contrast variant)") }
        var report = SchemeReport(rows: [], notes: notes)
        let names: [(SchemeRole, String)] = [(.text, "body text / code text"), (.quoteText, "quote text"), (.struck, "strikethrough"), (.heading, "heading"),
                                             (.headingMuted, "heading h5/h6, footnote"), (.accent, "accent (list marker, checked task, code language, image, quote bar)"),
                                             (.link, "link"), (.linkDestination, "link destination, unchecked task"), (.copper, "inline code, escape"),
                                             (.frontMatter, "front matter"), (.html, "html / comment"), (.marker, "syntax marker"), (.caret, "insertion point")]
        for (r, name) in names { report.rows.append(SchemeReport.Row(role: name, authentic: base[r]!, normal: normal.colours[r]!, highContrast: high.colours[r]!)) }
        return SchemeColors(info: info, serial: ColorSchemes.nextSerial(), isDark: dark, prose: prose, decor: decor, caret: role(.caret),
                            bannerWarning: ns(normal.bannerWarning), bannerInfo: ns(normal.bannerInfo), selection: selection, selectionAlphas: alphas, report: report)
    }
}
