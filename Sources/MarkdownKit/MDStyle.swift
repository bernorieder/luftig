import Foundation

/// Composable style facets for one run of text.
///
/// The low 25 bits are independent facets. Bits 25...27 hold the heading level (0 = none, 1...6) and bits
/// 28...29 hold the block-quote nesting depth (0 = none, 1...3, saturating). `blockquote` is set whenever the
/// depth is > 0.
///
/// `marker` is an *additional* flag: syntax punctuation keeps the facets of the construct it belongs to
/// (e.g. the `**` of a bold span is `[bold, marker]`, the `#` of a heading is `h1 + marker`), so a theme can
/// decide whether dim punctuation should also take the construct's font traits.
public struct MDStyle: OptionSet, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt32
    @inline(__always) public init(rawValue: UInt32) { self.rawValue = rawValue }

    // Inline emphasis
    public static let bold            = MDStyle(rawValue: 1 << 0)
    public static let italic          = MDStyle(rawValue: 1 << 1)
    public static let strikethrough   = MDStyle(rawValue: 1 << 2)
    public static let inlineCode      = MDStyle(rawValue: 1 << 3)
    // Code blocks
    public static let codeBlock       = MDStyle(rawValue: 1 << 4)   // body lines of fenced / indented code
    public static let codeFence       = MDStyle(rawValue: 1 << 5)   // the ``` / ~~~ fence lines (including info string)
    public static let codeLanguage    = MDStyle(rawValue: 1 << 6)   // first word of the info string
    // Quote
    public static let blockquote      = MDStyle(rawValue: 1 << 7)   // inside a block quote (see quoteDepth)
    // Syntax punctuation
    public static let marker          = MDStyle(rawValue: 1 << 8)
    // Lists
    public static let listMarker      = MDStyle(rawValue: 1 << 9)   // "-", "*", "+", "1.", "1)"
    public static let taskMarker      = MDStyle(rawValue: 1 << 10)  // "[ ]" / "[x]"
    public static let taskChecked     = MDStyle(rawValue: 1 << 11)  // set in addition to taskMarker on "[x]"
    // Links
    public static let linkText        = MDStyle(rawValue: 1 << 12)
    public static let linkDestination = MDStyle(rawValue: 1 << 13)  // url and optional title
    public static let image           = MDStyle(rawValue: 1 << 14)  // whole ![alt](src)
    public static let autolink        = MDStyle(rawValue: 1 << 15)  // <https://x>, bare URLs, www.x
    // Tables
    public static let table           = MDStyle(rawValue: 1 << 16)  // any table row (cell content)
    public static let tableHeader     = MDStyle(rawValue: 1 << 17)  // header row (in addition to table)
    public static let tableDelimiter  = MDStyle(rawValue: 1 << 18)  // pipes and the |---|---| row
    // Misc blocks
    public static let horizontalRule  = MDStyle(rawValue: 1 << 19)
    public static let frontMatter     = MDStyle(rawValue: 1 << 20)
    public static let html            = MDStyle(rawValue: 1 << 21)  // HTML blocks, comments, inline HTML
    public static let escape          = MDStyle(rawValue: 1 << 22)  // backslash escapes and entities
    public static let footnote        = MDStyle(rawValue: 1 << 23)  // [^1] references and [^1]: definitions
    public static let referenceLabel  = MDStyle(rawValue: 1 << 24)  // [ref] of [text][ref] and "[ref]: url"

    static let headingShift: UInt32 = 25
    static let quoteShift: UInt32 = 28
    static let facetMask: UInt32 = (1 << 25) - 1
    static let headingMask: UInt32 = 7 << headingShift
    static let quoteMask: UInt32 = 3 << quoteShift

    /// Only the independent facets (no heading level / quote depth).
    public var facets: MDStyle { MDStyle(rawValue: rawValue & MDStyle.facetMask) }

    /// 0 = not a heading, 1...6 = ATX / setext heading level (including its text, markers and underline).
    public var headingLevel: Int {
        get { Int((rawValue & MDStyle.headingMask) >> MDStyle.headingShift) }
        set {
            let v = UInt32(max(0, min(6, newValue)))
            rawValue = (rawValue & ~MDStyle.headingMask) | (v << MDStyle.headingShift)
        }
    }

    /// 0 = not in a quote, 1...3 = nesting depth (saturating at 3). Setting > 0 also sets `.blockquote`.
    public var quoteDepth: Int {
        get { Int((rawValue & MDStyle.quoteMask) >> MDStyle.quoteShift) }
        set {
            let v = UInt32(max(0, min(3, newValue)))
            rawValue = (rawValue & ~MDStyle.quoteMask) | (v << MDStyle.quoteShift)
            if v > 0 { rawValue |= MDStyle.blockquote.rawValue } else { rawValue &= ~MDStyle.blockquote.rawValue }
        }
    }

    public static func heading(_ level: Int) -> MDStyle { var s = MDStyle(); s.headingLevel = level; return s }
    public static func quote(depth: Int) -> MDStyle { var s = MDStyle(); s.quoteDepth = depth; return s }

    // Internal fast constructors (raw bit arithmetic, no clamping).
    @inline(__always) static func headingBits(_ level: Int) -> UInt32 { UInt32(level) << headingShift }
    @inline(__always) static func quoteBits(_ depth: Int) -> UInt32 {
        depth == 0 ? 0 : ((1 << 7) | (UInt32(min(depth, 3)) << quoteShift))
    }

    static let facetNames: [(MDStyle, String)] = [
        (.bold, "bold"), (.italic, "italic"), (.strikethrough, "strike"), (.inlineCode, "code"),
        (.codeBlock, "codeblock"), (.codeFence, "fence"), (.codeLanguage, "lang"),
        (.marker, "marker"), (.listMarker, "list"), (.taskMarker, "task"), (.taskChecked, "checked"),
        (.linkText, "link"), (.linkDestination, "dest"), (.image, "image"), (.autolink, "auto"),
        (.table, "table"), (.tableHeader, "thead"), (.tableDelimiter, "tdelim"),
        (.horizontalRule, "hr"), (.frontMatter, "fm"), (.html, "html"), (.escape, "esc"),
        (.footnote, "fn"), (.referenceLabel, "ref"),
    ]

    /// Compact human-readable name, e.g. `h1·bold·marker`, `q2·code`. Empty style is "".
    public var description: String {
        var parts: [String] = []
        let h = headingLevel
        if h > 0 { parts.append("h\(h)") }
        let q = quoteDepth
        if q > 0 { parts.append("q\(q)") } else if contains(.blockquote) { parts.append("q") }
        for (f, n) in MDStyle.facetNames where contains(f) { parts.append(n) }
        return parts.joined(separator: "·")
    }
}

/// A run of text (UTF-16 range) with one style.
public struct MDRun: Equatable, Sendable {
    public var range: NSRange
    public var style: MDStyle
    @inline(__always) public init(range: NSRange, style: MDStyle) { self.range = range; self.style = style }
    @inline(__always) init(_ location: Int, _ end: Int, _ style: MDStyle) {
        self.range = NSRange(location: location, length: end - location)
        self.style = style
    }
}

/// Runs for a line-aligned range of the text. `runs` are ordered, non-overlapping, non-empty, fully partition
/// `range`, and adjacent runs with equal style are coalesced. Unstyled text has the empty style.
public struct MDResult: Sendable {
    public var range: NSRange
    public var runs: [MDRun]
    /// Only set by the bounded `update(afterEdit:changeInLength:of:maxRegion:)`: when the work limit was hit before
    /// the block state re-converged, attributes you applied earlier at or after this offset (post-edit
    /// coordinates) may be stale. The styler has forgotten everything beyond it; request those ranges again with
    /// `styleRuns(in:of:)` when they are needed (e.g. when they scroll into view).
    public var staleFrom: Int?
    public init(range: NSRange, runs: [MDRun], staleFrom: Int? = nil) {
        self.range = range; self.runs = runs; self.staleFrom = staleFrom
    }
}
