import AppKit
import MarkdownKit

/// The glue between MarkdownKit (lexer: text -> MDRun) and the text view (LazyStyler: StyledRun -> attributes):
///
///   LazyStyler.runs             -> MarkdownStyler.styleRuns(in:of:)                       -> Theme.styledRuns
///   LazyStyler.restyleAfterEdit -> MarkdownStyler.update(afterEdit:changeInLength:of:maxRegion:) -> Theme.styledRuns
///   LazyStyler.onTextReplaced   -> MarkdownStyler.reset()
///
/// Tables are aligned on screen (TableAlignment.swift): a region that holds part of a table is widened to the whole table first, because the
/// width of a column depends on every row.
///
/// The lexer reads the text straight from the NSTextStorage string (bulk `getCharacters`, no copy). Main thread only.
/// `update` MUST be called from inside `textStorage(_:didProcessEditing:range:changeInLength:)` with exactly the values AppKit
/// passes there (they read {NSNotFound, 0} once the edit cycle is over): LazyStyler does that.
final class MarkdownRunProvider {
    let styler = MarkdownStyler()
    var theme: Theme
    /// Aligns the tables (on screen only); its `widthLimit` is the text container's width (EditorViewController).
    let tables = TableAligner()
    private weak var storage: NSTextStorage?

    /// Bound for the re-lex after one edit (UTF-16 units): typing an opening fence near the top of a huge document would
    /// otherwise restyle everything below it. The rest is reported as `staleFrom` and restyled lazily.
    var maxEditRegion = 60_000

    init(storage: NSTextStorage, theme: Theme) {
        self.storage = storage
        self.theme = theme
    }

    func reset() { styler.reset() }

    /// Runs for a line-aligned range. NOT clipped: MarkdownKit returns the whole block(s) around the range and the invariant
    /// "incremental == fresh lex" holds for the whole returned region, so the whole region is what gets applied.
    func runs(in range: NSRange) -> LazyStyler.RunResult {
        guard let ts = storage else { return LazyStyler.RunResult(region: NSRange(location: 0, length: 0), runs: []) }
        let text = ts.string as NSString
        let result = wholeTables(styler.styleRuns(in: range, of: text), text: text)
        return LazyStyler.RunResult(region: result.lex.range, runs: styledRuns(result, text: text))
    }

    func update(afterEdit edited: NSRange, delta: Int) -> LazyStyler.EditResult {
        guard let ts = storage else { return LazyStyler.EditResult(region: NSRange(location: 0, length: 0), runs: [], staleFrom: nil) }
        let text = ts.string as NSString
        let result = wholeTables(styler.update(afterEdit: edited, changeInLength: delta, of: text, maxRegion: maxEditRegion), text: text)
        return LazyStyler.EditResult(region: result.lex.range, runs: styledRuns(result, text: text), staleFrom: result.lex.staleFrom)
    }

    /// A lexer result, widened to the whole tables at its two ends where possible.
    struct TableRegion {
        var lex: MDResult
        /// The first / last table of the region goes on beyond it (too big, or its end was not found): it is not aligned.
        var cutAtStart = false
        var cutAtEnd = false
    }

    private func styledRuns(_ r: TableRegion, text: NSString) -> [StyledRun] {
        let styled = theme.styledRuns(r.lex.runs, text: text)
        return tables.align(styled, lexRuns: r.lex.runs, text: text, region: r.lex.range, cutAtStart: r.cutAtStart, cutAtEnd: r.cutAtEnd)
    }

    /// When the first line of `r` is a table row below the header, or the line after `r` goes on with its last table, lex the region again from the
    /// table's header to the table's end (the lexer resumes from a checkpoint; the runs are those of a fresh lex, so they may replace the first ones).
    func wholeTables(_ r: MDResult, text: NSString) -> TableRegion {
        guard r.range.length > 0, r.runs.contains(where: { $0.style.contains(.table) }) else { return TableRegion(lex: r) }
        let lines = TableAligner.lines(r.runs, text: text, in: r.range)
        guard let first = lines.first, let last = lines.last else { return TableRegion(lex: r) }
        let lex: (NSRange) -> MDResult = { [styler] in styler.styleRuns(in: $0, of: text) }
        var out = TableRegion(lex: r)
        var start = r.range.location, end = NSMaxRange(r.range)
        if first.isTable && !first.isHeader {
            if let s = TableExtent.start(above: first.start, text: text, lex: lex) { start = s } else { out.cutAtStart = true }
        }
        if last.isTable && last.next < text.length && last.next == end {
            if let e = TableExtent.end(below: end, text: text, lex: lex) { end = e } else { out.cutAtEnd = true }
        }
        guard start < r.range.location || end > NSMaxRange(r.range) else { return out }
        var wide = styler.styleRuns(in: NSRange(location: start, length: end - start), of: text)
        guard wide.range.location <= r.range.location, NSMaxRange(wide.range) >= NSMaxRange(r.range) else {
            return TableRegion(lex: r, cutAtStart: true, cutAtEnd: true)
        }
        wide.staleFrom = r.staleFrom
        out.lex = wide
        // the widened region can itself end inside a table again only if the lexer stopped early: then that table is cut
        if let l = TableAligner.lines(wide.runs, text: text, in: wide.range).last, l.isTable, l.next < text.length, out.cutAtEnd == false,
           let e2 = TableExtent.end(below: l.next, text: text, lex: lex), e2 > l.next {
            out.cutAtEnd = true
        }
        return out
    }

    /// Wire a LazyStyler to this provider.
    func attach(to lazy: LazyStyler) {
        lazy.runs = { [weak self] range in self?.runs(in: range) ?? LazyStyler.RunResult(region: NSRange(location: 0, length: 0), runs: []) }
        lazy.restyleAfterEdit = { [weak self] edited, delta in
            self?.update(afterEdit: edited, delta: delta) ?? LazyStyler.EditResult(region: NSRange(location: 0, length: 0), runs: [], staleFrom: nil)
        }
        lazy.onTextReplaced = { [weak self] in self?.reset() }
    }
}
