import Foundation
import MarkdownKit

// Differential testing against a SECOND independent implementation: markdown-it-py (Scripts/mdit_oracle.py), run once over a batch of
// documents written to a file. No pipes, no sockets, nothing but regular files: the Swift side writes docs.jsonl, the Python script
// writes oracle.jsonl, the Swift side reads both and compares them (letters / digits with em, strong, code, strike, image, code block,
// quote, table and heading-level flags; links only with the `link` flag). The comparison machinery is the one of Oracle.swift.
//
//   mdkit-checks --mdit-export <docs.jsonl> <corpus|gen|block|inline> [count] [seed]
//   python -I Scripts/mdit_oracle.py <docs.jsonl> <oracle.jsonl>
//   mdkit-checks --mdit-compare <docs.jsonl> <oracle.jsonl> [show=N] [samples=N] [link] [real] [nofn]

private let mditMask: UInt16 = OFlag.em | OFlag.strong | OFlag.code | OFlag.strike | OFlag.img | OFlag.codeBlock | OFlag.quote | OFlag.table | (7 << OFlag.headingShift)

/// Documents made of list items, quotes, code and blank lines with all sorts of indentation (spaces and tabs).
private func listDocument(_ r: inout RNG) -> String {
    let markers = ["-", "*", "+", "1.", "2.", "10.", "1)", "99."]
    let texts = ["a", "item *x*", "text `c`", "word", "# h", "> q", "```", "~~~", "<br>", "---", "| a |", "[x] t"]
    var out: [String] = []
    for _ in 0..<r.range(1, 8) {
        let k = r.int(100)
        func ws(_ lo: Int, _ hi: Int) -> String { r.chance(0.12) ? "\t" : String(repeating: " ", count: r.range(lo, hi)) }
        if k < 12 { out.append("") }
        else if k < 55 { out.append(ws(0, 4) + r.pick(markers) + (r.chance(0.08) ? "" : ws(1, 5)) + (r.chance(0.1) ? "" : r.pick(texts))) }
        else if k < 80 { out.append(ws(0, 9) + r.pick(texts)) }
        else if k < 88 { out.append((r.chance(0.5) ? "> " : ">") + ws(0, 6) + r.pick(texts)) }
        else { out.append(ws(4, 9) + "code " + r.pick(["x", "y z", "<b>", "*q*"])) }
    }
    return out.joined(separator: "\n") + (r.chance(0.8) ? "\n" : "")
}

/// Emphasis delimiters next to characters of every Unicode class (punctuation and symbols of many scripts, spaces, numbers, marks, emoji).
private func unicodeSoup(_ r: inout RNG) -> String {
    let chars = ["।", "॥", "־", "؟", "،", "«", "»", "“", "”", "—", "…", "€", "£", "™", "©", "½", "²", "ℕ", "→", "★", "☺", "😀", "👍🏽", "𝄞", "𝒳", "日", "本", "ー", "。", "、", "「", "」",
                 "！", "（", "）", "a", "é", "ñ", "Q", "7", "\u{00A0}", "\u{2009}", "\u{3000}", "\u{200B}", "\u{200D}", "\u{FE0F}", "\u{0301}", "ᚠ", "ก", "ๆ", "།", "፡", "᠂", "‿", "٪", "߷", "‽", "¿", "¡",
                 "§", "¶", "·", "ˆ", "˜", "°", "µ", "¬", "×", "÷", "∑", "≠", "∞", "♥", "✓", "❤", "▲", "◆", "𝟘", "\u{1F1E9}", "\u{1F3FB}", "\u{E000}", "ß", "ǅ", "Ⅷ", "①"]
    let delims = ["*", "**", "_", "__", "***", "*", "_", "**", "__"]
    var s = "w"
    for _ in 0..<r.range(3, 14) {
        let k = r.int(100)
        if k < 40 { s += r.pick(chars) }
        else if k < 70 { s += r.pick(delims) }
        else if k < 85 { s += r.pick(["a", "bc", "x1"]) }
        else { s += " " }
    }
    return s
}

/// Fences and HTML blocks in all sorts of containers and indentations.
private func fenceHtmlDocument(_ r: inout RNG) -> String {
    let frags = ["```", "``` js", "````", "~~~", "~~~~ x", "``` a`b", "~~~ a`b", "`````", "<div>", "</div>", "<pre>", "</pre>", "<script>", "</script>", "<style>", "</style>",
                 "<!--", "-->", "<!-- c -->", "<?php", "?>", "<![CDATA[", "]]>", "<!DOCTYPE x>", "<custom-tag>", "</custom>", "<a href=x>", "<br>", "<table>", "<details>",
                 "text *x*", "more text", "---", "# h", "| a |", "plain", "    indented", "<p>x</p>", "<div>x</div>", "<pre>x</pre>", "<b>x</b> y"]
    let prefixes = ["", "", "", "> ", ">", "- ", "  ", "   - ", ">> ", "1. ", "> - ", "    "]
    var out: [String] = []
    for _ in 0..<r.range(2, 9) {
        if r.chance(0.12) { out.append(r.chance(0.5) ? "" : ">"); continue }
        out.append(r.pick(prefixes) + String(repeating: " ", count: r.chance(0.25) ? r.range(1, 5) : 0) + r.pick(frags))
    }
    return out.joined(separator: "\n") + "\n"
}

/// A second inline soup: HTML, autolinks, entities, escapes, strikethrough, URLs, reference-free link syntax.
enum InlineSoup2 {
    static let words = ["a", "bc", "foo", "x1", "é", "日本", "Q", "ab_c", "http://x.org/a_b", "www.q.org/p", "a@b.co"]
    static let pieces = ["<", ">", "<a href=\"x\">", "</a>", "<br/>", "<b>", "</b>", "<https://x.org/y>", "<me@x.org>", "<!-- c -->", "<!-->", "&amp;", "&lt;", "&gt;",
                         "&copy;", "&nbsp;", "&", "~~", "~", "\\", "\\*", "\\_", "\\`", "\\[", "\\<", "\"", "'", "|", "(", ")", "[", "]", "](", "![", "*", "**", "_", "__", "`", "``", "***", " ", " ", " "]
    static func paragraph(_ r: inout RNG) -> String {
        var lines: [String] = []
        for _ in 0..<(r.chance(0.75) ? 1 : r.range(2, 3)) {
            var s = "w"
            for _ in 0..<r.range(2, 14) {
                s += r.chance(0.35) ? r.pick(words) : r.pick(pieces)
                if r.chance(0.3) { s += " " }
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}

/// Smaller documents than `Gen.document`, so that a mismatch is readable without minimisation.
private func smallDocument(_ r: inout RNG) -> String {
    var s = ""
    let lines = r.range(1, 7)
    let crlf = r.chance(0.05)
    for _ in 0..<lines {
        let k = r.int(100)
        if k < 10 { s += "" }
        else if k < 16 { s += String(repeating: " ", count: r.range(1, 6)) + Gen.fragment(&r) }
        else if k < 24 { s += Gen.fragment(&r) + " " + Gen.fragment(&r) }
        else if k < 30 { s += r.pick(Gen.codeComposites) }
        else { s += Gen.fragment(&r) }
        s += crlf ? "\r\n" : "\n"
    }
    if r.chance(0.25), s.hasSuffix("\n") { s.removeLast() }
    return s
}

private func jsonLine(_ obj: [String: Any]) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return nil }
    return String(data: d, encoding: .utf8)
}

func runMditExport(path: String, kind: String, count: Int, seed: UInt64) {
    var out = ""
    var n = 0
    func add(_ id: String, _ text: String) {
        if let l = jsonLine(["id": id, "text": text]) { out += l; out += "\n"; n += 1 }
    }
    var rng = RNG(seed: seed)
    switch kind {
    case "corpus":
        let styler = MarkdownStyler()
        for f in loadCorpus() where !f.text.isEmpty {
            // Front matter is not CommonMark: compare the body only.
            let t = NSString(string: f.text)
            var end = 0
            for r in styler.lexAll(t) { if r.style.contains(.frontMatter) { end = r.range.location + r.range.length } else { break } }
            add(f.path, end > 0 ? t.substring(from: end) : f.text)
        }
    case "corpusmut":
        // Real documents with 1-3 random line / character level mutations each (`count` variants per document): real structure pushed
        // into odd states, compared with markdown-it-py.
        let styler = MarkdownStyler()
        for f in loadCorpus() where f.text.utf16.count >= 200 && f.text.utf16.count <= 40_000 && !isParserFixture(f.path) {
            let t = NSString(string: f.text)
            var fm = 0
            for r in styler.lexAll(t) { if r.style.contains(.frontMatter) { fm = r.range.location + r.range.length } else { break } }
            let body = fm > 0 ? t.substring(from: fm) : f.text
            let lines = body.components(separatedBy: "\n")
            for v in 0..<count {
                var ls = lines
                for _ in 0..<rng.range(1, 3) {
                    if ls.isEmpty { break }
                    let i = rng.int(ls.count)
                    switch rng.int(8) {
                    case 0: ls.remove(at: i)
                    case 1: ls.insert(ls[i], at: i)
                    case 2: ls.insert(Gen.fragment(&rng), at: i)
                    case 3: ls[i] += rng.pick(["*", "_", "`", "[", "]", "(", ")", "<", ">", "|", "#", "-", " ", "\\", "~", "!"])
                    case 4: ls[i] = rng.pick(["*", "_", "`", "[", "]", "(", ")", "<", ">", "|", "#", "-", " ", "\\", "~", "!"]) + ls[i]
                    case 5: ls[i] = String(repeating: " ", count: rng.range(1, 6)) + ls[i]
                    case 6: if i + 1 < ls.count { ls.swapAt(i, i + 1) }
                    default: if !ls[i].isEmpty { let u = Array(ls[i]); ls[i] = String(u[0..<rng.int(u.count)] + u[min(u.count, rng.int(u.count) + 1)...]) }
                    }
                }
                add("\(f.path)#\(v)", ls.joined(separator: "\n"))
            }
        }
    case "uni": for i in 0..<count { add("uni-\(seed)-\(i)", unicodeSoup(&rng)) }
    case "fenceshtml": for i in 0..<count { add("fenceshtml-\(seed)-\(i)", fenceHtmlDocument(&rng)) }
    case "lists": for i in 0..<count { add("lists-\(seed)-\(i)", listDocument(&rng)) }
    case "gen": for i in 0..<count { add("gen-\(seed)-\(i)", smallDocument(&rng)) }
    case "tiny":
        for i in 0..<count {
            var s = ""
            for _ in 0..<rng.range(1, 3) { s += (rng.chance(0.12) ? "" : Gen.fragment(&rng)) + "\n" }
            add("tiny-\(seed)-\(i)", s)
        }
    case "genbig": for i in 0..<count { add("genbig-\(seed)-\(i)", Gen.document(&rng)) }
    case "block": for i in 0..<count { add("block-\(seed)-\(i)", BlockSoup.document(&rng)) }
    case "inline": for i in 0..<count { add("inline-\(seed)-\(i)", InlineSoup.paragraph(&rng)) }
    case "inline2": for i in 0..<count { add("inline2-\(seed)-\(i)", InlineSoup2.paragraph(&rng)) }
    default: print("unknown kind \(kind)"); return
    }
    FileManager.default.createFile(atPath: path, contents: out.data(using: .utf8))
    print("wrote \(n) documents to \(path)")
}

private func hasFootnoteDefinition(_ s: String) -> Bool {
    for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
        let t = line.drop(while: { $0 == " " })
        if t.hasPrefix("[^"), t.contains("]:") { return true }
    }
    return false
}

func runMditCompare(docsPath: String, oraclePath: String, flags: [String]) {
    func opt(_ k: String, _ d: Int) -> Int { flags.first(where: { $0.hasPrefix(k + "=") }).flatMap { Int($0.dropFirst(k.count + 1)) } ?? d }
    let showClasses = opt("show", 30), samples = opt("samples", 3)
    var mask = mditMask
    if flags.contains("link") { mask |= OFlag.link }
    guard let docsData = FileManager.default.contents(atPath: docsPath), let oracleData = FileManager.default.contents(atPath: oraclePath) else {
        print("cannot read input files"); return
    }
    var texts: [String: String] = [:]
    var order: [String] = []
    for l in String(decoding: docsData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
        if let d = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let id = d["id"] as? String, let t = d["text"] as? String {
            texts[id] = t; order.append(id)
        }
    }
    let styler = MarkdownStyler()
    var compared = 0, identical = 0, errors = 0, skipped = 0, tokensTotal = 0, tokensDiff = 0, cmarkAgrees = 0
    var classes: [String: (count: Int, docs: Set<String>, samples: [(len: Int, text: String)])] = [:]
    var docDiffs: [(id: String, regions: Int, tokens: Int)] = []
    for l in String(decoding: oracleData, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let id = d["id"] as? String, let text = texts[id] else { continue }
        if d["error"] != nil { errors += 1; continue }
        let real = flags.contains("real")
        if real && isParserFixture(id) { skipped += 1; continue }
        if !flags.contains("nofn") && hasFootnoteDefinition(text) { skipped += 1; continue }     // markdown-it moves footnote bodies to the end
        // documented deviations (one-character setext underline, front matter, definitions with the destination on the next line)
        if !real && !flags.contains("dev") && skipBlockCase(text) { skipped += 1; continue }
        // reference links / footnote references whose definition does not exist: the lexer styles them anyway (documented)
        if !real && !flags.contains("dev") && (text.contains("][") || text.contains("[^")) { skipped += 1; continue }
        if flags.contains("nourl") && (text.contains("www.") || text.contains("http://") || text.contains("https://")) { skipped += 1; continue }   // markdown-it does not linkify
        if flags.contains("notask") && text.contains("[x]") && text.contains("--") { skipped += 1; continue }   // a task marker inside a setext heading
        if flags.contains("norefs") && (text.contains("][") || text.contains("[^")) { skipped += 1; continue }
        // a one-column delimiter row `|-|` under a line without any pipe: a table for cmark-gfm and the lexer, not for markdown-it
        if !real && !flags.contains("dev") && text.contains("|-|") { skipped += 1; continue }
        guard let runs = d["runs"] as? [[Any]] else { continue }
        var o: [OTok] = []
        for r in runs {
            guard r.count == 2, let f = (r[0] as? NSNumber)?.uint16Value, let s = r[1] as? String else { continue }
            for u in s.unicodeScalars where wanted(u, alnumOnly: true) { o.append(OTok(c: u.value, f: f & mask)) }
        }
        let t = NSString(string: text)
        var lx = lexerTokens(t, styler.lexAll(t), alnumOnly: true)
        for i in 0..<lx.count { lx[i].f &= mask }
        compared += 1
        tokensTotal += lx.count
        if o == lx { identical += 1; continue }
        // Triangulation: markdown-it-py has quirks of its own (e.g. a code-span cache that an unclosed `[` upsets). When cmark-gfm
        // (Foundation) reproduces the lexer's token stream exactly, the difference is the oracle's, not the lexer's.
        if flags.contains("x2"), var f = oracleTokens(text, alnumOnly: true) {
            for i in 0..<f.count { f[i].f &= mask }
            if f == lx { cmarkAgrees += 1; continue }
        }
        let diffs = diffTokens(o, lx, k: lx.count < 200 ? 3 : 6, window: 2500)
        if diffs.isEmpty { identical += 1; continue }
        docDiffs.append((id, diffs.count, diffs.reduce(0) { $0 + max($1.lexer.count, $1.oracle.count) }))
        let li = LineIndex(t)
        if let want = flags.first(where: { $0.hasPrefix("doc=") }).map({ String($0.dropFirst(4)) }), id.hasSuffix(want) {
            print("regions of \(shortPath(id)):")
            for dd in diffs {
                let line = dd.lexerOffset >= 0 ? li.line(of: dd.lexerOffset) : 0
                print("  line \(line): oracle \(tokString(dd.oracle, max: 70)) | lexer \(tokString(dd.lexer, max: 70))")
            }
        }
        for dd in diffs {
            tokensDiff += dd.lexer.count
            let sameChars = dd.oracle.map(\.c) == dd.lexer.map(\.c)
            func union(_ s: ArraySlice<OTok>) -> UInt16 { s.reduce(0) { $0 | $1.f } }
            let ou = union(dd.oracle), lu = union(dd.lexer)
            let key: String
            if sameChars {
                let onlyO = ou & ~lu, onlyL = lu & ~ou
                let hO = (ou >> OFlag.headingShift) & 7, hL = (lu >> OFlag.headingShift) & 7
                var on = OFlag.names(onlyO & 0x1FF), ln = OFlag.names(onlyL & 0x1FF)
                if hO != hL { on += " h\(hO)"; ln += " h\(hL)" }
                key = "flags: oracle \(on == "plain" ? "-" : on) / lexer \(ln == "plain" ? "-" : ln)"
            } else if dd.oracle.isEmpty { key = "extra text in lexer (\(OFlag.names(lu)))" }
            else if dd.lexer.isEmpty { key = "text missing in lexer (oracle \(OFlag.names(ou)))" }
            else { key = "text differs: oracle \(OFlag.names(ou)) / lexer \(OFlag.names(lu))" }
            var e = classes[key] ?? (0, [], [])
            e.count += 1
            e.docs.insert(id)
            let line = dd.lexerOffset >= 0 ? li.line(of: dd.lexerOffset) : 0
            let src = line > 0 ? visible(t.substring(with: li.range(ofLine: line, in: t))) : ""
            let isCorpus = id.hasPrefix("/")
            let sample = isCorpus
                ? "\(shortPath(id)):\(line)  oracle \(tokString(dd.oracle, max: 40)) | lexer \(tokString(dd.lexer, max: 40))  ⟨\(src.prefix(110))⟩"
                : "\"\(visible(text))\"   oracle \(tokString(dd.oracle, max: 40)) | lexer \(tokString(dd.lexer, max: 40))"
            e.samples.append((isCorpus ? line : text.utf16.count, sample))
            e.samples.sort { $0.len < $1.len }
            if e.samples.count > samples { e.samples.removeLast(e.samples.count - samples) }
            classes[key] = e
        }
    }
    print("markdown-it-py differential: \(compared) documents compared (\(identical) identical, \(cmarkAgrees) differ from markdown-it-py but match cmark-gfm), \(errors) oracle errors, \(skipped) skipped (footnote definitions / parser fixtures); tokens \(tokensTotal), differing \(tokensDiff)")
    print("documents with differences: \(docDiffs.count)")
    if docDiffs.count > 0 && docDiffs.count <= 40 { for x in docDiffs.sorted(by: { $0.tokens > $1.tokens }) { print("   \(x.regions) / \(x.tokens)  \(shortPath(x.id))") } }
    if flags.contains("list") { for x in docDiffs.sorted(by: { $0.id < $1.id }).prefix(60) { print("   differs: \(shortPath(x.id)) (\(x.regions) regions)") } }
    if let n = flags.first(where: { $0.hasPrefix("shortest=") }).flatMap({ Int($0.dropFirst(9)) }) {
        print("shortest differing documents (distinct):")
        var seen = Set<String>()
        var shown = 0
        for x in docDiffs.sorted(by: { (texts[$0.id]?.utf16.count ?? 0, $0.id) < (texts[$1.id]?.utf16.count ?? 0, $1.id) }) {
            guard let tx = texts[x.id], seen.insert(tx).inserted else { continue }
            print("   \"\(visible(tx))\"")
            print("       lexer: \(renderAll(tx))")
            shown += 1
            if shown >= n { break }
        }
    }
    print("| difference class (oracle vs lexer) | regions | documents |")
    print("|---|---|---|")
    for (c, v) in classes.sorted(by: { $0.value.count > $1.value.count }).prefix(showClasses) { print("| \(c) | \(v.count) | \(v.docs.count) |") }
    print("")
    for (c, v) in classes.sorted(by: { $0.value.count > $1.value.count }).prefix(showClasses) {
        print("[\(c)]  \(v.count) regions")
        for s in v.samples { print("    \(s.text)") }
    }
}


/// `mdkit-checks --oracle-fuzz2 <paragraphs> <seed> [show]`: the HTML / entity / URL / escape soup against cmark-gfm (Foundation), with links
/// compared too (bare URLs are where markdown-it cannot serve as an oracle: it does not implement GFM extended autolinks).
func runOracleFuzz2Command(count: Int, seed: UInt64, show: Int) {
    var rng = RNG(seed: seed)
    let styler = MarkdownStyler()
    var bad: [String] = []
    var compared = 0
    for _ in 0..<count {
        let p = InlineSoup2.paragraph(&rng)
        // documented deviations / Foundation artefacts: reference links, empty destinations, tildes, comments and tags spanning lines
        if skipInlineCase(p) || p.contains("a@b.co") || p.contains("<!--") && !p.contains("-->") { continue }
        guard let o = oracleTokens(p, alnumOnly: true) else { continue }
        let t = NSString(string: p)
        let l = lexerTokens(t, styler.lexAll(t), alnumOnly: true)
        compared += 1
        if tolerateOracleNesting(o, l) != l { bad.append(p) }
    }
    print("oracle fuzz 2 seed \(seed): \(compared) paragraphs compared, \(bad.count) mismatches")
    bad.sort { $0.utf16.count < $1.utf16.count }
    for p in bad.prefix(show) {
        let t = NSString(string: p)
        let l = lexerTokens(t, styler.lexAll(t), alnumOnly: true)
        let o = tolerateOracleNesting(oracleTokens(p, alnumOnly: true) ?? [], l)
        print("MISMATCH \"\(visible(p))\"")
        print("   oracle: \(tokString(o[...], max: 200))")
        print("   lexer:  \(tokString(l[...], max: 200))")
    }
}
