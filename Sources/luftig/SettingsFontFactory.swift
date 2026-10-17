// SettingsFontFactory.swift
//
// Everything that decides how a `Theme` LOOKS apart from its colours (`ThemeSettings`), and the fonts behind it (`FontFactory`):
// a face of any installed family at any size / weight / slant, built through NSFontManager, with what the family cannot provide
// (no italic, no bold) faked by text attributes (`FontFace.addSyntheticAttributes`). Main thread only, like the Theme.

import AppKit

/// What a Theme is built from. `Equatable` so an editor can tell whether a preference change concerns it at all.
struct ThemeSettings: Equatable {
    /// Body font size in points; every other size (code, headings) derives from it.
    var baseSize: CGFloat = EditorPreferences.defaultFontSize
    /// Family of the text font; nil = the system font (SF Pro). A family that is not installed behaves like nil (the saved value is not touched).
    var bodyFamily: String?
    /// Family of the code font (code blocks, inline code, tables, front matter); nil = the system monospaced font (SF Mono).
    var codeFamily: String?
    /// Body line box as a multiple of the font size; nil = the automatic curve `Theme.lineHeightRatio(baseSize:)`.
    var lineHeightFactor: CGFloat?
}

/// One resolved face. `font` is always the size asked for. A family without an italic or bold face still gets italic / bold text: the
/// theme adds `.obliqueness` / `.strokeWidth` to the attributes of those runs (the font itself cannot carry it).
struct FontFace {
    let font: NSFont
    /// The family has no italic for this request: draw the glyphs slanted.
    let syntheticItalic: Bool
    /// 0 = the face has the weight, 1 = semibold faked by a thin stroke, 2 = bold faked by a stroke.
    let syntheticWeight: Int
    var isSynthetic: Bool { syntheticItalic || syntheticWeight > 0 }

    static let obliqueness = 0.2
    static let semiboldStroke = -1.5
    static let boldStroke = -3.0

    func addSyntheticAttributes(to attributes: inout TextAttributes) {
        if syntheticItalic { attributes[.obliqueness] = NSNumber(value: FontFace.obliqueness) }
        if syntheticWeight == 2 { attributes[.strokeWidth] = NSNumber(value: FontFace.boldStroke) }
        else if syntheticWeight == 1 { attributes[.strokeWidth] = NSNumber(value: FontFace.semiboldStroke) }
    }
}

enum FontFactory {
    private struct Key: Hashable { var family: String?; var mono: Bool; var size: CGFloat; var weight: CGFloat; var italic: Bool }

    nonisolated(unsafe) private static var cache: [Key: FontFace] = [:]
    /// How many faces were BUILT (not served from the cache) since launch: tests assert that styling builds none.
    nonisolated(unsafe) private(set) static var buildCount = 0
    private static let cacheLimit = 1500

    // MARK: installed families

    /// `family` if it is installed, else nil (= use the system font). NSFontManager answers nil for a family it does not know.
    static func resolve(_ family: String?) -> String? {
        guard let family, !family.isEmpty, let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
        return family
    }

    /// Installed families, sorted the way a person sorts them. Hidden system families (leading dot) are left out.
    static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Does the regular face of `family` carry the monospace trait?
    static func isMonospaced(family: String) -> Bool {
        guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: 12) else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }

    static func monospacedFamilies(among families: [String]) -> [String] { families.filter { isMonospaced(family: $0) } }

    // MARK: faces

    /// The least height a line needs so that its glyphs do not run into the lines around it, when it can hold all of `fonts`: the tallest ascender
    /// plus the deepest descender (the fonts of a line share one baseline, so two fonts of 18 pt "natural height" can still need 21).
    static func lineExtent(_ fonts: [NSFont]) -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        for f in fonts { ascent = max(ascent, f.ascender); descent = max(descent, -f.descender) }
        return ascent + descent
    }

    /// The face for a request. `family` must already be resolved (installed or nil). Cached per (family, mono, size, weight, italic).
    static func face(family: String?, mono: Bool, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> FontFace {
        let key = Key(family: family, mono: mono, size: size, weight: weight.rawValue, italic: italic)
        if let f = cache[key] { return f }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        let f = build(family: family, mono: mono, size: size, weight: weight, italic: italic)
        cache[key] = f
        buildCount += 1
        return f
    }

    private static func build(family: String?, mono: Bool, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> FontFace {
        guard let family else { return systemFace(mono: mono, size: size, weight: weight, italic: italic) }
        // NSFontManager's weight scale: 5 = regular, 8 = semibold ("demi"), 9 = bold. It answers the CLOSEST face of the family (Helvetica Neue
        // has no semibold: bold), nil when it has none with the trait (Papyrus has no italic), and sometimes the plain face (Zapfino, Monaco).
        let wanted = weight.rawValue >= NSFont.Weight.bold.rawValue ? 9 : (weight.rawValue >= NSFont.Weight.semibold.rawValue ? 8 : 5)
        let fm = NSFontManager.shared
        var found = fm.font(withFamily: family, traits: italic ? [.italicFontMask] : [], weight: wanted, size: size)
        if found == nil && italic { found = fm.font(withFamily: family, traits: [], weight: wanted, size: size) }
        if found == nil { found = fm.font(withFamily: family, traits: [], weight: 5, size: size) }
        guard var font = found else { return systemFace(mono: mono, size: size, weight: weight, italic: italic) }
        if abs(font.pointSize - size) > 0.01 { font = NSFont(descriptor: font.fontDescriptor, size: size) ?? font }       // never a wrong size
        let hasItalic = fm.traits(of: font).contains(.italicFontMask)
        let gotWeight = fm.weight(of: font)
        let fakeWeight = wanted >= 9 ? (gotWeight >= 8 ? 0 : 2) : (wanted >= 8 ? (gotWeight >= 7 ? 0 : 1) : 0)
        return FontFace(font: font, syntheticItalic: italic && !hasItalic, syntheticWeight: fakeWeight)
    }

    /// The system fonts exactly as the theme always built them.
    private static func systemFace(mono: Bool, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> FontFace {
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: size) ?? f
        }
        return FontFace(font: f, syntheticItalic: false, syntheticWeight: 0)
    }
}
