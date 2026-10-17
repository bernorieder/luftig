import AppKit

// MARK: - Colors

enum Palette {
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let marker = dynamicColor(light: NSColor(white: 0.62, alpha: 1), dark: NSColor(white: 0.45, alpha: 1))
    static let heading = dynamicColor(light: NSColor(srgbRed: 0.10, green: 0.15, blue: 0.35, alpha: 1),
                                      dark: NSColor(srgbRed: 0.62, green: 0.76, blue: 1.0, alpha: 1))
    static let link = dynamicColor(light: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.80, alpha: 1),
                                   dark: NSColor(srgbRed: 0.40, green: 0.65, blue: 1.0, alpha: 1))
    static let linkDest = dynamicColor(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.5, alpha: 1))
    static let codeText = dynamicColor(light: NSColor(srgbRed: 0.55, green: 0.18, blue: 0.10, alpha: 1),
                                       dark: NSColor(srgbRed: 0.96, green: 0.68, blue: 0.50, alpha: 1))
    static let inlineCodeText = dynamicColor(light: NSColor(srgbRed: 0.70, green: 0.15, blue: 0.40, alpha: 1),
                                             dark: NSColor(srgbRed: 1.0, green: 0.55, blue: 0.70, alpha: 1))
    static let quoteText = dynamicColor(light: NSColor(white: 0.32, alpha: 1), dark: NSColor(white: 0.72, alpha: 1))
    static let listMarker = dynamicColor(light: NSColor(srgbRed: 0.80, green: 0.35, blue: 0.0, alpha: 1),
                                         dark: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1))
    static let comment = dynamicColor(light: NSColor(srgbRed: 0.35, green: 0.55, blue: 0.35, alpha: 1),
                                      dark: NSColor(srgbRed: 0.45, green: 0.70, blue: 0.45, alpha: 1))
}

// MARK: - Theme

final class Theme {
    let bodySize: CGFloat
    /// If set, every non-heading line gets min == max line height of this value (stable heights while styling lazily).
    let uniformLineHeight: CGFloat?
    /// If true headings also get fixed line heights (per level) instead of font-natural ones.
    let uniformHeadings: Bool

    let bodyFont: NSFont
    let monoFont: NSFont
    private var cache: [UInt32: [NSAttributedString.Key: Any]] = [:]
    private var fontCache: [String: NSFont] = [:]
    private var pStyleCache: [UInt32: NSParagraphStyle] = [:]

    static let headingScale: [CGFloat] = [1.0, 1.75, 1.45, 1.25, 1.1, 1.0, 1.0]

    init(bodySize: CGFloat = 15, uniformLineHeight: CGFloat? = nil, uniformHeadings: Bool = false) {
        self.bodySize = bodySize
        self.uniformLineHeight = uniformLineHeight
        self.uniformHeadings = uniformHeadings
        bodyFont = NSFont.systemFont(ofSize: bodySize)
        monoFont = NSFont.monospacedSystemFont(ofSize: bodySize * 0.9, weight: .regular)
    }

    /// Attributes a text view needs just to display the document before any run is applied.
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: Palette.text, .paragraphStyle: paragraphStyle(for: 0)]
    }

    func font(base: NSFont, bold: Bool, italic: Bool, size: CGFloat, weight: NSFont.Weight?) -> NSFont {
        let key = "\(base.fontName)|\(bold)|\(italic)|\(size)|\(weight?.rawValue ?? -99)"
        if let f = fontCache[key] { return f }
        var f: NSFont
        if base.isFixedPitch {
            f = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : (weight ?? .regular))
        } else {
            f = NSFont.systemFont(ofSize: size, weight: bold ? .bold : (weight ?? .regular))
        }
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: size) ?? f
        }
        fontCache[key] = f
        return f
    }

    func headingLineHeight(_ level: Int) -> CGFloat {
        let lh = uniformLineHeight ?? 21
        switch level {
        case 1: return (lh * 1.75).rounded()
        case 2: return (lh * 1.45).rounded()
        case 3: return (lh * 1.25).rounded()
        case 4: return (lh * 1.12).rounded()
        default: return lh
        }
    }

    func paragraphStyle(for lineBits: UInt32) -> NSParagraphStyle {
        if let p = pStyleCache[lineBits] { return p }
        let p = NSMutableParagraphStyle()
        let level = Int(lineBits & S.headingMask)
        if level > 0 {
            if uniformHeadings || uniformLineHeight != nil {
                let h = uniformHeadings ? headingLineHeight(level) : (uniformLineHeight ?? 21) * Theme.headingScale[level]
                p.minimumLineHeight = h; p.maximumLineHeight = h
            }
            p.paragraphSpacingBefore = level <= 2 ? 10 : 6
            p.paragraphSpacing = 2
        } else {
            if let lh = uniformLineHeight { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
            if lineBits & S.quote != 0 { p.firstLineHeadIndent = 18; p.headIndent = 18 }
            if lineBits & S.codeBlock != 0 { p.firstLineHeadIndent = 4; p.headIndent = 4 }
        }
        pStyleCache[lineBits] = p
        return p
    }

    func attrs(_ style: UInt32) -> [NSAttributedString.Key: Any] {
        if let a = cache[style] { return a }
        let level = Int(style & S.headingMask)
        let isBold = style & S.bold != 0
        let isItalic = style & S.italic != 0
        var d: [NSAttributedString.Key: Any] = [:]
        var color = Palette.text

        if style & (S.codeBlock | S.inlineCode) != 0 {
            d[.font] = font(base: monoFont, bold: isBold && style & S.codeBlock == 0, italic: isItalic && style & S.codeBlock == 0, size: monoFont.pointSize, weight: nil)
            color = style & S.codeBlock != 0 ? Palette.codeText : Palette.inlineCodeText
        } else if level > 0 {
            let size = (bodySize * Theme.headingScale[level]).rounded()
            d[.font] = font(base: bodyFont, bold: true, italic: isItalic, size: size, weight: level >= 3 ? .semibold : .bold)
            color = Palette.heading
        } else {
            d[.font] = font(base: bodyFont, bold: isBold, italic: isItalic, size: bodySize, weight: nil)
            if style & S.quote != 0 { color = Palette.quoteText }
            if style & S.linkText != 0 { color = Palette.link }
            if style & S.linkDest != 0 { color = Palette.linkDest }
            if style & S.comment != 0 { color = Palette.comment }
            if style & S.listMarker != 0 { color = Palette.listMarker }
        }
        if style & S.marker != 0 { color = (style & S.listMarker != 0) ? Palette.listMarker : Palette.marker }
        if style & S.fence != 0 { color = Palette.marker }
        d[.foregroundColor] = color
        if style & S.strike != 0 { d[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style & S.linkText != 0 { d[.underlineStyle] = NSUnderlineStyle.single.rawValue; d[.underlineColor] = Palette.link.withAlphaComponent(0.4) }
        d[.paragraphStyle] = paragraphStyle(for: style & S.lineLevelMask)
        if style & S.codeBlock != 0 { d[.scribeBlock] = NSNumber(value: BlockKind.code.rawValue) }
        else if style & S.quote != 0 { d[.scribeBlock] = NSNumber(value: BlockKind.quote.rawValue) }
        else if style & S.rule != 0 { d[.scribeBlock] = NSNumber(value: BlockKind.rule.rawValue) }
        if style & S.inlineCode != 0 { d[.scribeInline] = NSNumber(value: 1) }
        cache[style] = d
        return d
    }
}
