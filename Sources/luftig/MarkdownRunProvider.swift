import AppKit
import MarkdownKit

/// The glue between MarkdownKit (lexer: text -> MDRun) and the text view (LazyStyler: StyledRun -> attributes):
///
///   LazyStyler.runs             -> MarkdownStyler.styleRuns(in:of:)                       -> Theme.styledRuns
///   LazyStyler.restyleAfterEdit -> MarkdownStyler.update(afterEdit:changeInLength:of:maxRegion:) -> Theme.styledRuns
///   LazyStyler.onTextReplaced   -> MarkdownStyler.reset()
///
/// The lexer reads the text straight from the NSTextStorage string (bulk `getCharacters`, no copy). Main thread only.
/// `update` MUST be called from inside `textStorage(_:didProcessEditing:range:changeInLength:)` with exactly the values AppKit
/// passes there (they read {NSNotFound, 0} once the edit cycle is over): LazyStyler does that.
final class MarkdownRunProvider {
    let styler = MarkdownStyler()
    var theme: Theme
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
        let result = styler.styleRuns(in: range, of: text)
        return LazyStyler.RunResult(region: result.range, runs: theme.styledRuns(result.runs, text: text))
    }

    func update(afterEdit edited: NSRange, delta: Int) -> LazyStyler.EditResult {
        guard let ts = storage else { return LazyStyler.EditResult(region: NSRange(location: 0, length: 0), runs: [], staleFrom: nil) }
        let text = ts.string as NSString
        let result = styler.update(afterEdit: edited, changeInLength: delta, of: text, maxRegion: maxEditRegion)
        return LazyStyler.EditResult(region: result.range, runs: theme.styledRuns(result.runs, text: text), staleFrom: result.staleFrom)
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
