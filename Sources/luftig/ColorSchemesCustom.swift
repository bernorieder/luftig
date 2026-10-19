import AppKit

// ColorSchemesCustom.swift - the user's own colour schemes: seven colours picked in Settings > Colors (the page, text, syntax markers, headings, the accent, links,
// inline code). A custom scheme is stored as a Base16 YAML file in the same folder as the imported schemes and read by the same code (SchemeImport): it is an imported
// scheme with the extra line `luftig: custom`, listed under the family "Custom" instead of "Imported", and built like every other scheme (ColorSchemesBuild.swift:
// the same tints, surfaces and legibility step). The file is a valid Base16 scheme, so other programs can use it too.
//
// The seven colours fill the 16 slots so that the file reads back with the same roles (SchemeImport's mapping):
//   base00 page           base01 / base02 the page moved 1/8, 2/8 towards the text (base02: the selection, see below)   base03 markers   base04 page moved 5/8 towards the text
//   base05 text           base06 / base07 the text moved 1/3, 2/3 towards white (dark schemes) or black (light schemes)
//   base08 accent         base09 inline code   base0A amber (the warning banner)   base0B inline code   base0C links   base0D headings (and the info banner)
//   base0E accent         base0F markers
// Derived: the caret is the text colour, light or dark is the page's luminance, the selection is the accent at 30 % over the page (written into base02, so the
// draft and the saved scheme are the same colours).
//
// Settings > Colors edits a DRAFT (`ColorSchemes.draft`): the editors show it live under the id `custom-draft`, which is never stored in the preferences;
// Save (a custom scheme only) writes the file and selects the saved scheme, Save as New… asks for a name and writes a copy under it (made free), Revert drops the
// draft, closing the window drops it too.

struct CustomScheme: Equatable {
    enum Role: Int, CaseIterable {
        case page, text, markers, headings, accent, links, code
        var title: String {
            switch self {
            case .page: return "Page"
            case .text: return "Text"
            case .markers: return "Markers"
            case .headings: return "Headings"
            case .accent: return "Accent"
            case .links: return "Links"
            case .code: return "Inline code"
            }
        }
        /// What the colour is used for (the row's note in Settings).
        var note: String {
            switch self {
            case .page: return "The background; its lightness sets light or dark."
            case .text: return "Body text, code blocks, the insertion point."
            case .markers: return "Syntax punctuation, and what is mixed from it."
            case .headings: return "All six levels, footnotes, the info banner."
            case .accent: return "List markers, tasks, the quote bar, the selection."
            case .links: return "Link text and autolinks."
            case .code: return "Inline code and backslash escapes."
            }
        }
    }

    var name: String
    /// One colour per role, 0xRRGGBB, in `Role` order.
    var colors: [UInt32]

    subscript(role: Role) -> UInt32 {
        get { colors[role.rawValue] }
        set { colors[role.rawValue] = newValue }
    }

    static let family = "Custom"
    static let draftID = "custom-draft"
    /// The YAML line that marks a custom scheme: `luftig: custom`.
    static let yamlKey = "luftig"
    static let yamlValue = "custom"
    static let fileNamePrefix = "custom-"
    /// The warning banner's colour (an amber; the banner is a faint tint of it over the page).
    static let warn: UInt32 = 0xE8B33C
    static let selectionAlpha = 0.3

    // MARK: from a scheme

    /// The colours of the scheme `id` as a starting point: a built-in theme's, an imported or custom scheme's, or the default scheme's palette for the current
    /// appearance (its light or its dark colours; it has no spec).
    static func from(schemeID id: String) -> CustomScheme {
        if let s = SchemeSpec.all.first(where: { $0.id == id }) ?? ColorSchemes.imported.first(where: { $0.id == id }) {
            return CustomScheme(name: s.name, colors: [s.bg, s.fg, s.comment, s.heading, s.accent, s.link, s.literal])
        }
        let dark = (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? luftigDark : luftigLight
    }

    /// The default scheme's light palette (ColorSchemes.makeDefaultColors: the page, text, marker, heading, accent, link and copper of the light variant);
    /// `schemes-custom` checks these against the palette.
    static let luftigLight = CustomScheme(name: "luftig", colors: [0xFFFFFF, 0x2E323E, 0x7C808C, 0x222876, 0x4046C4, 0x005CC8, 0xA83A00])
    /// ... and its dark palette.
    static let luftigDark = CustomScheme(name: "luftig", colors: [0x1E1E1E, 0xD9D9D9, 0x8E929E, 0xC4CCFF, 0x949EFF, 0x64A8FF, 0xFF9C6C])

    // MARK: to a scheme

    var dark: Bool { ColorMath.luminance(ColorMath.rgb(hex: self[.page])) < 0.5 }

    /// The selection the scheme shows over the page: the accent at `selectionAlpha` over the page, as a colour.
    var selectionHex: UInt32 { CustomScheme.hex(ColorMath.over(ColorMath.rgb(hex: self[.accent]), CustomScheme.selectionAlpha, ColorMath.rgb(hex: self[.page]))) }

    /// The scheme as the builder takes it (the same values the saved file gives back).
    func spec(id: String) -> SchemeSpec {
        SchemeSpec(id: id, name: name, family: CustomScheme.family, dark: dark,
                   bg: self[.page], fg: self[.text], comment: self[.markers], heading: self[.headings], accent: self[.accent], link: self[.links], literal: self[.code],
                   warn: CustomScheme.warn, info: self[.headings], caret: self[.text], selection: .opaque(selectionHex))
    }

    /// The Base16 YAML file of the scheme.
    func yaml() -> String {
        let page = ColorMath.rgb(hex: self[.page]), text = ColorMath.rgb(hex: self[.text])
        let extreme: RGB = dark ? RGB(1, 1, 1) : RGB(0, 0, 0)
        func h(_ c: RGB) -> String { ColorMath.hex(c) }
        func h(_ v: UInt32) -> String { String(format: "#%06x", v) }
        let slots: [(String, String)] = [
            ("base00", h(self[.page])), ("base01", h(ColorMath.mix(page, text, 1 / 8))), ("base02", h(selectionHex)), ("base03", h(self[.markers])),
            ("base04", h(ColorMath.mix(page, text, 5 / 8))), ("base05", h(self[.text])), ("base06", h(ColorMath.mix(text, extreme, 1 / 3))), ("base07", h(ColorMath.mix(text, extreme, 2 / 3))),
            ("base08", h(self[.accent])), ("base09", h(self[.code])), ("base0A", h(CustomScheme.warn)), ("base0B", h(self[.code])),
            ("base0C", h(self[.links])), ("base0D", h(self[.headings])), ("base0E", h(self[.accent])), ("base0F", h(self[.markers])),
        ]
        var out = "# A luftig colour scheme (Settings > Colors). Base16 layout: other programs can use it too.\n"
        out += "system: \"base16\"\nname: \"\(CustomScheme.cleanName(name))\"\nauthor: \"luftig\"\n\(CustomScheme.yamlKey): \"\(CustomScheme.yamlValue)\"\nvariant: \"\(dark ? "dark" : "light")\"\npalette:\n"
        for (k, v) in slots { out += "  \(k): \"\(v)\"\n" }
        return out
    }

    // MARK: files

    /// A name as it is written: trimmed, without quotes or line breaks; empty becomes "Custom".
    static func cleanName(_ s: String) -> String {
        let n = s.filter { $0 != "\"" && $0 != "'" && !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Custom" : n
    }

    /// The file a custom scheme of this name is stored in (in SchemeImport.directory): `custom-<slug>.yaml`.
    static func fileURL(forName name: String) -> URL {
        let stem = String(SchemeImport.id(forFile: URL(fileURLWithPath: cleanName(name) + ".yaml")).dropFirst(SchemeImport.idPrefix.count))
        return SchemeImport.directory.appendingPathComponent(fileNamePrefix + stem + ".yaml")
    }
    /// The id the saved scheme gets (`imported-custom-<slug>`: the file's).
    static func id(forName name: String) -> String { SchemeImport.id(forFile: fileURL(forName: name)) }

    /// Whether `id` is a custom scheme (a file with the `luftig: custom` line).
    static func isCustom(_ id: String) -> Bool { ColorSchemes.imported.contains { $0.id == id && $0.family == family } }

    /// `base` when no scheme of that name (or of its file) exists, else "base 2", "base 3", ...
    static func uniqueName(_ base: String) -> String {
        let b = cleanName(base)
        func taken(_ n: String) -> Bool {
            ColorSchemes.all.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame } || FileManager.default.fileExists(atPath: fileURL(forName: n).path)
        }
        if !taken(b) { return b }
        var i = 2
        while taken("\(b) \(i)") { i += 1 }
        return "\(b) \(i)"
    }

    /// Writes the scheme's file (replacing the file of the same name; `replacing` names a scheme whose file is removed first: a rename), reloads the list and
    /// returns the saved scheme's id.
    @discardableResult
    func save(replacing oldID: String? = nil) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: SchemeImport.directory, withIntermediateDirectories: true)
        let target = CustomScheme.fileURL(forName: name)
        if let oldID, oldID != SchemeImport.id(forFile: target), let old = CustomScheme.fileURL(ofSchemeID: oldID) { try? fm.removeItem(at: old) }
        try yaml().write(to: target, atomically: true, encoding: .utf8)
        ColorSchemes.reloadImported()
        return SchemeImport.id(forFile: target)
    }

    /// The file of the imported or custom scheme `id` (nil: not one, or its file is gone).
    static func fileURL(ofSchemeID id: String) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: SchemeImport.directory.path) else { return nil }
        for n in names where SchemeImport.fileExtensions.contains((n as NSString).pathExtension.lowercased()) {
            let url = SchemeImport.directory.appendingPathComponent(n)
            if SchemeImport.id(forFile: url) == id { return url }
        }
        return nil
    }

    /// Deletes the custom scheme `id` (its file) and reloads the list.
    static func delete(id: String) throws {
        guard isCustom(id), let url = fileURL(ofSchemeID: id) else { return }
        try FileManager.default.removeItem(at: url)
        ColorSchemes.reloadImported()
    }

    // MARK: colours

    static func hex(_ c: RGB) -> UInt32 {
        let q = ColorMath.quantize(c)
        return UInt32((q.x * 255).rounded()) << 16 | UInt32((q.y * 255).rounded()) << 8 | UInt32((q.z * 255).rounded())
    }
    static func color(_ v: UInt32) -> NSColor {
        let c = ColorMath.rgb(hex: v)
        return NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }
    /// The 0xRRGGBB of a colour from a colour well (any colour space; the alpha is dropped).
    static func hex(_ c: NSColor) -> UInt32 {
        let s = c.usingColorSpace(.sRGB) ?? c
        return hex(RGB(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)))
    }

    /// The roles of the draft the legibility step moved (the report's rows of a built scheme, named as the Settings rows are).
    static func adjustedRoles(of colors: SchemeColors) -> [Role] {
        guard let report = colors.report else { return [] }
        var out: [Role] = []
        for row in report.rows where row.normalChanged {
            let role: Role?
            if row.role.hasPrefix("body text") { role = .text } else if row.role == "heading" { role = .headings } else if row.role.hasPrefix("accent") { role = .accent }
            else if row.role == "link" { role = .links } else if row.role.hasPrefix("inline code") { role = .code } else if row.role == "syntax marker" { role = .markers } else { role = nil }
            if let role, !out.contains(role) { out.append(role) }
        }
        return out.sorted { $0.rawValue < $1.rawValue }
    }
}
