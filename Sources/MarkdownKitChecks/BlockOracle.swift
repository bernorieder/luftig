import Foundation
import MarkdownKit

// Block-structure differential fuzz against cmark-gfm (Foundation): random documents built from block starters, compared on
// the letters / digits they contain plus code block / quote / table / heading-level flags (see Oracle.swift).

enum BlockSoup {
    static let blocks = [
        "# Title", "## Sub", "### ", "#", "####### seven", "#nospace", "# closing ##", "###### six #",
        "> quote", ">> nested", "> ", ">", "> - item in quote", "> > deep", ">     code in quote",
        "- item", "* item", "+ item", "1. one", "2) two", "10. ten", "- [ ] task", "- [x] done", "  - nested", "    - deeper",
        "-", "1.", "- ", "   - three", "      - six", "1. - mixed", "- > quote in list", "- # heading in list", "- ```", "  ```",
        "```", "```swift", "~~~", "~~~~~", "````", "``` x `", "  ```", "> ```", "- ~~~ lang",
        "---", "***", "___", "- - -", "* * *", "===", "--", "==",
        "<div>", "</div>", "<!--", "-->", "<pre>", "</pre>", "<br>", "<?php", "?>", "<img src=x>", "<script>", "</script>", "<p>", "<custom-tag>",
        "    code", "\tcode", "        deep", "  two", "   three",
        "[r]: http://x.com", "[r]: <u> 'title'", "[bad]: x y z",
    ]
    /// Well-formed GFM tables (header, delimiter row, rows with the same number of cells); optionally followed by prose.
    static let tables = [
        "| a | b |\n|---|---|\n| 1 | 2 |", "a | b\n--- | ---\n1 | 2", "| a |\n|:-:|\n| x |\n| y |", "| `c\\|d` | e |\n|:--|--:|\n| f | g |",
        "x | y | z\n--|:-:|--:\n1 | 2 | 3\nmore | 4 | 5", "| a | b |\n|---|---|", "| h1 | h2 |\n| -- | -- |\n| **b** | `c` |\n\ntext after",
    ]
    static let paras = [
        "Some plain text here", "text with *em* and **strong** words", "`code` and ``dou`ble`` ticks", "[link](http://x.com 'title') end",
        "![img](a.png) alt", "<https://a.b/c> and more", "tab\tinside", "word", "two words", "a_b_c snake", "line  ", "emoji 😀 text", "日本語のテキスト",
    ]
    static func document(_ r: inout RNG) -> String {
        var s: [String] = []
        for _ in 0..<r.range(2, 12) {
            let k = r.int(100)
            if k < 14 { s.append("") }
            else if k < 20 { s.append(String(repeating: " ", count: r.range(1, 6)) + r.pick(paras)) }
            else if k < 62 { s.append(r.pick(blocks)) }
            else if k < 66 { s.append(r.pick(tables)); if r.chance(0.6) { s.append("") } }
            else if k < 72 { s.append(r.pick(blocks) + " " + r.pick(paras)) }
            else { s.append(r.pick(paras)) }
        }
        var t: [String] = []
        for (i, l) in s.enumerated() {
            t.append(l)
            if l.hasPrefix("[r]:") || l.hasPrefix("[bad]:") { t.append("") }
            _ = i
        }
        s = t
        return s.joined(separator: "\n") + (r.chance(0.8) ? "\n" : "")
    }
}

private let blockMask: UInt16 = OFlag.codeBlock | OFlag.quote | OFlag.table | (7 << OFlag.headingShift)

func blockTokens(_ text: String, _ styler: MarkdownStyler) -> ([OTok], [OTok])? {
    guard var o = oracleTokens(text, alnumOnly: true) else { return nil }
    let t = NSString(string: text)
    var l = lexerTokens(t, styler.lexAll(t), alnumOnly: true)
    for i in 0..<o.count { o[i].f &= blockMask }
    for i in 0..<l.count { l[i].f &= blockMask }
    return (o, l)
}

/// Documents exercising documented deviations rather than defects: front matter, a one-character setext underline
/// (`a` / `-`), a link reference definition whose destination is on the next line, and a lone HTML tag (`<br>`) directly after a
/// list item / quote line (a lazy continuation line: the lexer follows the spec and commonmark.js, cmark starts an HTML block).
func skipBlockCase(_ text: String) -> Bool {
    if text.hasPrefix("---") { return true }
    var container = false          // a list item / quote line has been seen since the last blank line
    var sawContainer = false       // ... or earlier in the document (an indented line after a blank line still belongs to the item)
    for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "-" || t == "=" { return true }
        if t.hasPrefix("[") && t.hasSuffix("]:") { return true }
        if t.isEmpty { container = false; continue }
        if t.hasPrefix("<") && t.hasSuffix(">") && t.filter({ $0 == "<" }).count == 1 && container { return true }
        if t.hasPrefix(">") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") || t.first.map({ $0.isNumber }) == true || (line.hasPrefix("  ") && sawContainer) { container = true; sawContainer = true }
    }
    return false
}

func blockMismatch(_ text: String, _ styler: MarkdownStyler) -> Bool {
    if skipBlockCase(text) { return false }
    guard let (o, l) = blockTokens(text, styler) else { return false }
    return o != l
}

/// `mdkit-checks --block-fuzz <documents> <seed> [show]`
func runBlockOracleFuzzCommand(count: Int, seed: UInt64, show: Int) {
    var rng = RNG(seed: seed)
    let styler = MarkdownStyler()
    var bad: [String] = []
    for _ in 0..<count {
        let d = BlockSoup.document(&rng)
        if blockMismatch(d, styler) { bad.append(d) }
    }
    print("block oracle fuzz seed \(seed): \(count) documents, \(bad.count) mismatches")
    var seen = Set<String>()
    var shown = 0
    for d in bad {
        if shown >= show { break }
        // minimise: drop lines, then characters
        var lines = d.components(separatedBy: "\n")
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < lines.count {
                var cand = lines; cand.remove(at: i)
                if !cand.isEmpty && blockMismatch(cand.joined(separator: "\n"), styler) { lines = cand; changed = true } else { i += 1 }
            }
        }
        var chars = Array(lines.joined(separator: "\n"))
        changed = true
        while changed {
            changed = false
            var i = 0
            while i < chars.count {
                var cand = chars; cand.remove(at: i)
                if !cand.isEmpty && blockMismatch(String(cand), styler) { chars = cand; changed = true } else { i += 1 }
            }
        }
        let m = String(chars)
        if !seen.insert(m).inserted { continue }
        shown += 1
        guard let (o, l) = blockTokens(m, styler) else { continue }
        print("MISMATCH \"\(visible(m))\"")
        print("   oracle: \(tokString(o[...], max: 120))")
        print("   lexer:  \(tokString(l[...], max: 120))")
        print("   lexer runs: \(renderAll(m))")
    }
    print("distinct minimal mismatches shown: \(shown) of \(bad.count)")
}
