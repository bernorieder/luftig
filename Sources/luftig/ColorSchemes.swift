import AppKit

// ColorSchemes.swift - the colour schemes of the editor: the public contract (`SchemeAppearance`, `ColorScheme`, `ColorSchemes`), the container of
// the precomputed colours of one scheme (`SchemeColors`), and the DEFAULT scheme "luftig" (exactly the palette luftig always had).
//
// Layers (see docs/color-schemes.md):
//   ColorSchemesData.swift   the authentic palettes of well-known editor themes (hex values and where they come from)
//   ColorSchemesBuild.swift  authentic palette -> Markdown roles -> tints -> deterministic legibility adjustment -> `SchemeColors`
//   ColorSchemesMath.swift   WCAG contrast, OKLab / OKLCH, the adjustment step
//   Palette.swift            what the rest of the app reads (`Palette.heading`, ...): computed from the CURRENT scheme; `Palette.apply(schemeID:)`
//
// Main thread only, like the rest of the styling code.

/// What a scheme asks of the macOS appearance.
enum SchemeAppearance {
    /// Follows the macOS appearance (light or dark, and "Increase contrast"). Only the default scheme.
    case system
    /// The scheme IS light: `Palette.apply` forces the light appearance (Aqua) for the whole app.
    case light
    /// The scheme IS dark: `Palette.apply` forces the dark appearance (Dark Aqua) for the whole app.
    case dark
}

/// One selectable scheme, as the Settings window lists it. Two schemes are equal when their ids are (`Identifiable`, `Hashable` for lists and menus).
struct ColorScheme: Identifiable, Hashable {
    let id: String
    let name: String
    /// The theme family ("Solarized" for Solarized Light and Dark): Settings can group by it.
    let family: String
    let appearance: SchemeAppearance
    /// ~5 representative colours for a menu or a preview: page, text, heading, link, code (in the scheme's own light or, for the default, the light appearance).
    let swatch: [NSColor]

    static func == (a: ColorScheme, b: ColorScheme) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ColorSchemes {
    /// The scheme that is used when nothing is chosen, and for an unknown id.
    static let defaultID = "luftig"

    /// All schemes, the default first, then the families in the order of the Settings list, then the imported ones (SchemeImport: files in Application
    /// Support, read once at first use and again after an import).
    static var all: [ColorScheme] {
        if let a = cachedAll { return a }
        let a = [defaultScheme] + SchemeSpec.all.map { $0.scheme } + imported.map { $0.scheme }
        cachedAll = a
        return a
    }
    nonisolated(unsafe) private static var cachedAll: [ColorScheme]?
    nonisolated(unsafe) private static var importedSpecs: [SchemeSpec]?
    /// The imported schemes (files), loaded at first use.
    static var imported: [SchemeSpec] {
        if let s = importedSpecs { return s }
        let s = SchemeImport.load()
        importedSpecs = s
        return s
    }
    /// Reads the imported schemes' folder again (after an import, or when files were removed); a scheme that was rebuilt gets fresh colours.
    static func reloadImported() {
        let fresh = SchemeImport.load()
        for s in fresh { resolvedCache.removeValue(forKey: s.id) }
        importedSpecs = fresh
        cachedAll = nil
    }

    /// The scheme with this id; an unknown id (a preference written by a newer version, a typo) gives the default. The draft of Settings > Colors
    /// (`CustomScheme.draftID`) resolves while there is one; it is not in `all` (never listed, never stored).
    static func scheme(withID id: String) -> ColorScheme {
        if id == CustomScheme.draftID, let d = draft { return d.scheme }
        return all.first { $0.id == id } ?? all[0]
    }

    /// The scheme being edited in Settings > Colors (nil: none). Setting it drops the colours built for the previous draft.
    nonisolated(unsafe) static var draft: SchemeSpec? {
        didSet { resolvedCache.removeValue(forKey: CustomScheme.draftID) }
    }

    // MARK: resolved colours

    nonisolated(unsafe) private static var resolvedCache: [String: SchemeColors] = [:]
    nonisolated(unsafe) private static var serialCounter = 0
    static func nextSerial() -> Int { serialCounter += 1; return serialCounter }

    /// The precomputed colours of a scheme. Built on first use (the default: from the fixed table below; the others: the adjustment step runs once, ~1 ms)
    /// and kept: switching back and forth never recomputes anything.
    static func colors(for scheme: ColorScheme) -> SchemeColors {
        if let c = resolvedCache[scheme.id] { return c }
        let c: SchemeColors
        if scheme.id == defaultID { return defaultColors }
        else if scheme.id == CustomScheme.draftID, let d = draft { c = SchemeBuilder.build(d, info: scheme) }
        else if let spec = SchemeSpec.all.first(where: { $0.id == scheme.id }) ?? imported.first(where: { $0.id == scheme.id }) { c = SchemeBuilder.build(spec, info: scheme) }
        else { c = colors(for: all[0]) }
        resolvedCache[scheme.id] = c
        return c
    }

    // MARK: the default scheme "luftig"

    static let defaultScheme = ColorScheme(
        id: defaultID, name: "luftig", family: "luftig", appearance: .system,
        swatch: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), NSColor(srgbRed: 46 / 255, green: 50 / 255, blue: 62 / 255, alpha: 1),
                 NSColor(srgbRed: 34 / 255, green: 40 / 255, blue: 118 / 255, alpha: 1), NSColor(srgbRed: 0, green: 92 / 255, blue: 200 / 255, alpha: 1),
                 NSColor(srgbRed: 168 / 255, green: 58 / 255, blue: 0, alpha: 1)])

    static let defaultColors: SchemeColors = makeDefaultColors(info: defaultScheme)

    /// EXACTLY the palette luftig had before there were schemes (values unchanged: the screenshots and the visual tests are the reference).
    /// ONE restrained accent family plus ONE warm accent, everything else neutral:
    ///   * indigo / blue (hue ~235): structure. Headings (deep ink), links (clearer blue, always underlined), checked tasks, list markers,
    ///     the code-language label, image alt text, footnote labels, the caret, the quote bar and the quote tint.
    ///   * copper (hue ~20): literal text. Inline code and backslash escapes - the only warm colour, so code spans pop out of prose.
    ///   * neutrals: body text (the system label colour), syntax markers, link destinations, quotes, struck text, comments / HTML, front matter,
    ///     tables, code bands. Nothing is red, green, teal or purple.
    /// Separable for colour-blind readers by construction: the two families sit on the blue-yellow axis (which protan / deutan / tritan
    /// vision keep), and every colour has a second cue that is not a colour (headings are bigger and bold, links are underlined, code is
    /// monospaced on a pill / band, quotes have a bar and an indent).
    private static func makeDefaultColors(info: ColorScheme) -> SchemeColors {
        typealias C = (Int, Int, Int)
        func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a) }
        /// text colours: (light, dark, light high contrast, dark high contrast)
        func ink(_ l: C, _ d: C, _ lhc: C, _ dhc: C) -> NSColor {
            Palette.dynamic(rgb(l.0, l.1, l.2), rgb(d.0, d.1, d.2), hcLight: rgb(lhc.0, lhc.1, lhc.2), hcDark: rgb(dhc.0, dhc.1, dhc.2))
        }
        /// translucent decoration colours: (colour, alpha) per variant
        func tint(_ l: (C, CGFloat), _ d: (C, CGFloat), _ lhc: (C, CGFloat), _ dhc: (C, CGFloat)) -> NSColor {
            func c(_ x: (C, CGFloat)) -> NSColor { rgb(x.0.0, x.0.1, x.0.2, x.1) }
            return Palette.dynamic(c(l), c(d), hcLight: c(lhc), hcDark: c(dhc))
        }
        let background = NSColor.textBackgroundColor                      // the page (system semantic colour: follows the appearance)
        let text = Palette.dynamic(NSColor.labelColor, NSColor.labelColor, hcLight: .black, hcDark: .white)
        let quoteText = ink((74, 80, 100), (184, 188, 204), (40, 44, 60), (224, 228, 240))       // muted slate, still >= 4.5:1 on the quote tint
        let struck = ink((96, 100, 114), (162, 166, 178), (62, 66, 80), (208, 212, 222))          // also occurs in table cells, on the header row tint: 4.7:1 there; the first values, 104 / 156, were 4.25 and 4.40
        let heading = ink((34, 40, 118), (196, 204, 255), (20, 24, 90), (214, 220, 255))          // deep indigo ink; levels 5 and 6 use the muted variant
        let headingMuted = ink((78, 84, 140), (162, 170, 222), (48, 54, 112), (204, 210, 246))
        let accent = ink((64, 70, 196), (148, 158, 255), (40, 46, 170), (200, 206, 255))          // checked tasks, list markers, the code-language label, image alt text, the caret
        let marker = ink((124, 128, 140), (142, 146, 158), (84, 88, 100), (190, 194, 206))        // syntax punctuation: dim but >= 3:1 (>= 4.5:1 with Increase contrast)
        let link = ink((0, 92, 200), (100, 168, 255), (0, 60, 160), (176, 214, 255))
        let linkDestination = ink((94, 100, 116), (158, 164, 180), (60, 66, 82), (206, 210, 222))
        let copper = ink((168, 58, 0), (255, 156, 108), (116, 32, 0), (255, 204, 176))             // the warm accent: inline code, backslash escapes
        let codeText = ink((46, 50, 62), (222, 226, 234), (0, 0, 0), (255, 255, 255))
        let prose = SchemeColors.Prose(
            background: background, text: text, quoteText: quoteText, struck: struck, heading: heading, headingMuted: headingMuted, accent: accent,
            marker: marker, link: link, linkUnderline: link.withAlphaComponent(0.5), linkDestination: linkDestination, image: accent, footnote: headingMuted,
            escape: copper, copper: copper, codeText: codeText, inlineCode: copper, codeLanguage: accent, listMarker: accent, taskUnchecked: linkDestination,
            tableText: NSColor.labelColor, frontMatter: ink((76, 84, 106), (168, 176, 198), (48, 54, 72), (214, 220, 234)),
            html: ink((84, 94, 112), (158, 168, 186), (52, 60, 76), (210, 216, 230)))
        // decoration colours (translucent on purpose: the text, the selection and what lies below stay readable)
        let decor = SchemeColors.Decor(
            codeBand: tint(((30, 36, 60), 0.055), ((204, 219, 255), 0.085), ((30, 36, 60), 0.08), ((204, 219, 255), 0.09)),
            quoteBand: tint(((64, 70, 196), 0.05), ((148, 158, 255), 0.085), ((64, 70, 196), 0.07), ((148, 158, 255), 0.09)),
            quoteBar: tint(((64, 70, 196), 0.55), ((148, 158, 255), 0.65), ((40, 46, 170), 1.0), ((200, 206, 255), 1.0)),
            nestedBand: tint(((64, 70, 196), 0.04), ((148, 158, 255), 0.06), ((64, 70, 196), 0.04), ((148, 158, 255), 0.05)),      // an extra tint for each nesting level of a quote
            inlinePill: tint(((168, 58, 0), 0.09), ((255, 156, 108), 0.15), ((168, 58, 0), 0.10), ((255, 156, 108), 0.14)),
            panelBand: tint(((30, 36, 60), 0.035), ((204, 219, 255), 0.05), ((30, 36, 60), 0.05), ((204, 219, 255), 0.06)),        // tables and front matter: lighter than code
            tableHeaderBand: tint(((30, 36, 60), 0.075), ((204, 219, 255), 0.10), ((30, 36, 60), 0.08), ((204, 219, 255), 0.10)),
            rule: tint(((0, 0, 0), 0.26), ((255, 255, 255), 0.30), ((0, 0, 0), 0.60), ((255, 255, 255), 0.65)),
            bandBorder: tint(((0, 0, 0), 0), ((0, 0, 0), 0), ((0, 0, 0), 0.38), ((255, 255, 255), 0.42)))                   // a hairline, only with Increase contrast
        return SchemeColors(info: info, serial: nextSerial(), isDark: false, prose: prose, decor: decor,
                            caret: accent,
                            bannerWarning: Palette.dynamic(rgb(255, 240, 196), rgb(76, 62, 22)), bannerInfo: Palette.dynamic(rgb(222, 236, 255), rgb(28, 50, 84)),
                            // NSTextView paints the selection OPAQUE; `LuftigLayoutManager` paints the system selection colour at this alpha instead (see there)
                            selection: nil, selectionAlphas: [0.65, 0.50, 0.75, 0.55], report: nil)
    }
}

/// All colours of one scheme as the editor reads them: precomputed `NSColor` objects (hot paths read them on every style-cache fill and draw pass).
/// A class, so that reading one colour out of `Palette.current` never copies the other forty (`Palette` keeps ONE in a static variable).
final class SchemeColors {
    struct Prose {
        let background, text, quoteText, struck, heading, headingMuted, accent, marker: NSColor
        let link, linkUnderline, linkDestination, image, footnote, escape, copper, codeText: NSColor
        let inlineCode, codeLanguage, listMarker, taskUnchecked, tableText, frontMatter, html: NSColor
    }
    struct Decor {
        let codeBand, quoteBand, quoteBar, nestedBand, inlinePill, panelBand, tableHeaderBand, rule, bandBorder: NSColor
    }
    /// The selection of a fixed scheme, one entry per `PaletteVariant.rawValue`: the translucent fill of the active selection, and of the selection in a
    /// window that is not key.
    struct Selection {
        let active: [NSColor]
        let inactive: [NSColor]
    }

    let info: ColorScheme
    /// Unique per resolved scheme (and constant for it): caches that depend on the colours key on it.
    let serial: Int
    /// A fixed scheme that is dark (a light scheme and the system scheme: false).
    let isDark: Bool
    let prose: Prose
    let decor: Decor
    /// The insertion point colour.
    let caret: NSColor
    let bannerWarning: NSColor
    let bannerInfo: NSColor
    /// nil for the system scheme (the system selection colour is used, see `LuftigLayoutManager.selectionFillColor`).
    let selection: Selection?
    /// By `PaletteVariant.rawValue`: how opaque the selection is painted (the system colour for the default scheme; the scheme's own colour otherwise).
    let selectionAlphas: [CGFloat]
    /// What the legibility step changed (fixed schemes only): for the documentation and the self-test.
    let report: SchemeReport?

    var isSystem: Bool { info.appearance == .system }

    init(info: ColorScheme, serial: Int, isDark: Bool, prose: Prose, decor: Decor, caret: NSColor, bannerWarning: NSColor, bannerInfo: NSColor,
         selection: Selection?, selectionAlphas: [CGFloat], report: SchemeReport?) {
        self.info = info; self.serial = serial; self.isDark = isDark; self.prose = prose; self.decor = decor; self.caret = caret
        self.bannerWarning = bannerWarning; self.bannerInfo = bannerInfo; self.selection = selection; self.selectionAlphas = selectionAlphas; self.report = report
    }

    /// The palette variant for an appearance. The system scheme follows the appearance; a fixed scheme IS light or dark whatever the window says
    /// (so a stray `window.appearance` can never give light text on a light page); both follow the "Increase contrast" switch.
    func variant(for appearance: NSAppearance) -> PaletteVariant {
        if isSystem { return Palette.systemVariant(for: appearance) }
        switch (isDark, ContrastWatcher.shared.increase) {
        case (false, false): return .light
        case (true, false): return .dark
        case (false, true): return .lightHC
        case (true, true): return .darkHC
        }
    }
}

/// What the legibility step did to one scheme (fixed schemes): per role the authentic colour and the colour in use, in the normal and the
/// "Increase contrast" variant.
struct SchemeReport {
    struct Row {
        let role: String
        /// The colour the role would have without any adjustment (the theme's own colour, or a mix of two of them).
        let authentic: RGB
        let normal: RGB
        let highContrast: RGB
        var normalChanged: Bool { ColorMath.hex(authentic) != ColorMath.hex(normal) }
        /// Change of the OKLCH lightness, in points of 100.
        var normalDeltaL: Double { ColorMath.deltaL(from: authentic, to: normal) }
        var highContrastDeltaL: Double { ColorMath.deltaL(from: normal, to: highContrast) }
    }
    var rows: [Row] = []
    /// Notes about the non-colour adjustments (the selection made visible, ...).
    var notes: [String] = []
}
