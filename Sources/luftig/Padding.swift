import AppKit

/// Every bit of air in the editor, from ONE number: the padding in points (Settings > Layout > Padding, `EditorPreferences.padding`, 0 ... 50). The same
/// value is every gap: between the window's edge and the panels on all four sides, between the outline and the text, between the word count row and the
/// outline / text below it, between the syntax bar and the text above it, and between the text and the edges of its own panel. At 0 everything touches;
/// at 50 the editor floats. The panels themselves are their content: the word count row is its line, the bar is its symbols. Structural sizes - the
/// outline's width, the indent per heading level, the font sizes, the gaps between the bar's symbols, the outline's row height (a slider of its own) -
/// are not padding and do not move.
struct Padding: Equatable {
    let points: CGFloat

    init(points: CGFloat) { self.points = max(0, points.rounded()) }
    static let standard = Padding(points: EditorPreferences.defaultPadding)

    #if LUFTIG_SELFTEST
    /// Self-test only: a scenario about the system's chrome wants the text view at the window's edge (no frame, no viewport margin).
    nonisolated(unsafe) static var windowOverride: CGFloat?
    #endif
    private var gap: CGFloat {
        #if LUFTIG_SELFTEST
        if let o = Padding.windowOverride { return o }
        #endif
        return points
    }

    /// The frame between the window's edge and the panels on the left and the right (EditorViewController.windowPaddingConstraints).
    var window: CGFloat { gap }
    /// The frame at the top and the bottom: half the padding (the vertical gaps read larger than the horizontal ones; measured by eye, Settings > Layout).
    var windowVertical: CGFloat { (gap / 2).rounded() }
    /// Above and below the text viewport and the outline alike: a margin outside the scrolling (verticalInsetConstraints), so that scrolled text starts
    /// exactly where the outline's first entry starts; the text container has no vertical inset of its own. Also the gap between the text viewport and
    /// the syntax bar below it and the word count row above it. Half the padding, like the frame's top and bottom.
    var textInsetVertical: CGFloat { (gap / 2).rounded() }
    /// Between the text and the sides of its panel: on the left that is the gap to the outline (`ReadableColumnController.minInset`). (Not part of the
    /// self-test's flush override: a scenario about the window's chrome keeps the bands away from the window's corners.)
    var textInsetHorizontal: CGFloat { points }
    /// The word count row is its line (the outline's entries and the row's text start at the window frame: no gaps of their own).
    static let wordCountContentHeight: CGFloat = 16
    var wordCountHeight: CGFloat { Padding.wordCountContentHeight }
    /// The syntax bar is its symbols; the gaps between them are fixed (SyntaxBarView.gapInGroup / gapBetweenGroups).
    static let barContentHeight: CGFloat = 18
    var barHeight: CGFloat { Padding.barContentHeight }
}
