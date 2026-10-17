import Foundation
import MarkdownKit

/// `mdkit-checks --stress [bytes]`: pathological inputs, each repeated to `bytes` (default 1 MB). Reports lexAll throughput,
/// the cost of one keystroke in the middle (after a full style) and a cold first screen at the end. Anything below
/// 20 MB/s or above 5 ms per keystroke is flagged.
func runStress(bytes: Int, filter: String? = nil) {
    func rep(_ s: String, _ n: Int? = nil) -> String {
        let count = n ?? max(1, bytes / max(1, s.utf8.count))
        return String(repeating: s, count: count)
    }
    /// Paragraphs of ~60,000 units (just under the 64K inline cap, the worst case for the inline lexer) made of `pattern`,
    /// hard-wrapped every ~80 units, separated by blank lines.
    func para(_ pattern: String) -> String {
        var out = ""
        let unit = pattern.utf16.count
        var para = ""
        var col = 0
        let perPara = 60_000 / max(1, unit)
        for _ in 0..<perPara {
            para += pattern
            col += unit
            if col >= 80 { para += "\n"; col = 0 }
        }
        while out.utf8.count < bytes { out += para + "\n\n" }
        return out
    }
    var cases: [(String, String)] = [
        ("stars", rep("*")), ("underscores", rep("_")), ("stars+words", rep("*a ")), ("**a* pattern", rep("**a* ")), ("***_ pattern", rep("***a_")),
        ("tildes", rep("~~a ")), ("backticks 1..8", rep("` `` ``` ```` ````` `````` ``````` ```````` ")), ("unmatched backticks growing", (1...1400).map { String(repeating: "`", count: min($0, 63)) + "a " }.joined()),
        ("open brackets", rep("[")), ("[a](", rep("[a](")), ("[a][", rep("[a][")), ("![a](", rep("![a](")), ("][ and ](", rep("][")), ("[x](y 'z", rep("[x](y 'z ")),
        ("link tails ](aaaa...", rep("[a](" + String(repeating: "a", count: 900) + "\n")), ("nested brackets", String(repeating: "[", count: bytes / 4) + String(repeating: "](x)", count: bytes / 8)),
        ("angle brackets", rep("<")), ("<a ", rep("<a ")), ("<!--", rep("<!-- ")), ("<http://", rep("<http://x ")), ("html tags", rep("<span class=\"a\">x</span> ")),
        ("entities", rep("&amp;&#35;&#x1F;&x;")), ("backslashes", rep("\\")), ("amp+colon", rep("&:.http://a.")), ("urls", rep("http://a.b/c_d_e_(f) www.x.org/y ")),
        ("deep quotes", rep(">") + "\nx\n"), ("quote lines", rep("> ")), ("nested lists", rep("  - a\n")), ("deep indent lists", (0..<2000).map { String(repeating: " ", count: min($0, 120)) + "- x\n" }.joined()),
        ("many short lines", rep("a\n")), ("blank lines", rep("\n")), ("whitespace lines", rep("   \n")), ("dashes lines", rep("-\n")), ("table rows", rep("| a | b | c |\n")),
        ("table delimiter lines", rep("|-|-|\n")), ("pipes", rep("|")), ("headings", rep("# h\n")), ("setext-like", rep("a\n---\n")), ("fences unclosed", rep("```\n")),
        ("fences alternating", rep("```\nx\n~~~\n")), ("indented code with blanks", rep("    code\n\n")), ("code then only blank lines", "    code\n" + rep("\n")), ("code then blank quote lines", ">     code\n" + rep(">\n")),
        ("code then blank lines in a list", "-     code\n" + rep("\n")), ("code, 1000 blanks, code", rep("    code\n" + String(repeating: "\n", count: 1000))), ("indented code in list", rep("- a\n\n      code\n\n")), ("empty list items", rep("-\n")),
        ("ordered list", rep("1. a\n")), ("tasks", rep("- [ ] a\n")), ("footnote defs", rep("[^a]: x\n")), ("ref defs", rep("[a]: http://x\n")), ("html blocks", rep("<div>\nx\n\n")),
        ("html comment unclosed", "<!--\n" + rep("x\n")), ("front matter unclosed", "---\n" + rep("a: b\n")), ("CRLF text", rep("line *a* `b` [c](d)\r\n")), ("CR text", rep("line *a*\r")),
        ("long line no break", rep("word *a* `b` [c](d) ")), ("long line 5 MB-style prose", rep("abcdefghij ")), ("emoji", rep("😀*a*👨‍👩‍👧 ")), ("CJK", rep("日本語*テ*スト、")), ("NUL", rep("a\u{0}b ")),
        ("lone surrogates", String(decoding: Array(repeating: UInt16(0xD800), count: bytes / 2), as: UTF16.self)),
        ("paragraph 300 lines", (0..<(bytes / 600)).map { _ in String(repeating: "word *a* b\n", count: 300) + "\n" }.joined()),
        ("CJK lines with emphasis", rep("日本語の*テキスト*です。**太字**と_斜体_、「引用」*強調*\n")), ("emoji + accents with emphasis", rep("é*é* ñ**ñ** ü_ü_ 😀*😀* ❤️**❤️** «*q*»\n")),
        ("Hindi / Arabic with emphasis", rep("*शब्द*। **मोटा**। *النص*، **غامق**؟\n")),
        ("realistic mix", Corpus.make(bytes: bytes, seed: 7)),
    ]
    let patterns = ["*", "**", "*a", "a*", "_", "**a* ", "***a_", "~~a ", "`", "``a", "` `` ``` ", "[", "[a](", "[a][", "![a](", "][", "](", "[x](y 'z ", "<", "<a ", "<!-- ", "<http://x ", "&", "&#", "\\", "http://a_b(", "www.a.b/(", "[^a", "- ", "> ", "|", ":", "a ", "[a](" + String(repeating: "b", count: 300) + " ", "*[a](b)* ", "**[a](b `c`)** ", "[a *b* ](c) "]
    for p in patterns { cases.append(("P60K " + p.replacingOccurrences(of: "\n", with: "\\n"), para(p))) }
    var flagged = 0
    print(String(format: "%-30@ %10@ %10@ %14@ %12@", "case" as NSString, "MB" as NSString, "MB/s" as NSString, "keystroke us" as NSString, "cold end ms" as NSString))
    for (name, s) in cases {
        if let f = filter, !name.contains(f) { continue }
        let t = NSString(string: s)
        if t.length == 0 { continue }
        let st = MarkdownStyler()
        var best = UInt64.max
        for _ in 0..<2 { let a = nowNS(); _ = st.lexAll(t); best = min(best, nowNS() - a) }
        let mbps = Double(s.utf8.count) / 1e6 / (Double(best) / 1e9)
        // keystroke in the middle after a full style
        let m = NSMutableString(string: s)
        let s2 = MarkdownStyler()
        _ = s2.styleRuns(in: NSRange(location: 0, length: m.length), of: m)
        var samples: [UInt64] = []
        let pos = (m.length / 2)
        for k in 0..<30 {
            m.insert("x", at: pos + k)
            let a = nowNS()
            _ = s2.update(afterEdit: NSRange(location: pos + k, length: 1), changeInLength: 1, of: m)
            samples.append(nowNS() - a)
        }
        let keyUs = us(Dist(samples).p(0.5))
        // cold first screen at the end
        let s3 = MarkdownStyler()
        let a3 = nowNS()
        _ = s3.styleRuns(in: NSRange(location: max(0, t.length - 2000), length: 2000), of: t)
        let coldMs = ms(nowNS() - a3)
        let flag = (mbps < 20 || keyUs > 5000 || coldMs > 100) ? "  <-- SLOW" : ""
        if !flag.isEmpty { flagged += 1 }
        print(String(format: "%-30@ %10.2f %10.1f %14.1f %12.2f%@", name as NSString, Double(s.utf8.count) / 1e6, mbps, keyUs, coldMs, flag as NSString))
    }
    print("flagged: \(flagged)")
}
