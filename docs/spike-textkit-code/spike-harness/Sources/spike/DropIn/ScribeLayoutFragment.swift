import AppKit

/// TextKit 2 decorations. Install via NSTextLayoutManagerDelegate:
///
///     func textLayoutManager(_ m: NSTextLayoutManager, textLayoutFragmentFor loc: NSTextLocation,
///                            in element: NSTextElement) -> NSTextLayoutFragment {
///         element is NSTextParagraph ? ScribeLayoutFragment(textElement: element, range: element.elementRange)
///                                    : NSTextLayoutFragment(textElement: element, range: element.elementRange)
///     }
///
/// Building the TK2 stack by hand (see spike-harness/Sources/spike/Harness.swift):
///
///     let cs = NSTextContentStorage();  let tlm = NSTextLayoutManager()
///     let tc = NSTextContainer(size: NSSize(width: w, height: .greatestFiniteMagnitude))
///     tlm.textContainer = tc;  cs.addTextLayoutManager(tlm)
///     let tv = ScribeEditorTextView(frame: frame, textContainer: tc)      // a TextKit 2 text view
///     tlm.delegate = <object implementing the method above>               // weak: keep it alive
///
/// Rules for TK2 (measured, see docs/spike-textkit.md): never touch `tv.layoutManager`; find the visible range with
/// `tlm.textViewportLayoutController.viewportRange`, never with `characterIndexForInsertion(at:)`; never re-apply attributes to styled
/// text; call `NSTextStorage.invalidateNeighbourParagraphs(of:)` (below) when block membership of lines changed.
///
/// One fragment == one paragraph (== one source line of a code block, but a whole wrapped quote paragraph).
final class ScribeLayoutFragment: NSTextLayoutFragment {

    private struct Info {
        var kind: BlockKind?
        var continuesAbove = false
        var continuesBelow = false
        var hasInline = false
    }
    private var cachedInfo: Info?

    private var info: Info {
        if let i = cachedInfo { return i }
        var i = Info()
        if let para = textElement as? NSTextParagraph {
            let s = para.attributedString
            if s.length > 0 {
                if let v = s.attribute(.scribeBlock, at: 0, effectiveRange: nil) as? NSNumber { i.kind = BlockKind(rawValue: v.intValue) }
                // does the paragraph contain inline-code spans?
                var r = NSRange(location: 0, length: 0)
                var idx = 0
                while idx < s.length {
                    if s.attribute(.scribeInline, at: idx, longestEffectiveRange: &r, in: NSRange(location: idx, length: s.length - idx)) != nil {
                        i.hasInline = true; break
                    }
                    idx = NSMaxRange(r)
                    if r.length == 0 { break }
                }
            }
        }
        cachedInfo = i
        return i
    }

    /// Look at the characters just before / after this paragraph in the backing store.
    private func neighbours(of kind: BlockKind) -> (Bool, Bool)? {
        guard let tlm = textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage,
              let ts = cs.textStorage else { return nil }
        let start = cs.offset(from: cs.documentRange.location, to: rangeInElement.location)
        let end = cs.offset(from: cs.documentRange.location, to: rangeInElement.endLocation)
        func k(_ i: Int) -> BlockKind? {
            guard i >= 0, i < ts.length, let v = ts.attribute(.scribeBlock, at: i, effectiveRange: nil) as? NSNumber else { return nil }
            return BlockKind(rawValue: v.intValue)
        }
        return (k(start - 1) == kind, k(end) == kind)
    }

    private var textContainerWidth: CGFloat { textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width }

    override var renderingSurfaceBounds: CGRect {
        var b = super.renderingSurfaceBounds
        let i = info
        if i.kind != nil {
            // Fragment-local coordinates: x = 0 is the fragment origin; the text column starts at -layoutFragmentFrame.minX.
            let left = -layoutFragmentFrame.minX - DecorationMetrics.bandOutset - 1
            let right = -layoutFragmentFrame.minX + textContainerWidth + DecorationMetrics.bandOutset + 1
            b = b.union(CGRect(x: left, y: 0, width: right - left, height: layoutFragmentFrame.height))
        }
        if i.hasInline {
            b = b.insetBy(dx: -DecorationMetrics.inlinePillHPad - 1, dy: -DecorationMetrics.inlinePillVPad - 1)
        }
        return b
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let i = info
        if i.kind != nil || i.hasInline {
            let tv = textLayoutManager?.textContainer?.textView
            let appearance = tv?.effectiveAppearance ?? NSAppearance.currentDrawing()
            let colors = DecorationDrawing.Colors(appearance: appearance)
            let scale = tv?.window?.backingScaleFactor ?? 2
            drawDecorations(at: point, in: context, info: i, colors: colors, scale: scale)
        }
        super.draw(at: point, in: context)
    }

    private func drawDecorations(at point: CGPoint, in ctx: CGContext, info i0: Info, colors: DecorationDrawing.Colors, scale: CGFloat) {
        // Neighbour continuity is evaluated at draw time (never cached): a lazily styled neighbour may change after this
        // fragment was laid out, and its layout is not necessarily invalidated.
        var i = i0
        if let k = i.kind, let (above, below) = neighbours(of: k) { i.continuesAbove = above; i.continuesBelow = below }
        let frame = layoutFragmentFrame
        let columnLeft = point.x - frame.minX            // x of the text column's left edge in the drawing context
        let outset = DecorationMetrics.bandOutset
        let x0 = columnLeft - outset
        let x1 = columnLeft + textContainerWidth + outset
        let y0 = point.y
        let y1 = point.y + frame.height

        if let kind = i.kind {
            switch kind {
            case .code:
                DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), color: colors.codeBand,
                                           continuesAbove: i.continuesAbove, continuesBelow: i.continuesBelow)
            case .quote:
                DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), color: colors.quoteBand,
                                           continuesAbove: i.continuesAbove, continuesBelow: i.continuesBelow)
                DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: DecorationMetrics.quoteBarWidth, height: y1 - y0),
                                           color: colors.quoteBar, continuesAbove: i.continuesAbove, continuesBelow: i.continuesBelow)
            case .rule:
                DecorationDrawing.fillRule(ctx, x0: columnLeft, x1: columnLeft + textContainerWidth, y: (y0 + y1) / 2, color: colors.rule, scale: scale)
            }
        }

        if i.hasInline {
            for lf in textLineFragments {
                let s = lf.attributedString
                let range = lf.characterRange
                var idx = range.location
                let end = NSMaxRange(range)
                while idx < end {
                    var eff = NSRange(location: 0, length: 0)
                    let v = s.attribute(.scribeInline, at: idx, longestEffectiveRange: &eff, in: NSRange(location: idx, length: end - idx))
                    if v != nil {
                        let clipped = NSIntersectionRange(eff, range)
                        let xa = lf.locationForCharacter(at: clipped.location).x
                        let xb = clipped.upperBound >= end ? lf.typographicBounds.width : lf.locationForCharacter(at: clipped.upperBound).x
                        let font = (s.attribute(.font, at: clipped.location, effectiveRange: nil) as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        let baseline = lf.typographicBounds.minY + lf.glyphOrigin.y
                        let top = baseline - font.ascender - DecorationMetrics.inlinePillVPad
                        let bottom = baseline - font.descender + DecorationMetrics.inlinePillVPad
                        let r = CGRect(x: point.x + lf.typographicBounds.minX + xa - DecorationMetrics.inlinePillHPad,
                                       y: point.y + top,
                                       width: (xb - xa) + 2 * DecorationMetrics.inlinePillHPad,
                                       height: bottom - top)
                        DecorationDrawing.fillRounded(ctx, rect: r, radius: DecorationMetrics.inlinePillRadius, color: colors.pill)
                    }
                    idx = NSMaxRange(eff)
                    if eff.length == 0 { break }
                }
            }
        }
    }
}

extension NSTextStorage {
    /// TextKit 2 only. Call (inside beginEditing/endEditing) after the block membership of `range` changed, i.e. whenever lines
    /// joined or left a code block / quote.
    ///
    /// Why: the rounded corners of a band depend on the NEIGHBOUR lines. TK2 re-creates fragments only for the paragraphs whose
    /// attributes changed, so the paragraph above/below keeps drawing its old corner (a visible notch) unless it is invalidated too.
    /// Measured: without this the neighbour's fragment is not re-created; with it it is. `edited(.editedAttributes ...)` is the
    /// cheapest way to invalidate a paragraph without changing anything. (TK1 evaluates the neighbours at draw time and needs nothing.)
    func invalidateNeighbourParagraphs(of range: NSRange) {
        let ns = string as NSString
        guard ns.length > 0 else { return }
        if range.location > 0 {
            edited(.editedAttributes, range: ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0)), changeInLength: 0)
        }
        let end = NSMaxRange(range)
        if end < ns.length {
            edited(.editedAttributes, range: ns.paragraphRange(for: NSRange(location: end, length: 0)), changeInLength: 0)
        }
    }
}
