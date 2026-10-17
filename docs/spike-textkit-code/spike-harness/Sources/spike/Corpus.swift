import Foundation

/// Deterministic realistic markdown-ish corpus generator.
struct SplitMix64 {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000.0 < p }
}

enum Corpus {
    static let words: [String] = """
    the of and to in is that for it as with was on be by at this have from or one had not but what all were when we there can an your which their said if do will each about how up out them then she many some so these would other into has more her two like him see time could no make than first been its who now people my made over did down only way find use may water long little very after words called just where most know get through back much before go good new write our used me man too any day same right look think also around another came come work three word must because does part even place well such here take why help put different away again off went old number great tell men say small every found still between name should home big give air line set own under read last never us left end along while might next sound below saw something thought both few those always looked show large often together asked house don't world going want school important until form food keep children feet land side without boy once animal life enough took sometimes four head above kind began almost live page got earth need far hand high year mother light country father let night picture being study second soon story since white ever paper hard near sentence better best across during today however sure knew try told young sun thing whole hear example heard several change answer room sea against top turned learn point city play toward five using himself usually
    """.split(separator: " ").map(String.init)

    static let exotic: [String] = ["café", "naïve", "Übung", "größer", "—", "“quoted”", "‘single’", "…", "日本語", "✓", "→", "Zürich", "señor", "😀", "𝒳"]

    static let codeLines: [String] = [
        "func render(_ node: Node, depth: Int = 0) -> String {",
        "    let indent = String(repeating: \"  \", count: depth)",
        "    for child in node.children { out += render(child, depth: depth + 1) }",
        "    return indent + node.name + \"\\n\"",
        "}",
        "let total = items.reduce(0) { $0 + $1.count }",
        "if let value = dict[\"key\"], value > 42 { print(value) }",
        "#include <stdio.h>",
        "int main(int argc, char **argv) { return 0; }",
        "for (int i = 0; i < n; i++) { sum += a[i] * b[i]; }",
        "SELECT id, name FROM users WHERE created_at > now() - interval '7 days';",
        "$ git commit -m \"fix: handle empty input\"",
        "export PATH=\"$HOME/.local/bin:$PATH\"",
        "{ \"name\": \"scribe\", \"version\": \"1.0.0\", \"private\": true }",
        "    // TODO: cache the result between calls",
        "const result = await fetch(url).then(r => r.json());",
        "def main():\n    pass",
        "# comment line inside a code block",
        "x = [i ** 2 for i in range(10) if i % 2 == 0]",
        "",
    ]

    /// kind: "wrapped" (hard-wrapped ~78 columns, avg line ~50 bytes incl. short lines) or "long" (one line per paragraph)
    static func generate(targetBytes: Int, seed: UInt64 = 42, kind: String = "wrapped") -> String {
        var rng = SplitMix64(seed)
        var out = [UInt8]()
        out.reserveCapacity(targetBytes + 4096)
        let wrapCol = kind == "long" ? 100_000 : 78

        func put(_ s: String) { out.append(contentsOf: s.utf8) }
        func nl() { out.append(10) }

        func word() -> String {
            if rng.chance(0.012) { return exotic[rng.int(exotic.count)] }
            return words[rng.int(words.count)]
        }

        func inlineWord() -> String {
            let r = rng.int(100)
            switch r {
            case 0..<5: return "**" + word() + "**"
            case 5..<9: return "*" + word() + "*"
            case 9..<12: return "`" + word() + "_" + word() + "()`"
            case 12..<14: return "[" + word() + "](https://example.com/" + word() + ")"
            case 14..<15: return "~~" + word() + "~~"
            case 15..<16: return "_" + word() + " " + word() + "_"
            case 16..<17: return "***" + word() + "***"
            default: return word()
            }
        }

        func paragraph(minWords: Int, maxWords: Int, prefix: String = "", contPrefix: String = "") {
            let n = minWords + rng.int(maxWords - minWords + 1)
            var line = prefix
            var first = true
            var lineHasWord = false
            for i in 0..<n {
                var w = inlineWord()
                if i == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
                if i == n - 1 { w += "." } else if rng.chance(0.07) { w += "," }
                let sep = lineHasWord ? " " : ""
                if line.utf8.count + sep.utf8.count + w.utf8.count > wrapCol && lineHasWord {
                    put(line); nl()
                    line = contPrefix
                    lineHasWord = false
                    first = false
                }
                line += (lineHasWord ? " " : "") + w
                lineHasWord = true
            }
            _ = first
            put(line); nl()
        }

        if kind == "oneline" {
            put("# One very long line\n\nStart of the long line: ")
            while out.count < targetBytes { put(inlineWord()); out.append(32) }
            put("\nTail line after the long line.\n")
            return String(decoding: out, as: UTF8.self)
        }
        var blockIndex = 0
        while out.count < targetBytes {
            blockIndex += 1
            let r = rng.int(100)
            switch r {
            case 0..<7:
                let level = 1 + rng.int(4)
                put(String(repeating: "#", count: level) + " ")
                var t = word().capitalized
                for _ in 0..<(1 + rng.int(5)) { t += " " + word() }
                put(t); nl(); nl()
            case 7..<42:
                paragraph(minWords: 15, maxWords: kind == "long" ? 140 : 60)
                nl()
            case 42..<55:
                // list
                let ordered = rng.chance(0.3)
                let items = 3 + rng.int(6)
                for i in 0..<items {
                    let nested = i > 0 && rng.chance(0.25)
                    let indent = nested ? "    " : ""
                    var marker = ordered ? "\(i + 1). " : "- "
                    if !ordered && rng.chance(0.15) { marker = rng.chance(0.5) ? "- [ ] " : "- [x] " }
                    paragraph(minWords: 4, maxWords: 22, prefix: indent + marker, contPrefix: indent + "  ")
                }
                nl()
            case 55..<64:
                // quote
                let lines = 2 + rng.int(4)
                for _ in 0..<lines {
                    var line = "> "
                    for _ in 0..<(6 + rng.int(8)) { line += inlineWord() + " " }
                    put(line.trimmingCharacters(in: .whitespaces)); nl()
                }
                nl()
            case 64..<78:
                // fenced code
                let langs = ["swift", "python", "c", "sh", "json", "sql", "js", ""]
                put("```" + langs[rng.int(langs.count)]); nl()
                for _ in 0..<(4 + rng.int(18)) { put(codeLines[rng.int(codeLines.count)]); nl() }
                put("```"); nl(); nl()
            case 78..<81:
                put("---"); nl(); nl()
            case 81..<85:
                put("| Name | Value | Notes |"); nl()
                put("|------|:-----:|-------|"); nl()
                for _ in 0..<(2 + rng.int(5)) { put("| \(word()) | \(rng.int(1000)) | \(word()) \(word()) |"); nl() }
                nl()
            case 85..<88:
                put("<!-- " + word() + " " + word() + " " + word() + " -->"); nl(); nl()
            default:
                paragraph(minWords: 8, maxWords: 30)
                nl()
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static let dir: String = {
        let d = ProcessInfo.processInfo.environment["SPIKE_SCRATCH"] ?? "/tmp"
        return d + "/corpora"
    }()

    /// Cached on disk so repeated runs don't pay generation; generation itself is not part of any measurement.
    static func load(_ name: String) -> String {
        let (bytes, kind) = spec(name)
        let path = "\(dir)/\(name).md"
        if let s = try? String(contentsOfFile: path, encoding: .utf8) { return s }
        let s = generate(targetBytes: bytes, kind: kind)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? s.write(toFile: path, atomically: true, encoding: .utf8)
        return s
    }

    static func spec(_ name: String) -> (Int, String) {
        switch name {
        case "20k": return (20_000, "wrapped")
        case "100k": return (100_000, "wrapped")
        case "1m": return (1_000_000, "wrapped")
        case "5m": return (5_000_000, "wrapped")
        case "10m": return (10_000_000, "wrapped")
        case "20m": return (20_000_000, "wrapped")
        case "1m-long": return (1_000_000, "long")
        case "5m-long": return (5_000_000, "long")
        case "2m-oneline": return (2_000_000, "oneline")
        case "10m-oneline": return (10_000_000, "oneline")
        case "20m-long": return (20_000_000, "long")
        default: return (1_000_000, "wrapped")
        }
    }
}
