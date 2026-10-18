// ListEditing.swift - what Return, Tab and Shift-Tab do on a list or quote line (pure: text + selection in, one TextChange out, or nil for
// "the ordinary key"). Wired in EditorViewController's `textView(_:doCommandBy:)`; Settings > General > "Continue lists on Return" switches it off.
//
//   Return   on a list item / quote line   -> a new line with the same prefix: indentation, quote markers, the next number (the items below are
//                                            renumbered when they were in sequence), an unchecked task box for a task item; the text after the
//                                            caret moves to the new item
//   Return   on an EMPTY item              -> the item is outdented (an indented one) or its marker is removed (a top-level one); an empty quote line
//                                            loses one level of `>`
//   Tab      on list lines                 -> the lines are indented by the width of the marker of the item above them (a sub-list)
//   Shift-Tab                              -> back to the indentation of the parent item
//
// Everything works on UTF-16 units of an NSString. A tab counts as 4 columns of indentation.

import Foundation

enum ListContinuation {

    /// What a line starts with: `indent` `quotes` `marker` `task`, each the exact text (so that the continuation keeps the user's spelling: `*   ` stays `*   `).
    struct LinePrefix: Equatable {
        var indent = ""          // spaces / tabs
        var quotes = ""          // one or more `>` markers with their spaces (`> > `)
        var marker = ""          // `- `, `* `, `+ `, `1. `, `1) ` with the white space after it; empty: no list marker
        var number: Int?         // the number of a numbered marker
        var delimiter = ""       // `.` or `)` of a numbered marker
        var task = ""            // `[ ] `, `[x] ` with its space; empty: no task box
        var hasList: Bool { !marker.isEmpty }
        var hasQuote: Bool { !quotes.isEmpty }
        var isEmpty: Bool { !hasList && !hasQuote }
        var text: String { indent + quotes + marker + task }
        var length: Int { text.utf16.count }
        /// Columns of the indentation (a tab = 4).
        var indentWidth: Int { ListContinuation.width(of: indent) }
        /// Columns the marker (and its white space) occupies: what a nested item is indented by.
        var markerWidth: Int { max(2, marker.utf16.count) }
    }

    static func width(of indent: String) -> Int {
        var w = 0
        for u in indent.utf16 { w = u == 0x09 ? (w / 4 + 1) * 4 : w + 1 }
        return w
    }

    /// The prefix of one line (without its line break).
    static func prefix(of line: String) -> LinePrefix {
        let u = Array(line.utf16)
        var p = LinePrefix()
        var i = 0
        while i < u.count, u[i] == 0x20 || u[i] == 0x09 { i += 1 }
        p.indent = String(utf16CodeUnits: Array(u[0..<i]), count: i)
        // quote markers: `>` followed by an optional space, repeated (spaces between them allowed)
        var q = i
        var quoteEnd = i
        while q < u.count, u[q] == 0x3E {
            q += 1
            if q < u.count, u[q] == 0x20 { q += 1 }
            quoteEnd = q
            var s = q
            while s < u.count, u[s] == 0x20, s - q < 3 { s += 1 }
            if s < u.count, u[s] == 0x3E { q = s } else { break }
        }
        if quoteEnd > i { p.quotes = String(utf16CodeUnits: Array(u[i..<quoteEnd]), count: quoteEnd - i); i = quoteEnd }
        // up to three more spaces, then the list marker
        var m = i
        while m < u.count, u[m] == 0x20, m - i < 3 { m += 1 }
        var markerEnd = -1
        if m < u.count, u[m] == 0x2D || u[m] == 0x2A || u[m] == 0x2B {
            if m + 1 == u.count || u[m + 1] == 0x20 || u[m + 1] == 0x09 { markerEnd = m + 1 }
        } else {
            var d = m
            while d < u.count, u[d] >= 0x30, u[d] <= 0x39, d - m < 9 { d += 1 }
            if d > m, d < u.count, u[d] == 0x2E || u[d] == 0x29, d + 1 == u.count || u[d + 1] == 0x20 || u[d + 1] == 0x09 {
                p.number = Int(String(utf16CodeUnits: Array(u[m..<d]), count: d - m))
                p.delimiter = u[d] == 0x2E ? "." : ")"
                markerEnd = d + 1
            }
        }
        guard markerEnd >= 0 else { return p }
        var e = markerEnd
        while e < u.count, u[e] == 0x20 || u[e] == 0x09, e - markerEnd < 4 { e += 1 }
        p.marker = String(utf16CodeUnits: Array(u[i..<e]), count: e - i)          // (the spaces before the marker belong to it: `  - ` after a quote)
        i = e
        // a task box: [ ] / [x] / [X] followed by a space (or the end of the line)
        if i + 2 < u.count, u[i] == 0x5B, u[i + 1] == 0x20 || u[i + 1] == 0x78 || u[i + 1] == 0x58, u[i + 2] == 0x5D, i + 3 == u.count || u[i + 3] == 0x20 {
            let te = min(u.count, i + 4)
            p.task = String(utf16CodeUnits: Array(u[i..<te]), count: te - i)
        }
        return p
    }

    // MARK: Return

    /// The edit Return performs at `selection` (a caret; nil for a selection, for a line that is not a list / quote line, or for a caret inside the prefix).
    static func returnChange(in text: NSString, selection: NSRange) -> TextChange? {
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let caret = selection.location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let contentEnd = lineContentEnd(text, lineRange)
        let line = text.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let p = prefix(of: line)
        guard !p.isEmpty else { return nil }
        let caretInLine = caret - lineRange.location
        guard caretInLine >= p.length else { return nil }
        let rest = (line as NSString).substring(from: p.length)
        let restIsBlank = rest.allSatisfy { $0 == " " || $0 == "\t" }

        if restIsBlank && caret == contentEnd {
            // an empty item: outdent it, or take its marker away; an empty quote line loses one `>`
            let lineContent = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            if p.hasList {
                if p.indentWidth > 0, let out = indentChange(in: text, selection: NSRange(location: lineRange.location, length: 0), outdent: true) { return out }
                let new = p.quotes
                return TextChange(range: lineContent, replacement: new, selection: NSRange(location: lineRange.location + new.utf16.count, length: 0))
            }
            // quote only: one level less
            var q = p.quotes
            if q.hasSuffix(" ") { q.removeLast() }
            if q.hasSuffix(">") { q.removeLast() }
            while q.hasSuffix(" ") { q.removeLast() }
            if !q.isEmpty { q += " " }
            let new = p.indent + q
            return TextChange(range: lineContent, replacement: new, selection: NSRange(location: lineRange.location + new.utf16.count, length: 0))
        }

        // continue the list / quote
        var next = p
        if let n = p.number {
            let digits = (p.marker as NSString).range(of: "\(n)\(p.delimiter)")
            if digits.location != NSNotFound { next.marker = (p.marker as NSString).replacingCharacters(in: digits, with: "\(n + 1)\(p.delimiter)") }
        }
        if !p.task.isEmpty { next.task = "[ ]" + String(p.task.dropFirst(3)) }
        let newPrefix = next.text
        var range = NSRange(location: caret, length: 0)
        var tail = ""
        // the items below, when they were numbered in sequence: one up each
        if let n = p.number {
            var expected = n + 1
            var pos = NSMaxRange(lineRange)
            var last = -1
            while pos < text.length {
                let r = text.lineRange(for: NSRange(location: pos, length: 0))
                let e = lineContentEnd(text, r)
                let q = prefix(of: text.substring(with: NSRange(location: r.location, length: e - r.location)))
                guard q.number == expected, q.delimiter == p.delimiter, q.indent == p.indent, q.quotes == p.quotes else { break }
                expected += 1
                last = e
                pos = NSMaxRange(r)
                if r.length == 0 { break }
            }
            if last > caret {
                range = NSRange(location: caret, length: last - caret)
                let block = text.substring(with: range) as NSString
                var lines: [String] = []
                var i = 0
                var first = true
                while i < block.length {
                    let r = block.lineRange(for: NSRange(location: i, length: 0))
                    let e = lineContentEnd(block, r)
                    var s = block.substring(with: NSRange(location: r.location, length: e - r.location))
                    if !first {
                        let q = prefix(of: s)
                        if let m = q.number {
                            let whole = (q.indent + q.quotes).utf16.count
                            let digits = (s as NSString).range(of: "\(m)\(q.delimiter)", options: [], range: NSRange(location: whole, length: q.marker.utf16.count))
                            if digits.location != NSNotFound { s = (s as NSString).replacingCharacters(in: digits, with: "\(m + 1)\(q.delimiter)") }
                        }
                    }
                    first = false
                    lines.append(s + block.substring(with: NSRange(location: e, length: NSMaxRange(r) - e)))
                    i = NSMaxRange(r)
                    if r.length == 0 { break }
                }
                tail = lines.joined()
            }
        }
        let replacement = "\n" + newPrefix + tail
        return TextChange(range: range, replacement: replacement, selection: NSRange(location: caret + 1 + newPrefix.utf16.count, length: 0))
    }

    // MARK: Tab / Shift-Tab

    /// Indent (or outdent) the list items among the lines `selection` touches. nil when none of them is a list item (the ordinary tab). Items inside a
    /// block quote are left alone (their indentation sits after the `>`).
    static func indentChange(in text: NSString, selection: NSRange, outdent: Bool) -> TextChange? {
        let sel = NSIntersectionRange(selection, NSRange(location: 0, length: text.length))
        let sel2 = sel.length == 0 && selection.location <= text.length ? NSRange(location: selection.location, length: 0) : sel
        let lines = text.lineRange(for: sel2)
        var body = text.substring(with: lines)
        var trailing = ""
        if body.hasSuffix("\r\n") { trailing = "\r\n"; body.removeLast(2) } else if body.hasSuffix("\n") || body.hasSuffix("\r") { trailing = String(body.removeLast()) }
        let parts = body.components(separatedBy: "\n")
        var out: [String] = []
        var firstDelta = 0
        var any = false
        var offset = lines.location
        for (i, line) in parts.enumerated() {
            let p = prefix(of: line)
            var new = line
            if p.hasList && !p.hasQuote {
                let width = p.indentWidth
                var target: Int
                if outdent {
                    target = parentIndent(before: offset, in: text, below: width) ?? 0
                    if target >= width { target = 0 }
                } else {
                    target = width + (siblingMarkerWidth(before: offset, in: text, at: width) ?? p.markerWidth)
                }
                if target != width {
                    any = true
                    var q = p
                    q.indent = String(repeating: " ", count: target)
                    // a numbered item that moves: its number follows the item above it at the new depth (1 when there is none)
                    if p.number != nil {
                        let n = (previousNumber(before: offset, in: text, at: target, delimiter: p.delimiter) ?? 0) + 1
                        q.marker = p.marker.replacingOccurrences(of: "\(p.number!)\(p.delimiter)", with: "\(n)\(p.delimiter)")
                    }
                    new = q.text + (line as NSString).substring(from: p.length)
                }
            }
            if i == 0 { firstDelta = new.utf16.count - line.utf16.count }
            out.append(new)
            offset += line.utf16.count + 1
        }
        guard any else { return nil }
        let replacement = out.joined(separator: "\n") + trailing
        let selection: NSRange
        if sel2.length == 0 {
            // the caret stays on its character; a caret that was inside the old prefix lands after the new one
            let p = prefix(of: parts[0])
            let newPrefixLength = (out[0] as NSString).length - ((parts[0] as NSString).length - p.length)
            let inLine = sel2.location - lines.location
            selection = NSRange(location: inLine >= p.length ? sel2.location + firstDelta : lines.location + newPrefixLength, length: 0)
        } else {
            selection = NSRange(location: lines.location, length: (replacement as NSString).length - trailing.utf16.count)
        }
        return TextChange(range: lines, replacement: replacement, selection: selection)
    }

    /// The width of the marker of the item above `location` that sits at indentation `width` (the sibling a Tab nests under); nil when there is none
    /// within the contiguous block of lines.
    private static func siblingMarkerWidth(before location: Int, in text: NSString, at width: Int) -> Int? {
        var result: Int?
        walkUp(before: location, in: text) { p in
            if p.hasList && p.indentWidth == width { result = p.markerWidth; return false }
            if p.hasList && p.indentWidth < width { return false }
            return true
        }
        return result
    }

    /// The indentation of the nearest item above `location` whose indentation is less than `width` (the parent a Shift-Tab goes back to).
    private static func parentIndent(before location: Int, in text: NSString, below width: Int) -> Int? {
        var result: Int?
        walkUp(before: location, in: text) { p in
            if p.hasList && p.indentWidth < width { result = p.indentWidth; return false }
            return true
        }
        return result
    }

    /// The number of the nearest numbered item above `location` at indentation `width` with the same delimiter (nil: none before another depth).
    private static func previousNumber(before location: Int, in text: NSString, at width: Int, delimiter: String) -> Int? {
        var result: Int?
        walkUp(before: location, in: text) { p in
            if p.hasList && p.indentWidth == width { if p.delimiter == delimiter { result = p.number }; return false }
            if p.hasList && p.indentWidth < width { return false }
            return true
        }
        return result
    }

    /// The prefixes of the lines above `location` (the line start), nearest first, until a blank line or `visit` returns false.
    private static func walkUp(before location: Int, in text: NSString, _ visit: (LinePrefix) -> Bool) {
        var pos = location
        while pos > 0 {
            let r = text.lineRange(for: NSRange(location: pos - 1, length: 0))
            let e = lineContentEnd(text, r)
            let line = text.substring(with: NSRange(location: r.location, length: e - r.location))
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) { return }
            if !visit(prefix(of: line)) { return }
            pos = r.location
        }
    }

    static func lineContentEnd(_ text: NSString, _ lineRange: NSRange) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let c = text.character(at: end - 1)
            if c == 0x0A || c == 0x0D { end -= 1 } else { break }
        }
        return end
    }
}
