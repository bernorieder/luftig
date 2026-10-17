import Foundation
import MarkdownKit

// Differential testing against an independent CommonMark / GFM implementation: Foundation's
// `AttributedString(markdown:)` is built on cmark-gfm and is part of macOS, so it needs no extra dependency.
//
// Both sides are reduced to a stream of (character, flags) tokens - emphasis, strong, strike, code, link, image,
// code block, block quote, table, heading level - and the streams are compared. Syntax punctuation does not
// appear in the oracle's text, so on the lexer side every character carrying a "syntax" facet (marker, list
// marker, fence, destination, ...) is dropped. `alnumOnly` restricts the comparison to letters and digits, which
// makes it robust against whitespace, bullets, table pipes and the like when whole documents are compared.

struct OTok: Equatable {
    var c: UInt32
    var f: UInt16
    var off: Int32 = -1          // lexer side only: source offset (UTF-16), not part of equality
    static func == (a: OTok, b: OTok) -> Bool { a.c == b.c && a.f == b.f }
}

enum OFlag {
    static let em: UInt16 = 1, strong: UInt16 = 2, code: UInt16 = 4, strike: UInt16 = 8, link: UInt16 = 16, img: UInt16 = 32
    static let codeBlock: UInt16 = 64, quote: UInt16 = 128, table: UInt16 = 256
    static let headingShift: UInt16 = 9           // 3 bits
    static func names(_ f: UInt16) -> String {
        var p: [String] = []
        if f & em != 0 { p.append("em") }
        if f & strong != 0 { p.append("strong") }
        if f & code != 0 { p.append("code") }
        if f & strike != 0 { p.append("strike") }
        if f & link != 0 { p.append("link") }
        if f & img != 0 { p.append("img") }
        if f & codeBlock != 0 { p.append("codeblock") }
        if f & quote != 0 { p.append("quote") }
        if f & table != 0 { p.append("table") }
        let h = (f >> headingShift) & 7
        if h != 0 { p.append("h\(h)") }
        return p.isEmpty ? "plain" : p.joined(separator: "+")
    }
}

@inline(__always) func wanted(_ u: Unicode.Scalar, alnumOnly: Bool) -> Bool {
    if u.value < 128 {
        let v = u.value
        if alnumOnly { return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) }
        return v > 32 && v != 127
    }
    if alnumOnly { return u.properties.isAlphabetic || u.properties.numericType != nil }
    return !u.properties.isWhitespace
}

/// Oracle tokens, or nil when the parser rejects the text.
func oracleTokens(_ text: String, alnumOnly: Bool) -> [OTok]? {
    let opts = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let a = try? AttributedString(markdown: text, options: opts) else { return nil }
    var out: [OTok] = []
    for run in a.runs {
        var f: UInt16 = 0
        if let i = run.inlinePresentationIntent {
            if i.contains(.inlineHTML) || i.contains(.blockHTML) { continue }
            if i.contains(.emphasized) { f |= OFlag.em }
            if i.contains(.stronglyEmphasized) { f |= OFlag.strong }
            if i.contains(.code) { f |= OFlag.code }
            if i.contains(.strikethrough) { f |= OFlag.strike }
        }
        if run.link != nil { f |= OFlag.link }
        if run.imageURL != nil { f |= OFlag.img }
        var thematic = false
        if let p = run.presentationIntent {
            for comp in p.components {
                switch comp.kind {
                case .header(let level): f |= UInt16(min(6, level)) << OFlag.headingShift
                case .codeBlock: f |= OFlag.codeBlock
                case .blockQuote: f |= OFlag.quote
                case .table, .tableHeaderRow, .tableRow, .tableCell: f |= OFlag.table
                case .thematicBreak: thematic = true
                default: break
                }
            }
        }
        if thematic { continue }
        for u in String(a[run.range].characters).unicodeScalars where wanted(u, alnumOnly: alnumOnly) {
            out.append(OTok(c: u.value, f: f))
        }
    }
    return out
}

/// Lexer tokens in the same space. `markerFacets` are dropped (they do not occur in a renderer's text).
func lexerTokens(_ text: NSString, _ runs: [MDRun], alnumOnly: Bool) -> [OTok] {
    var out: [OTok] = []
    let drop: MDStyle = [.marker, .listMarker, .codeFence, .horizontalRule, .frontMatter, .html, .linkDestination, .referenceLabel, .tableDelimiter, .footnote]
    for r in runs {
        let s = r.style
        if !s.isDisjoint(with: drop) { continue }
        var f: UInt16 = 0
        if s.contains(.bold) { f |= OFlag.strong }
        if s.contains(.italic) { f |= OFlag.em }
        if s.contains(.strikethrough) { f |= OFlag.strike }
        if s.contains(.inlineCode) { f |= OFlag.code }
        if s.contains(.linkText) || s.contains(.autolink) { f |= OFlag.link }
        if s.contains(.image) { f |= OFlag.img }
        if s.contains(.codeBlock) { f |= OFlag.codeBlock }
        if s.quoteDepth > 0 { f |= OFlag.quote }
        if s.contains(.table) { f |= OFlag.table }
        f |= UInt16(s.headingLevel) << OFlag.headingShift
        var off = r.range.location
        let scalars = Array(text.substring(with: r.range).unicodeScalars)
        var k = 0
        let esc = s.contains(.escape)
        while k < scalars.count {
            let u = scalars[k]
            let w = u.value > 0xFFFF ? 2 : 1
            if esc && u == "\\" {                                              // backslash of an escape: syntax; the next character is visible text
                off += 1; k += 1
                if k < scalars.count {
                    let v = scalars[k]
                    if wanted(v, alnumOnly: alnumOnly) { out.append(OTok(c: v.value, f: f, off: Int32(off))) }
                    off += v.value > 0xFFFF ? 2 : 1; k += 1
                }
                continue
            }
            if esc && u == "&" {                                                // entity: decoded text unknown here, skipped
                while k < scalars.count && scalars[k] != ";" { off += scalars[k].value > 0xFFFF ? 2 : 1; k += 1 }
                if k < scalars.count { off += 1; k += 1 }
                continue
            }
            if wanted(u, alnumOnly: alnumOnly) { out.append(OTok(c: u.value, f: f, off: Int32(off))) }
            off += w; k += 1
        }
    }
    return out
}

/// Foundation's attribute conversion drops an emphasis flag from the rest of an outer span once an inner span of the SAME
/// kind has closed (`_foo _bar_ baz_` loses the emphasis on ` baz`). Wherever the lexer has such a span and the oracle
/// agreed on an earlier token of it, a missing flag later in the same lexer span is tolerated.
func tolerateOracleNesting(_ o: [OTok], _ l: [OTok]) -> [OTok] {
    guard o.count == l.count else { return o }
    var out = o
    for flag in [OFlag.em, OFlag.strong] {
        var agreed = false
        for i in 0..<l.count {
            if l[i].f & flag == 0 { agreed = false; continue }
            if o[i].c != l[i].c { return o }
            if o[i].f & flag != 0 { agreed = true } else if agreed { out[i].f |= flag }
        }
    }
    return out
}

struct TokDiff {
    var oracle: ArraySlice<OTok>
    var lexer: ArraySlice<OTok>
    var lexerOffset: Int          // source offset of the first lexer token in / after the region, -1 if unknown
}

/// Greedy resynchronising diff (windows of `k` equal tokens re-align the streams).
func diffTokens(_ a: [OTok], _ b: [OTok], k: Int = 6, window: Int = 2500) -> [TokDiff] {
    var out: [TokDiff] = []
    var i = 0, j = 0
    func key(_ t: [OTok], _ p: Int) -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for q in p..<(p + k) { h = (h ^ UInt64(t[q].c)) &* 1099511628211; h = (h ^ UInt64(t[q].f)) &* 1099511628211 }
        return h
    }
    while i < a.count && j < b.count {
        if a[i] == b[j] { i += 1; j += 1; continue }
        let i0 = i, j0 = j
        // build a table of windows of b near j
        var table: [UInt64: Int] = [:]
        let jEnd = min(b.count - k, j + window)
        if j <= jEnd { for q in j...jEnd where table[key(b, q)] == nil { table[key(b, q)] = q } }
        var found = false
        let iEnd = min(a.count - k, i + window)
        if i <= iEnd {
            for p in i...iEnd {
                if let q = table[key(a, p)], Array(a[p..<(p + k)]) == Array(b[q..<(q + k)]) {
                    out.append(TokDiff(oracle: a[i0..<p], lexer: b[j0..<q], lexerOffset: q > j0 ? Int(b[j0].off) : (j0 < b.count ? Int(b[j0].off) : -1)))
                    i = p; j = q; found = true
                    break
                }
            }
        }
        if !found {
            out.append(TokDiff(oracle: a[i0...], lexer: b[j0...], lexerOffset: Int(b[j0].off)))
            return out
        }
    }
    if i < a.count || j < b.count {
        out.append(TokDiff(oracle: a[min(i, a.count)...], lexer: b[min(j, b.count)...], lexerOffset: j < b.count ? Int(b[j].off) : -1))
    }
    return out
}

func tokString(_ t: ArraySlice<OTok>, max n: Int = 60) -> String {
    var s = ""
    var lastF: UInt16 = 0xFFFF
    var count = 0
    for x in t {
        if x.f != lastF { s += "⟦\(OFlag.names(x.f))⟧"; lastF = x.f }
        s.unicodeScalars.append(Unicode.Scalar(x.c) ?? "?")
        count += 1
        if count >= n { s += "…"; break }
    }
    return s
}

// MARK: - Synthetic inline differential fuzz

enum InlineSoup {
    static let words = ["a", "bc", "foo", "x1", "é", "日本", "я", "Q", "ab_c"]
    static let punct = [".", ",", "!", "?", ":", ";", "-", "'", "\"", "(", ")", "/", "+", "=", "%", "@"]
    static let delims = ["*", "**", "***", "_", "__", "___", "`", "``", "[", "]", "](", "![", ")", "*", "_", "**", "__"]
    static let escapes = ["\\*", "\\_", "\\[", "\\`", "\\]"]

    static func paragraph(_ r: inout RNG) -> String {
        let nLines = r.chance(0.7) ? 1 : r.range(2, 3)
        var lines: [String] = []
        for _ in 0..<nLines {
            var s = "w"
            for _ in 0..<r.range(2, 16) {
                let k = r.int(100)
                if k < 28 { s += r.pick(words) }
                else if k < 38 { s += r.pick(punct) }
                else if k < 72 { s += r.pick(delims) }
                else if k < 76 { s += r.pick(escapes) }
                else { s += " " }
                if r.chance(0.35) { s += " " }
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs `count` random inline paragraphs through both implementations. Returns the mismatching cases.
func runInlineOracleFuzz(count: Int, seed: UInt64, verbose: Bool) -> [(String, [TokDiff])] {
    var rng = RNG(seed: seed)
    var bad: [(String, [TokDiff])] = []
    var compared = 0, rejected = 0
    let styler = MarkdownStyler()
    for _ in 0..<count {
        let p = InlineSoup.paragraph(&rng)
        if skipInlineCase(p) { continue }
        guard let o = oracleTokens(p, alnumOnly: false) else { rejected += 1; continue }
        let t = NSString(string: p)
        let l = lexerTokens(t, styler.lexAll(t), alnumOnly: false)
        compared += 1
        if tolerateOracleNesting(o, l) != l {
            let d = diffTokens(o, l, k: 4, window: 200)
            if !d.isEmpty { bad.append((p, d)) }
        }
    }
    if verbose { print("inline oracle fuzz seed \(seed): \(compared) paragraphs compared, \(rejected) rejected by the oracle, \(bad.count) mismatches") }
    return bad
}
