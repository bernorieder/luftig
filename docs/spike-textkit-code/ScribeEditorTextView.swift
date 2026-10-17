import AppKit

/// NSTextView subclass hooks needed for the decorations (TextKit 1 path; harmless with TextKit 2).
class ScribeEditorTextView: NSTextView {

    /// OFF by default, and best left off. Decorations reach into the text container inset and their rounded corners depend on
    /// the neighbour lines, so one could widen every invalidated rect to the full view width. Measured (ExpInvalidate): it is
    /// not needed on TextKit 1 - after an attribute change AppKit already invalidates full-width rows (x 0..viewWidth) from the
    /// changed line down to the end of the laid-out area.
    /// Side effect found in the spike: overriding setNeedsDisplay and clipping the rects to `bounds` changes how AppKit's TK1
    /// text view behaves during background layout of a CONTIGUOUS layout manager (the multi-second stall after open disappears,
    /// the layout then crawls instead). Widening WITHOUT clipping made the stall worse (10 s at 5 MB). With non-contiguous layout
    /// no difference was measurable, so: do not override invalidation unless a concrete stale-pixel bug requires it.
    var widenInvalidationForDecorations = false

    func widenedForDecorations(_ r: NSRect) -> NSRect {
        guard widenInvalidationForDecorations else { return r }
        let pad = DecorationMetrics.bandCornerRadius + 2
        return NSRect(x: 0, y: r.minY - pad, width: bounds.width, height: r.height + 2 * pad).intersection(bounds)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(widenedForDecorations(invalidRect))
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(widenedForDecorations(rect), avoidAdditionalLayout: flag)
    }

    /// TK1: draw the bands/bars/pills with the full dirty rect as clip (see ScribeLayoutManager for why not in the layout manager).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if textLayoutManager == nil, let lm = layoutManager as? ScribeLayoutManager, let tc = textContainer {
            lm.drawDecorations(in: rect, origin: textContainerOrigin, container: tc)
        }
    }
}
