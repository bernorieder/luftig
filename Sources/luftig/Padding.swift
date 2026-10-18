import AppKit

/// Every bit of air in the editor, from ONE factor (Settings > General > Padding, `EditorPreferences.padding`, 0.5 ... 2.0): the text's insets, the
/// panes' margins and heights. At 1.0 these are the values luftig always had; everything scales in proportion, rounded to whole points, so the
/// editor stays in balance from tight to airy. Structural sizes - the outline's width, the indent per heading level, the font sizes - are not padding
/// and do not move.
struct Padding: Equatable {
    let factor: CGFloat

    init(factor: CGFloat) { self.factor = factor }
    static let standard = Padding(factor: 1)

    private func scaled(_ base: CGFloat, min floor: CGFloat = 0) -> CGFloat { max(floor, (base * factor).rounded()) }

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

    // the syntax bar (bottom)
    var barHeight: CGFloat { scaled(40, min: 24) }
    var barGapInGroup: CGFloat { scaled(16, min: 8) }
    var barGapBetweenGroups: CGFloat { scaled(30, min: 14) }
}
