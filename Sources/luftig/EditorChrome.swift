// EditorChrome.swift - the logic behind the three understated elements around the text (outline, word count, syntax bar), without any view:
//   * OutlineScanner: the headings of a document (ATX and setext, outside fences and front matter), scanned in bounded chunks so that a 20 MB
//     document never blocks the main thread for more than a millisecond or two per run-loop turn;
//   * WordCounter: words, chunked the same way;
//   * SyntaxInsertion: what clicking an element of the syntax bar does to the text (pure: text + selection in, replacement + selection out).
// All of it works on UTF-16 units of an NSString (what NSTextStorage holds), never forces layout, and is covered by the `chrome-*` self-tests.

import Foundation

// MARK: - Outline

struct OutlineEntry: Equatable {
    var level: Int          // 1 ... 6
    var title: String       // the heading text, markers and surrounding white space removed
    var location: Int       // UTF-16 offset of the first character of the heading line (the paragraph line for a setext heading)
}

/// A chunked scanner: feed it the text in pieces (`scan(_:upTo:)` scans at most `budget` units and returns false until it reached the end). The state
/// between calls is the position, whether a fence is open, and what the previous line was (for setext underlines).
struct OutlineScanner {
    static let maxEntries = 5000                 // beyond this an outline is useless; the scan stops there
    static let maxTitleLength = 200

    private(set) var entries: [OutlineEntry] = []
    private(set) var position = 0                // next unit to read
    private var fence: (char: unichar, length: Int)? = nil
    private var frontMatter = false
    private var lineIndex = 0
    private var previous: (start: Int, end: Int, isParagraph: Bool) = (0, 0, false)
    private var buffer = [unichar](repeating: 0, count: 1 << 16)

    var isFinished: Bool { finished }
    private var finished = false

    /// Scans from the current position up to `budget` more units (whole lines). Returns true when the whole text has been scanned.
    @discardableResult
    mutating func scan(_ text: NSString, budget: Int = 1_000_000) -> Bool {
        let length = text.length
        if position >= length { finished = true; return true }
        let stop = min(length, position + budget)
        var lineStart = position
        while lineStart < length, lineStart < stop, entries.count < OutlineScanner.maxEntries {
            // the line
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentEnd = lineContentEnd(text, lineRange)
            let n = contentEnd - lineStart
            if n > buffer.count { buffer = [unichar](repeating: 0, count: n + 1024) }
            if n > 0 { buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: lineStart, length: n)) } }
            inspect(lineStart: lineStart, count: n, text: text)
            lineIndex += 1
            lineStart = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        position = lineStart
        if position >= length || entries.count >= OutlineScanner.maxEntries { finished = true; position = length }
        return finished
    }

    /// The whole text in one go (tests, small documents).
    static func headings(in text: NSString) -> [OutlineEntry] {
        var s = OutlineScanner()
        while !s.scan(text, budget: 1 << 20) {}
        return s.entries
    }

    private func lineContentEnd(_ text: NSString, _ lineRange: NSRange) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let c = text.character(at: end - 1)
            if c == 0x0A || c == 0x0D { end -= 1 } else { break }
        }
        return end
    }

    private mutating func inspect(lineStart: Int, count n: Int, text: NSString) {
        let b = buffer
        func isBlankLine() -> Bool { for i in 0..<n where b[i] != 0x20 && b[i] != 0x09 { return false }; return true }
        var i = 0
        var indent = 0
        while i < n, b[i] == 0x20, indent < 3 { i += 1; indent += 1 }
        let first = i < n ? b[i] : 0

        // front matter: `---` on the very first line, up to the next `---` line
        if lineIndex == 0, n == 3, b[0] == 0x2D, b[1] == 0x2D, b[2] == 0x2D { frontMatter = true; previous = (lineStart, lineStart + n, false); return }
        if frontMatter {
            if n == 3, b[0] == 0x2D, b[1] == 0x2D, b[2] == 0x2D { frontMatter = false }
            previous = (lineStart, lineStart + n, false)
            return
        }
        // fences: ``` or ~~~ (3 or more) open; a line of at least as many of the same character closes
        if first == 0x60 || first == 0x7E {
            var k = i
            while k < n, b[k] == first { k += 1 }
            let run = k - i
            if run >= 3 {
                if let f = fence {
                    var rest = k
                    while rest < n, b[rest] == 0x20 || b[rest] == 0x09 { rest += 1 }
                    if f.char == first, run >= f.length, rest == n { fence = nil }
                } else if first == 0x7E || !b[k..<n].contains(0x60) {       // (a backtick fence's info string may not contain backticks)
                    fence = (first, run)
                }
                previous = (lineStart, lineStart + n, false)
                return
            }
        }
        if fence != nil { previous = (lineStart, lineStart + n, false); return }

        // ATX: 1-6 #, then a space / tab or the end of the line
        if first == 0x23 {
            var k = i
            while k < n, b[k] == 0x23, k - i < 7 { k += 1 }
            let level = k - i
            if level <= 6, k == n || b[k] == 0x20 || b[k] == 0x09 {
                var s = k, e = n
                while s < e, b[s] == 0x20 || b[s] == 0x09 { s += 1 }
                while e > s, b[e - 1] == 0x20 || b[e - 1] == 0x09 { e -= 1 }
                var c = e                                                       // a closing sequence of #, preceded by a space (or the whole title)
                while c > s, b[c - 1] == 0x23 { c -= 1 }
                if c < e, c == s || b[c - 1] == 0x20 || b[c - 1] == 0x09 { e = c; while e > s, b[e - 1] == 0x20 || b[e - 1] == 0x09 { e -= 1 } }
                entries.append(OutlineEntry(level: level, title: title(b, s, e), location: lineStart))
                previous = (lineStart, lineStart + n, false)
                return
            }
        }
        // setext underline: a line of = or - (after at most 3 spaces, trailing spaces allowed) under a paragraph line
        if (first == 0x3D || first == 0x2D), previous.isParagraph {
            var k = i
            while k < n, b[k] == first { k += 1 }
            var rest = k
            while rest < n, b[rest] == 0x20 || b[rest] == 0x09 { rest += 1 }
            if rest == n, k > i {
                // the title is the previous line (one line of the paragraph is what people write)
                let prevLen = previous.end - previous.start
                var pb = [unichar](repeating: 0, count: prevLen)
                pb.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: previous.start, length: prevLen)) }
                var s = 0, e = prevLen
                while s < e, pb[s] == 0x20 || pb[s] == 0x09 { s += 1 }
                while e > s, pb[e - 1] == 0x20 || pb[e - 1] == 0x09 { e -= 1 }
                entries.append(OutlineEntry(level: first == 0x3D ? 1 : 2, title: title(pb, s, e), location: previous.start))
                previous = (lineStart, lineStart + n, false)
                return
            }
        }
        // a paragraph line: not blank, not a quote, not a list item or rule candidate (those cannot carry a setext underline here)
        let blank = isBlankLine()
        let isParagraph = !blank && first != 0x3E && first != 0x3C && !(indent == 0 && (first == 0x2D || first == 0x2A || first == 0x2B || first == 0x3D) && n > i + 1 && (b[i + 1] == 0x20 || b[i + 1] == first))
        previous = (lineStart, lineStart + n, isParagraph)
    }

    private func title(_ b: [unichar], _ s: Int, _ e: Int) -> String {
        guard e > s else { return "" }
        let end = min(e, s + OutlineScanner.maxTitleLength)
        return String(utf16CodeUnits: Array(b[s..<end]), count: end - s)
    }
}

// MARK: - Words

/// Counts words: runs of non-white-space that contain at least one letter or digit (so `---`, `|`, `**` and `#` on their own are not words), and every
/// CJK ideograph, kana or Hangul syllable as a word of its own (the convention for those scripts). Chunked like the outline scanner.
struct WordCounter {
    private(set) var count = 0
    private(set) var position = 0
    private var inToken = false
    private var tokenHasLetter = false
    private var buffer = [unichar](repeating: 0, count: 1 << 16)
    private var finished = false
    var isFinished: Bool { finished }

    /// Scans at most `budget` more units of `range` (the whole text by default). Returns true when done.
    @discardableResult
    mutating func scan(_ text: NSString, range: NSRange? = nil, budget: Int = 1_000_000) -> Bool {
        let r = range ?? NSRange(location: 0, length: text.length)
        if position < r.location { position = r.location }
        let end = NSMaxRange(r)
        var done = 0
        while position < end, done < budget {
            let n = min(buffer.count, end - position, budget - done)
            buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: position, length: n)) }
            for k in 0..<n { consume(buffer[k]) }
            position += n
            done += n
        }
        if position >= end { if inToken && tokenHasLetter { count += 1 }; inToken = false; finished = true }
        return finished
    }

    static func words(in text: NSString, range: NSRange? = nil) -> Int {
        var c = WordCounter()
        while !c.scan(text, range: range, budget: 1 << 20) {}
        return c.count
    }

    @inline(__always) private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x0B || c == 0xA0 || c == 0x3000 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x1680
    }
    @inline(__always) private static func isIdeograph(_ c: unichar) -> Bool {
        (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF) || (c >= 0x3040 && c <= 0x30FF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0x3100 && c <= 0x312F)
    }
    @inline(__always) private static func isLetterOrDigit(_ c: unichar) -> Bool {
        if c < 0x80 { return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        if c >= 0xD800 && c <= 0xDFFF { return true }                       // a surrogate: emoji, supplementary letters - count the token
        if c >= 0x2000 && c <= 0x2BFF { return false }                      // general punctuation, symbols, arrows, box drawing, dingbats
        if c == 0xB7 || c == 0xBF || c == 0xA1 || c == 0xAB || c == 0xBB { return false }
        return c >= 0xC0 || (c >= 0xAA && c <= 0xBA && c != 0xAB && c != 0xAC && c != 0xAD && c != 0xAE && c != 0xAF && c != 0xB0 && c != 0xB1 && c != 0xB4 && c != 0xB6 && c != 0xB7 && c != 0xB8)
    }

    private mutating func consume(_ c: unichar) {
        if WordCounter.isSpace(c) {
            if inToken && tokenHasLetter { count += 1 }
            inToken = false; tokenHasLetter = false
        } else if WordCounter.isIdeograph(c) {
            if inToken && tokenHasLetter { count += 1 }
            inToken = false; tokenHasLetter = false
            count += 1
        } else {
            inToken = true
            if !tokenHasLetter && WordCounter.isLetterOrDigit(c) { tokenHasLetter = true }
        }
    }
}

// MARK: - The syntax bar

enum SyntaxElement: CaseIterable {
    case heading1, heading2, heading3, paragraph, bold, italic, strike, code, link, image, quote, bulletList, numberedList, task, rule, fence, table

    /// The bar's groups, left to right (a wider gap between groups, no lines).
    static let groups: [[SyntaxElement]] = [[.heading1, .heading2, .heading3, .paragraph], [.bold, .italic, .strike, .code], [.link, .image], [.quote, .bulletList, .numberedList, .task], [.rule, .fence, .table]]

    /// What the bar shows: the RESULT of the element, not its syntax - text drawn the way the element looks, or a system symbol.
    enum Face { case text(String, bold: Bool, italic: Bool, strike: Bool, mono: Bool), symbol(String) }
    var face: Face {
        switch self {
        case .heading1: return .text("H1", bold: false, italic: false, strike: false, mono: false)
        case .heading2: return .text("H2", bold: false, italic: false, strike: false, mono: false)
        case .heading3: return .text("H3", bold: false, italic: false, strike: false, mono: false)
        case .paragraph: return .text("¶", bold: false, italic: false, strike: false, mono: false)
        case .bold: return .text("B", bold: true, italic: false, strike: false, mono: false)
        case .italic: return .text("I", bold: false, italic: true, strike: false, mono: false)
        case .strike: return .text("S", bold: false, italic: false, strike: true, mono: false)
        case .code: return .symbol("curlybraces")
        case .link: return .symbol("link")
        case .image: return .symbol("photo")
        case .quote: return .symbol("text.quote")
        case .bulletList: return .symbol("list.bullet")
        case .numberedList: return .symbol("list.number")
        case .task: return .symbol("checklist")
        case .rule: return .symbol("minus")
        case .fence: return .symbol("chevron.left.forwardslash.chevron.right")
        case .table: return .symbol("tablecells")
        }
    }
    var name: String {
        switch self {
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .paragraph: return "Plain paragraph (removes heading, list and quote markers)"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strike: return "Strikethrough"
        case .code: return "Inline code"
        case .link: return "Link"
        case .image: return "Image"
        case .quote: return "Quote"
        case .bulletList: return "List"
        case .numberedList: return "Numbered list"
        case .task: return "Task"
        case .rule: return "Horizontal rule"
        case .fence: return "Code block"
        case .table: return "Table"
        }
    }
    /// The heading level this element sets (nil for the others).
    var headingLevel: Int? { self == .heading1 ? 1 : self == .heading2 ? 2 : self == .heading3 ? 3 : nil }

    /// The Format menu: the item's title, its key (a character) and modifiers (MainMenu.swift makes the NSMenuItem; the bar's tooltips show the shortcut).
    struct Shortcut: Equatable {
        var key: String
        var shift = false
        var option = false
        /// What the tooltip says: ⌥⇧⌘K.
        var label: String { (option ? "⌥" : "") + (shift ? "⇧" : "") + "⌘" + key.uppercased() }
    }
    var menuTitle: String {
        switch self {
        case .paragraph: return "Plain Paragraph"
        case .bulletList: return "Bulleted List"
        default: return name
        }
    }
    var shortcut: Shortcut {
        switch self {
        case .heading1: return Shortcut(key: "1", shift: true)
        case .heading2: return Shortcut(key: "2", shift: true)
        case .heading3: return Shortcut(key: "3", shift: true)
        case .paragraph: return Shortcut(key: "0", shift: true)
        case .bold: return Shortcut(key: "b")
        case .italic: return Shortcut(key: "i")
        case .strike: return Shortcut(key: "x", shift: true)
        case .code: return Shortcut(key: "c", shift: true)
        case .link: return Shortcut(key: "k")
        case .image: return Shortcut(key: "k", shift: true)
        case .quote: return Shortcut(key: "q", option: true)
        case .bulletList: return Shortcut(key: "u", option: true)
        case .numberedList: return Shortcut(key: "o", option: true)
        case .task: return Shortcut(key: "x", option: true)
        case .rule: return Shortcut(key: "-", option: true)
        case .fence: return Shortcut(key: "c", option: true)
        case .table: return Shortcut(key: "t", option: true)
        }
    }
    /// The tag of the Format menu's item for this element (and back).
    var menuTag: Int { SyntaxElement.allCases.firstIndex(of: self)! + 1 }
    static func element(menuTag: Int) -> SyntaxElement? { menuTag >= 1 && menuTag <= allCases.count ? allCases[menuTag - 1] : nil }
}

/// One edit: replace `range` of the text with `replacement`, then select `selection` (in the coordinates of the text after the edit).
struct TextChange: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

enum SyntaxInsertion {

    /// The edit that clicking `element` performs on `text` with the current `selection`.
    static func change(for element: SyntaxElement, in text: NSString, selection: NSRange) -> TextChange {
        let sel = NSIntersectionRange(selection, NSRange(location: 0, length: text.length))
        let sel2 = sel.length == 0 && selection.location <= text.length ? NSRange(location: selection.location, length: 0) : sel
        switch element {
        case .bold: return wrap(text, sel2, "**", placeholder: "bold")
        case .italic: return wrap(text, sel2, "_", placeholder: "italic")
        case .strike: return wrap(text, sel2, "~~", placeholder: "struck")
        case .code: return wrap(text, sel2, "`", placeholder: "code")
        case .link: return link(text, sel2, image: false)
        case .image: return link(text, sel2, image: true)
        case .heading1, .heading2, .heading3, .paragraph, .quote, .bulletList, .numberedList, .task: return prefixLines(element, text, sel2)
        case .rule: return block(text, sel2, body: "---", caretAfter: true)
        case .fence: return fence(text, sel2)
        case .table: return block(text, sel2, body: "| Column | Column |\n| --- | --- |\n|  |  |", caretAfter: false, select: NSRange(location: 2, length: 6))
        }
    }

    // MARK: inline

    /// Wrap the selection in `marker` ... `marker`; an empty selection gets a placeholder word, selected; a selection that is already wrapped (the markers
    /// inside or just outside it) is unwrapped.
    private static func wrap(_ text: NSString, _ sel: NSRange, _ marker: String, placeholder: String) -> TextChange {
        let m = marker.utf16.count
        if sel.length >= 2 * m {
            let inner = text.substring(with: sel)
            if inner.hasPrefix(marker), inner.hasSuffix(marker) {
                let core = (inner as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
                return TextChange(range: sel, replacement: core, selection: NSRange(location: sel.location, length: sel.length - 2 * m))
            }
        }
        if sel.location >= m, NSMaxRange(sel) + m <= text.length,
           text.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let core = text.substring(with: sel)
            return TextChange(range: NSRange(location: sel.location - m, length: sel.length + 2 * m), replacement: core, selection: NSRange(location: sel.location - m, length: sel.length))
        }
        let body = sel.length > 0 ? text.substring(with: sel) : placeholder
        return TextChange(range: sel, replacement: marker + body + marker, selection: NSRange(location: sel.location + m, length: (body as NSString).length))
    }

    private static func link(_ text: NSString, _ sel: NSRange, image: Bool) -> TextChange {
        let bang = image ? "!" : ""
        let selected = sel.length > 0 ? text.substring(with: sel) : ""
        let looksLikeURL = selected.hasPrefix("http://") || selected.hasPrefix("https://") || selected.hasPrefix("www.")
        let label = image ? "alt" : "text"
        if looksLikeURL {
            let r = bang + "[" + label + "](" + selected + ")"
            return TextChange(range: sel, replacement: r, selection: NSRange(location: sel.location + bang.utf16.count + 1, length: label.utf16.count))
        }
        let body = selected.isEmpty ? label : selected
        let r = bang + "[" + body + "](url)"
        if selected.isEmpty {
            return TextChange(range: sel, replacement: r, selection: NSRange(location: sel.location + bang.utf16.count + 1, length: label.utf16.count))
        }
        let urlAt = sel.location + bang.utf16.count + 1 + (body as NSString).length + 2
        return TextChange(range: sel, replacement: r, selection: NSRange(location: urlAt, length: 3))
    }

    // MARK: lines

    /// Apply a per-line prefix to every line the selection touches. The caret (an empty selection) stays on its character; a selection grows to the lines.
    private static func prefixLines(_ element: SyntaxElement, _ text: NSString, _ sel: NSRange) -> TextChange {
        let lines = text.lineRange(for: sel)
        var body = text.substring(with: lines)
        var trailingNewline = ""
        if body.hasSuffix("\r\n") { trailingNewline = "\r\n"; body.removeLast(2) } else if body.hasSuffix("\n") || body.hasSuffix("\r") { trailingNewline = String(body.removeLast()) }
        let parts = body.components(separatedBy: "\n")
        var out: [String] = []
        var firstDelta = 0
        switch element {
        case .heading1, .heading2, .heading3:
            // that level exactly; the same level again makes the line plain
            let level = element.headingLevel ?? 1
            for (i, line) in parts.enumerated() {
                let (hashes, rest) = headingPrefix(line)
                let new = hashes == level ? rest : String(repeating: "#", count: level) + " " + rest
                if i == 0 { firstDelta = new.utf16.count - line.utf16.count }
                out.append(new)
            }
        case .paragraph:
            // plain lines: heading markers, quote markers (any depth) and list markers gone, the text kept
            for (i, line) in parts.enumerated() {
                var s = line
                while s.hasPrefix("> ") || s == ">" { s = s == ">" ? "" : String(s.dropFirst(2)) }
                s = headingPrefix(s).1
                let mark = listPrefix(s)
                if mark.length > 0 { s = String(s.dropFirst(mark.length)) }
                if i == 0 { firstDelta = s.utf16.count - line.utf16.count }
                out.append(s)
            }
        case .quote:
            let all = parts.allSatisfy { $0.hasPrefix("> ") || $0 == ">" }
            for (i, line) in parts.enumerated() {
                let new = all ? (line == ">" ? "" : String(line.dropFirst(2))) : "> " + line
                if i == 0 { firstDelta = new.utf16.count - line.utf16.count }
                out.append(new)
            }
        case .bulletList, .numberedList, .task:
            let marks = parts.map { listPrefix($0) }
            let wanted: String = element == .bulletList ? "- " : element == .task ? "- [ ] " : "1. "
            let allAlready = marks.allSatisfy { $0.kind == (element == .bulletList ? "bullet" : element == .task ? "task" : "number") }
            var number = 1
            for (i, line) in parts.enumerated() {
                let rest = String(line.dropFirst(marks[i].length))
                let new: String
                if allAlready { new = rest }
                else if element == .numberedList { new = "\(number). " + rest; number += 1 }
                else { new = wanted + rest }
                if i == 0 { firstDelta = new.utf16.count - line.utf16.count }
                out.append(new)
            }
        default: break
        }
        let replacement = out.joined(separator: "\n") + trailingNewline
        let selection: NSRange
        if sel.length == 0 {
            selection = NSRange(location: max(lines.location, sel.location + firstDelta), length: 0)
        } else {
            selection = NSRange(location: lines.location, length: (replacement as NSString).length - trailingNewline.utf16.count)
        }
        return TextChange(range: lines, replacement: replacement, selection: selection)
    }

    /// (number of #, the text after them and the following white space) for an ATX heading line, (0, line) otherwise.
    static func headingPrefix(_ line: String) -> (Int, String) {
        var hashes = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#" { hashes += 1; idx = line.index(after: idx) }
        guard hashes >= 1, hashes <= 6, idx == line.endIndex || line[idx] == " " || line[idx] == "\t" else { return (0, line) }
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" { idx = line.index(after: idx) }
        return (hashes, String(line[idx...]))
    }

    /// The list marker a line starts with: ("bullet" | "task" | "number" | "", length of the marker including its space). Leading spaces are part of the marker.
    static func listPrefix(_ line: String) -> (kind: String, length: Int) {
        let u = Array(line.utf16)
        var i = 0
        while i < u.count, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        guard i < u.count else { return ("", 0) }
        if u[i] == 0x2D || u[i] == 0x2A || u[i] == 0x2B {
            guard i + 1 < u.count, u[i + 1] == 0x20 else { return ("", 0) }
            var j = i + 2
            // task: [ ] or [x] / [X] followed by a space
            if j + 3 < u.count, u[j] == 0x5B, u[j + 1] == 0x20 || u[j + 1] == 0x78 || u[j + 1] == 0x58, u[j + 2] == 0x5D, u[j + 3] == 0x20 { j += 4; return ("task", j) }
            if j + 3 == u.count, u[j] == 0x5B, u[j + 1] == 0x20 || u[j + 1] == 0x78 || u[j + 1] == 0x58, u[j + 2] == 0x5D { return ("task", j + 3) }
            return ("bullet", j)
        }
        var j = i
        while j < u.count, u[j] >= 0x30, u[j] <= 0x39, j - i < 9 { j += 1 }
        if j > i, j + 1 < u.count, u[j] == 0x2E || u[j] == 0x29, u[j + 1] == 0x20 { return ("number", j + 2) }
        if j > i, j + 1 == u.count, u[j] == 0x2E || u[j] == 0x29 { return ("number", j + 1) }
        return ("", 0)
    }

    // MARK: blocks

    /// Insert `body` on lines of its own at the caret (a selection is replaced). `select`: a range inside `body` to select afterwards; else the caret goes
    /// after the body (`caretAfter`) or stays at its start.
    private static func block(_ text: NSString, _ sel: NSRange, body: String, caretAfter: Bool, select: NSRange? = nil) -> TextChange {
        let before = sel.location > 0 ? text.character(at: sel.location - 1) : 0x0A
        let after = NSMaxRange(sel) < text.length ? text.character(at: NSMaxRange(sel)) : 0x0A
        let atLineStart = before == 0x0A || before == 0x0D
        var head = atLineStart ? "" : "\n"
        if !atLineStart, sel.location > 1, text.character(at: sel.location - 2) == 0x0A || text.character(at: sel.location - 2) == 0x0D { head = "\n" }
        let tail = (after == 0x0A || after == 0x0D) ? "\n" : "\n\n"
        let r = head + body + tail
        let bodyStart = sel.location + head.utf16.count
        let selection = select.map { NSRange(location: bodyStart + $0.location, length: $0.length) }
            ?? NSRange(location: caretAfter ? bodyStart + body.utf16.count + 1 : bodyStart, length: 0)
        return TextChange(range: sel, replacement: r, selection: selection)
    }

    private static func fence(_ text: NSString, _ sel: NSRange) -> TextChange {
        if sel.length == 0 { return block(text, sel, body: "```\n\n```", caretAfter: false, select: NSRange(location: 4, length: 0)) }
        let lines = text.lineRange(for: sel)
        var body = text.substring(with: lines)
        var trailing = "\n"
        if body.hasSuffix("\n") { body.removeLast() } else { trailing = "\n" }
        let r = "```\n" + body + "\n```" + trailing
        return TextChange(range: lines, replacement: r, selection: NSRange(location: lines.location + 4, length: (body as NSString).length))
    }
}
