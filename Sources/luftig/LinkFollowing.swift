// LinkFollowing.swift - ⌘-click (and Edit > Open Link) on a link: what the link under a character is, and where it leads.
//
//   destination(at:in:runs:)   the lexer's runs of the line say whether the character is in `[text](dest)`, `![alt](src)`, `<autolink>`, a bare URL
//                              or `[text][ref]` (the `[ref]: url` definition is looked up in the text); the result is the destination as written
//   target(for:base:)          a destination string -> a web URL (http, https, mailto, ...; `www.` gets https), a file (relative to the document's
//                              folder, with an optional #anchor) or an anchor in this document (`#heading`)
//   slug(_:)                   GitHub's heading anchors: lower case, punctuation removed, spaces to hyphens (what `#anchor` is matched against)
//
// Pure; EditorViewController's `links` extension does the opening (NSWorkspace, NSDocumentController, the outline's jump).

import Foundation
import MarkdownKit

enum LinkTarget: Equatable {
    case web(URL)
    case file(URL, anchor: String?)
    case anchor(String)
}

enum LinkFollowing {

    /// The destination of the link that holds the character at `index` (nil: not on a link). `runs`: the lexer's runs covering the line.
    static func destination(at index: Int, in text: NSString, runs: [MDRun]) -> String? {
        guard !runs.isEmpty, index >= 0 else { return nil }
        // the run under the character (a caret at the end of a run belongs to it)
        guard var i = runs.firstIndex(where: { NSLocationInRange(index, $0.range) }) ?? (index > 0 ? runs.firstIndex(where: { NSMaxRange($0.range) == index }) : nil) else { return nil }
        let s = runs[i].style
        let onLink = s.contains(.linkText) || s.contains(.linkDestination) || s.contains(.image) || s.contains(.autolink) || s.contains(.referenceLabel)
        guard onLink else {
            // `[label]` on its own (a shortcut reference) is plain text to the lexer, which resolves no references: the brackets around the
            // character on this line, and a definition for what is between them
            guard s.facets.isEmpty || s.facets == [.blockquote], !s.contains(.inlineCode) else { return nil }
            let line = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            let lineText = text.substring(with: line) as NSString
            let local = index - line.location
            var open = local
            while open >= 0, open < lineText.length, lineText.character(at: open) != 0x5B { if lineText.character(at: open) == 0x5D && open != local { return nil }; open -= 1 }
            guard open >= 0, open < lineText.length else { return nil }
            var close = local
            while close < lineText.length, lineText.character(at: close) != 0x5D { if lineText.character(at: close) == 0x5B && close != open { return nil }; close += 1 }
            guard close < lineText.length, close > open + 1 else { return nil }
            return definition(of: lineText.substring(with: NSRange(location: open + 1, length: close - open - 1)), in: text)
        }
        if s.contains(.autolink) {
            if !s.contains(.marker) { return trimmedAutolink(text.substring(with: runs[i].range)) }
            // the `<` or `>` of an autolink: the run beside it
            for j in [i + 1, i - 1] where j >= 0 && j < runs.count && runs[j].style.contains(.autolink) && !runs[j].style.contains(.marker) {
                return trimmedAutolink(text.substring(with: runs[j].range))
            }
            return nil
        }
        // back to the first run of this link, then forward to its destination or reference label (bounded: links are short)
        while i > 0, isLinkPart(runs[i - 1].style), i > 0 { i -= 1; if runs[i].style.contains(.marker) && text.substring(with: runs[i].range).hasPrefix("[") || text.substring(with: runs[i].range).hasPrefix("!") { break } }
        var k = i
        var steps = 0
        while k < runs.count, steps < 40 {
            let st = runs[k].style
            if st.contains(.linkDestination) && !st.contains(.marker) {
                var d = text.substring(with: runs[k].range).trimmingCharacters(in: .whitespaces)
                if d.hasPrefix("<") && d.hasSuffix(">") { d = String(d.dropFirst().dropLast()) }
                return d.isEmpty ? nil : d
            }
            if st.contains(.referenceLabel) && !st.contains(.marker) {
                let label = text.substring(with: runs[k].range)
                return definition(of: label, in: text)
            }
            if !isLinkPart(st) && !(st.facets.isEmpty && text.substring(with: runs[k].range).allSatisfy { $0 == " " }) { break }
            k += 1; steps += 1
        }
        // `[text]` alone, or `[text][]`: the label is the text
        if let r = runs[i...].first(where: { $0.style.contains(.linkText) && !$0.style.contains(.marker) }) {
            return definition(of: text.substring(with: r.range), in: text)
        }
        return nil
    }

    private static func isLinkPart(_ s: MDStyle) -> Bool {
        s.contains(.linkText) || s.contains(.linkDestination) || s.contains(.image) || s.contains(.referenceLabel)
    }

    private static func trimmedAutolink(_ s: String) -> String? {
        var d = s.trimmingCharacters(in: .whitespaces)
        if d.hasPrefix("<") { d.removeFirst() }
        if d.hasSuffix(">") { d.removeLast() }
        return d.isEmpty ? nil : d
    }

    /// The destination of `[label]: dest` anywhere in the text (labels compare case-insensitively, as CommonMark says).
    static func definition(of label: String, in text: NSString) -> String? {
        let wanted = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty, wanted.utf16.count <= 999 else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: wanted)
        guard let re = try? NSRegularExpression(pattern: "^ {0,3}\\[" + escaped + "\\]:[ \\t]*(<[^>\\n]*>|[^ \\t\\n]+)", options: [.anchorsMatchLines, .caseInsensitive]) else { return nil }
        guard let m = re.firstMatch(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) else { return nil }
        var d = text.substring(with: m.range(at: 1))
        if d.hasPrefix("<") && d.hasSuffix(">") { d = String(d.dropFirst().dropLast()) }
        return d.isEmpty ? nil : d
    }

    /// Where a destination leads. `base`: the folder of the document (nil: an untitled document; relative paths then lead nowhere).
    static func target(for destination: String, base: URL?) -> LinkTarget? {
        let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if d.hasPrefix("#") { let a = String(d.dropFirst()); return a.isEmpty ? nil : .anchor(a) }
        if d.lowercased().hasPrefix("www.") { return URL(string: "https://" + d).map { .web($0) } }
        if let u = URL(string: d), let scheme = u.scheme?.lowercased(), !scheme.isEmpty {
            if scheme == "file" { return .file(u.standardizedFileURL, anchor: u.fragment) }
            if scheme.count > 1 { return .web(u) }                   // (a one-letter scheme is a Windows drive, not a scheme)
        }
        // a path: `#anchor` split off, percent-escapes decoded, relative to the document's folder
        var path = d, anchor: String?
        if let hash = d.firstIndex(of: "#") { path = String(d[..<hash]); anchor = String(d[d.index(after: hash)...]); if anchor?.isEmpty == true { anchor = nil } }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return anchor.map { .anchor($0) } }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return .file(URL(fileURLWithPath: expanded).standardizedFileURL, anchor: anchor) }
        guard let base else { return nil }
        return .file(URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL, anchor: anchor)
    }

    /// GitHub's anchor of a heading title: lower case, everything but letters, digits, spaces and hyphens removed, spaces to hyphens.
    static func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased() {
            if ch == " " || ch == "-" { out.append("-") }
            else if ch.isLetter || ch.isNumber || ch == "_" { out.append(ch) }
        }
        return out
    }

    /// The outline entry an anchor names: by slug, or by the title itself (case-insensitive); nil when none matches.
    static func entry(for anchor: String, in entries: [OutlineEntry]) -> OutlineEntry? {
        let a = (anchor.removingPercentEncoding ?? anchor).lowercased()
        let s = slug(a)
        return entries.first { slug($0.title) == s } ?? entries.first { $0.title.lowercased() == a }
    }

    /// Files luftig opens itself (as documents): Markdown and plain text, and files without an extension.
    static func opensAsDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        return ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt", "text"].contains(ext)
    }
}
