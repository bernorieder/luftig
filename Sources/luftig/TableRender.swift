import AppKit
import MarkdownKit

// Tables drawn as a grid while the caret is elsewhere (View > Tables as Grids, EditorPreferences.renderTables).
//
// The text of the table stays in the text storage exactly as it is; only how it is laid out and drawn changes, and only while no selection touches
// the table (TableAligner.revealed: clicking into it, an arrow key, Find or Select All show the Markdown again, aligned as before).
//
//   * Every source row stays ONE paragraph (invariant 8). Its characters carry `.luftigTableRow` (a TableRenderRow): LuftigLayoutManager gives them
//     no glyphs (`.null`), so they take no room, and the row's paragraph style has the height of the drawn row (min = max line height). The
//     delimiter row becomes a thin line under the header.
//   * The drawn row (grid lines, cell text in the text font, wrapped inside its column, with its bold / italic / code / links, the Markdown markers
//     left out) is painted with the other decorations, from the text view's drawBackground (LuftigLayoutManager.drawDecorations).
//   * The column widths come from the cells' widths in one line; a table wider than the text column is squeezed like a browser lays out a table: every
//     column keeps at least its longest word (or less, when even those do not fit), the rest of the room goes to the columns in proportion to what
//     they would need more. A row is as tall as its tallest cell.
//   * Like the alignment, the result is a pure function of the text, the theme, the column width and the selection, so an incremental restyle equals a
//     fresh one (the oracle of the self-tests renders with the editor's limit and selection).
//   * Not drawn (shown as aligned Markdown): tables in quotes (their `>` prefixes are part of every row), tables over the size bound or cut by the
//     region, and a table the selection touches.

extension NSAttributedString.Key {
    /// On every character of a row of a table drawn as a grid (its line break included): the TableRenderRow to draw. Its glyphs are hidden.
    static let luftigTableRow = NSAttributedString.Key("luftig.tableRow")
}

/// One drawn row of a table. Equal when everything that is drawn is equal (the attribute values are compared by the self-tests' oracle).
final class TableRenderRow: NSObject {
    enum Kind: Int { case header, delimiter, body }
    let kind: Kind
    let isLast: Bool
    /// The left edge of every column and the right edge of the last one, from the table's left edge.
    let edges: [CGFloat]
    /// The text drawn in each cell (none for the delimiter row).
    let cells: [NSAttributedString]
    /// The height of each cell's text, wrapped to its column.
    let cellHeights: [CGFloat]
    /// Where the text of each cell ends in the row's line (UTF-16 offset from the line's start): a click into a cell puts the caret there.
    let cellEnds: [Int]
    let height: CGFloat

    init(kind: Kind, isLast: Bool, edges: [CGFloat], cells: [NSAttributedString], cellHeights: [CGFloat], cellEnds: [Int], height: CGFloat) {
        self.kind = kind; self.isLast = isLast; self.edges = edges; self.cells = cells; self.cellHeights = cellHeights; self.cellEnds = cellEnds
        self.height = height
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TableRenderRow else { return false }
        return kind == o.kind && isLast == o.isLast && edges == o.edges && cells == o.cells && cellHeights == o.cellHeights && cellEnds == o.cellEnds
            && height == o.height
    }
    override var hash: Int { var h = Hasher(); h.combine(kind); h.combine(edges); h.combine(height); h.combine(cellEnds); return h.finalize() }
    override var description: String { "row(\(kind), h \(height), cells \(cells.map { $0.string }))" }
}

enum TableRenderer {
    /// Room left and right of the text in a cell.
    static let padX: CGFloat = 9
    /// The height of the delimiter row: the line under the header.
    static let delimiterHeight: CGFloat = 2

    /// The drawn rows of a table (header, delimiter row, body rows: one per line of `table`), or nil when it cannot be drawn.
    /// `available`: the width the table may take.
    static func rows(_ table: ArraySlice<TableAligner.Line>, lexRuns: [MDRun], text: NSString, theme: Theme, available: CGFloat) -> [TableRenderRow]? {
        let lines = Array(table)
        guard lines.count >= 2, lines[0].isHeader else { return nil }
        // the cells of every line: (start, end) of the trimmed text between the pipes
        var cellRanges: [[(Int, Int)]] = []
        var ri = 0
        for line in lines {
            while ri < lexRuns.count && NSMaxRange(lexRuns[ri].range) <= line.start { ri += 1 }
            var contentStart = line.end
            var separators: [Int] = []
            var j = ri
            while j < lexRuns.count && lexRuns[j].range.location < line.end {
                let run = lexRuns[j]
                if run.style.quoteDepth > 0 { return nil }                      // (a table in a quote: not drawn)
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
            cellRanges.append(bounds.map { (a0, b0) in
                var a = a0, b = b0
                while a < b, text.character(at: a) == 0x20 || text.character(at: a) == 0x09 { a += 1 }
                while b > a, text.character(at: b - 1) == 0x20 || text.character(at: b - 1) == 0x09 { b -= 1 }
                return (a, b)
            })
        }
        let columns = cellRanges[0].count
        guard columns > 0 else { return nil }
        // the columns' alignment, from the delimiter row
        let aligns: [NSTextAlignment] = (0..<columns).map { k in
            guard k < cellRanges[1].count else { return .left }
            let (a, b) = cellRanges[1][k]
            guard b > a else { return .left }
            let left = text.character(at: a) == 0x3A, right = text.character(at: b - 1) == 0x3A && b - a > 1
            return left && right ? .center : (right ? .right : .left)
        }
        // the text of the cells, in the text font
        let lineHeight = cellLineHeight(theme)
        var cells: [[NSAttributedString]] = []
        for (n, row) in cellRanges.enumerated() {
            if n == 1 { cells.append([]); continue }
            cells.append((0..<columns).map { k in
                k < row.count ? cellText(row[k], header: n == 0, align: aligns[k], lineHeight: lineHeight, lexRuns: lexRuns, text: text, theme: theme)
                              : NSAttributedString()
            })
        }
        // column widths: what one line of each cell needs, squeezed into `available`
        var natural = [CGFloat](repeating: 0, count: columns)
        for row in cells {
            for (k, c) in row.enumerated() where c.length > 0 { natural[k] = max(natural[k], ceil(width(of: c))) }
        }
        var widths = (0..<columns).map { natural[$0] + 2 * padX }
        if widths.reduce(0, +) > available {
            // a column that fits in an equal share keeps its width; the others share the rest: each keeps its longest word, the room beyond that goes
            // to them in proportion to what they would need more
            let share = available / CGFloat(columns)
            let fixed = (0..<columns).filter { widths[$0] <= share }
            let free = (0..<columns).filter { widths[$0] > share }
            let room = available - fixed.reduce(0) { $0 + widths[$1] }
            // the longest word of a squeezed column (measured only for those: a word at a time is the costly part)
            let mins = free.map { k in min(natural[k], cells.reduce(0) { k < $1.count && $1[k].length > 0 ? max($0, ceil(longestWord(in: $1[k]))) : $0 }) + 2 * padX }
            let minTotal = mins.reduce(0, +)
            if minTotal >= room {
                for (n, k) in free.enumerated() { widths[k] = floor(mins[n] * room / minTotal) }
            } else {
                let want = zip(free, mins).reduce(0) { $0 + widths[$1.0] - $1.1 }
                for (n, k) in free.enumerated() { widths[k] = floor(mins[n] + (widths[k] - mins[n]) * (room - minTotal) / max(1, want)) }
            }
        }
        var edges: [CGFloat] = [0]
        for w in widths { edges.append(edges.last! + w) }
        // the rows: as tall as the tallest cell, at least one line of text
        let padY = max(3, floor((theme.bodyLineHeight - lineHeight) / 2))
        var out: [TableRenderRow] = []
        for (n, line) in lines.enumerated() {
            let isLast = n == lines.count - 1
            let ends = cellRanges[n].map { $0.1 - line.start }
            if n == 1 {
                out.append(TableRenderRow(kind: .delimiter, isLast: isLast, edges: edges, cells: [], cellHeights: [], cellEnds: ends, height: delimiterHeight))
                continue
            }
            var heights: [CGFloat] = []
            for (k, c) in cells[n].enumerated() {
                let w = max(1, widths[k] - 2 * padX)
                heights.append(c.length == 0 ? lineHeight : ceil(c.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height))
            }
            let h = max(theme.bodyLineHeight, (heights.max() ?? lineHeight) + 2 * padY)
            out.append(TableRenderRow(kind: n == 0 ? .header : .body, isLast: isLast, edges: edges, cells: cells[n], cellHeights: heights, cellEnds: ends, height: h))
        }
        return out
    }

    /// The line height inside a cell: tighter than the text's own (a wrapped cell is one block of text, not separate lines).
    static func cellLineHeight(_ theme: Theme) -> CGFloat { (theme.baseSize * 1.35).rounded() }

    /// The cell's text with the styles it has, without the table's own styling and without the Markdown markers (`**`, backticks, the brackets and the
    /// address of a link, the backslash of an escape).
    private static func cellText(_ range: (Int, Int), header: Bool, align: NSTextAlignment, lineHeight: CGFloat, lexRuns: [MDRun], text: NSString,
                                 theme: Theme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard range.1 > range.0 else { return out }
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        para.baseWritingDirection = .natural
        var i = lexRuns.firstIndex { NSMaxRange($0.range) > range.0 } ?? lexRuns.count
        while i < lexRuns.count && lexRuns[i].range.location < range.1 {
            let run = lexRuns[i]
            i += 1
            let s = run.style
            if s.contains(.marker) || s.contains(.linkDestination) || s.contains(.tableDelimiter) { continue }
            let a = max(run.range.location, range.0), b = min(NSMaxRange(run.range), range.1)
            guard b > a else { continue }
            var piece = text.substring(with: NSRange(location: a, length: b - a))
            if s.contains(.escape), piece.hasPrefix("\\") { piece.removeFirst() }
            if piece.isEmpty { continue }
            var style = s.subtracting([.table, .tableHeader, .tableDelimiter])
            if header { style.insert(.bold) }
            var attrs = theme.attributes(for: style)
            for key in [NSAttributedString.Key.luftigPanel, .luftigBlock, .luftigInline, .kern] { attrs[key] = nil }
            attrs[.paragraphStyle] = para
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    private static func width(of s: NSAttributedString) -> CGFloat {
        s.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).width
    }

    private static func longestWord(in s: NSAttributedString) -> CGFloat {
        let ns = s.string as NSString
        var widest: CGFloat = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, r, _, _ in
            widest = max(widest, width(of: s.attributedSubstring(from: r)))
        }
        return widest
    }

    // MARK: drawing

    /// Draws one row whose line fragment is `rect` (view coordinates); the table starts at `left`.
    static func draw(_ row: TableRenderRow, rect: CGRect, left: CGFloat, ctx: CGContext, line: CGColor, strong: CGColor, scale: CGFloat) {
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let hair = 1 / scale
        let right = left + (row.edges.last ?? 0)
        ctx.saveGState()
        // the lines between the columns
        ctx.setFillColor(line)
        for e in row.edges.dropFirst().dropLast() {
            ctx.fill(CGRect(x: snap(left + e), y: snap(rect.minY), width: hair, height: snap(rect.maxY) - snap(rect.minY)))
        }
        switch row.kind {
        case .delimiter:
            ctx.setFillColor(strong)
            ctx.fill(CGRect(x: snap(left), y: snap(rect.midY) - hair, width: snap(right) - snap(left), height: 2 * hair))
        case .body where !row.isLast:
            ctx.fill(CGRect(x: snap(left), y: snap(rect.maxY) - hair, width: snap(right) - snap(left), height: hair))
        default: break
        }
        ctx.restoreGState()
        // the text, in the middle of the row
        for (k, cell) in row.cells.enumerated() where cell.length > 0 && k + 1 < row.edges.count {
            let x = left + row.edges[k] + padX, w = row.edges[k + 1] - row.edges[k] - 2 * padX
            let h = row.cellHeights[k]
            let y = rect.minY + max(0, (rect.height - h) / 2)
            cell.draw(with: CGRect(x: x, y: y, width: max(1, w), height: h + 1), options: [.usesLineFragmentOrigin])
        }
    }
}
