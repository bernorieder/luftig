import AppKit
import CoreText
import MarkdownKit

// HangingIndent.swift - list items (and indented continuation lines) HANG: when such a line wraps, the second and following lines of the
// wrapped line start where the TEXT of its first line starts (after the marker), not at the left edge.
//
// TextKit takes `headIndent` (the indent of every line of a paragraph but the first) from the paragraph style of the paragraph, and in
// luftig a paragraph is one source line (docs/ARCHITECTURE.md, invariant 8: one paragraph style per LINE, including its line break). So the
// whole feature is a number per line: the x position at which the line's text starts. It is a PURE FUNCTION OF THE LINE'S RUNS (their text and
// styles) and of the theme's fonts, which is what keeps the incremental restyle equal to a fresh lex (invariant 5, ARCHITECTURE.md invariant 21).
//
// A line hangs when it is a plain line (not a heading, code, rule, table, front matter or HTML line, and not right-to-left) that starts with a
// PREFIX made of
//     [spaces / tabs]  [block quote markers `> `]  [list marker `- ` `1. `]  [task marker `[ ]`]  [spaces / tabs]
// that contains a list marker or leading white space beyond the quote markers, and that has text after the prefix. The head indent is the
// x position where that text starts: the line's own indent (a quote's) plus the width of the prefix, measured in the fonts the characters
// REALLY have (the list marker run is semibold; white space belongs to whichever run the lexer put it in: it can be the tail of the previous
// line's run), with tabs advancing to the next tab stop of the paragraph (28 pt grid, see `paragraphStyle`). The position is that of the FIRST
// GLYPH of the text, not the end of the prefix: many families kern the space before a T, A, V, W, Y (Avenir Next: 0.34 em / 100), and TextKit puts
// the glyph where the kerning says, so the first character of the text is measured together with the prefix (found by the matrix-indent scenario:
// wrapped lines were up to 0.9 pt right of the text of the first line).
//
// Not applied: code blocks and fences, tables, front matter, headings (also setext), rules, HTML, right-to-left lines (their paragraph is
// right-aligned and has no left edge to hang from), and lines whose prefix would leave no room (`hangLimit`: 10 em, beyond which the wrapped
// part would be squeezed into a column of one character: TextKit gives every character its own line when headIndent reaches the container
// width, measured).

/// One source line of a lexed region that hangs. Buffer coordinates (index 0 = first character of the region).
struct HangLine {
    var start: Int
    /// Exclusive; includes the line break.
    var end: Int
    /// Absolute head indent in HALF points (the cache key of the attributes quantises to 0.5 pt).
    var indent: Int
}

/// Widths of line prefixes for ONE theme: (start x, the prefix characters and the first character of the text, each with the style of the run it sits
/// in) -> x where the text starts. The prefixes that occur are few ("- ", "  - ", "1. ", "10. ", "- [ ] ", "> - ") and so are the letters a text starts with,
/// so a lookup replaces a CoreText layout.
final class HangMeasurer {
    struct Key: Hashable {
        var startX: Int                  // half points
        var units: [UInt64]              // style.rawValue << 16 | UTF-16 unit: the prefix, then the first character of the text (the last element)
    }
    private var cache: [Key: CGFloat] = [:]
    /// What the cached widths were measured with. A theme that is re-configured in place (fonts, size) invalidates them.
    private var signature: (size: CGFloat, body: NSFont, marker: NSFont)?
    /// Scratch for the caller: the prefix being looked up, followed by the first character of the text (reused, so a lookup allocates only for the key).
    var scratch: [UInt64] = []

    func validate(for theme: Theme) {
        let body = theme.font(for: MDStyle()), marker = theme.font(for: .listMarker)
        if let s = signature, s.size == theme.baseSize, s.body === body, s.marker === marker { return }
        signature = (theme.baseSize, body, marker)
        cache.removeAll(keepingCapacity: true)
        last = nil
    }

    var count: Int { cache.count }

    /// The last answer: a list is mostly made of lines with the same prefix, which then costs a comparison and no hashing or allocation.
    private var last: (key: Key, x: CGFloat)?

    /// x position (from the container's left edge) of the first character of the text, after the prefix `scratch` (whose last element is that character),
    /// starting at `startX`.
    func endX(startX: CGFloat, theme: Theme) -> CGFloat {
        let half = Int((startX * 2).rounded())
        if let l = last, l.key.startX == half, l.key.units == scratch { return l.x }
        let key = Key(startX: half, units: scratch)
        var w: CGFloat
        if let hit = cache[key] { w = hit } else {
            w = HangMeasurer.measure(startX: startX, units: scratch, theme: theme)
            if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }      // (a document with thousands of different prefixes: stay bounded)
            cache[key] = w
        }
        last = (key, w)
        return w
    }

    /// The attributes that can change the width of a glyph run; the others (colour, underline, paragraph style, decoration marks) cannot.
    static let metricKeys: [NSAttributedString.Key] = [.font, .kern, .ligature, .strokeWidth, .obliqueness, .expansion]

    /// CoreText position of the first character of the text: `units` is the prefix followed by that character. The prefix is measured segment by
    /// segment between tabs (a tab moves x to the next multiple of the tab interval); the segment that runs into the first character is laid out WITH
    /// it, and the position of its glyph is read (kerning and all, which is what TextKit lays out: verified against glyph positions to 0.0001 pt).
    static func measure(startX: CGFloat, units: [UInt64], theme: Theme) -> CGFloat {
        var x = startX
        var i = 0
        let n = units.count - 1                                            // the prefix is units[0 ..< n], the first character of the text units[n]
        func attributed(_ unitsOfOneRun: [unichar], _ raw: UInt64) -> NSAttributedString {
            // the character attributes the run really gets (the font, and whatever else changes advances: kerning, synthetic styles of a family)
            let all = theme.attributes(for: MDStyle(rawValue: UInt32(truncatingIfNeeded: raw)))
            var metric: [NSAttributedString.Key: Any] = [:]
            for key in HangMeasurer.metricKeys { if let v = all[key] { metric[key] = v } }
            return NSAttributedString(string: String(decoding: unitsOfOneRun, as: UTF16.self), attributes: metric)
        }
        while i < n {
            if units[i] & 0xFFFF == 0x09 {
                x = ((x / Theme.hangTabInterval).rounded(.down) + 1) * Theme.hangTabInterval
                i += 1
                continue
            }
            let text = NSMutableAttributedString()
            var length = 0                                                 // UTF-16 length of the prefix characters of this segment
            while i < n, units[i] & 0xFFFF != 0x09 {
                let raw = units[i] >> 16
                var chars: [unichar] = []
                while i < n, units[i] >> 16 == raw, units[i] & 0xFFFF != 0x09 { chars.append(unichar(units[i] & 0xFFFF)); i += 1 }
                text.append(attributed(chars, raw))
                length += chars.count
            }
            if i == n {
                // the last segment runs into the first character of the text: its glyph position includes the kerning between the two
                text.append(attributed([unichar(units[n] & 0xFFFF)], units[n] >> 16))
                x += HangMeasurer.glyphX(of: length, in: CTLineCreateWithAttributedString(text as CFAttributedString))
            } else {
                x += CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text as CFAttributedString), nil, nil, nil))
            }
        }
        return x
    }

    /// The pen position of the glyph that belongs to UTF-16 index `index` of the line. (`CTLineGetOffsetForStringIndex` is the CARET position: it splits a
    /// kerning adjustment between the two glyphs; TextKit draws the glyph where the run positions say.)
    private static func glyphX(of index: Int, in line: CTLine) -> CGFloat {
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var indices = [CFIndex](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            if let k = indices.firstIndex(of: index) { return positions[k].x }
        }
        return CGFloat(CTLineGetOffsetForStringIndex(line, index, nil))      // (no glyph of its own: part of a cluster)
    }
}

extension Theme {
    /// Tab stops of a hanging line: AppKit's own default grid (28 pt; `tabStops` of the default paragraph style are 12 stops of 28 pt, and a 13th
    /// tab used to jump back to 28). Set explicitly so that the width of a tab in a prefix is known here.
    static let hangTabInterval: CGFloat = 28
    /// Prefixes longer than this many UTF-16 units are not measured: they hang at `hangLimit`.
    static let hangMaxPrefixUnits = 96
    /// The head indent never exceeds this (10 em of the base size = six levels of 4-space nesting): see the header.
    var hangLimit: CGFloat { baseSize * 10 }

    /// Facets that make a line something other than a plain line of text (the line-level style is the one of the run that holds the line break).
    private static let hangExcluded: MDStyle = [.codeBlock, .codeFence, .horizontalRule, .table, .frontMatter, .html]

    @inline(__always)
    static func hangEligible(_ lineStyle: MDStyle) -> Bool {
        lineStyle.headingLevel == 0 && lineStyle.isDisjoint(with: hangExcluded)
    }

    /// The lines of the region that hang, in order. `runs` partition the region (`start` = its first character, buffer index 0), `buf` holds its
    /// characters. `isRTLLine(k)` says whether the line containing buffer index `k` is right-to-left (nil: the region has no such character).
    /// One forward pass over the characters; the analysis only runs for CANDIDATE lines (first character is white space, or the first run is a
    /// list marker or a block quote marker), so a document without lists costs the scan for line breaks and nothing else.
    func hangingLines(runs: [MDRun], start: Int, buffer buf: UnsafeBufferPointer<unichar>, length: Int, isRTLLine: ((Int) -> Bool)?) -> [HangLine] {
        var result: [HangLine] = []
        let n = runs.count
        guard n > 0, length > 0 else { return result }
        var ri = 0
        var pos = 0
        var validated = false
        while pos < length {
            var e = pos                                             // index of the line break (or length)
            while e < length {
                let c = buf[e]
                if c == 0x0A || (c == 0x0D && !(e + 1 < length && buf[e + 1] == 0x0A)) { break }
                e += 1
            }
            let next = e < length ? e + 1 : length
            if e > pos {
                let c0 = buf[pos]
                while ri < n - 1, NSMaxRange(runs[ri].range) - start <= pos { ri += 1 }
                var candidate = c0 == 0x20 || c0 == 0x09
                if !candidate {
                    let st = runs[ri].style
                    candidate = st.contains(.listMarker) || (c0 == 0x3E && st.contains(.marker) && st.quoteDepth > 0)
                }
                if candidate {
                    if !validated { hangMeasurer.validate(for: self); validated = true }
                    if let h = hangIndent(lineStart: pos, lineEnd: e, runIndex: ri, runs: runs, start: start, buffer: buf, length: length, isRTLLine: isRTLLine) {
                        result.append(HangLine(start: pos, end: next, indent: h))
                    }
                }
            }
            pos = next
        }
        return result
    }

    /// The head indent (half points) of the line [ls, e) or nil when it does not hang. `ri` = the run that holds buffer index `ls`.
    private func hangIndent(lineStart ls: Int, lineEnd e: Int, runIndex ri: Int, runs: [MDRun], start: Int, buffer buf: UnsafeBufferPointer<unichar>,
                            length: Int, isRTLLine: ((Int) -> Bool)?) -> Int? {
        // 1. the prefix: white space, quote markers, list / task markers, up to the first character of the text
        var p = ls
        var rk = ri
        var sawMarker = false, sawWhitespace = false
        while p < e {
            while rk < runs.count - 1, NSMaxRange(runs[rk].range) - start <= p { rk += 1 }
            let st = runs[rk].style
            let c = buf[p]
            if c == 0x20 || c == 0x09 {
                while p < e, buf[p] == 0x20 || buf[p] == 0x09 { p += 1 }
                sawWhitespace = true
                continue
            }
            let runEnd = min(e, NSMaxRange(runs[rk].range) - start)
            if st.contains(.listMarker) || st.contains(.taskMarker) { p = runEnd; sawMarker = true; continue }
            if c == 0x3E, st.contains(.marker), st.quoteDepth > 0 { p = runEnd; continue }       // `> ` (the lexer puts the space into the marker run)
            break
        }
        guard p < e, sawMarker || sawWhitespace else { return nil }          // no text after the prefix, or nothing to hang by (`> text`, `text`)

        // 2. what kind of line it is: the run that holds the line break decides (Theme.styledRuns, line-level facets)
        var rb = rk
        let bi = min(e, length - 1)
        while rb < runs.count - 1, NSMaxRange(runs[rb].range) - start <= bi { rb += 1 }
        let lineStyle = runs[rb].style
        guard Theme.hangEligible(lineStyle) else { return nil }
        if let rtl = isRTLLine, rtl(ls) { return nil }

        // 3. the width
        let startX: CGFloat = lineStyle.quoteDepth > 0 ? DecorationMetrics.quoteIndent(depth: lineStyle.quoteDepth) : 0
        var x: CGFloat
        if p - ls > Theme.hangMaxPrefixUnits {
            x = hangLimit
        } else {
            let m = hangMeasurer
            m.scratch.removeAll(keepingCapacity: true)
            var q = ls
            var r = ri
            while q < p {
                while r < runs.count - 1, NSMaxRange(runs[r].range) - start <= q { r += 1 }
                let raw = UInt64(runs[r].style.rawValue) << 16
                let stop = min(p, NSMaxRange(runs[r].range) - start)
                while q < stop { m.scratch.append(raw | UInt64(buf[q])); q += 1 }
            }
            m.scratch.append((UInt64(runs[rk].style.rawValue) << 16) | UInt64(buf[p]))          // the first character of the text, in its own run's style
            x = m.endX(startX: startX, theme: self)
        }
        x = max(startX, min(x, hangLimit))
        let half = Int((x * 2).rounded())
        return half > Int((startX * 2).rounded()) ? min(half, 4095) : nil
    }
}
