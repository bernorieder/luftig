import AppKit

// Shared between the TextKit 1 and TextKit 2 decoration renderers.
//
// The style runs (lexer -> Theme.attrs) only set two custom attributes:
//   .scribeBlock  = NSNumber(BlockKind.rawValue)   on every character of a code-block / quote / rule LINE (incl. its "\n")
//   .scribeInline = NSNumber(1)                      on the characters of an inline code span (incl. the backticks)
// Everything else (band geometry, rounding, colours) lives in the renderers.

extension NSAttributedString.Key {
    static let scribeBlock = NSAttributedString.Key("scribe.block")
    static let scribeInline = NSAttributedString.Key("scribe.inline")
}

func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

/// Decoration colours: translucent on purpose (the selection highlight and the text stay readable whatever the paint order).
enum DecorationPalette {
    static let codeBand = dynamicColor(light: NSColor(white: 0.0, alpha: 0.055), dark: NSColor(white: 1.0, alpha: 0.075))
    static let quoteBand = dynamicColor(light: NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 0.07),
                                        dark: NSColor(srgbRed: 1.0, green: 0.70, blue: 0.25, alpha: 0.08))
    static let quoteBar = dynamicColor(light: NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 0.85),
                                       dark: NSColor(srgbRed: 1.0, green: 0.70, blue: 0.25, alpha: 0.85))
    static let inlinePill = dynamicColor(light: NSColor(white: 0.0, alpha: 0.075), dark: NSColor(white: 1.0, alpha: 0.13))
    static let rule = dynamicColor(light: NSColor(white: 0.0, alpha: 0.28), dark: NSColor(white: 1.0, alpha: 0.30))
}

enum BlockKind: Int {
    case code = 1
    case quote = 2
    case rule = 3
}

/// Geometry constants, in points. All values are relative to the text container (text column).
enum DecorationMetrics {
    /// Bands extend this far to the left and right of the text column (into the text container inset).
    /// Requires textContainerInset.width >= bandOutset (+ a couple of points).
    static var bandOutset: CGFloat = 8
    static var bandCornerRadius: CGFloat = 6
    static var quoteBarWidth: CGFloat = 3
    static var inlinePillRadius: CGFloat = 4
    static var inlinePillHPad: CGFloat = 2.5
    static var inlinePillVPad: CGFloat = 1.5
    static var ruleThickness: CGFloat = 1
}

enum DecorationDrawing {
    /// Rounded rect path where only the top and/or bottom corner pairs are rounded (y grows downwards: view is flipped).
    static func bandPath(_ r: CGRect, radius: CGFloat, roundTop: Bool, roundBottom: Bool) -> CGPath {
        let rt = roundTop ? min(radius, r.height / 2, r.width / 2) : 0
        let rb = roundBottom ? min(radius, r.height / 2, r.width / 2) : 0
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + rt, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rt, y: r.minY))
        if rt > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rt), radius: rt) }
        else { p.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rb))
        if rb > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rb, y: r.maxY), radius: rb) }
        else { p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX + rb, y: r.maxY))
        if rb > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rb), radius: rb) }
        else { p.addLine(to: CGPoint(x: r.minX, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rt))
        if rt > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rt, y: r.minY), radius: rt) }
        else { p.addLine(to: CGPoint(x: r.minX, y: r.minY)) }
        p.closeSubpath()
        return p
    }

    /// Fill a block band. `continuesAbove/Below` means the block carries on beyond this piece, so that side is square
    /// (adjacent pieces then meet seamlessly, no matter how the view was invalidated).
    static func fillBand(_ ctx: CGContext, rect: CGRect, color: CGColor, continuesAbove: Bool, continuesBelow: Bool) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(bandPath(rect, radius: DecorationMetrics.bandCornerRadius, roundTop: !continuesAbove, roundBottom: !continuesBelow))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func fillRounded(_ ctx: CGContext, rect: CGRect, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func fillRule(_ ctx: CGContext, x0: CGFloat, x1: CGFloat, y: CGFloat, color: CGColor, scale: CGFloat) {
        let t = max(DecorationMetrics.ruleThickness, 1 / scale)
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x0, y: (y * scale).rounded() / scale - t / 2, width: x1 - x0, height: t))
        ctx.restoreGState()
    }

    /// Resolve dynamic colours for the given appearance.
    struct Colors {
        var codeBand: CGColor
        var quoteBand: CGColor
        var quoteBar: CGColor
        var pill: CGColor
        var rule: CGColor

        init(appearance: NSAppearance) {
            var cb: CGColor = .black, qb: CGColor = .black, qr: CGColor = .black, pl: CGColor = .black, ru: CGColor = .black
            appearance.performAsCurrentDrawingAppearance {
                cb = DecorationPalette.codeBand.cgColor
                qb = DecorationPalette.quoteBand.cgColor
                qr = DecorationPalette.quoteBar.cgColor
                pl = DecorationPalette.inlinePill.cgColor
                ru = DecorationPalette.rule.cgColor
            }
            codeBand = cb; quoteBand = qb; quoteBar = qr; pill = pl; rule = ru
        }
    }
}
