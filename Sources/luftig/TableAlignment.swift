import AppKit
import CoreText
import MarkdownKit

// Tables aligned on screen, without changing a character of the file.
//
// The text of a table stays exactly what the file holds; only the space before each cell's closing pipe grows (a `.kern` attribute on the cell's
// last character), so that the pipes of every row line up. Editing, the caret, selection, undo, saving, Copy and Export see the plain source.
//
//   * A column is as wide as its widest cell, measured from the start of the line in the fonts the cells really have (CoreText, with the font
//     fallback AppKit gives CJK / emoji), so a mixed-width cell or a cell with bold or code lines up too. A table that is already aligned in the
//     source (Format > Align Table) gets no extra space at all.
//   * The width of a column depends on EVERY row, so a table is always styled as a whole: MarkdownRunProvider widens each region it styles to the
//     whole tables it touches (`TableExtent`), and a keystroke in one cell restyles the whole table.
//   * A table wider than the text column (`widthLimit`) has rows that wrap: only its leading columns whose closing pipes still fit on the first line
//     of every row are aligned, and each row HANGS: its wrapped lines start where the text of its second cell starts (a head indent per row, which is
//     a paragraph in luftig), unless that is more than half the column.
//   * Not aligned (left as they are): tables over `maxTableUnits` (every keystroke in one re-measures all of it), and tables with a tab character in
//     a row (a tab's width depends on where it starts). The decision is a pure function of the text, the theme and `widthLimit`, so an incremental
//     restyle equals a fresh one.
final class TableAligner {
    /// Widest a table may be (from the start of its line, indent included) and still be aligned whole: the width of the text container.
    var widthLimit: CGFloat = .greatestFiniteMagnitude
    /// Tables over this many UTF-16 units are not aligned.
    static let maxTableUnits = 24_000

    /// The limits at which the tables measured so far change (whole points, rounded up): a table's width, where each of its closing pipes ends, twice
    /// its widest hang. When `widthLimit` moves across one of them, what is aligned changes and the text must be restyled; otherwise a window resize
    /// leaves the styling alone. Stale entries (tables since deleted) only cost a restyle.
    private var measuredWidths = Set<Int>()
    private var measuredOverflow = false
    private static let maxRemembered = 4096

    /// A new limit (the text container's width changed). True when a table that was measured may change its alignment: restyle.
    func setWidthLimit(_ limit: CGFloat) -> Bool {
        let old = widthLimit
        guard abs(old - limit) > 0.25 else { return false }
        widthLimit = limit
        if measuredOverflow { return true }
        let lo = min(old, limit), hi = max(old, limit)
        return measuredWidths.contains { CGFloat($0) > lo - 1 && CGFloat($0) <= hi + 1 }
    }

    private func remember(_ width: CGFloat) {
        guard !measuredOverflow else { return }
        measuredWidths.insert(Int(width.rounded(.up)))
        if measuredWidths.count > TableAligner.maxRemembered { measuredOverflow = true; measuredWidths.removeAll() }
    }

    // MARK: lines

    /// One line of a region: [start, end) is its text, `next` the start of the following line (after the line break).
    struct Line {
        var start: Int
        var end: Int
        var next: Int
        var isTable: Bool
        var isHeader: Bool
    }

    /// The lines of `range` (which starts at a line start) with their table role, from the lexer runs that cover it. Line breaks are the lexer's:
    /// LF, CRLF and CR.
    static func lines(_ runs: [MDRun], text: NSString, in range: NSRange) -> [Line] {
        let start = range.location, end = min(NSMaxRange(range), text.length)
        guard end > start else { return [] }
        var buf = [unichar](repeating: 0, count: end - start)
        text.getCharacters(&buf, range: NSRange(location: start, length: end - start))
        var out: [Line] = []
        var ri = 0
        var pos = start
        while pos < end {
            var k = pos - start
            while k < buf.count, buf[k] != 0x0A, buf[k] != 0x0D { k += 1 }
            let le = k + start
            var next = le
            if k < buf.count { next = (buf[k] == 0x0D && k + 1 < buf.count && buf[k + 1] == 0x0A) ? le + 2 : le + 1 }
            if k + 1 == buf.count, buf[k] == 0x0D, end < text.length, text.character(at: end) == 0x0A { next = end + 1 }
            var table = false, header = false
            while ri < runs.count && NSMaxRange(runs[ri].range) <= pos { ri += 1 }
            var j = ri
            while j < runs.count && runs[j].range.location < le {
                let s = runs[j].style
                if s.contains(.table) { table = true; if s.contains(.tableHeader) { header = true } }
                j += 1
            }
            out.append(Line(start: pos, end: le, next: next, isTable: table, isHeader: header))
            pos = next
        }
        return out
    }

    // MARK: aligning

    /// `styled` with the alignment of every complete table in `region` added. `cutAtStart` / `cutAtEnd`: the first / last table of the region goes on
    /// beyond it (it could not be widened to the whole table, or the table is too big): those are left alone.
    func align(_ styled: [StyledRun], lexRuns: [MDRun], text: NSString, region: NSRange, cutAtStart: Bool, cutAtEnd: Bool) -> [StyledRun] {
        guard lexRuns.contains(where: { $0.style.contains(.table) }) else { return styled }
        let lines = TableAligner.lines(lexRuns, text: text, in: region)
        // the tables: a header line and the table lines after it (a region may also start in the middle of one: that is a table too, marked cut)
        var tables: [ArraySlice<Line>] = []
        var i = 0
        while i < lines.count {
            guard lines[i].isTable else { i += 1; continue }
            var j = i + 1
            while j < lines.count && lines[j].isTable && !lines[j].isHeader { j += 1 }
            tables.append(lines[i..<j])
            i = j
        }
        var edits = Edits()
        for (n, table) in tables.enumerated() {
            if n == 0 && cutAtStart && table.first!.start == lines.first!.start { continue }
            if n == tables.count - 1 && cutAtEnd && table.last!.next >= lines.last!.next { continue }
            guard table.first!.isHeader else { continue }
            guard table.last!.end - table.first!.start <= TableAligner.maxTableUnits else { continue }
            alignment(of: table, styled: styled, lexRuns: lexRuns, text: text, into: &edits)
        }
        var out = styled
        if !edits.paragraphs.isEmpty { out = TableAligner.apply(edits.paragraphs, key: .paragraphStyle, to: out) }
        if !edits.kerns.isEmpty { out = TableAligner.apply(edits.kerns, key: .kern, to: out) }
        return out
    }

    /// What aligning adds to the styled runs: `.kern` on the character before a closing pipe, a paragraph style with a head indent on a row (its whole
    /// line, line break included). Each list sorted, not overlapping.
    struct Edits {
        var kerns: [(range: NSRange, value: Any)] = []
        var paragraphs: [(range: NSRange, value: Any)] = []
    }

    /// The paragraph styles of hanging rows: (the row's own style, head indent in half points) -> the style with that head indent. The row's style is
    /// kept alive by the cache, so its identity cannot be reused for another.
    private var hangStyles: [HangKey: (base: NSParagraphStyle, style: NSParagraphStyle)] = [:]
    private struct HangKey: Hashable { var base: ObjectIdentifier; var half: Int }

    private func hangStyle(_ base: NSParagraphStyle, half: Int) -> NSParagraphStyle {
        let key = HangKey(base: ObjectIdentifier(base), half: half)
        if let hit = hangStyles[key] { return hit.style }
        let p = base.mutableCopy() as! NSMutableParagraphStyle
        p.headIndent = CGFloat(half) / 2
        if hangStyles.count > 1024 { hangStyles.removeAll(keepingCapacity: true) }
        hangStyles[key] = (base, p)
        return p
    }

    /// The extra space before each closing pipe of one table (and, for a table wider than the column, the head indent of each row).
    private func alignment(of table: ArraySlice<Line>, styled: [StyledRun], lexRuns: [MDRun], text: NSString, into edits: inout Edits) {
        struct Row {
            var line: Line
            var terminators: [Int]
            var offsets: [CGFloat]
            /// Where each closing pipe ends.
            var pipeEnds: [CGFloat]
            /// Where the text of the second cell starts (nil: the row has no second cell with text).
            var secondCell: CGFloat?
            var width: CGFloat
            var indent: CGFloat
            var paragraph: NSParagraphStyle?
        }
        var rows: [Row] = []
        rows.reserveCapacity(table.count)
        var runIndex = 0
        var styledIndex = 0
        for line in table {
            let length = line.end - line.start
            guard length > 0 else { continue }
            let content = text.substring(with: NSRange(location: line.start, length: length)) as NSString
            if content.range(of: "\t").location != NSNotFound { return }
            // the pipes that separate cells (the lexer's delimiters; an escaped `\|` is not one); the first is an opening pipe when no cell text is before it
            while runIndex < lexRuns.count && NSMaxRange(lexRuns[runIndex].range) <= line.start { runIndex += 1 }
            var separators: [Int] = []
            var sawCellText = false, leading = -1
            var j = runIndex
            while j < lexRuns.count && lexRuns[j].range.location < line.end {
                let run = lexRuns[j]
                let a = max(run.range.location, line.start), b = min(NSMaxRange(run.range), line.end)
                if run.style.contains(.table) {
                    for p in a..<b {
                        let c = text.character(at: p)
                        if c == 0x7C && run.style.contains(.tableDelimiter) {
                            if !sawCellText && separators.isEmpty && leading < 0 { leading = p } else { separators.append(p) }
                        } else if c != 0x20 {
                            sawCellText = true
                        }
                    }
                }
                j += 1
            }
            // measure the line in the fonts it has (the styled runs), with AppKit's font fallback for what those fonts cannot show
            let measured = NSMutableAttributedString(string: content as String)
            while styledIndex < styled.count && NSMaxRange(styled[styledIndex].range) <= line.start { styledIndex += 1 }
            var indent: CGFloat = 0
            var paragraph: NSParagraphStyle?
            var s = styledIndex
            var nonASCII = false
            while s < styled.count && styled[s].range.location < line.end {
                let r = NSIntersectionRange(styled[s].range, NSRange(location: line.start, length: length))
                if r.length > 0, let font = styled[s].attributes[.font] {
                    measured.addAttribute(.font, value: font, range: NSRange(location: r.location - line.start, length: r.length))
                }
                if s == styledIndex, let p = styled[s].attributes[.paragraphStyle] as? NSParagraphStyle { indent = p.firstLineHeadIndent; paragraph = p }
                s += 1
            }
            for k in 0..<length where content.character(at: k) > 0x7F { nonASCII = true; break }
            let all = NSRange(location: 0, length: length)
            if nonASCII { measured.fixFontAttribute(in: all) }
            measured.addAttribute(.paragraphStyle, value: TableAligner.leftToRight, range: all)
            let ctLine = CTLineCreateWithAttributedString(measured as CFAttributedString)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let offsets = separators.map { CTLineGetOffsetForStringIndex(ctLine, $0 - line.start, nil) }
            let pipeEnds = separators.map { CTLineGetOffsetForStringIndex(ctLine, $0 + 1 - line.start, nil) }
            var secondCell: CGFloat?
            if let first = separators.first {
                var k = first + 1 - line.start
                while k < length && content.character(at: k) == 0x20 { k += 1 }
                if k < length && !(separators.count > 1 && k == separators[1] - line.start) {
                    secondCell = CTLineGetOffsetForStringIndex(ctLine, k, nil)
                }
            }
            rows.append(Row(line: line, terminators: separators, offsets: offsets, pipeEnds: pipeEnds, secondCell: secondCell, width: width,
                            indent: indent, paragraph: paragraph))
        }
        let columns = rows.map(\.terminators.count).max() ?? 0
        guard columns > 0 else { return }
        // where each closing pipe goes: as far right as the widest cell of its column needs (cell widths are differences of pipe positions, so the
        // indent and any quote or list prefix of a line are part of its first cell)
        var x = [CGFloat](repeating: 0, count: columns)
        for k in 0..<columns {
            var best: CGFloat = 0
            for row in rows where row.offsets.count > k {
                let cell = row.offsets[k] - (k > 0 ? row.offsets[k - 1] : 0)
                best = max(best, (k > 0 ? x[k - 1] : 0) + cell)
            }
            x[k] = best
        }
        // where each closing pipe ends once aligned, in the row that reaches furthest (its indent included): the column fits up to there
        var edge = [CGFloat](repeating: 0, count: columns)
        var widest: CGFloat = 0
        for row in rows {
            for k in row.offsets.indices { edge[k] = max(edge[k], row.indent + x[k] + row.pipeEnds[k] - row.offsets[k]) }
            let shift = row.offsets.isEmpty ? 0 : x[row.offsets.count - 1] - row.offsets[row.offsets.count - 1]
            widest = max(widest, row.indent + row.width + shift)
        }
        remember(widest)
        edge.forEach(remember)
        let limit = widthLimit + 0.01
        let fits = widest <= limit
        // the columns that are aligned: all of them, or (the rows wrap) the leading ones whose pipes stay on the first line of every row
        let aligned = fits ? columns : (edge.firstIndex { $0 > limit } ?? columns)
        for row in rows {
            var before: CGFloat = 0
            for (k, p) in row.terminators.enumerated() where k < aligned {
                let shift = x[k] - row.offsets[k]
                let kern = ((shift - before) * 100).rounded() / 100
                before = shift
                guard kern >= 0.01 else { continue }
                edits.kerns.append((text.rangeOfComposedCharacterSequence(at: p - 1), NSNumber(value: Double(kern))))
            }
        }
        // the rows of a table that does not fit hang from their second cell (when the first column is aligned, so the second starts at one place)
        guard !fits, aligned > 0 else { return }
        var hangs: [(row: Row, half: Int)] = []
        var widestHang: CGFloat = 0
        for row in rows {
            guard let second = row.secondCell, let base = row.paragraph else { continue }
            let hang = row.indent + second + x[0] - row.offsets[0]
            widestHang = max(widestHang, hang)
            let half = Int((hang * 2).rounded())
            if CGFloat(half) / 2 > base.headIndent + 0.25 { hangs.append((row, half)) }
        }
        remember(widestHang * 2)
        guard widestHang <= widthLimit / 2 else { return }
        for (row, half) in hangs {
            edits.paragraphs.append((NSRange(location: row.line.start, length: row.line.next - row.line.start), hangStyle(row.paragraph!, half: half)))
        }
    }

    private static let leftToRight: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = .leftToRight
        return p
    }()

    /// The runs with `key` set on the given ranges (sorted, not overlapping): a run is split where a range starts or ends.
    static func apply(_ kerns: [(range: NSRange, value: Any)], key: NSAttributedString.Key, to styled: [StyledRun]) -> [StyledRun] {
        var out: [StyledRun] = []
        out.reserveCapacity(styled.count + kerns.count * 2)
        var ki = 0
        for run in styled {
            var pos = run.range.location
            let end = NSMaxRange(run.range)
            while ki < kerns.count && NSMaxRange(kerns[ki].range) <= pos { ki += 1 }
            var j = ki
            while pos < end {
                guard j < kerns.count, kerns[j].range.location < end else {
                    out.append(StyledRun(range: NSRange(location: pos, length: end - pos), attributes: run.attributes))
                    break
                }
                let ks = max(kerns[j].range.location, pos), ke = min(NSMaxRange(kerns[j].range), end)
                if ks > pos { out.append(StyledRun(range: NSRange(location: pos, length: ks - pos), attributes: run.attributes)) }
                var a = run.attributes
                a[key] = kerns[j].value
                out.append(StyledRun(range: NSRange(location: ks, length: ke - ks), attributes: a))
                pos = ke
                if NSMaxRange(kerns[j].range) <= end { j += 1 }
            }
        }
        return out
    }
}

// MARK: - the extent of a table

/// Finding where a table that a region only partly covers begins and ends, by asking the lexer about the lines above / below (it resumes from its
/// checkpoints, so this is cheap). Bounded by `TableAligner.maxTableUnits`: a bigger table is not aligned anyway.
enum TableExtent {
    /// Start of the table whose row starts at `lineStart` (not a header line): the header line above. nil: not found within the bound.
    static func start(above lineStart: Int, text: NSString, limit: Int = TableAligner.maxTableUnits, lex: (NSRange) -> MDResult) -> Int? {
        var s = lineStart
        let floor = max(0, lineStart - limit - 4096)
        while s > 0 {
            if s < floor { return nil }
            let probe = text.lineRange(for: NSRange(location: max(0, s - 2048), length: 0)).location
            let r = lex(NSRange(location: probe, length: s - probe))
            guard r.range.location <= probe else { return nil }
            let lines = TableAligner.lines(r.runs, text: text, in: NSRange(location: r.range.location, length: s - r.range.location))
            for line in lines.reversed() {
                if !line.isTable { return line.next }
                if line.isHeader { return line.start }
            }
            s = r.range.location
        }
        return 0
    }

    /// End (the start of the first line after it) of the table that goes on at `lineStart`. nil: not found within the bound.
    static func end(below lineStart: Int, text: NSString, limit: Int = TableAligner.maxTableUnits, lex: (NSRange) -> MDResult) -> Int? {
        var e = lineStart
        let ceiling = min(text.length, lineStart + limit + 4096)
        while e < text.length {
            if e > ceiling { return nil }
            let probeEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(text.length - 1, e + 2048), length: 0)))
            let r = lex(NSRange(location: e, length: probeEnd - e))
            guard r.range.location <= e, NSMaxRange(r.range) > e else { return nil }
            let lines = TableAligner.lines(r.runs, text: text, in: r.range)
            for line in lines where line.start >= e {
                if !line.isTable || line.isHeader { return line.start }
            }
            e = NSMaxRange(r.range)
        }
        return text.length
    }
}

// MARK: - Format > Align Table

/// Format > Align Table: rewrites the table at the caret with spaces, so that it is aligned in the file itself (in a diff, in another editor, for
/// an agent that reads the file): `| cell | cell |`, every cell padded to its column's width (counted in characters, East Asian wide characters
/// and emoji as two), the delimiter row as dashes of the same width with the column's colons kept. A right-aligned column (`---:`) is padded on
/// the left, a centred one (`:---:`) on both sides. Rows keep their indent or quote prefix; a row with fewer cells than the header gets empty ones,
/// cells beyond the header's are kept. Escaped pipes and the content of every cell stay as they are.
enum TableFormatter {
    /// The edit that aligns the table whose lines are `lines` (header, delimiter row, body rows), lexed as `runs`. nil: nothing to change.
    /// `caret`: where the caret is; the result keeps it in the same cell, at the same place in the cell's text.
    static func change(text: NSString, runs: [MDRun], lines: [TableAligner.Line], caret: Int) -> TextChange? {
        guard lines.count >= 2, lines[0].isHeader else { return nil }
        struct Row { var prefix: String; var cells: [String]; var cellStarts: [Int]; var cellEnds: [Int]; var line: TableAligner.Line }
        var rows: [Row] = []
        var ri = 0
        for line in lines {
            while ri < runs.count && NSMaxRange(runs[ri].range) <= line.start { ri += 1 }
            // where the table text starts (after an indent or a quote prefix), and the separating pipes
            var contentStart = line.end
            var separators: [Int] = []
            var j = ri
            while j < runs.count && runs[j].range.location < line.end {
                let run = runs[j]
                if run.style.contains(.table) {
                    let a = max(run.range.location, line.start), b = min(NSMaxRange(run.range), line.end)
                    for p in a..<b {
                        let c = text.character(at: p)
                        if contentStart == line.end && c != 0x20 && c != 0x09 { contentStart = p }
                        if c == 0x7C && run.style.contains(.tableDelimiter) { separators.append(p) }
                    }
                }
                j += 1
            }
            if contentStart == line.end { contentStart = line.start }
            var prefixEnd = contentStart
            while prefixEnd > line.start, text.character(at: prefixEnd - 1) == 0x20 || text.character(at: prefixEnd - 1) == 0x09 { prefixEnd -= 1 }
            var prefix = text.substring(with: NSRange(location: line.start, length: prefixEnd - line.start))
            if prefix.hasSuffix(">") { prefix += " " }
            // cells: what lies between the pipes; the opening pipe opens no cell, text after the last pipe is a cell only if it is not blank
            var bounds: [(Int, Int)] = []
            var from = contentStart
            for (n, p) in separators.enumerated() {
                if n == 0 && p == contentStart { from = p + 1; continue }
                bounds.append((from, p))
                from = p + 1
            }
            if from < line.end {
                let rest = text.substring(with: NSRange(location: from, length: line.end - from))
                if !rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).isEmpty || bounds.isEmpty { bounds.append((from, line.end)) }
            }
            var cells: [String] = [], starts: [Int] = [], ends: [Int] = []
            for (a0, b0) in bounds {
                var a = a0, b = b0
                while a < b, text.character(at: a) == 0x20 || text.character(at: a) == 0x09 { a += 1 }
                while b > a, text.character(at: b - 1) == 0x20 || text.character(at: b - 1) == 0x09 { b -= 1 }
                cells.append(text.substring(with: NSRange(location: a, length: b - a)))
                starts.append(a); ends.append(b)
            }
            rows.append(Row(prefix: prefix, cells: cells, cellStarts: starts, cellEnds: ends, line: line))
        }
        let columns = rows[0].cells.count
        guard columns > 0 else { return nil }
        // the columns' alignment, from the delimiter row
        enum Align { case none, left, right, center }
        let aligns: [Align] = (0..<columns).map { k in
            guard k < rows[1].cells.count else { return .none }
            let c = rows[1].cells[k]
            switch (c.hasPrefix(":"), c.hasSuffix(":") && c.count > 1) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        for n in rows.indices where n != 1 && rows[n].cells.count < columns {
            let missing = columns - rows[n].cells.count
            rows[n].cells += Array(repeating: "", count: missing)
            rows[n].cellStarts += Array(repeating: Int.max, count: missing)          // (not in the text: the caret is never in one)
            rows[n].cellEnds += Array(repeating: Int.max, count: missing)
        }
        let allColumns = rows.map(\.cells.count).max() ?? columns
        var widths = [Int](repeating: 0, count: allColumns)
        for (n, row) in rows.enumerated() where n != 1 {
            for (k, c) in row.cells.enumerated() { widths[k] = max(widths[k], displayWidth(c)) }
        }
        for k in 0..<columns { widths[k] = max(widths[k], 3) }
        // the caret's cell (from just after the text of the cell before it) and its place in the cell's text
        let caretRow = rows.firstIndex { caret >= $0.line.start && caret <= $0.line.end }
        var caretCell = -1, caretOffset = 0
        if let cr = caretRow {
            let r = rows[cr]
            for k in r.cells.indices where r.cellStarts[k] != Int.max && (k == 0 || caret > r.cellEnds[k - 1]) { caretCell = k }
            if caretCell >= 0 { caretOffset = max(0, min(caret - r.cellStarts[caretCell], r.cellEnds[caretCell] - r.cellStarts[caretCell])) }
        }
        var newCaret = caret
        var out = ""
        var outLength = 0                                      // UTF-16 length of `out`
        for (n, row) in rows.enumerated() {
            var line = row.prefix + "|"
            for (k, cell) in row.cells.enumerated() {
                let w = widths[k]
                var body: String
                var lead = 0
                if n == 1 {
                    let a = k < columns ? aligns[k] : .none
                    switch a {
                    case .none: body = String(repeating: "-", count: w)
                    case .left: body = ":" + String(repeating: "-", count: w - 1)
                    case .right: body = String(repeating: "-", count: w - 1) + ":"
                    case .center: body = ":" + String(repeating: "-", count: w - 2) + ":"
                    }
                } else {
                    let pad = w - displayWidth(cell)
                    switch k < columns ? aligns[k] : .none {
                    case .right: lead = pad
                    case .center: lead = pad / 2
                    default: lead = 0
                    }
                    body = String(repeating: " ", count: lead) + cell + String(repeating: " ", count: pad - lead)
                }
                if n == caretRow && k == caretCell {
                    newCaret = rows[0].line.start + outLength + (line as NSString).length + 1 + lead + min(caretOffset, (body as NSString).length - lead)
                }
                line += " " + body + " |"
            }
            out += line
            outLength += (line as NSString).length
            if n < rows.count - 1 {
                let br = text.substring(with: NSRange(location: row.line.end, length: row.line.next - row.line.end))
                out += br
                outLength += (br as NSString).length
            }
        }
        let range = NSRange(location: rows[0].line.start, length: rows[rows.count - 1].line.end - rows[0].line.start)
        guard text.substring(with: range) != out else { return nil }
        return TextChange(range: range, replacement: out, selection: NSRange(location: newCaret, length: 0))
    }

    /// Columns a cell takes in a monospaced font: East Asian wide characters and emoji take two, everything else one (a cluster of combining marks is
    /// one character).
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s { w += isWide(ch) ? 2 : 1 }
        return w
    }

    static func isWide(_ ch: Character) -> Bool {
        guard let first = ch.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        if ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) && first.properties.isEmoji { return true }
        let v = first.value
        return (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) || (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
    }
}
