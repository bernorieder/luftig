import AppKit

/// TextKit 1 decorations: full-width code bands, quote bars and panels, table / front matter bands, horizontal rules, inline-code pills.
/// Also paints the selection translucent (see `fillBackgroundRectArray`; the colours come from the current colour scheme, see Palette.swift).
///
/// Driven by the `.luftigBlock` / `.luftigPanel` / `.luftigInline` attributes.
///
/// IMPORTANT (measured): AppKit clips `drawBackground(forGlyphRange:at:)` to the line-fragment rects, i.e. to the text
/// container. Anything drawn there can NOT extend into the text container inset (bands cut off, no rounded outer corners).
/// So the decorations are drawn from the text view's `drawBackground(in:)` (see LuftigEditorTextView), which runs
/// with the full dirty rect as clip and BEFORE the layout manager paints selection + glyphs.
///
/// Geometry, measured (TextKit 1, fixed line heights): the line box of a line with `minimumLineHeight == maximumLineHeight` keeps its extra
/// leading ABOVE the text; the text sits at the bottom of the box (baseline = bottom - descent). A band that simply covers the line boxes
/// therefore has a gap above the first line and none below the last one (descenders touched the edge). The bands here are laid around the
/// TEXT instead: top = top of the first line's glyphs - padding, bottom = bottom of the last line's glyphs + padding. A side that continues
/// beyond the drawn part (a block cut by the dirty rect) uses the line box edge, which is where the next piece starts.
final class LuftigLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tables drawn as a grid (TableRender.swift)

    /// Glyphs were hidden in this text: from now on a change of attributes regenerates the glyphs of its range. AppKit regenerates glyphs when a FONT
    /// changes, not when only `.luftigTableRow` does, so a row shown as Markdown again kept its hidden glyphs (and a row drawn again its visible ones).
    private var hidesGlyphs = false

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
        if hidesGlyphs, editMask.contains(.editedAttributes), invalidatedCharRange.length > 0 {      // (also with characters: the styler restyles inside the edit)
            invalidateGlyphs(forCharacterRange: invalidatedCharRange, changeInLength: 0, actualCharacterRange: nil)
        }
    }

    /// The characters of a table drawn as a grid get no glyphs (`.null`: they take no room); their rows are drawn by `drawDecorations`. Line breaks keep
    /// their glyph, so every row stays a line of its own.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let ts = textStorage, glyphRange.length > 0 else { return 0 }
        let first = charIndexes[0], last = charIndexes[glyphRange.length - 1]
        let span = NSIntersectionRange(NSRange(location: first, length: last - first + 1), NSRange(location: 0, length: ts.length))
        guard span.length > 0 else { return 0 }
        var hidden = IndexSet()
        for key in [NSAttributedString.Key.luftigTableRow, .luftigImage] {
            ts.enumerateAttribute(key, in: span, options: []) { v, r, _ in if v != nil { hidden.insert(integersIn: r.location..<NSMaxRange(r)) } }
        }
        guard !hidden.isEmpty else { return 0 }
        hidesGlyphs = true
        let text = ts.string as NSString
        var newProps = [NSLayoutManager.GlyphProperty](repeating: [], count: glyphRange.length)
        for i in 0..<glyphRange.length {
            let c = charIndexes[i]
            var p = props[i]
            if hidden.contains(c) {
                let ch = text.character(at: c)
                if ch != 0x0A && ch != 0x0D { p = .null }
            }
            newProps[i] = p
        }
        newProps.withUnsafeBufferPointer { setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange) }
        return glyphRange.length
    }

    /// Self-test only (the render scenario): paint the selection as an ACTIVE (key window) selection although the offscreen window is never key.
    nonisolated(unsafe) static var simulateActiveSelection = false

    /// Called by LuftigEditorTextView.drawBackground(in:). `origin` = textContainerOrigin (view coordinates).
    ///
    /// The dirty rect can be ANY strip: the few lines of an edit, the rows scrolling exposes (a few points, at any y), the caret. What a strip shows must be
    /// pixel for pixel what a full draw shows (`visual-redraw` checks it), so every shape is a function of its own line fragment and of the ATTRIBUTES of the
    /// characters before and after it, never of which neighbouring fragments happen to lie in the dirty rect. The one thing that reaches into a neighbouring
    /// fragment's rect is the padding of a band below its last line, which is why the fragment above the dirty rect is drawn as well.
    func drawDecorations(in dirtyRect: NSRect, origin: NSPoint, container tc: NSTextContainer) {
        // full width: a dirty rect that lies wholly in the text container inset (left or right of the column) still has bands, bars and panels in it
        let local = NSRect(x: 0, y: dirtyRect.minY - origin.y, width: tc.size.width, height: dirtyRect.height)
        var glyphs = glyphRange(forBoundingRect: local, in: tc)
        guard glyphs.length > 0 else { return }
        if glyphs.location > 0 {
            var above = NSRange(location: 0, length: 0)
            let r = lineFragmentRect(forGlyphAt: glyphs.location - 1, effectiveRange: &above, withoutAdditionalLayout: true)   // never forces layout
            if r.height > 0, above.length > 0 { glyphs = NSUnionRange(above, glyphs) }
        }
        drawDecorations(forGlyphRange: glyphs, at: origin)
    }

    /// `v` rounded to the device pixel grid.
    private func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

    // MARK: line fragments

    private enum Category { case none, quote, code, rule, panel }

    private struct Frag {
        var rect: CGRect               // line fragment rect (container coordinates; includes paragraph spacing before)
        var used: CGRect               // the line box proper
        var chars: NSRange
        var glyphs: NSRange
        var category: Category
        var depth: Int                 // quote depth of the line (0 outside quotes)
        var isCode: Bool               // a code / fence line (inside a quote or not)
        var isRule: Bool               // a horizontal rule line (inside a quote it is part of the quote: category .quote)
        var panel: PanelKind?
        var font: NSFont?              // font of the first character
    }

    /// Block category of the character at `i` (for "does the block continue beyond what is drawn").
    private func category(at i: Int, _ ts: NSTextStorage) -> Category {
        guard i >= 0, i < ts.length else { return .none }
        let a = ts.attributes(at: i, effectiveRange: nil)
        if let (kind, depth) = BlockMark.decode(a[.luftigBlock]) {
            switch kind {
            case .rule: return depth > 0 ? .quote : .rule
            case .quote: return .quote
            case .code: return depth > 0 ? .quote : .code
            }
        }
        return a[.luftigPanel] != nil ? .panel : .none
    }

    /// Top and bottom of the glyphs of a line (extra leading is above the text): the top of the ascenders, the bottom of the descenders, the largest font
    /// size on the line, and the descent.
    private func textExtent(of f: Frag, _ ts: NSTextStorage) -> (top: CGFloat, bottom: CGFloat, size: CGFloat, descent: CGFloat) {
        var asc: CGFloat = 0, desc: CGFloat = 0, size: CGFloat = 0
        let r = NSIntersectionRange(f.chars, NSRange(location: 0, length: ts.length))
        ts.enumerateAttribute(.font, in: r, options: []) { v, _, _ in
            if let font = v as? NSFont { asc = max(asc, font.ascender); desc = max(desc, -font.descender); size = max(size, font.pointSize) }
        }
        if size == 0 { size = f.font?.pointSize ?? 16; asc = size * 0.97; desc = size * 0.21 }
        let bottom = f.used.maxY
        return (max(f.used.minY, bottom - (asc + desc)), bottom, size, desc)
    }

    /// A line that is only a code fence (```` ``` ````, `~~~`): the backticks sit high in the line, so a band that ends with it would show a wide gap below them.
    private func isFenceOnly(_ f: Frag, _ ts: NSTextStorage) -> Bool {
        guard f.isCode else { return false }
        let ns = ts.string as NSString
        let end = min(NSMaxRange(f.chars), ns.length)
        var i = f.chars.location, ticks = 0
        while i < end {
            let c = ns.character(at: i)
            if c == 0x60 || c == 0x7E { ticks += 1 } else if c != 0x20 && c != 0x0A && c != 0x0D && c != 0x09 { return false }
            i += 1
            if i - f.chars.location > 40 { return false }
        }
        return ticks >= 3
    }

    /// The top (above: true) or bottom edge of a band around the text of line fragment `f`: the glyphs' edge plus the padding, but never closer to the
    /// neighbouring line's text than 1 pt (the space between two lines is the leading above the text: a band that starts right under a text line must
    /// not run into its descenders).
    private func bandEdge(_ f: Frag, _ ts: NSTextStorage, above: Bool) -> CGFloat {
        if f.chars.location < ts.length, ts.attribute(.luftigTableRow, at: f.chars.location, effectiveRange: nil) != nil { return above ? f.rect.minY : f.rect.maxY }   // a drawn table row: the band holds the whole row
        let e = textExtent(of: f, ts)
        let pad = e.size * DecorationMetrics.bandPaddingRatio
        let leading = max(0, e.top - f.used.minY)
        let room = max(2, leading - 1)
        // never above the fragment's own rect: `room` is at least 2 pt, but with a tight line box (line spacing 1.1, a font whose glyphs fill it) there is
        // no leading above the text, and the band would reach into the fragment above. A strip drawn on its own (a scrolled-in row, the caret) that lies
        // in that fragment does not draw this fragment, so its pixels differed from the full draw (invariant 18).
        if above { return max(f.rect.minY, e.top - min(pad, room)) }
        // closing fence: end the band just under the baseline (the backticks are ~0.5 em above it), not under the empty descender zone
        if isFenceOnly(f, ts) { return e.bottom - e.descent + pad * 0.25 }
        return e.bottom + min(pad, room)
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
        let x0 = origin.x - outset
        let x1 = origin.x + width + outset

        var frags: [Frag] = []
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, used, _, glyphRange, _ in
            let charRange = self.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.location < length else { return }
            let a = ts.attributes(at: charRange.location, effectiveRange: nil)
            var f = Frag(rect: rect, used: used, chars: charRange, glyphs: glyphRange, category: .none, depth: 0, isCode: false, isRule: false, panel: nil, font: a[.font] as? NSFont)
            if let (kind, depth) = BlockMark.decode(a[.luftigBlock]) {
                f.depth = depth
                switch kind {
                case .rule: f.category = depth > 0 ? .quote : .rule; f.isRule = true
                case .quote: f.category = .quote
                case .code: f.category = depth > 0 ? .quote : .code; f.isCode = true
                }
            } else if let p = a[.luftigPanel] as? NSNumber, let kind = PanelKind(rawValue: p.intValue) {
                f.category = .panel
                f.panel = kind
            }
            frags.append(f)
        }

        // ---- blocks: runs of consecutive line fragments of one category
        var i = 0
        while i < frags.count {
            let first = frags[i]
            if first.category == .none || first.category == .rule {
                if first.category == .rule { drawRule(ctx, first, ts, origin: origin, width: width, color: colors.rule, scale: scale) }
                i += 1
                continue
            }
            var j = i
            while j + 1 < frags.count, frags[j + 1].category == first.category, frags[j + 1].rect.minY <= frags[j].rect.maxY + 1 { j += 1 }
            let run = frags[i...j]
            let continuesAbove = category(at: first.chars.location - 1, ts) == first.category
            let continuesBelow = category(at: NSMaxRange(frags[j].chars), ts) == first.category
            let top = continuesAbove ? first.rect.minY : bandEdge(first, ts, above: true)
            let bottom = continuesBelow ? frags[j].rect.maxY : bandEdge(frags[j], ts, above: false)
            // snapped to the device pixel grid: a hairline border (Increase contrast) then lies exactly on pixel rows and a piece drawn alone looks like
            // the same piece of the full drawing (at a fractional edge the two pieces meeting there each cover part of a row)
            let y0 = snap(origin.y + top, scale), y1 = snap(origin.y + bottom, scale)
            let band = CGRect(x: snap(x0, scale), y: y0, width: snap(x1, scale) - snap(x0, scale), height: y1 - y0)
            switch first.category {
            case .code:
                DecorationDrawing.fillBand(ctx, rect: band, color: colors.codeBand, continuesAbove: continuesAbove, continuesBelow: continuesBelow, border: colors.border)
            case .panel:
                DecorationDrawing.fillBand(ctx, rect: band, color: colors.panel, continuesAbove: continuesAbove, continuesBelow: continuesBelow, border: colors.border)
                // the header row of a table: a stronger tint down to the bottom of the header line
                if let h = run.first(where: { $0.panel == .tableHeader }) {
                    let hb = min(y1, origin.y + h.rect.maxY)
                    if hb > y0 + 1 {
                        DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: y0, width: x1 - x0, height: hb - y0), color: colors.tableHeader,
                                                   continuesAbove: continuesAbove, continuesBelow: true, border: nil)
                    }
                }
            case .quote:
                drawQuote(ctx, Array(run), ts, colors: colors, x0: band.minX, x1: band.maxX, top: y0, bottom: y1,
                          continuesAbove: continuesAbove, continuesBelow: continuesBelow, origin: origin, width: width, scale: scale)
            default: break
            }
            i = j + 1
        }

        drawPills(ctx, frags, ts, tc, origin: origin, colors: colors)
        drawTableRows(ctx, frags, ts, origin: origin, colors: colors, scale: scale)
    }

    /// The rows of tables drawn as a grid (their glyphs are hidden): grid lines and cell text, in each row's own line fragment.
    private func drawTableRows(_ ctx: CGContext, _ frags: [Frag], _ ts: NSTextStorage, origin: NSPoint, colors: DecorationDrawing.Colors, scale: CGFloat) {
        let tv = textContainers.first?.textView
        let selected = (tv?.selectedRanges ?? []).map { $0.rangeValue }.filter { $0.length > 0 }
        for f in frags where f.chars.location < ts.length {
            if let image = ts.attribute(.luftigImage, at: f.chars.location, effectiveRange: nil) as? ImageRenderLine {
                let indent = (ts.attribute(.paragraphStyle, at: f.chars.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
                let rect = CGRect(x: origin.x + f.rect.minX, y: origin.y + f.rect.minY, width: f.rect.width, height: f.rect.height)
                ImageRenderer.draw(image, rect: rect, left: rect.minX + indent, ctx: ctx, placeholder: colors.panel, scale: scale)
                continue
            }
            guard let row = ts.attribute(.luftigTableRow, at: f.chars.location, effectiveRange: nil) as? TableRenderRow else { continue }
            let indent = (ts.attribute(.paragraphStyle, at: f.chars.location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
            let rect = CGRect(x: origin.x + f.rect.minX, y: origin.y + f.rect.minY, width: f.rect.width, height: f.rect.height)
            let left = origin.x + f.rect.minX + indent
            // a selection that passes over the table: its rows are tinted like selected text (their glyphs, which the selection would paint behind, are hidden)
            let line = (ts.string as NSString).lineRange(for: NSRange(location: f.chars.location, length: 0))
            if let tv, selected.contains(where: { NSIntersectionRange($0, line).length > 0 }), let fill = selectionTint(tv) {
                ctx.setFillColor(fill)
                ctx.fill(CGRect(x: left, y: rect.minY, width: row.edges.last ?? 0, height: rect.height))
            }
            TableRenderer.draw(row, rect: rect, left: left, ctx: ctx, line: colors.rule, strong: colors.rule, scale: scale)
        }
    }

    /// The colour of selected text's background, translucent as `fillBackgroundRectArray` paints it.
    private func selectionTint(_ tv: NSTextView) -> CGColor? {
        let appearance = tv.effectiveAppearance
        let variant = Palette.variant(for: appearance)
        let active = tv.window?.isKeyWindow ?? false || LuftigLayoutManager.simulateActiveSelection
        var out: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            let alpha = Palette.selectionAlpha(variant)
            let c = Palette.selectionFill(variant, active: active) ?? (active ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).withAlphaComponent(alpha)
            out = c.cgColor
        }
        return out
    }

    // MARK: rules

    private func drawRule(_ ctx: CGContext, _ f: Frag, _ ts: NSTextStorage, origin: NSPoint, width: CGFloat, color: CGColor, scale: CGFloat) {
        // the rule runs through the middle of the dashes, not through the middle of the line box
        let baseline = f.rect.minY + location(forGlyphAt: f.glyphs.location).y
        let font = f.font ?? NSFont.systemFont(ofSize: 16)
        // the rule starts after the marker text (`---`, `***`, `___` look alike that way, and the line does not strike through the characters)
        let start = min(origin.x + width - 20, origin.x + f.used.maxX + 10)
        DecorationDrawing.fillRule(ctx, x0: start, x1: origin.x + width, y: origin.y + baseline - font.xHeight * 0.5, color: color, scale: scale)
    }

    // MARK: quotes

    /// Quote depth of the line that contains character `i` (0: no quote, or outside the text). Rules and code lines inside a quote count.
    private func quoteDepth(at i: Int, _ ts: NSTextStorage) -> Int {
        guard i >= 0, i < ts.length, let (_, depth) = BlockMark.decode(ts.attribute(.luftigBlock, at: i, effectiveRange: nil)) else { return 0 }
        return depth
    }

    /// One quote block (consecutive lines with a quote depth, including code lines and rules inside a quote): the tinted band with the outer bar, and for
    /// every deeper level a panel (a little darker) with its own bar; code inside a quote is a code-coloured panel inside the band.
    /// `top` / `bottom` are view coordinates.
    ///
    /// Every inner shape is built from line fragments: where it carries on above / below the fragment (decided from the attributes of the neighbouring
    /// character, so it does not matter whether that line is in the dirty rect) it runs to the fragment's edge and is square there; at its true ends it
    /// is rounded and has its own padding. A panel drawn for 3 lines of a 30-line block therefore looks exactly like those 3 lines of the whole drawing.
    private func drawQuote(_ ctx: CGContext, _ run: [Frag], _ ts: NSTextStorage, colors: DecorationDrawing.Colors, x0: CGFloat, x1: CGFloat,
                           top: CGFloat, bottom: CGFloat, continuesAbove: Bool, continuesBelow: Bool, origin: NSPoint, width: CGFloat, scale: CGFloat) {
        let step = DecorationMetrics.quoteBarStep, barW = DecorationMetrics.quoteBarWidth
        DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top), color: colors.quoteBand,
                                   continuesAbove: continuesAbove, continuesBelow: continuesBelow)

        /// Own leading above the text of a fragment (the extra line height sits above the glyphs).
        func leading(_ f: Frag) -> CGFloat { max(0, textExtent(of: f, ts).top - f.used.minY) }
        /// Top edge (view coordinates) of an inner shape that STARTS at fragment `f`: just inside the band when the quote itself starts here, else
        /// halfway through the gap above the text.
        func startEdge(_ f: Frag) -> CGFloat {
            if category(at: f.chars.location - 1, ts) != .quote { return max(origin.y + bandEdge(f, ts, above: true), origin.y + f.used.minY) + 3 }
            return origin.y + f.used.minY + leading(f) * 0.5
        }
        /// Bottom edge of an inner shape that ENDS at fragment `f`.
        func endEdge(_ f: Frag) -> CGFloat {
            if category(at: NSMaxRange(f.chars), ts) != .quote { return min(origin.y + bandEdge(f, ts, above: false), origin.y + f.used.maxY + 3) }
            return origin.y + f.used.maxY + leading(f) * 0.5
        }
        /// Snap to the device pixel grid so that neighbouring pieces meet without a seam.
        func snap(_ v: CGFloat) -> CGFloat { self.snap(v, scale) }

        // deeper levels: panels + bars, per run of lines with depth >= level
        if run.contains(where: { $0.depth >= 2 }) {
            for level in 2...3 {
                var k = 0
                while k < run.count {
                    guard run[k].depth >= level else { k += 1; continue }
                    var m = k
                    while m + 1 < run.count, run[m + 1].depth >= level { m += 1 }
                    let above = quoteDepth(at: run[k].chars.location - 1, ts) >= level
                    let below = quoteDepth(at: NSMaxRange(run[m].chars), ts) >= level
                    let py0 = snap(above ? origin.y + run[k].rect.minY : startEdge(run[k]))
                    let py1 = snap(below ? origin.y + run[m].rect.maxY : endEdge(run[m]))
                    let bx = x0 + CGFloat(level - 1) * step
                    let inset = DecorationMetrics.panelRightInset * CGFloat(level - 1) * 0.5
                    DecorationDrawing.fillBand(ctx, rect: CGRect(x: bx, y: py0, width: x1 - inset - bx - DecorationMetrics.panelRightInset * 0.5, height: py1 - py0),
                                               color: colors.nested[level], continuesAbove: above, continuesBelow: below, radius: DecorationMetrics.panelCornerRadius)
                    let b0 = py0 + (above ? 0 : 2), b1 = py1 - (below ? 0 : 2)
                    DecorationDrawing.fillBand(ctx, rect: CGRect(x: bx, y: b0, width: barW, height: max(0, b1 - b0)), color: colors.quoteBar,
                                               continuesAbove: above, continuesBelow: below, radius: barW / 2)
                    k = m + 1
                }
            }
        }
        // code inside a quote: a code-coloured panel inside the band, to the right of the bars of its own depth
        var k = 0
        while k < run.count {
            guard run[k].isCode else { k += 1; continue }
            var m = k
            while m + 1 < run.count, run[m + 1].isCode { m += 1 }
            let d = max(1, run[k].depth)
            let px = x0 + CGFloat(d - 1) * step + barW + 5
            let above = isCodeLine(at: run[k].chars.location - 1, ts)
            let below = isCodeLine(at: NSMaxRange(run[m].chars), ts)
            let py0 = snap(above ? origin.y + run[k].rect.minY : startEdge(run[k]))
            let py1 = snap(below ? origin.y + run[m].rect.maxY : endEdge(run[m]))
            DecorationDrawing.fillBand(ctx, rect: CGRect(x: px, y: py0, width: x1 - DecorationMetrics.panelRightInset - px, height: py1 - py0), color: colors.codeInQuote[min(3, d)],
                                       continuesAbove: above, continuesBelow: below, radius: DecorationMetrics.panelCornerRadius, border: colors.border)
            k = m + 1
        }
        // the outer bar: the whole block, rounded at its true ends
        DecorationDrawing.fillBand(ctx, rect: CGRect(x: x0, y: top, width: barW, height: bottom - top), color: colors.quoteBar,
                                   continuesAbove: continuesAbove, continuesBelow: continuesBelow, radius: barW / 2)
        // horizontal rules inside the quote: a hairline from the end of the marker text to the right edge of the text column
        for f in run where f.isRule { drawRule(ctx, f, ts, origin: origin, width: width, color: colors.rule, scale: scale) }
    }

    private func isCodeLine(at i: Int, _ ts: NSTextStorage) -> Bool {
        guard i >= 0, i < ts.length, let (kind, _) = BlockMark.decode(ts.attribute(.luftigBlock, at: i, effectiveRange: nil)) else { return false }
        return kind == .code
    }

    // MARK: inline code pills

    /// One pill per line fragment, so a wrapped span gets one per line; the side of a pill where the span wraps stays open (square, no padding).
    private func drawPills(_ ctx: CGContext, _ frags: [Frag], _ ts: NSTextStorage, _ tc: NSTextContainer, origin: NSPoint, colors: DecorationDrawing.Colors) {
        let length = ts.length
        for f in frags {
            if f.chars.location < length, ts.attribute(.luftigTableRow, at: f.chars.location, effectiveRange: nil) != nil { continue }   // (a drawn table row: its glyphs are hidden)
            var idx = f.chars.location
            let end = min(NSMaxRange(f.chars), length)
            while idx < end {
                var eff = NSRange(location: 0, length: 0)
                let v = ts.attribute(.luftigInline, at: idx, longestEffectiveRange: &eff, in: NSRange(location: idx, length: end - idx))
                // (inline code in a table drawn as a grid has hidden glyphs; they can sit in the line fragment ABOVE the row)
                if v != nil, ts.attribute(.luftigTableRow, at: eff.location, effectiveRange: nil) == nil, ts.attribute(.luftigImage, at: eff.location, effectiveRange: nil) == nil {
                    let gr = glyphRange(forCharacterRange: eff, actualCharacterRange: nil)
                    if gr.length > 0 {
                        let bounds = boundingRect(forGlyphRange: gr, in: tc)
                        let loc = location(forGlyphAt: gr.location)
                        let font = (ts.attribute(.font, at: eff.location, effectiveRange: nil) as? NSFont) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        let baseline = f.rect.minY + loc.y
                        let top = baseline - font.ascender - DecorationMetrics.inlinePillVPad
                        let bottom = baseline - font.descender + DecorationMetrics.inlinePillVPad
                        let leftOpen = eff.location == f.chars.location && eff.location > 0 && ts.attribute(.luftigInline, at: eff.location - 1, effectiveRange: nil) != nil
                        let rightOpen = NSMaxRange(eff) == end && end < length && ts.attribute(.luftigInline, at: end, effectiveRange: nil) != nil
                        let pad = DecorationMetrics.inlinePillHPad
                        let left = bounds.minX - (leftOpen ? 0 : pad), right = bounds.maxX + (rightOpen ? 0 : pad)
                        let r = CGRect(x: origin.x + left, y: origin.y + top, width: right - left, height: bottom - top)
                        DecorationDrawing.fillRounded(ctx, rect: r, radius: DecorationMetrics.inlinePillRadius, color: colors.pill, leftOpen: leftOpen, rightOpen: rightOpen, border: colors.border)
                    }
                }
                idx = NSMaxRange(eff)
                if eff.length == 0 { break }
            }
        }
    }

    // MARK: the selection

    /// NSTextView paints the selection through this call (called from `_drawBackgroundForGlyphRange:atPoint:`, measured), OPAQUE: `selectedTextBackgroundColor`
    /// in a key window, the system grey when inactive. The decorations were drawn before, so an opaque selection hid the band and the pills under it, and
    /// in dark mode coloured text on it was 1.7 - 2.7:1. Paint it translucent instead (`Palette.selectionAlpha`). NSLayoutManager's own implementation
    /// ignores the colour it is handed for this fill (measured: passing red changed nothing), so the rectangles are filled here, source-over.
    /// Fills that are not the selection (find highlights, ...) go to `super` untouched.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        guard let fill = selectionFillColor(color, charRange: charRange) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        fill.setFill()
        for i in 0..<rectCount { rectArray[i].fill(using: .sourceOver) }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The translucent colour to fill a SELECTION rectangle with, or nil when this fill is not the selection.
    func selectionFillColor(_ color: NSColor, charRange: NSRange) -> NSColor? {
        guard let tv = textContainers.first?.textView else { return nil }
        let selected = tv.selectedRanges.map { $0.rangeValue }
        guard charRange.length > 0, selected.contains(where: { NSIntersectionRange($0, charRange).length == charRange.length }) else { return nil }
        let appearance = tv.effectiveAppearance
        let variant = Palette.variant(for: appearance)
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { return }
            func same(_ other: NSColor) -> Bool {
                guard let o = other.usingColorSpace(.sRGB) else { return false }
                return abs(o.redComponent - c.redComponent) < 0.004 && abs(o.greenComponent - c.greenComponent) < 0.004 && abs(o.blueComponent - c.blueComponent) < 0.004
            }
            if same(.findHighlightColor) { return }
            let alpha = Palette.selectionAlpha(variant)
            let inactive = same(.unemphasizedSelectedTextBackgroundColor) || same(.unemphasizedSelectedContentBackgroundColor)
            // a fixed colour scheme paints its own selection colours (translucent as well: `Palette.selectionFill`); the default scheme uses the system's
            if inactive && !LuftigLayoutManager.simulateActiveSelection {
                result = Palette.selectionFill(variant, active: false) ?? color.withAlphaComponent(alpha)                        // inactive window: the system grey, same alpha
            } else {
                result = Palette.selectionFill(variant, active: true) ?? NSColor.selectedTextBackgroundColor.withAlphaComponent(alpha)   // the active selection: the accent-derived system colour
            }
        }
        return result
    }
}
