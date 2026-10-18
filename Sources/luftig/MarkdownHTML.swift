// MarkdownHTML.swift - Markdown -> HTML from the lexer's runs (Edit > Copy as HTML / Copy as Rich Text, File > Export as HTML…).
//
// The lexer (MarkdownKit) gives every character a style: the block it is in (heading level, quote depth, code block, table, rule, front matter,
// HTML) and its inline facets (bold, italic, strikethrough, code, link text / destination, image, autolink, escape, ...), with the syntax
// punctuation marked `marker`. That is enough to write HTML line by line: the line-level facets open and close the blocks, the inline facets
// open and close tags, the markers are left out, list items come from the `listMarker` runs (nesting by the marker's column), block quotes
// from the quote depth. What the lexer does not resolve (reference links) is looked up here (LinkFollowing.definition); what it leaves as
// plain text (`[shortcut]` references) stays text.
//
// Pure: text + runs in, a string out. `html(_:runs:range:)` renders whole lines around `range` (nil: everything); `document(body:title:...)` wraps
// a body into a page with a small stylesheet.

import Foundation
import MarkdownKit

enum MarkdownHTML {

    // MARK: entry points

    /// The HTML of the lines that `range` touches (nil: the whole text). `runs`: the lexer's runs for the WHOLE text (the block state of a line depends
    /// on what is above it).
    static func html(_ text: NSString, runs: [MDRun], range: NSRange? = nil) -> String {
        guard text.length > 0, !runs.isEmpty else { return "" }
        let whole = NSRange(location: 0, length: text.length)
        var r = range.map { NSIntersectionRange($0, whole) } ?? whole
        if r.length == 0 && range != nil { r = whole }
        let lines = text.lineRange(for: r)
        var w = Writer(text: text, runs: runs)
        w.render(lines)
        return w.out
    }

    /// A complete HTML page: the body, a title, and a stylesheet that uses the editor's fonts (nil: the system's) and reads well on its own.
    static func document(body: String, title: String, bodyFont: String?, codeFont: String?) -> String {
        let bodyFamily = (bodyFont.map { "\"\($0)\", " } ?? "") + "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        let codeFamily = (codeFont.map { "\"\($0)\", " } ?? "") + "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace"
        let css = """
        body { font-family: \(bodyFamily); font-size: 16px; line-height: 1.5; max-width: 44em; margin: 3em auto; padding: 0 1.5em; color: #222; background: #fff; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; }
        h1 { font-size: 1.6em; } h2 { font-size: 1.35em; } h3 { font-size: 1.18em; } h4 { font-size: 1.05em; }
        pre, code { font-family: \(codeFamily); font-size: 0.9em; }
        pre { background: #f4f4f6; padding: 0.8em 1em; overflow-x: auto; border-radius: 4px; }
        code { background: #f4f0ee; padding: 0.1em 0.3em; border-radius: 3px; } pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: 0.2em 1em; border-left: 3px solid #b8bcd4; color: #4a5064; background: #f6f6fb; }
        table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid #d8d8de; padding: 0.3em 0.7em; text-align: left; } th { background: #f0f0f4; }
        hr { border: 0; border-top: 1px solid #c8c8d0; margin: 2em 0; }
        a { color: #005cc8; } img { max-width: 100%; }
        ul.task { list-style: none; padding-left: 1.2em; } li.task input { margin-right: 0.4em; }
        @media (prefers-color-scheme: dark) { body { color: #dde0ea; background: #1c1d22; } pre { background: #26272e; } code { background: #2c2a2a; }
          blockquote { background: #23242c; border-color: #5c62a0; color: #b8bccc; } th, td { border-color: #3a3b44; } th { background: #26272e; } hr { border-color: #44454e; } a { color: #74a8ff; } }
        """
        return "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>\(escape(title))</title>\n<style>\n\(css)\n</style>\n</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: the writer

    private struct Writer {
        let text: NSString
        let runs: [MDRun]
        var out = ""
        // open blocks
        var quoteDepth = 0
        var lists: [List] = []              // innermost last
        var para: [String] = []             // lines of the open paragraph (already converted)
        var paraIsItemText = false          // the paragraph is the text of the open list item (no <p>)
        var code: Code?
        var table: [TableRow]? = nil
        var lastLineBlank = true
        var runCursor = 0

        struct List { var ordered: Bool; var indent: Int; var itemOpen: Bool; var contentIndent: Int }
        struct Code { var fenced: Bool; var lines: [String]; var language: String }
        struct TableRow { var cells: [String]; var header: Bool; var delimiter: Bool }

        init(text: NSString, runs: [MDRun]) { self.text = text; self.runs = runs }

        // MARK: runs

        /// Index of the run that holds `location` (the last run for a location at the end).
        func runIndex(at location: Int) -> Int {
            var lo = 0, hi = runs.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(runs[mid].range) <= location { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func style(at location: Int) -> MDStyle { runs[runIndex(at: min(location, text.length - 1))].style }

        // MARK: lines

        mutating func render(_ range: NSRange) {
            var pos = range.location
            let end = NSMaxRange(range)
            while pos < end {
                let line = text.lineRange(for: NSRange(location: pos, length: 0))
                var contentEnd = NSMaxRange(line)
                while contentEnd > line.location, text.character(at: contentEnd - 1) == 0x0A || text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
                processLine(start: line.location, contentEnd: contentEnd, lineEnd: NSMaxRange(line))
                pos = NSMaxRange(line)
                if line.length == 0 { break }
            }
            closeParagraph()
            closeCode()
            closeTable()
            closeLists(to: -1)
            closeQuotes(to: 0)
        }

        private mutating func processLine(start: Int, contentEnd: Int, lineEnd: Int) {
            // the line-level style is the style of the run that holds the line break (the lexer gives the break the style of its line)
            let lineStyle = style(at: max(start, lineEnd - 1))
            let s = lineStyle
            // front matter: left out
            if s.contains(.frontMatter) { return }
            // code blocks first: nothing inside them is structure
            if s.contains(.codeFence) {
                closeParagraph(); closeTable()
                if code == nil {
                    code = Code(fenced: true, lines: [], language: languageOfFence(start: start, end: contentEnd))
                } else {
                    closeCode()
                }
                lastLineBlank = false
                return
            }
            if s.contains(.codeBlock) {
                closeParagraph(); closeTable()
                var line = text.substring(with: NSRange(location: start, length: contentEnd - start))
                if code == nil { code = Code(fenced: false, lines: [], language: "") }
                if code!.fenced == false {        // indented code: the four columns of indentation go
                    if line.hasPrefix("\t") { line.removeFirst() } else { var n = 0; while n < 4, line.hasPrefix(" ") { line.removeFirst(); n += 1 } }
                }
                code!.lines.append(line)
                lastLineBlank = false
                return
            }
            if code != nil, !code!.fenced { closeCode() }

            // quotes: the `> ` markers at the start of the line are structure
            let depth = s.quoteDepth
            var cs = start
            while cs < contentEnd {
                let st = style(at: cs)
                let c = text.character(at: cs)
                if st.contains(.marker) && st.quoteDepth > 0 && (c == 0x3E || c == 0x20 || c == 0x09) { cs += 1 } else { break }
            }
            if depth != quoteDepth {
                closeParagraph(); closeTable(); closeLists(to: -1)
                if depth < quoteDepth { closeQuotes(to: depth) } else { while quoteDepth < depth { out += "<blockquote>\n"; quoteDepth += 1 } }
            }
            let content = NSRange(location: cs, length: contentEnd - cs)
            let blank = isBlank(content)

            if blank {
                closeParagraph(); closeTable()
                lastLineBlank = true
                return
            }
            // a reference definition `[label]: url`: nothing to show
            if style(at: cs).contains(.referenceLabel), text.character(at: cs) == 0x5B, definitionLine(content) { lastLineBlank = false; return }
            if s.contains(.horizontalRule) {
                closeParagraph(); closeTable(); closeLists(to: -1)
                out += "<hr>\n"; lastLineBlank = false
                return
            }
            if s.contains(.table) {
                closeParagraph()
                if table == nil { closeLists(to: -1); table = [] }
                table!.append(tableRow(content, header: s.contains(.tableHeader)))
                lastLineBlank = false
                return
            }
            closeTable()
            if s.contains(.html), text.character(at: cs) == 0x3C, !s.contains(.listMarker) {
                closeParagraph()
                out += text.substring(with: content) + "\n"; lastLineBlank = false
                return
            }
            if s.headingLevel > 0 {
                if isUnderlineLine(content) { lastLineBlank = false; return }           // the `===` / `---` under a setext heading
                closeParagraph(); closeLists(to: -1)
                let level = s.headingLevel
                out += "<h\(level)>" + inline(content).trimmingCharacters(in: .whitespaces) + "</h\(level)>\n"     // (the blank before a closing `##`)
                lastLineBlank = false
                return
            }
            // a list item: the content starts with a marker run (after its indentation)
            var i = cs
            var indent = 0
            while i < contentEnd, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { indent = text.character(at: i) == 0x09 ? (indent / 4 + 1) * 4 : indent + 1; i += 1 }
            if i < contentEnd, style(at: i).contains(.listMarker) {
                let markerRun = runs[runIndex(at: i)]
                let markerText = text.substring(with: NSIntersectionRange(markerRun.range, content))
                let ordered = markerText.first?.isNumber == true
                let number = ordered ? Int(markerText.prefix { $0.isNumber }) ?? 1 : 1
                var after = min(NSMaxRange(markerRun.range), contentEnd)
                var task: Bool? = nil
                if after < contentEnd, style(at: after).contains(.taskMarker) {
                    task = style(at: after).contains(.taskChecked)
                    after = min(NSMaxRange(runs[runIndex(at: after)].range), contentEnd)
                    while after < contentEnd, text.character(at: after) == 0x20 { after += 1 }
                }
                closeParagraph()
                openItem(ordered: ordered, indent: indent, number: number, contentIndent: indent + (markerText.utf16.count), task: task)
                let rest = NSRange(location: after, length: contentEnd - after)
                para = [inline(rest)]; paraIsItemText = true
                if let task { para[0] = "<input type=\"checkbox\" disabled" + (task ? " checked" : "") + "> " + para[0] }
                lastLineBlank = false
                return
            }
            // a text line: continues the open paragraph, continues the open list item (indented, or lazily right after it), or starts a paragraph
            if !lists.isEmpty {
                let top = lists[lists.count - 1]
                if indent >= min(top.contentIndent, top.indent + 2) || (!lastLineBlank && !para.isEmpty) {
                    if lastLineBlank { closeParagraph(); para = []; paraIsItemText = false }
                    appendParagraphLine(content)
                    lastLineBlank = false
                    return
                }
                closeParagraph(); closeLists(to: -1)
            }
            appendParagraphLine(content)
            lastLineBlank = false
        }

        private func isBlank(_ r: NSRange) -> Bool {
            var i = r.location
            while i < NSMaxRange(r) { let c = text.character(at: i); if c != 0x20 && c != 0x09 { return false }; i += 1 }
            return true
        }

        private func isUnderlineLine(_ r: NSRange) -> Bool {
            var i = r.location
            while i < NSMaxRange(r), text.character(at: i) == 0x20 { i += 1 }
            guard i < NSMaxRange(r) else { return false }
            let c = text.character(at: i)
            guard c == 0x3D || c == 0x2D, style(at: i).contains(.marker) else { return false }
            while i < NSMaxRange(r), text.character(at: i) == c || text.character(at: i) == 0x20 { i += 1 }
            return i == NSMaxRange(r)
        }

        private func definitionLine(_ r: NSRange) -> Bool {
            // `[label]:` then a destination run on the same line
            var i = r.location
            while i < NSMaxRange(r) { if text.character(at: i) == 0x5D { break }; i += 1 }
            guard i + 1 < NSMaxRange(r), text.character(at: i + 1) == 0x3A else { return false }
            var j = i + 2
            while j < NSMaxRange(r) { if style(at: j).contains(.linkDestination) { return true }; if text.character(at: j) != 0x20 { return false }; j += 1 }
            return false
        }

        private func languageOfFence(start: Int, end: Int) -> String {
            var i = start
            while i < end { if style(at: i).contains(.codeLanguage) { let run = runs[runIndex(at: i)]; return text.substring(with: NSIntersectionRange(run.range, NSRange(location: start, length: end - start))).trimmingCharacters(in: .whitespaces) }; i = NSMaxRange(runs[runIndex(at: i)].range) }
            return ""
        }

        // MARK: blocks

        private mutating func appendParagraphLine(_ content: NSRange) {
            var r = content
            // the indentation of a continuation line (inside a list item, or just indented) is not part of the text
            while r.length > 0, text.character(at: r.location) == 0x20 || text.character(at: r.location) == 0x09 { r = NSRange(location: r.location + 1, length: r.length - 1) }
            // trailing spaces are not part of the text; two or more (or a backslash) at the end of a line are a hard break
            var hard = false
            var e = NSMaxRange(r)
            var spaces = 0
            while e > r.location, text.character(at: e - 1) == 0x20 { e -= 1; spaces += 1 }
            if spaces >= 2 { hard = true }
            else if spaces == 0, e > r.location, isTrailingBackslash(e - 1) { hard = true; e -= 1 }
            r = NSRange(location: r.location, length: e - r.location)
            var s = inline(r)
            if hard { s += "<br>" }
            para.append(s)
        }

        private func isTrailingBackslash(_ i: Int) -> Bool {
            // a single backslash at the end of the line (not an escaped backslash `\\`)
            var n = 0
            var k = i
            while k >= 0, text.character(at: k) == 0x5C { n += 1; k -= 1 }
            return n % 2 == 1
        }

        private mutating func closeParagraph() {
            guard !para.isEmpty else { paraIsItemText = false; return }
            let body = para.joined(separator: "\n")
            if paraIsItemText { out += body }                                                   // `<li>text` - the item closes with </li> on the same line
            else if lists.last?.itemOpen == true { out += "\n<p>" + body + "</p>\n" }           // a further paragraph inside the item
            else { out += "<p>" + body + "</p>\n" }
            para = []
            paraIsItemText = false
        }

        private mutating func closeCode() {
            guard let c = code else { return }
            let cls = c.language.isEmpty ? "" : " class=\"language-\(escape(c.language))\""
            out += "<pre><code\(cls)>" + c.lines.map { escape($0) }.joined(separator: "\n") + (c.lines.isEmpty ? "" : "\n") + "</code></pre>\n"
            code = nil
        }

        private mutating func openItem(ordered: Bool, indent: Int, number: Int, contentIndent: Int, task: Bool?) {
            // deeper lists close until one at or above this indentation is open
            while let top = lists.last, top.indent > indent { closeList() }
            if let top = lists.last, top.indent == indent, top.ordered != ordered { closeList() }
            if let top = lists.last, top.indent == indent {
                if top.itemOpen { out += "</li>\n" }
            } else {
                // nested in the open item (or a new list at the top level)
                let start = ordered && number != 1 ? " start=\"\(number)\"" : ""
                if lists.last?.itemOpen == true { out += "\n" }
                out += (ordered ? "<ol\(start)>" : (task != nil ? "<ul class=\"task\">" : "<ul>")) + "\n"
                lists.append(List(ordered: ordered, indent: indent, itemOpen: false, contentIndent: contentIndent))
            }
            lists[lists.count - 1].itemOpen = true
            lists[lists.count - 1].contentIndent = contentIndent
            out += task != nil ? "<li class=\"task\">" : "<li>"
        }

        private mutating func closeList() {
            guard let top = lists.popLast() else { return }
            if top.itemOpen { out += "</li>\n" }
            out += (top.ordered ? "</ol>" : "</ul>") + "\n"
        }

        private mutating func closeLists(to indent: Int) {
            closeParagraph()
            while let top = lists.last, top.indent > indent { closeList() }
        }

        private mutating func closeQuotes(to depth: Int) {
            while quoteDepth > depth { out += "</blockquote>\n"; quoteDepth -= 1 }
        }

        // MARK: tables

        private func tableRow(_ content: NSRange, header: Bool) -> TableRow {
            // cells between unescaped pipes; a leading / trailing pipe is the table's frame
            var cells: [NSRange] = []
            var i = content.location
            var cellStart = content.location
            let end = NSMaxRange(content)
            while i < content.location + 1, i < end, text.character(at: i) == 0x20 { i += 1; cellStart = i }
            if i < end, text.character(at: i) == 0x7C { i += 1; cellStart = i }
            while i < end {
                let c = text.character(at: i)
                if c == 0x7C, !(i > content.location && text.character(at: i - 1) == 0x5C) { cells.append(NSRange(location: cellStart, length: i - cellStart)); cellStart = i + 1 }
                i += 1
            }
            let tail = NSRange(location: cellStart, length: end - cellStart)
            if !isBlank(tail) || cells.isEmpty { cells.append(tail) }
            let texts = cells.map { text.substring(with: $0).trimmingCharacters(in: .whitespaces) }
            let delimiter = !texts.isEmpty && texts.allSatisfy { t in !t.isEmpty && t.allSatisfy { $0 == "-" || $0 == ":" } && t.contains("-") }
            if delimiter { return TableRow(cells: texts, header: false, delimiter: true) }
            return TableRow(cells: cells.map { inline(trimmed($0)) }, header: header, delimiter: false)
        }

        private func trimmed(_ r: NSRange) -> NSRange {
            var a = r.location, b = NSMaxRange(r)
            while a < b, text.character(at: a) == 0x20 { a += 1 }
            while b > a, text.character(at: b - 1) == 0x20 { b -= 1 }
            return NSRange(location: a, length: b - a)
        }

        private mutating func closeTable() {
            guard let rows = table else { return }
            table = nil
            guard !rows.isEmpty else { return }
            var aligns: [String] = []
            if let d = rows.first(where: { $0.delimiter }) {
                aligns = d.cells.map { c in c.hasPrefix(":") && c.hasSuffix(":") ? "center" : c.hasSuffix(":") ? "right" : c.hasPrefix(":") ? "left" : "" }
            }
            func cell(_ tag: String, _ s: String, _ k: Int) -> String {
                let a = k < aligns.count && !aligns[k].isEmpty ? " align=\"\(aligns[k])\"" : ""
                return "<\(tag)\(a)>\(s)</\(tag)>"
            }
            out += "<table>\n"
            var headerDone = false
            for row in rows where !row.delimiter {
                if row.header && !headerDone {
                    out += "<thead>\n<tr>" + row.cells.enumerated().map { cell("th", $1, $0) }.joined() + "</tr>\n</thead>\n<tbody>\n"
                    headerDone = true
                } else {
                    if !headerDone { out += "<tbody>\n"; headerDone = true }
                    out += "<tr>" + row.cells.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>\n"
                }
            }
            if headerDone { out += "</tbody>\n" }
            out += "</table>\n"
        }

        // MARK: inline

        /// The HTML of the characters in `range`: facets open and close tags, markers are left out, links and images are assembled from their parts.
        func inline(_ range: NSRange) -> String {
            guard range.length > 0 else { return "" }
            var s = ""
            var open: [MDStyle] = []                  // the facets with an open tag, in opening order
            var i = runIndex(at: range.location)
            let end = NSMaxRange(range)
            var skipUntil = -1                        // an image: everything up to its closing paren is done
            var linkHref: String? = nil
            func tag(_ f: MDStyle, close: Bool) -> String {
                switch f {
                case .bold: return close ? "</strong>" : "<strong>"
                case .italic: return close ? "</em>" : "<em>"
                case .strikethrough: return close ? "</del>" : "<del>"
                case .inlineCode: return close ? "</code>" : "<code>"
                case .linkText: return close ? "</a>" : "<a href=\"\(escape(linkHref ?? ""))\">"
                default: return ""
                }
            }
            let order: [MDStyle] = [.linkText, .bold, .italic, .strikethrough, .inlineCode]
            while i < runs.count, runs[i].range.location < end {
                let run = runs[i]
                let r = NSIntersectionRange(run.range, range)
                i += 1
                guard r.length > 0, NSMaxRange(r) > skipUntil else { continue }
                let st = run.style
                // an image: `![alt](src "title")` -> <img>
                if st.contains(.image) {
                    if st.contains(.marker) && !st.contains(.linkDestination) && text.substring(with: r).hasPrefix("!") {
                        // assemble from the runs that follow
                        var alt = "", src = "", k = i, title = ""
                        var closeAt = NSMaxRange(r)
                        while k < runs.count, runs[k].range.location < end, runs[k].style.contains(.image) || (runs[k].style.facets.isEmpty && isBlank(runs[k].range)) {
                            let rk = runs[k], tk = text.substring(with: NSIntersectionRange(rk.range, range))
                            if rk.style.contains(.image) {
                                if !rk.style.contains(.marker) && !rk.style.contains(.linkDestination) { alt += tk }
                                if rk.style.contains(.linkDestination) && !rk.style.contains(.marker) { if src.isEmpty { src = tk.trimmingCharacters(in: .whitespaces) } else { title = tk.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) } }
                                closeAt = NSMaxRange(NSIntersectionRange(rk.range, range))
                            }
                            k += 1
                        }
                        if src.hasPrefix("<") && src.hasSuffix(">") { src = String(src.dropFirst().dropLast()) }
                        s += closeAll(&open, tag)
                        s += "<img src=\"\(escape(src))\" alt=\"\(escape(alt))\"" + (title.isEmpty ? "" : " title=\"\(escape(title))\"") + ">"
                        skipUntil = closeAt
                        continue
                    }
                    continue
                }
                if st.contains(.linkDestination) {
                    // `(dest "title")` shows nothing, the blank between the two included: up to the closing paren
                    var k = i - 1, endAt = NSMaxRange(r)
                    while k < runs.count, runs[k].range.location < end {
                        let sk = runs[k].style
                        if sk.contains(.linkDestination) {
                            endAt = NSMaxRange(NSIntersectionRange(runs[k].range, range))
                            if sk.contains(.marker), text.substring(with: runs[k].range).hasSuffix(")") { break }
                        } else if !(sk.facets.isEmpty && isBlank(runs[k].range)) { break }
                        k += 1
                    }
                    skipUntil = endAt
                    continue
                }
                if st.contains(.referenceLabel) && !st.contains(.linkText) { continue }       // the [ref] part shows nothing
                // autolinks: the URL is the text and the target
                if st.contains(.autolink) {
                    if st.contains(.marker) { continue }
                    var u = text.substring(with: r)
                    if u.hasPrefix("<") { u.removeFirst() }; if u.hasSuffix(">") { u.removeLast() }
                    let href = u.lowercased().hasPrefix("www.") ? "https://" + u : (u.contains("@") && !u.contains("://") ? "mailto:" + u : u)
                    s += closeAll(&open, tag) + "<a href=\"\(escape(href))\">\(escape(u))</a>"
                    continue
                }
                // the facets this run wants open
                var wanted: [MDStyle] = []
                for f in order where st.contains(f) { wanted.append(f) }
                if st.contains(.linkText), !open.contains(.linkText) { linkHref = hrefForLink(startingAt: i - 1, within: range) }
                // close what is open and not wanted (and everything opened after it, so that the tags nest), then open the rest in order
                if let firstGone = open.firstIndex(where: { !wanted.contains($0) }) {
                    while open.count > firstGone { s += tag(open.removeLast(), close: true) }
                }
                for f in wanted where !open.contains(f) { s += tag(f, close: false); open.append(f) }
                // the text itself
                if st.contains(.marker) { continue }                                     // syntax punctuation
                let piece = text.substring(with: r)
                if st.contains(.html) { s += piece; continue }                             // inline HTML as it is
                if st.contains(.escape) {
                    if piece.hasPrefix("\\"), piece.count == 2 { s += escape(String(piece.dropFirst())) } else { s += piece }   // `\*` -> `*`; `&amp;` stays
                    continue
                }
                if st.contains(.footnote) { s += "<sup>" + escape(piece) + "</sup>"; continue }
                s += escape(piece)
            }
            s += closeAll(&open, tag)
            return s
        }

        private func closeAll(_ open: inout [MDStyle], _ tag: (MDStyle, Bool) -> String) -> String {
            var s = ""
            while let last = open.popLast() { s += tag(last, true) }
            return s
        }

        /// The destination of the link whose text starts in run `index`: the first destination run that follows its `]`, or the definition of its reference label.
        private func hrefForLink(startingAt index: Int, within range: NSRange) -> String {
            var k = index
            var steps = 0
            while k < runs.count, steps < 60, runs[k].range.location < NSMaxRange(range) + 1 {
                let st = runs[k].style
                if st.contains(.linkDestination) && !st.contains(.marker) && !st.contains(.image) {
                    var d = text.substring(with: runs[k].range).trimmingCharacters(in: .whitespaces)
                    if d.hasPrefix("<") && d.hasSuffix(">") { d = String(d.dropFirst().dropLast()) }
                    return d
                }
                if st.contains(.referenceLabel) && !st.contains(.marker) { return LinkFollowing.definition(of: text.substring(with: runs[k].range), in: text) ?? "" }
                let isPart = st.contains(.linkText) || st.contains(.linkDestination) || st.contains(.referenceLabel)
                if !isPart && !(st.facets.isEmpty && text.substring(with: runs[k].range) == " ") {
                    // `[text]` alone: the text is the label
                    if runs[index].style.contains(.linkText) { return LinkFollowing.definition(of: text.substring(with: runs[index].range), in: text) ?? "" }
                    return ""
                }
                k += 1; steps += 1
            }
            return ""
        }
    }
}
