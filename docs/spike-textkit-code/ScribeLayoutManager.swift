import AppKit

/// TextKit 1 decorations: full-width code bands, quote bars, horizontal rules, inline-code pills.
///
/// Driven by the `.scribeBlock` / `.scribeInline` attributes.
///
/// IMPORTANT (measured): AppKit clips `drawBackground(forGlyphRange:at:)` to the line-fragment rects, i.e. to the text
/// container. Anything drawn there can NOT extend into the text container inset (bands cut off, no rounded outer corners).
/// So the decorations are drawn from the text view's `drawBackground(in:)` (see ScribeEditorTextView), which runs
/// with the full dirty rect as clip and BEFORE the layout manager paints selection + glyphs.
final class ScribeLayoutManager: NSLayoutManager {

    /// Called by ScribeEditorTextView.drawBackground(in:). `origin` = textContainerOrigin (view coordinates).
    func drawDecorations(in dirtyRect: NSRect, origin: NSPoint, container tc: NSTextContainer) {
        let local = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = glyphRange(forBoundingRect: local, in: tc)
        if glyphs.length > 0 { drawDecorations(forGlyphRange: glyphs, at: origin) }
    }

    private struct Group {
        var kind: BlockKind
        var minY: CGFloat
        var maxY: CGFloat
        var firstChar: Int
        var lastCharEnd: Int
    }

    func drawDecorations(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let ts = textStorage,
              let tc = textContainers.first,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        let appearance = tc.textView?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let colors = DecorationDrawing.Colors(appearance: appearance)
        let scale = tc.textView?.window?.backingScaleFactor ?? 2
        let width = tc.size.width
        let outset = DecorationMetrics.bandOutset
        let length = ts.length

        var groups: [Group] = []
        var pills: [(CGRect, NSRange)] = []   // line rect (container coords) + char range of the line

        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location < length else { return }
            if let v = ts.attribute(.scribeBlock, at: charRange.location, effectiveRange: nil) as? NSNumber,
               let kind = BlockKind(rawValue: v.intValue) {
                if var g = groups.last, g.kind == kind, rect.minY <= g.maxY + 1 {
                    g.maxY = max(g.maxY, rect.maxY)
                    g.lastCharEnd = NSMaxRange(charRange)
                    groups[groups.count - 1] = g
                } else {
                    groups.append(Group(kind: kind, minY: rect.minY, maxY: rect.maxY,
                                        firstChar: charRange.location, lastCharEnd: NSMaxRange(charRange)))
                }
            }
            pills.append((rect, charRange))
        }

        // Block bands
        for g in groups {
            let continuesAbove = g.firstChar > 0 && blockKind(ts, at: g.firstChar - 1) == g.kind
            let continuesBelow = g.lastCharEnd < length && blockKind(ts, at: g.lastCharEnd) == g.kind
            let x0 = origin.x - outset
            let x1 = origin.x + width + outset
            let y0 = origin.y + g.minY
            let y1 = origin.y + g.maxY
            switch g.kind {
            case .code:
                DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                                           color: colors.codeBand, continuesAbove: continuesAbove, continuesBelow: continuesBelow)
            case .quote:
                DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                                           color: colors.quoteBand, continuesAbove: continuesAbove, continuesBelow: continuesBelow)
                let bar = CGRect(x: x0, y: y0, width: DecorationMetrics.quoteBarWidth, height: y1 - y0)
                DecorationDrawing.fillBand(ctx, rect: bar, color: colors.quoteBar,
                                           continuesAbove: continuesAbove, continuesBelow: continuesBelow)
            case .rule:
                DecorationDrawing.fillRule(ctx, x0: origin.x, x1: origin.x + width, y: (y0 + y1) / 2, color: colors.rule, scale: scale)
            }
        }

        // Inline code pills (per line fragment so wrapped spans get one pill per line)
        for (lineRect, lineChars) in pills {
            var idx = lineChars.location
            let end = NSMaxRange(lineChars)
            while idx < end {
                var eff = NSRange(location: 0, length: 0)
                let v = ts.attribute(.scribeInline, at: idx, longestEffectiveRange: &eff, in: NSRange(location: idx, length: end - idx))
                if v != nil {
                    let gr = glyphRange(forCharacterRange: eff, actualCharacterRange: nil)
                    if gr.length > 0 {
                        let bounds = boundingRect(forGlyphRange: gr, in: tc)
                        let loc = location(forGlyphAt: gr.location)
                        let font = (ts.attribute(.font, at: eff.location, effectiveRange: nil) as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        let baseline = lineRect.minY + loc.y
                        let top = baseline - font.ascender - DecorationMetrics.inlinePillVPad
                        let bottom = baseline - font.descender + DecorationMetrics.inlinePillVPad
                        let r = CGRect(x: origin.x + bounds.minX - DecorationMetrics.inlinePillHPad,
                                       y: origin.y + top,
                                       width: bounds.width + 2 * DecorationMetrics.inlinePillHPad,
                                       height: bottom - top)
                        DecorationDrawing.fillRounded(ctx, rect: r, radius: DecorationMetrics.inlinePillRadius, color: colors.pill)
                    }
                }
                idx = NSMaxRange(eff)
                if eff.length == 0 { break }
            }
        }
    }

    @inline(__always)
    private func blockKind(_ ts: NSTextStorage, at i: Int) -> BlockKind? {
        guard let v = ts.attribute(.scribeBlock, at: i, effectiveRange: nil) as? NSNumber else { return nil }
        return BlockKind(rawValue: v.intValue)
    }
}
