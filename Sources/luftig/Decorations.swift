import AppKit

// Block / inline decorations. Driven by custom attributes that the Theme puts on the style runs:
//   .luftigBlock  = NSNumber(BlockMark.encode(kind, depth))  on every character of a code-block / quote / rule LINE (incl. its "\n")
//   .luftigPanel  = NSNumber(PanelKind)                      on every character of a table / front matter LINE (incl. its "\n"), outside quotes
//   .luftigInline = NSNumber(1)                              on the characters of an inline code span (incl. the backticks)
// Everything else (band geometry, rounding, colours) lives in LuftigLayoutManager (TextKit 1, drawn from the text view).

extension NSAttributedString.Key {
    static let luftigBlock = NSAttributedString.Key("luftig.block")
    static let luftigInline = NSAttributedString.Key("luftig.inline")
    /// Tables and front matter (outside quotes): a lighter band behind the line. NSNumber(PanelKind).
    static let luftigPanel = NSAttributedString.Key("luftig.panel")
}

enum PanelKind: Int {
    case tableHeader = 1
    case tableDelimiter = 2
    case tableBody = 3
    case frontMatter = 4
}

enum BlockKind: Int {
    case code = 1
    case quote = 2
    case rule = 3
}

/// The value of `.luftigBlock`: the kind in the low 4 bits, the block-quote nesting depth (1...3) above it.
enum BlockMark {
    static func encode(_ kind: BlockKind, depth: Int = 0) -> NSNumber { NSNumber(value: kind.rawValue | (max(0, min(3, depth)) << 4)) }
    static func decode(_ v: Any?) -> (kind: BlockKind, depth: Int)? {
        guard let n = v as? NSNumber, let k = BlockKind(rawValue: n.intValue & 0xF) else { return nil }
        return (k, n.intValue >> 4)
    }
}

/// Decoration colours come from the Palette (single source of truth).
enum DecorationPalette {
    static var codeBand: NSColor { Palette.codeBand }
    static var quoteBand: NSColor { Palette.quoteBand }
    static var quoteBar: NSColor { Palette.quoteBar }
    static var inlinePill: NSColor { Palette.inlinePill }
    static var rule: NSColor { Palette.rule }
}

/// Geometry constants, in points. All values are relative to the text container (text column).
enum DecorationMetrics {
    /// Bands extend this far to the left and right of the text column (into the text container inset).
    /// Requires textContainerInset.width >= bandOutset (+ a couple of points).
    static let bandOutset: CGFloat = 10
    static let bandCornerRadius: CGFloat = 6
    static let quoteBarWidth: CGFloat = 3
    /// Distance between the bars of nested quotes (and between the text indents of nested quote lines).
    static let quoteBarStep: CGFloat = 12
    /// Nested quote panels and code panels inside a quote: corner radius, and how far they stop short of the quote's right edge.
    static let panelCornerRadius: CGFloat = 4
    static let panelRightInset: CGFloat = 6
    static let inlinePillRadius: CGFloat = 4
    static let inlinePillHPad: CGFloat = 2.5
    static let inlinePillVPad: CGFloat = 0.5
    static let ruleThickness: CGFloat = 1
    /// Text indent inside code / table / front matter bands. 0: the band reaches `bandOutset` beyond the text on BOTH sides, so the
    /// padding is the same left and right, and the text lines up with the prose around the band.
    static let codeIndent: CGFloat = 0
    /// Text indent of quote lines (the `>` markers start here); the bar sits `bandOutset` to the left of the column, so the gap between a bar and
    /// the marker next to it is the same (13 pt) at every nesting level: `quoteIndent(depth) - bandOutset + level * quoteBarStep + barWidth`.
    static func quoteIndent(depth: Int) -> CGFloat { 6 + CGFloat(max(0, depth - 1)) * quoteBarStep }
    /// Vertical padding of a band above / below its text, relative to the font size.
    static let bandPaddingRatio: CGFloat = 0.28
}

enum DecorationDrawing {
    /// Rounded rect path with an individual radius per corner (y grows downwards: the view is flipped).
    static func path(_ r: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) -> CGPath {
        let maxR = min(r.width, r.height) / 2
        let tl = min(topLeft, maxR), tr = min(topRight, maxR), br = min(bottomRight, maxR), bl = min(bottomLeft, maxR)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
        p.closeSubpath()
        return p
    }

    /// Rounded rect path where only the top and/or bottom corner pairs are rounded.
    static func bandPath(_ r: CGRect, radius: CGFloat, roundTop: Bool, roundBottom: Bool) -> CGPath {
        path(r, topLeft: roundTop ? radius : 0, topRight: roundTop ? radius : 0, bottomRight: roundBottom ? radius : 0, bottomLeft: roundBottom ? radius : 0)
    }

    /// Fill a block band. `continuesAbove/Below` means the block carries on beyond this piece, so that side is square
    /// (adjacent pieces then meet seamlessly, no matter how the view was invalidated). `border`: hairline (Increase contrast only).
    static func fillBand(_ ctx: CGContext, rect: CGRect, color: CGColor, continuesAbove: Bool, continuesBelow: Bool,
                         radius: CGFloat = DecorationMetrics.bandCornerRadius, border: CGColor? = nil) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(bandPath(rect, radius: radius, roundTop: !continuesAbove, roundBottom: !continuesBelow))
        ctx.fillPath()
        if let border, border.alpha > 0 {
            // inset by half a line: the stroke stays inside the band; the open sides (continuing blocks) get no line
            ctx.setStrokeColor(border)
            ctx.setLineWidth(1)
            var inner = rect.insetBy(dx: 0.5, dy: 0)                  // the closed ends are inset by half a line, the open ones run to the edge of the piece
            if !continuesAbove { inner.origin.y += 0.5; inner.size.height -= 0.5 }
            if !continuesBelow { inner.size.height -= 0.5 }
            ctx.addPath(bandOutline(inner, radius: max(0, radius - 0.5), openTop: continuesAbove, openBottom: continuesBelow))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The outline of a band to STROKE: both vertical edges, and the top / bottom edge (with its two rounded corners) only where the band really ends.
    /// Where it carries on (`openTop` / `openBottom`) there is no line: a piece of a block must not draw a line across the block.
    static func bandOutline(_ r: CGRect, radius rr: CGFloat, openTop: Bool, openBottom: Bool) -> CGPath {
        let rad = min(rr, min(r.width, r.height) / 2)
        let t = openTop ? 0 : rad, b = openBottom ? 0 : rad
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.maxY - b))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + t))
        if openTop {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
        } else {
            if t > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + t, y: r.minY), radius: t) }
            p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY))
            if t > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + t), radius: t) }
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
        if !openBottom {
            if b > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - b, y: r.maxY), radius: b) }
            p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
            if b > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - b), radius: b) }
        }
        return p
    }

    static func fillRounded(_ ctx: CGContext, rect: CGRect, radius: CGFloat, color: CGColor, leftOpen: Bool = false, rightOpen: Bool = false, border: CGColor? = nil) {
        ctx.saveGState()
        ctx.setFillColor(color)
        let r = min(radius, rect.height / 2)
        ctx.addPath(path(rect, topLeft: leftOpen ? 0 : r, topRight: rightOpen ? 0 : r, bottomRight: rightOpen ? 0 : r, bottomLeft: leftOpen ? 0 : r))
        ctx.fillPath()
        if let border, border.alpha > 0 {
            ctx.setStrokeColor(border)
            ctx.setLineWidth(1)
            ctx.addPath(openOutline(rect.insetBy(dx: 0.5, dy: 0.5), radius: max(0, r - 0.5), leftOpen: leftOpen, rightOpen: rightOpen))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// The outline of a rounded rect whose left and / or right end can be OPEN (a wrapped inline-code span: no vertical edge where the line breaks).
    static func openOutline(_ r: CGRect, radius rr: CGFloat, leftOpen: Bool, rightOpen: Bool) -> CGPath {
        if !leftOpen && !rightOpen { return path(r, topLeft: rr, topRight: rr, bottomRight: rr, bottomLeft: rr) }
        let p = CGMutablePath()
        // top edge, with the right corner and edge when the right end is closed
        if leftOpen { p.move(to: CGPoint(x: r.minX, y: r.minY)) }
        else { p.move(to: CGPoint(x: r.minX, y: r.minY + rr)); p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rr, y: r.minY), radius: rr) }
        if rightOpen {
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.move(to: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            p.addLine(to: CGPoint(x: r.maxX - rr, y: r.minY))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rr), radius: rr)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rr))
            p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rr, y: r.maxY), radius: rr)
        }
        // bottom edge back to the left; the left corner and edge when the left end is closed
        if leftOpen { p.addLine(to: CGPoint(x: r.minX, y: r.maxY)) }
        else {
            p.addLine(to: CGPoint(x: r.minX + rr, y: r.maxY))
            p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rr), radius: rr)
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + rr))
        }
        return p
    }

    static func fillRule(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, y: CGFloat, color: CGColor, scale: CGFloat) {
        let t = max(DecorationMetrics.ruleThickness, 1 / scale)
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x0, y: (y * scale).rounded() / scale - t / 2, width: x1 - x0, height: t))
        ctx.restoreGState()
    }

    /// The decoration colours resolved for one palette variant (cached: resolving the dynamic colours is not free).
    ///
    /// The BIG fills (bands, panels) are OPAQUE colours: the translucent tint composited over what is below it, which is always the opaque page
    /// colour and the bands drawn before (the drawing order is fixed). Measured: CoreGraphics blends a translucent fill at ~1.4 ns per pixel (a
    /// 860 x 1000 pt window full of bands: 2.5 ms per redraw), an opaque fill is 10x cheaper (0.1 - 0.25 ms) and looks the same.
    /// Small shapes (bars, pills) stay translucent.
    struct Colors {
        var codeBand: CGColor                 // code band over the page
        var quoteBand: CGColor                // quote band over the page
        var nested: [CGColor]                 // nested quote panel, index = quote level (2, 3); each over the previous level
        var codeInQuote: [CGColor]            // code panel inside a quote of depth d (index d = 1...3), over that quote's stack
        var panel: CGColor                    // table / front matter band over the page
        var tableHeader: CGColor              // header row over the panel
        var quoteBar: CGColor
        var pill: CGColor
        var rule: CGColor
        var border: CGColor

        /// Keyed by (scheme, variant): the colours of a scheme never change, so switching schemes back and forth recomputes nothing and never shows a stale entry.
        nonisolated(unsafe) private static var cache: [Int: Colors] = [:]

        init(appearance: NSAppearance) {
            let variant = Palette.variant(for: appearance)
            let key = Palette.serial * 4 + variant.rawValue
            if let c = Colors.cache[key] { self = c; return }
            typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
            func parts(_ c: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
                let s = c.usingColorSpace(.sRGB) ?? c
                return (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
            }
            func over(_ top: NSColor, _ base: RGB) -> RGB {
                let t = parts(top)
                return (t.r * t.a + base.r * (1 - t.a), t.g * t.a + base.g * (1 - t.a), t.b * t.a + base.b * (1 - t.a))
            }
            func cg(_ c: RGB) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
            var cb: CGColor = .black, qb: CGColor = .black, nest: [CGColor] = [], ciq: [CGColor] = [], pn: CGColor = .black, th: CGColor = .black
            var qr: CGColor = .black, pl: CGColor = .black, ru: CGColor = .black, bo: CGColor = .black
            appearance.performAsCurrentDrawingAppearance {
                let page = parts(Palette.background)
                let bg: RGB = (page.r, page.g, page.b)
                cb = cg(over(Palette.codeBand, bg))
                let q1 = over(Palette.quoteBand, bg)
                let q2 = over(Palette.nestedBand, q1), q3 = over(Palette.nestedBand, q2)
                qb = cg(q1)
                nest = [cg(q1), cg(q1), cg(q2), cg(q3)]                                  // index = level (0 and 1 unused)
                ciq = [cg(q1), cg(over(Palette.codeBand, q1)), cg(over(Palette.codeBand, q2)), cg(over(Palette.codeBand, q3))]
                let p = over(Palette.panelBand, bg)
                pn = cg(p)
                th = cg(over(Palette.tableHeaderBand, p))
                qr = Palette.quoteBar.cgColor
                pl = Palette.inlinePill.cgColor
                ru = Palette.rule.cgColor
                bo = Palette.bandBorder.cgColor
            }
            codeBand = cb; quoteBand = qb; nested = nest; codeInQuote = ciq; panel = pn; tableHeader = th; quoteBar = qr; pill = pl; rule = ru; border = bo
            Colors.cache[key] = self
        }
    }
}
