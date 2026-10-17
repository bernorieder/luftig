import AppKit

// Palette.swift - every colour luftig uses, read from ONE place. The values come from the CURRENT colour scheme (ColorSchemes.swift): the default scheme
// "luftig" is the palette luftig always had (all colours dynamic: light, dark, and the high-contrast variants when the system asks for "Increase contrast");
// the other schemes are well-known editor themes (a fixed light or dark look, see docs/color-schemes.md).
//
// The accessors (`Palette.heading`, `Palette.codeBand`, ...) keep their names and types; they are read in hot paths (every style-cache fill, every draw
// pass), so they are plain loads of colour objects that were created once per scheme. `Palette.apply(schemeID:)` makes another scheme current.
// A `Theme` caches colour OBJECTS in its attribute dictionaries: after `apply`, build a new `Theme` (what the font-size path already does) and restyle.
//
// Legibility: the text colours of every scheme are verified >= 4.5:1 against the surface they sit on (page, code band, quote tint, inline-code pill, table /
// front matter panel), syntax markers >= 3:1 (7:1 and 4.5:1 with Increase contrast), by the `visual-contrast` self-test, which runs over every scheme.

/// Which of the four palettes an appearance asks for.
enum PaletteVariant: Int {
    case light, dark, lightHC, darkHC
    var isDark: Bool { self == .dark || self == .darkHC }
    var isHighContrast: Bool { self == .lightHC || self == .darkHC }
}

/// The system "Increase contrast" switch (System Settings > Accessibility > Display). AppKit exposes it only as a global flag (measured: the
/// `.accessibilityHighContrastAqua` appearance object has the name `Aqua` and resolves every colour like Aqua; the system colours switch on the flag),
/// so a custom palette follows the flag. The value is cached (reading NSWorkspace for every colour resolution would be slow); a change repaints every text view.
final class ContrastWatcher {
    nonisolated(unsafe) static let shared = ContrastWatcher()
    nonisolated(unsafe) private var system: Bool
    /// Self-test / render only: pretend the switch is on / off.
    nonisolated(unsafe) var override: Bool?
    var increase: Bool { override ?? system }
    private var observer: NSObjectProtocol?
    private init() {
        system = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.system = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            for w in NSApp.windows { if let v = w.contentView { ContrastWatcher.redisplay(v) } }
        }
    }
    private static func redisplay(_ v: NSView) {
        if v is NSTextView { v.needsDisplay = true }
        for s in v.subviews { redisplay(s) }
    }
}

enum Palette {
    // MARK: the current scheme

    /// The colours of the current scheme. Main thread only.
    nonisolated(unsafe) private(set) static var current: SchemeColors = ColorSchemes.defaultColors

    /// The current scheme (id, name, family, appearance, swatch).
    static var scheme: ColorScheme { current.info }
    /// True for the default scheme (system colours, follows the macOS appearance).
    static var isSystemScheme: Bool { current.isSystem }
    /// Unique per scheme and constant for it; changes when `apply` really switches. Caches of derived colours key on it.
    static var serial: Int { current.serial }

    /// Posted (object = nil, main thread) after `apply` switched to another scheme and the appearance of the app was set accordingly. Text views and the
    /// banner listen to repaint with the new page colour, caret and decorations; the editors rebuild their `Theme` through `EditorPreferences.didChange`.
    static let didChangeNotification = Notification.Name("LuftigPaletteDidChange")

    /// Makes the scheme with this id current (an unknown id: the default) and forces the app's appearance: Aqua for a light scheme, Dark Aqua for a dark one,
    /// nil (follow the system) for the default. Callable repeatedly; main thread. A real switch posts `didChangeNotification` and marks the text views
    /// of the open windows for redisplay.
    static func apply(schemeID id: String) {
        let target = ColorSchemes.colors(for: ColorSchemes.scheme(withID: id))
        let appearance: NSAppearance?
        switch target.info.appearance {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        let changed = target.serial != current.serial
        current = target
        if let app = NSApp, app.appearance?.name != appearance?.name { app.appearance = appearance }
        guard changed else { return }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        if let app = NSApp { for w in app.windows { if let v = w.contentView { redisplay(v) } } }
    }

    private static func redisplay(_ v: NSView) {
        if v is NSTextView { v.needsDisplay = true }
        for s in v.subviews { redisplay(s) }
    }

    // MARK: variants

    /// The palette variant for an appearance under the CURRENT scheme: the system scheme follows the appearance (dark or light, and the high-contrast
    /// variant when "Increase contrast" is on); a fixed scheme is light or dark by itself.
    static func variant(for appearance: NSAppearance) -> PaletteVariant { current.variant(for: appearance) }

    /// The variant the macOS appearance asks for (the default scheme's rule).
    static func systemVariant(for appearance: NSAppearance) -> PaletteVariant {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch (dark, ContrastWatcher.shared.increase) {
        case (false, false): return .light
        case (true, false): return .dark
        case (false, true): return .lightHC
        case (true, true): return .darkHC
        }
    }

    /// A colour of the DEFAULT scheme that resolves differently per variant (also for views that are not on screen). `light` / `dark` are the normal palettes;
    /// the high-contrast pair falls back to them when not given. (It follows the macOS appearance, not the current scheme: the default scheme's colours stay
    /// right for old `Theme`s that still hold them while another scheme is current.)
    static func dynamic(_ light: NSColor, _ dark: NSColor, hcLight: NSColor? = nil, hcDark: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch systemVariant(for: appearance) {
            case .light: return light
            case .dark: return dark
            case .lightHC: return hcLight ?? light
            case .darkHC: return hcDark ?? dark
            }
        }
    }

    // MARK: background and prose

    /// The page.
    static var background: NSColor { current.prose.background }
    /// Body text.
    static var text: NSColor { current.prose.text }
    /// Block-quote text: muted, still >= 4.5:1 on the quote tint.
    static var quoteText: NSColor { current.prose.quoteText }
    /// Strikethrough text (it also occurs in table cells, on the header row tint).
    static var struck: NSColor { current.prose.struck }
    /// Heading text. Levels 5 and 6 use the muted variant.
    static var heading: NSColor { current.prose.heading }
    static var headingMuted: NSColor { current.prose.headingMuted }
    /// The accent: checked tasks, list markers, the code-language label, image alt text, the quote bar and tint.
    static var accent: NSColor { current.prose.accent }
    /// The insertion point.
    static var caret: NSColor { current.caret }

    // MARK: syntax punctuation (#, *, _, `, ~~, > , [ ] ( ), table pipes, fences): dim but >= 3:1 (>= 4.5:1 with Increase contrast)
    static var marker: NSColor { current.prose.marker }

    // MARK: links and references
    static var link: NSColor { current.prose.link }
    static var linkUnderline: NSColor { current.prose.linkUnderline }
    static var linkDestination: NSColor { current.prose.linkDestination }
    static var image: NSColor { current.prose.image }
    static var footnote: NSColor { current.prose.footnote }
    /// Backslash escapes and entities: literal text, so the warm colour.
    static var escape: NSColor { current.prose.escape }

    // MARK: code
    /// The literal-text colour (the warm accent of the default scheme).
    static var copper: NSColor { current.prose.copper }
    static var codeText: NSColor { current.prose.codeText }
    static var inlineCode: NSColor { current.prose.inlineCode }
    static var codeLanguage: NSColor { current.prose.codeLanguage }

    // MARK: lists
    static var listMarker: NSColor { current.prose.listMarker }
    static var taskUnchecked: NSColor { current.prose.taskUnchecked }

    // MARK: tables, front matter, html
    static var tableText: NSColor { current.prose.tableText }
    static var frontMatter: NSColor { current.prose.frontMatter }
    static var html: NSColor { current.prose.html }

    // MARK: decoration colours (translucent on purpose: the text, the selection and what lies below stay readable)
    static var codeBand: NSColor { current.decor.codeBand }
    static var quoteBand: NSColor { current.decor.quoteBand }
    static var quoteBar: NSColor { current.decor.quoteBar }
    /// An extra tint for each nesting level of a quote (drawn over the quote tint) and for code inside a quote.
    static var nestedBand: NSColor { current.decor.nestedBand }
    static var inlinePill: NSColor { current.decor.inlinePill }
    /// Tables and front matter: a lighter band than code; the header row of a table is tinted a little stronger.
    static var panelBand: NSColor { current.decor.panelBand }
    static var tableHeaderBand: NSColor { current.decor.tableHeaderBand }
    static var rule: NSColor { current.decor.rule }
    /// A hairline around bands. Only with Increase contrast (clear alpha otherwise): the band tint alone is not a boundary then.
    static var bandBorder: NSColor { current.decor.bandBorder }

    // MARK: the selection
    /// NSTextView paints the selection OPAQUE, over the bands and pills (the decorations are drawn first), so a band or a pill under
    /// the selection vanished, and in dark mode coloured text on the system selection colour was 1.7 - 2.7:1. `LuftigLayoutManager` draws the
    /// selection translucent instead: the system colour at this alpha over the page / band (default scheme), or the scheme's own selection colour
    /// (`selectionFill`). More text contrast, the band stays visible. Chosen by the `visual-contrast` self-test (body text >= 4.5:1, coloured text >= 3:1
    /// on the selection for every system accent colour; the same for every scheme).
    static func selectionAlpha(_ v: PaletteVariant) -> CGFloat { current.selectionAlphas[v.rawValue] }

    /// The translucent fill of the selection of a fixed scheme (nil for the default scheme: it uses the system selection colour).
    /// `active`: the window is key; otherwise the quieter fill of an inactive window.
    static func selectionFill(_ v: PaletteVariant, active: Bool) -> NSColor? {
        guard let s = current.selection else { return nil }
        return active ? s.active[v.rawValue] : s.inactive[v.rawValue]
    }

    // MARK: the notification strip above the text (opaque, so it reads the same over anything)
    static var bannerWarning: NSColor { current.bannerWarning }
    static var bannerInfo: NSColor { current.bannerInfo }

    // MARK: contrast table for the `theme` self-test (normal palettes): (name, foreground, min ratio, over what)
    enum Surface { case plain, code, quote, pill }
    static var textColorsToCheck: [(name: String, color: NSColor, minRatio: Double, surface: Surface)] {
        [
            ("body text", text, 4.5, .plain), ("quote text", quoteText, 4.5, .quote), ("strikethrough text", struck, 4.5, .plain),
            ("heading", heading, 4.5, .plain), ("heading (h5/h6)", headingMuted, 4.5, .plain), ("accent / checked task", accent, 4.5, .plain),
            ("link text", link, 4.5, .plain), ("link destination", linkDestination, 4.5, .plain), ("image alt", image, 4.5, .plain),
            ("footnote / reference label", footnote, 4.5, .plain), ("escape", escape, 4.5, .plain),
            ("code block text", codeText, 4.5, .code), ("code block text (on plain)", codeText, 4.5, .plain), ("code language", codeLanguage, 4.5, .code),
            ("inline code", inlineCode, 4.5, .pill), ("inline code (in a quote)", inlineCode, 4.5, .quote),
            ("list marker", listMarker, 4.5, .plain), ("list marker (in a quote)", listMarker, 4.5, .quote),
            ("unchecked task", taskUnchecked, 4.5, .plain), ("table text", tableText, 4.5, .plain),
            ("front matter", frontMatter, 4.5, .plain), ("html / comment", html, 4.5, .plain),
            ("link text (in a quote)", link, 4.5, .quote),
            ("syntax marker", marker, 3.0, .plain), ("syntax marker (on code band)", marker, 3.0, .code),
            ("syntax marker (in a quote)", marker, 3.0, .quote), ("syntax marker (in inline code)", marker, 3.0, .pill),
        ]
    }

    // MARK: the full table for the `visual-contrast` self-test (all variants, all surfaces)
    enum FullSurface: String, CaseIterable { case plain, code, quote, nestedQuote, codeInQuote, pill, pillInQuote, panel, tableHeader }

    /// The colour of a role in the current scheme.
    static func color(for role: SchemeRole) -> NSColor {
        switch role {
        case .text: return text
        case .quoteText: return quoteText
        case .struck: return struck
        case .heading: return heading
        case .headingMuted: return headingMuted
        case .accent: return accent
        case .link: return link
        case .linkDestination: return linkDestination
        case .copper: return copper
        case .codeText: return codeText
        case .frontMatter: return frontMatter
        case .html: return html
        case .marker: return marker
        case .caret: return caret
        }
    }

    /// (name, colour, min ratio on every listed surface, min ratio with Increase contrast, surfaces): `ColorSchemes.contrastRules` with the colours of the current scheme.
    static var fullContrastTable: [(name: String, color: NSColor, min: Double, minHC: Double, on: [FullSurface])] {
        ColorSchemes.contrastRules.map { (name: $0.name, color: color(for: $0.role), min: $0.min, minHC: $0.minHC, on: $0.on) }
    }
}
