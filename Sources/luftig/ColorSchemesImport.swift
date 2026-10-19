import AppKit

// ColorSchemesImport.swift - colour schemes from files: Base16 (and Base24) YAML, the format hundreds of editor themes are published in
// (https://github.com/tinted-theming/schemes). Settings > Text > Color scheme > Import Scheme… copies the file into
// ~/Library/Application Support/<bundle id>/Color Schemes/ and the scheme appears in the list under the family "Imported", built like every
// built-in theme (ColorSchemesBuild.swift: the same roles, tints and legibility step). To remove one, delete its file there (the popup has
// "Show Imported Schemes in Finder"); a scheme whose file is gone reads as the default.
//
// Both spellings of the format are read:
//   scheme: "Name"            system: "base16"
//   author: "..."             name: "Name"
//   base00: "181818"          author: "..."
//   ...                       variant: "dark"
//   base0F: "ba8baf"          palette:
//                               base00: "#181818"
//                               ...
// How the 16 colours become Markdown roles (the Base16 styling guide's meaning of each slot):
//   base00 background -> the page          base05 default foreground -> text, code text     base03 comments -> syntax markers (and what is mixed from them)
//   base0D functions / headings -> headings  base0E keywords -> accent (list markers, tasks, quote bar)   base0C support / regex -> links
//   base0B strings -> inline code            base0A classes / yellow -> the warning banner   base0D -> the info banner   base05 -> the caret
//   base02 selection background -> the selection
// Light or dark: the luminance of base00.

enum SchemeImport {
    static let family = "Imported"
    static let idPrefix = "imported-"
    static let fileExtensions = ["yaml", "yml"]

    /// Self-test only: the folder the schemes are read from and copied to (nil: the real one).
    nonisolated(unsafe) static var directoryOverride: URL?

    /// ~/Library/Application Support/<bundle id>/Color Schemes
    static var directory: URL {
        if let o = directoryOverride { return o }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "luftig").appendingPathComponent("Color Schemes")
    }

    // MARK: files

    /// Every scheme file in the folder, by file name; files that are not Base16 schemes are skipped. Files imported under the placeholder bundle
    /// identifier of the first builds (local.luftig.luftig) are taken over once, when the new folder does not exist yet.
    static func load() -> [SchemeSpec] {
        let fm = FileManager.default
        if directoryOverride == nil, !fm.fileExists(atPath: directory.path) {
            let old = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(EditorPreferences.placeholderDomain).appendingPathComponent("Color Schemes")
            if fm.fileExists(atPath: old.path) { try? fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true); try? fm.copyItem(at: old, to: directory) }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [SchemeSpec] = []
        for name in names.sorted() where fileExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8), let s = spec(fromYAML: text, id: id(forFile: url)) else { continue }
            out.append(s)
        }
        return out
    }

    /// The id of the scheme a file holds: `imported-` + the file's name without its extension, lower case, blanks and odd characters as hyphens.
    static func id(forFile url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        var slug = ""
        for ch in stem { if ch.isLetter || ch.isNumber { slug.append(ch) } else if !slug.hasSuffix("-") { slug.append("-") } }
        while slug.hasSuffix("-") { slug.removeLast() }
        return idPrefix + (slug.isEmpty ? "scheme" : slug)
    }

    enum ImportError: LocalizedError {
        case notAScheme
        var errorDescription: String? { "This file is not a Base16 colour scheme (a YAML file with base00 … base0F)." }
    }

    /// Copies `url` into the folder (replacing a file of the same name), reloads the list and returns the scheme's id. Throws when the file cannot be read
    /// or is not a scheme.
    @discardableResult
    static func importFile(_ url: URL) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = spec(fromYAML: text, id: id(forFile: url)) else { throw ImportError.notAScheme }
        // the file is stored under the SCHEME's name, not the download's: two schemes downloaded as "scheme.yaml" are two schemes, and the id
        // (from the stored name) tells them apart; the same scheme imported again replaces itself
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = String(id(forFile: URL(fileURLWithPath: parsed.name + ".yaml")).dropFirst(idPrefix.count))
        let target = directory.appendingPathComponent(stem + ".yaml")
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try text.write(to: target, atomically: true, encoding: .utf8)
        ColorSchemes.reloadImported()
        return id(forFile: target)
    }

    // MARK: parsing

    /// The scheme a Base16 YAML text describes (nil: not one, or a colour is missing / malformed).
    static func spec(fromYAML text: String, id: String) -> SchemeSpec? {
        let kv = parseYAML(text)
        var c: [Int: UInt32] = [:]
        for i in 0..<16 {
            let key = String(format: "base%02X", i)
            guard let v = kv[key.lowercased()], let hex = hexValue(v) else { return nil }
            c[i] = hex
        }
        var name = kv["scheme"] ?? kv["name"] ?? ""
        name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = id.dropFirst(idPrefix.count).replacingOccurrences(of: "-", with: " ").capitalized }
        let bg = c[0x00]!
        let dark: Bool
        if let v = kv["variant"]?.lowercased(), v == "dark" || v == "light" { dark = v == "dark" } else { dark = ColorMath.luminance(ColorMath.rgb(hex: bg)) < 0.5 }
        return SchemeSpec(id: id, name: name, family: family, dark: dark,
                          bg: bg, fg: c[0x05]!, comment: c[0x03]!, heading: c[0x0D]!, accent: c[0x0E]!, link: c[0x0C]!, literal: c[0x0B]!,
                          warn: c[0x0A]!, info: c[0x0D]!, caret: c[0x05]!, selection: .opaque(c[0x02]!))
    }

    /// `key: value` lines (keys lower-cased; a nested block such as `palette:` contributes its own keys; quotes removed; `#` starts a comment only where a value
    /// could not be a colour).
    static func parseYAML(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                let q = value.first!
                value.removeFirst()
                if let end = value.firstIndex(of: q) { value = String(value[..<end]) }
            } else {
                // unquoted: the first word; a `#` that starts a comment is preceded by a space
                if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
                value = value.split(separator: " ").first.map(String.init) ?? value
            }
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// "#rrggbb" / "rrggbb" (also "rgb" shorthand) -> 0xRRGGBB.
    static func hexValue(_ s: String) -> UInt32? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, h.allSatisfy({ $0.isHexDigit }), let v = UInt32(h, radix: 16) else { return nil }
        return v
    }
}
