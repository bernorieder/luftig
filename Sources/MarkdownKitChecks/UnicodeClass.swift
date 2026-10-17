import Foundation
import MarkdownKit

// `mdkit-checks --unicode-class`: the lexer approximates CommonMark's "Unicode whitespace" and "Unicode punctuation" (categories P and S)
// with range tables. This asks the lexer - through the public API, by looking at how a `*` next to the character flanks - which class it
// assigns to every scalar of the first three planes and compares it with the real general category.

private func lexerClass(_ s: String, _ styler: MarkdownStyler) -> Int {
    // 0 = other, 1 = whitespace, 2 = punctuation / symbol
    func italic(_ t: String) -> Bool {
        let n = t as NSString
        return styler.lexAll(n).contains { $0.style.contains(.italic) }
    }
    if italic("a*" + s + "b*c") { return 0 }          // left-flanking after a letter: only a character that is neither space nor punctuation
    if italic("a*b" + s + "* c") { return 2 }         // right-flanking before a space: any non-space character
    return 1
}

private func trueClass(_ u: Unicode.Scalar) -> Int {
    switch u.properties.generalCategory {
    case .spaceSeparator: return 1
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return 2
    default: return (u.value == 9 || u.value == 10 || u.value == 12 || u.value == 13) ? 1 : 0
    }
}

@discardableResult
func runUnicodeClassCheck(upTo limit: UInt32 = 0x30000, show: Int = 80, quiet: Bool = false) -> Int {
    let styler = MarkdownStyler()
    var mismatches: [(UInt32, Int, Int)] = []
    var checked = 0
    var v: UInt32 = 0x20
    while v < limit {
        defer { v += 1 }
        if v >= 0xD800 && v < 0xE000 { continue }
        guard let u = Unicode.Scalar(v) else { continue }
        if v < 0x80 { continue }                              // ASCII is exercised by the whole suite
        let tc = trueClass(u), s = String(Character(u))
        // unassigned / private-use / control characters are irrelevant
        let gc = u.properties.generalCategory
        if gc == .unassigned || gc == .privateUse || gc == .control || gc == .format || gc == .surrogate { continue }
        checked += 1
        let lc = lexerClass(s, styler)
        if lc != tc { mismatches.append((v, lc, tc)) }
    }
    if quiet { return mismatches.count }
    print("unicode class check: \(checked) scalars compared, \(mismatches.count) mismatches (lexer class vs general category; 0 other, 1 space, 2 punctuation / symbol)")
    // summarise as ranges of the same (lexer, true) pair
    var ranges: [(UInt32, UInt32, Int, Int)] = []
    for (c, l, t) in mismatches {
        if let last = ranges.last, last.2 == l, last.3 == t, c <= last.1 + 3 { ranges[ranges.count - 1].1 = c } else { ranges.append((c, c, l, t)) }
    }
    for r in ranges.prefix(show) {
        let name = Unicode.Scalar(r.0)?.properties.name ?? "?"
        print(String(format: "  U+%04X...U+%04X  lexer %d, category says %d   (%@)", r.0, r.1, r.2, r.3, name as NSString))
    }
    if ranges.count > show { print("  ... \(ranges.count - show) more ranges") }
    return mismatches.count
}
