import AppKit

/// Every bit of air in the editor, from ONE factor (Settings > Layout > Padding, `EditorPreferences.padding`, 0.5 ... 2.0), in two layers: the WINDOW
/// padding - the frame between the window's edge and the panels, on all four sides - and the padding INSIDE each panel (the text's insets, the
/// outline's margins, the word count's row, the syntax bar's height). At 1.0 the panel values are the ones luftig always had and the window frame is
/// 12 pt; everything scales in proportion, rounded to whole points, so the editor stays in balance from tight to airy. Structural sizes - the
/// outline's width, the indent per heading level, the font sizes, the gaps between the syntax bar's elements, the outline's row height (a slider of
/// its own) - are not padding and do not move.
struct Padding: Equatable {
    let factor: CGFloat

    init(factor: CGFloat) { self.factor = factor }
    static let standard = Padding(factor: 1)

    private func scaled(_ base: CGFloat, min floor: CGFloat = 0) -> CGFloat { max(floor, (base * factor).rounded()) }

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
    /// The least space between the window's edge (or the outline) and the text column (`ReadableColumnController.minInset`); it must keep room for the
    /// decoration bands, which reach `DecorationMetrics.bandOutset` into it.
    var textInsetHorizontal: CGFloat { scaled(28, min: DecorationMetrics.bandOutset + 4) }
    /// Space above the first and below the last line of the text.
    var textInsetVertical: CGFloat { scaled(20, min: 4) }
    /// Extra air on the RIGHT of the text, on top of the horizontal inset (`ReadableColumnController.trailingExtra`): the text's right edge keeps the same
    /// distance from the scroller as the outline's entries keep from the window's left edge.
    var textTrailingExtra: CGFloat { scaled(16, min: 4) }

    // the outline (left); the height of its rows is a setting of its own (Settings > Layout > Outline spacing), not padding
    var outlineLeading: CGFloat { scaled(16, min: 4) }
    var outlineTop: CGFloat { scaled(20, min: 2) }

    // the word count (top right)
    var wordCountHeight: CGFloat { scaled(22, min: 16) }
    var wordCountTrailing: CGFloat { scaled(16, min: 4) }

    // the syntax bar (bottom); the gaps between its elements are fixed (SyntaxBarView.gapInGroup / gapBetweenGroups)
    var barHeight: CGFloat { scaled(40, min: 24) }
}
