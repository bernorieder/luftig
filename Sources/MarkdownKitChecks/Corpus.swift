import Foundation

/// Deterministic generator of realistic Markdown (headings, paragraphs with inline styling, lists, quotes,
/// fenced code, tables, rules, comments) for benchmarks and large-document tests.
enum Corpus {
    static let words: [String] = ("the of and to in is that for it as with was on be at by this have from or one had not but what all were when we there can an your which their said if do will each about how up out them then she many some so these would other into has more her two like him see time could no make than first been its who now people my made over did down only way find use may water long little very after words called just where most know get through back much before go good new write our me man too any day same right look think also around another came come work three word must because does part even place well such here take why help put different away again off went old number great tell men say small every found still between name should home big give air line set own under read last never us left end along while might next sound below saw something thought both few those always looked show large often together asked house don't world going want school important until form food keep children feet land side without boy once animal life enough took sometimes four head above kind began almost live page got earth need far hand high year mother light country father let night picture being study second soon story since white ever paper hard near sentence better best across during today however sure knew try told young sun thing whole hear example heard several change answer room sea against top turned learn point city play toward five using himself usually").split(separator: " ").map(String.init)
    static let langs = ["swift", "python", "js", "c", "rust", "json", "sh", ""]
    static let codeLines = [
        "let x = foo(bar, baz) // comment", "    return value * 2", "if (a && b) { c(); }", "func run() -> Int {", "}", "import Foundation",
        "for i in 0..<10 { print(i) }", "  \"key\": [1, 2, 3],", "$ make && make install", "def f(x): return x ** 2", "#include <stdio.h>", "",
    ]

    static func sentence(_ r: inout RNG, minWords: Int = 5, maxWords: Int = 18) -> String {
        let n = r.range(minWords, maxWords)
        var out: [String] = []
        for i in 0..<n {
            var w = r.pick(words)
            if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
            let k = r.int(100)
            if k < 5 { w = "*\(w)*" }
            else if k < 8 { w = "**\(w)**" }
            else if k < 11 { w = "`\(w)`" }
            else if k < 13 { w = "[\(w)](https://example.com/\(r.pick(words)))" }
            else if k < 14 { w = "~~\(w)~~" }
            else if k < 15 { w = "_\(w)_" }
            else if k < 16 { w = "https://example.org/\(r.pick(words))/\(r.pick(words))" }
            else if k < 17 { w = "\(w)," }
            out.append(w)
        }
        return out.joined(separator: " ") + "."
    }

    static func paragraph(_ r: inout RNG) -> String {
        let sentences = r.range(1, 6)
        let text = (0..<sentences).map { _ in sentence(&r) }.joined(separator: " ")
        if r.chance(0.5) { return text + "\n" }            // one long line
        // hard-wrap at ~78 columns
        var lines: [String] = []
        var cur = ""
        for w in text.split(separator: " ") {
            if cur.count + w.count + 1 > 78 { lines.append(cur); cur = String(w) } else { cur += cur.isEmpty ? String(w) : " " + w }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func list(_ r: inout RNG) -> String {
        let items = r.range(2, 8)
        let ordered = r.chance(0.3)
        let task = r.chance(0.15)
        var out = ""
        for i in 0..<items {
            let marker = ordered ? "\(i + 1). " : r.pick(["- ", "- ", "* "])
            out += marker + (task ? (r.chance(0.5) ? "[ ] " : "[x] ") : "") + sentence(&r, minWords: 3, maxWords: 12) + "\n"
            if r.chance(0.2) { out += "  - " + sentence(&r, minWords: 2, maxWords: 8) + "\n" }
        }
        return out
    }

    static func quote(_ r: inout RNG) -> String {
        (0..<r.range(1, 4)).map { _ in "> " + sentence(&r, minWords: 4, maxWords: 14) }.joined(separator: "\n") + "\n"
    }

    static func code(_ r: inout RNG) -> String {
        var out = "```\(r.pick(langs))\n"
        for _ in 0..<r.range(3, 20) { out += r.pick(codeLines) + "\n" }
        return out + "```\n"
    }

    static func table(_ r: inout RNG) -> String {
        let cols = r.range(2, 5)
        var out = "| " + (0..<cols).map { _ in r.pick(words) }.joined(separator: " | ") + " |\n"
        out += "|" + String(repeating: "---|", count: cols) + "\n"
        for _ in 0..<r.range(2, 8) {
            out += "| " + (0..<cols).map { _ in r.chance(0.2) ? "**\(r.pick(words))**" : r.pick(words) }.joined(separator: " | ") + " |\n"
        }
        return out
    }

    static func make(bytes target: Int, seed: UInt64) -> String {
        var r = RNG(seed: seed)
        var out = "---\ntitle: Benchmark corpus\ntags: [a, b]\n---\n\n"
        out.reserveCapacity(target + 4096)
        while out.utf8.count < target {
            let k = r.int(100)
            let block: String
            if k < 6 { block = String(repeating: "#", count: r.range(1, 4)) + " " + sentence(&r, minWords: 2, maxWords: 8) + "\n" }
            else if k < 46 { block = paragraph(&r) }
            else if k < 62 { block = list(&r) }
            else if k < 69 { block = quote(&r) }
            else if k < 78 { block = code(&r) }
            else if k < 83 { block = table(&r) }
            else if k < 84 { block = "---\n" }
            else if k < 85 { block = "<!-- " + sentence(&r) + " -->\n" }
            else { block = paragraph(&r) }
            out += block + "\n"
        }
        return out
    }
}
