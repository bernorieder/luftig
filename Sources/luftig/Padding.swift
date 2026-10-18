import AppKit

/// Every bit of air in the editor, from ONE factor (Settings > Layout > Padding, `EditorPreferences.padding`, 0 ... 2), in two layers: the WINDOW
/// padding - the frame between the window's edge and the panels, on all four sides - and the padding INSIDE each panel (the text's insets, the
/// outline's margins, the air of the word count's row and the syntax bar). At 1 the panel values are the ones luftig always had and the window frame
/// is 12 pt; at 0 there is NO padding at all - the panels touch the window's edge, the text its panel's edge, the bar and the row are as tall as
/// their content -; everything scales in proportion, rounded to whole points. Structural sizes - the outline's width, the indent per heading level,
/// the font sizes, the gaps between the syntax bar's elements, the outline's row height (a slider of its own) - are not padding and do not move.
struct Padding: Equatable {
    let factor: CGFloat

    init(factor: CGFloat) { self.factor = factor }
    static let standard = Padding(factor: 1)

    private func scaled(_ base: CGFloat) -> CGFloat { max(0, (base * factor).rounded()) }

    // the window
    /// The frame between the window's edge and the panels, on every side.
    var window: CGFloat {
        #if LUFTIG_SELFTEST
        if let o = Padding.windowOverride { return o }
        #endif
        return scaled(12)
    }
    #if LUFTIG_SELFTEST
    /// Self-test only: a scenario about the system's chrome wants the text view at the window's edge.
    nonisolated(unsafe) static var windowOverride: CGFloat?
    #endif

    // the text
    /// The least space between the window's edge (or the outline) and the text column (`ReadableColumnController.minInset`). The decoration bands reach
    /// `DecorationMetrics.bandOutset` into it; with less than that they run to the panel's edge.
    var textInsetHorizontal: CGFloat { scaled(28) }
    /// Space above the first and below the last line of the text.
    var textInsetVertical: CGFloat { scaled(20) }
    /// Extra air on the RIGHT of the text, on top of the horizontal inset (`ReadableColumnController.trailingExtra`): the text's right edge keeps the same
    /// distance from the scroller as the outline's entries keep from the window's left edge.
    var textTrailingExtra: CGFloat { scaled(16) }

    // the outline (left); the height of its rows is a setting of its own (Settings > Layout > Outline spacing), not padding
    var outlineLeading: CGFloat { scaled(16) }
    var outlineTop: CGFloat { scaled(20) }

    // the word count (top right): its content (a 12 pt line) plus air
    static let wordCountContentHeight: CGFloat = 16
    var wordCountHeight: CGFloat { Padding.wordCountContentHeight + scaled(6) }
    var wordCountTrailing: CGFloat { scaled(16) }

    // the syntax bar (bottom): its content (the symbols) plus air; the gaps between its elements are fixed (SyntaxBarView.gapInGroup / gapBetweenGroups)
    static let barContentHeight: CGFloat = 18
    var barHeight: CGFloat { Padding.barContentHeight + scaled(22) }
}
