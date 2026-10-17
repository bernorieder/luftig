import Foundation

/// Leaf state that survives across lines.
enum Leaf {
    static let none: UInt8 = 0
    static let fenced: UInt8 = 1
    static let html: UInt8 = 2
    static let frontMatter: UInt8 = 3
    static let table: UInt8 = 4
    /// An indented code block is open: the last non-blank line was indented code. Blank lines keep it open
    /// *provisionally* (see `Lexer.pendBlanks`): they belong to the block only if another code line follows.
    static let indentedCode: UInt8 = 5
}

/// Compact block state at a line start with no pending paragraph. This is *everything* the lexer needs to
/// resume at that line (a pure function of the text before it). Equatable so that incremental re-lexing can
/// detect re-convergence.
struct BlockState: Equatable {
    var leaf: UInt8 = Leaf.none
    /// fenced: fence character ('`' or '~'); html: end-condition type 1...7
    var leafKind: UInt8 = 0
    /// fenced: opening fence length
    var fenceLen: UInt16 = 0
    /// The previous line was paragraph text (even if its lines were already flushed by the paragraph cap).
    var inPara: Bool = false
    /// The previous line opened an empty list item (a marker with nothing after it) as the innermost container and nothing has
    /// followed yet: a blank line now closes that item instead of keeping it open.
    var emptyItem: Bool = false
    var ccount: UInt8 = 0
    /// Container stack, 8 bits each, 16 entries: 0x80 = block quote, 1...127 = list item content column.
    var c0: UInt64 = 0
    var c1: UInt64 = 0

    static let maxContainers = 16

    @inline(__always) func container(_ i: Int) -> UInt8 {
        i < 8 ? UInt8(truncatingIfNeeded: c0 >> UInt64(8 * i)) : UInt8(truncatingIfNeeded: c1 >> UInt64(8 * (i - 8)))
    }

    @inline(__always) mutating func push(_ v: UInt8) {
        let i = Int(ccount)
        if i < 8 { c0 |= UInt64(v) << UInt64(8 * i) } else { c1 |= UInt64(v) << UInt64(8 * (i - 8)) }
        ccount += 1
    }

    /// Drop containers so that `n` remain.
    mutating func truncate(to n: Int) {
        guard n < Int(ccount) else { return }
        if n <= 0 { c0 = 0; c1 = 0 }
        else if n < 8 { c0 &= (UInt64(1) << UInt64(8 * n)) &- 1; c1 = 0 }
        else if n == 8 { c1 = 0 }
        else { c1 &= (UInt64(1) << UInt64(8 * (n - 8))) &- 1 }
        ccount = UInt8(n)
    }

    var hasListItem: Bool {
        var i = 0
        let n = Int(ccount)
        while i < n { if container(i) & 0x80 == 0 { return true }; i += 1 }
        return false
    }

    var quoteCount: Int {
        var i = 0, q = 0
        let n = Int(ccount)
        while i < n { if container(i) & 0x80 != 0 { q += 1 }; i += 1 }
        return q
    }

    mutating func clearLeaf() { leaf = Leaf.none; leafKind = 0; fenceLen = 0 }
}

/// Resume point: lexing may restart at `offset` with `state` and an empty pending paragraph.
/// `validAfter` is `offset` for ordinary checkpoints. A checkpoint taken at the first line of a paragraph that
/// itself closed the previous paragraph ("weak" checkpoint) depends on that line's classification, so it is
/// only a valid restart point for edits at or after `validAfter` (the end of that line).
struct Checkpoint {
    var offset: Int
    var state: BlockState
    var validAfter: Int
    init(offset: Int, state: BlockState, validAfter: Int? = nil) {
        self.offset = offset; self.state = state; self.validAfter = validAfter ?? offset
    }
}

/// Character classification tables, shared and immutable.
final class CharTables {
    /// 0 = nothing special for the inline lexer, otherwise a small code (see Inline.swift).
    let inlineClass: UnsafeMutablePointer<UInt8>
    /// For flanking: 0 = other, 1 = whitespace, 2 = punctuation
    let uniClassASCII: UnsafeMutablePointer<UInt8>

    static let shared = CharTables()

    private init() {
        inlineClass = .allocate(capacity: 128)
        inlineClass.initialize(repeating: 0, count: 128)
        uniClassASCII = .allocate(capacity: 128)
        uniClassASCII.initialize(repeating: 0, count: 128)
        for c in 0..<128 {
            let u = UInt8(c)
            let isWS = u == 32 || u == 9 || u == 10 || u == 13 || u == 11 || u == 12
            let isAlnum = (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
            if isWS { uniClassASCII[c] = 1 }
            else if !isAlnum && u > 32 && u < 127 { uniClassASCII[c] = 2 }
            else if u < 32 || u == 127 { uniClassASCII[c] = 1 }   // control characters: treat as whitespace
        }
        for ch in "\\`*_~[]!<&:.".utf8 { inlineClass[Int(ch)] = 1 }
    }
}

@inline(__always) func isSpaceOrTab(_ c: UInt16) -> Bool { c == 32 || c == 9 }
@inline(__always) func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
@inline(__always) func isAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
@inline(__always) func isAlnum(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) }
@inline(__always) func isASCIIPunct(_ c: UInt16) -> Bool {
    (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
}
@inline(__always) func lower(_ c: UInt16) -> UInt16 { (c >= 65 && c <= 90) ? c + 32 : c }

/// Unicode class of one scalar for emphasis flanking (CommonMark 0.31): 1 = Unicode whitespace (category Zs; tab, LF, FF and CR are
/// handled by the ASCII table), 2 = Unicode punctuation (categories P and S), 0 = anything else. Asked from the Unicode data of the
/// runtime, never from hand-written ranges; the lexer caches the answer per BMP scalar (see `Lexer.clsAt`).
func unicodeClass(_ cp: UInt32) -> UInt8 {
    guard let u = Unicode.Scalar(cp) else { return 0 }
    switch u.properties.generalCategory {
    case .spaceSeparator: return 1
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return 2
    default: return 0
    }
}

// MARK: - HTML block names (CommonMark type 6)

enum HTMLNames {
    static let blockNames: [[UInt8]] = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul",
    ].map { Array($0.utf8) }
    static let rawNames: [[UInt8]] = ["script", "pre", "style", "textarea"].map { Array($0.utf8) }
}
