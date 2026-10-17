import Foundation
import MarkdownKit

// Real-world corpus runner: every *.md file found (read-only) under /opt/homebrew, /Library/Developer and /Applications.
// For each file: lexAll with full structural invariants and timing, cold styleRuns agreement, random incremental edits
// (incremental == full), an "oddity detector" over the style runs, and a differential comparison with cmark-gfm
// (Foundation's AttributedString markdown parser, see Oracle.swift). Nothing is copied, nothing is written.

let corpusRoots = ["/opt/homebrew", "/Library/Developer", "/Applications"]

/// Flags of `--corpus` after the two numeric arguments: `oracle`, `oddities`, `review=N`, `limit=N`, `dups` (oddity detector also on
/// byte-identical copies of a file; default: each distinct content once), `fixtures` (also on parser test fixtures; default: skipped),
/// `dump=<class>` (print every instance of one oddity class instead of the round-robin review list), `real` (oracle comparison only on
/// distinct non-fixture files), `inline` (oracle comparison also on emphasis / code / strike flags), `samples=N` (samples per oracle class).
nonisolated(unsafe) var corpusFlags: [String] = []
func corpusStringOpt(_ k: String) -> String? { corpusFlags.first(where: { $0.hasPrefix(k + "=") }).map { String($0.dropFirst(k.count + 1)) } }
/// Parser test suites (CommonMark / markdown-it / Pygments fixtures) are deliberately pathological, not documents a person writes.
func isParserFixture(_ path: String) -> Bool {
    path.contains("/fixtures/") || path.contains("/test_port/") || path.contains("commonmark_spec") || path.contains("/examplefiles/") || path.contains("/parquet-testing/")
}

struct CorpusFile {
    var path: String
    var text: String
    var bytes: Int
    var invalidUTF8: Bool
    var hasBOM: Bool
}

func loadCorpus(limit: Int = Int.max) -> [CorpusFile] {
    var paths: [String] = []
    let fm = FileManager.default
    for root in corpusRoots {
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { continue }
        for case let url as URL in en {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            paths.append(url.path)
        }
    }
    paths.sort()
    var out: [CorpusFile] = []
    for p in paths.prefix(limit) {
        guard let d = fm.contents(atPath: p) else { continue }
        var invalid = false
        let s: String
        if let x = String(data: d, encoding: .utf8) { s = x } else { s = String(decoding: d, as: UTF8.self); invalid = true }
        out.append(CorpusFile(path: p, text: s, bytes: d.count, invalidUTF8: invalid, hasBOM: d.starts(with: [0xEF, 0xBB, 0xBF])))
    }
    return out
}

func shortPath(_ p: String) -> String {
    var s = p
    for r in corpusRoots where s.hasPrefix(r) { s = String(s.dropFirst(r.count)); break }
    return s.count > 90 ? "…" + s.suffix(88) : s
}

// MARK: - Line index

struct LineIndex {
    var starts: [Int] = [0]
    init(_ t: NSString) {
        let n = t.length
        var i = 0
        while i < n {
            let c = t.character(at: i)
            if c == 10 { starts.append(i + 1) }
            else if c == 13 { if i + 1 < n && t.character(at: i + 1) == 10 { i += 1 }; starts.append(i + 1) }
            i += 1
        }
    }
    func line(of off: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let m = (lo + hi) / 2; if starts[m] <= off { lo = m + 1 } else { hi = m } }
        return lo            // 1-based
    }
    func range(ofLine l: Int, in t: NSString) -> NSRange {
        let s = starts[l - 1]
        var e = l < starts.count ? starts[l] : t.length
        while e > s && (t.character(at: e - 1) == 10 || t.character(at: e - 1) == 13) { e -= 1 }
        return NSRange(location: s, length: e - s)
    }
}

// MARK: - Oddity detector

struct Oddity {
    var cls: String
    var file: String
    var line: Int
    var excerpt: String
    var score: Double
}

private func clip(_ s: String, _ n: Int = 110) -> String {
    let v = visible(s)
    return v.count > n ? String(v.prefix(n)) + "…" : v
}

private func isAlnumUnit(_ c: unichar) -> Bool {
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 0xC0
}

func detectOddities(file: String, text t: NSString, runs: [MDRun]) -> [Oddity] {
    var out: [Oddity] = []
    let n = t.length
    if n == 0 { return out }
    let li = LineIndex(t)
    func add(_ cls: String, _ off: Int, _ score: Double, _ extra: String = "") {
        let l = li.line(of: max(0, min(off, n - 1)))
        let ex = clip(t.substring(with: li.range(ofLine: l, in: t))) + (extra.isEmpty ? "" : "   ⟨\(extra)⟩")
        out.append(Oddity(cls: cls, file: file, line: l, excerpt: ex, score: score))
    }

    // 1. spans of one inline facet
    let facets: [(MDStyle, String)] = [(.bold, "bold"), (.italic, "italic"), (.strikethrough, "strike"), (.inlineCode, "code")]
    for (f, name) in facets {
        var start = -1, end = 0
        func flush() {
            guard start >= 0 else { return }
            let len = end - start
            var nl = 0, sentences = 0
            let cap = min(len, 2500)
            let sub = t.substring(with: NSRange(location: start, length: cap)) as NSString
            var i = 0
            while i < sub.length {
                let c = sub.character(at: i)
                if c == 10 { nl += 1 }
                if (c == 46 || c == 33 || c == 63) && i + 2 < sub.length && (sub.character(at: i + 1) == 32 || sub.character(at: i + 1) == 10) {
                    var j = i + 1
                    while j < sub.length && (sub.character(at: j) == 32 || sub.character(at: j) == 10) { j += 1 }
                    if j < sub.length && sub.character(at: j) >= 65 && sub.character(at: j) <= 90 { sentences += 1 }
                }
                i += 1
            }
            if name == "code" {
                if len > 200 || nl >= 2 { add("code-span-long", start, Double(len) + Double(nl) * 50, "len \(len), \(nl) line breaks") }
            } else {
                if len > 250 || nl >= 3 || sentences >= 3 { add("\(name)-long", start, Double(len) + Double(sentences) * 100, "len \(len), \(nl) line breaks, \(sentences) sentences") }
                if name != "strike" {
                    let before: unichar = start > 0 ? t.character(at: start - 1) : 32
                    let after: unichar = end < n ? t.character(at: end) : 32
                    // intraword (a*b*c): only `*` can do that; the markers are part of the span, look just outside
                    if isAlnumUnit(before) || isAlnumUnit(after) { add("\(name)-intraword", start, 1) }
                }
            }
            start = -1
        }
        for r in runs {
            if r.style.contains(f) {
                if start < 0 { start = r.range.location }
                end = r.range.location + r.range.length
            } else { flush() }
        }
        flush()
    }

    // 2. coverage and unclosed constructs
    var codeUnits = 0, htmlUnits = 0, fmUnits = 0, quoteUnits = 0, tableUnits = 0
    for r in runs {
        let s = r.style
        if s.contains(.codeBlock) || s.contains(.codeFence) { codeUnits += r.range.length }
        if s.contains(.html) { htmlUnits += r.range.length }
        if s.contains(.frontMatter) { fmUnits += r.range.length }
        if s.quoteDepth > 0 { quoteUnits += r.range.length }
        if s.contains(.table) { tableUnits += r.range.length }
    }
    let codeCover = n >= 1500 && Double(codeUnits) / Double(n) > 0.5
    if n >= 1500 && Double(htmlUnits) / Double(n) > 0.5 { add("html-cover>50%", 0, Double(htmlUnits) / Double(n) * 100, "\(htmlUnits * 100 / n)% of the document") }
    if fmUnits > 3000 || (n >= 1500 && Double(fmUnits) / Double(n) > 0.25) { add("frontmatter-large", 0, Double(fmUnits), "\(fmUnits) units = \(fmUnits * 100 / n)%") }
    if n >= 1500 && Double(quoteUnits) / Double(n) > 0.8 { add("quote-cover>80%", 0, Double(quoteUnits) / Double(n) * 100) }
    if n >= 1500 && Double(tableUnits) / Double(n) > 0.5 { add("table-cover>50%", 0, Double(tableUnits) / Double(n) * 100) }

    // 3. line based: fences, table rows without pipes, headings, setext, stray markers
    var inFence = false
    var fenceOpenLine = 0, fenceOpenOff = 0
    var tableProse = 0
    var fencedCodeLines = 0, indentedCodeLines = 0
    // style of the first non-prefix run of each line
    var ri = 0
    for l in 1...li.starts.count {
        let lr = li.range(ofLine: l, in: t)
        let lineEnd = lr.location + lr.length
        while ri < runs.count && runs[ri].range.location + runs[ri].range.length <= lr.location { ri += 1 }
        var k = ri
        var hasFence = false, tableRow = false, headingLevel = 0, atxMarker = false, hasPipe = false, codeLine = false
        var firstContent = -1
        while k < runs.count && runs[k].range.location < max(lineEnd, lr.location + 1) {
            let s = runs[k].style
            if s.contains(.codeFence) { hasFence = true }
            if s.contains(.codeBlock) && !s.contains(.codeFence) { codeLine = true }
            if s.contains(.table) && !s.contains(.tableDelimiter) { tableRow = true }
            if s.headingLevel > 0 { headingLevel = s.headingLevel; if s.contains(.marker) && firstContent < 0 && t.character(at: runs[k].range.location) == 35 { atxMarker = true } }
            if firstContent < 0 && !s.isEmpty { firstContent = runs[k].range.location }
            k += 1
        }
        if tableRow && lr.length > 60 {
            let line = t.substring(with: lr) as NSString
            hasPipe = line.range(of: "|").location != NSNotFound
            if !hasPipe { tableProse += 1; add("table-row-without-pipe", lr.location, Double(lr.length)) }
        }
        if codeLine { if inFence { fencedCodeLines += 1 } else { indentedCodeLines += 1 } }
        if hasFence {
            if !inFence { inFence = true; fenceOpenLine = l; fenceOpenOff = lr.location } else { inFence = false }
        }
        if headingLevel == 1 && atxMarker {
            let line = t.substring(with: lr)
            let body = line.drop(while: { $0 == " " || $0 == "#" }).trimmingCharacters(in: .whitespaces)
            // A '#' comment of an unfenced shell / Python snippet: lower-case text or code punctuation, directly after a non-blank line
            // that is not itself a heading (an ATX heading may interrupt a paragraph, a comment line usually follows code).
            let prevLine = l > 1 ? t.substring(with: li.range(ofLine: l - 1, in: t)).trimmingCharacters(in: .whitespaces) : ""
            if !prevLine.isEmpty && !prevLine.hasPrefix("#"), let c = body.first, c.isLowercase || body.contains("=") || body.contains(";") || body.contains("()") || body.hasPrefix("!") || body.hasPrefix("/") || body.hasPrefix("$") {
                add("h1-looks-like-code-comment", lr.location, 1)
            }
        }
    }
    if codeCover { add("codeblock-cover>50%", 0, Double(codeUnits) / Double(n) * 100, "\(codeUnits * 100 / n)% of the document; code lines: \(fencedCodeLines) fenced, \(indentedCodeLines) indented") }
    if inFence {
        let coverage = Double(n - fenceOpenOff) / Double(n)
        add("fence-unclosed-at-eof", fenceOpenOff, coverage * 100, "opens on line \(fenceOpenLine), covers \(Int(coverage * 100))% of the document")
    }
    // setext headings: heading runs whose first line has no '#'
    do {
        var i = 0
        while i < runs.count {
            let s = runs[i].style
            if s.headingLevel > 0 {
                var j = i
                var hasATXMarker = false
                var end = runs[i].range.location
                while j < runs.count && runs[j].style.headingLevel == s.headingLevel {
                    if runs[j].style.contains(.marker) && runs[j].range.length > 0 && t.character(at: runs[j].range.location) == 35 { hasATXMarker = true }
                    end = runs[j].range.location + runs[j].range.length
                    j += 1
                }
                if !hasATXMarker {
                    let sl = li.line(of: runs[i].range.location), el = li.line(of: max(0, end - 1))
                    if el - sl >= 3 { add("setext-heading-long", runs[i].range.location, Double(el - sl), "\(el - sl) lines") }
                    else if end - runs[i].range.location > 400 { add("setext-heading-long", runs[i].range.location, Double(end - runs[i].range.location), "\(end - runs[i].range.location) units") }
                }
                i = j
            } else { i += 1 }
        }
    }

    // 4. characters in plain runs: stray strong markers, missed links, bare URLs in quotes
    let nonText: MDStyle = [.inlineCode, .codeBlock, .codeFence, .html, .frontMatter, .linkDestination, .autolink, .marker, .linkText, .image, .escape, .referenceLabel, .footnote, .horizontalRule]
    for r in runs where r.style.isDisjoint(with: nonText) && r.range.length >= 2 {
        let sub = t.substring(with: r.range) as NSString
        var from = 0
        while from < sub.length {
            let a = sub.range(of: "**", options: [], range: NSRange(location: from, length: sub.length - from))
            let b = sub.range(of: "__", options: [], range: NSRange(location: from, length: sub.length - from))
            let hit = (a.location == NSNotFound) ? b : (b.location == NSNotFound ? a : (a.location < b.location ? a : b))
            if hit.location == NSNotFound { break }
            // not a run of 3+ (hr / banner)
            let abs = r.range.location + hit.location
            if !(hit.length == 2 && abs + 2 < n && t.character(at: abs + 2) == t.character(at: abs)) && !(abs > 0 && t.character(at: abs - 1) == t.character(at: abs)) {
                add("stray-strong-marker", abs, 1)
            }
            from = hit.location + hit.length
        }
        var q = sub.range(of: "](")
        while q.location != NSNotFound {
            add("link-not-recognised", r.range.location + q.location, 1)
            let nf = q.location + 2
            if nf >= sub.length { break }
            q = sub.range(of: "](", options: [], range: NSRange(location: nf, length: sub.length - nf))
        }
        for pre in ["\"http", "'http", "[http", "{http", "=http", ":http", ",http"] {
            var u = sub.range(of: pre)
            while u.location != NSNotFound {
                add("bare-url-after-\(pre.first!)", r.range.location + u.location, 1)
                let nf = u.location + pre.count
                if nf >= sub.length { break }
                u = sub.range(of: pre, options: [], range: NSRange(location: nf, length: sub.length - nf))
            }
        }
    }
    // 5. autolink ending in punctuation
    for r in runs where r.style.contains(.autolink) && !r.style.contains(.marker) {
        let last = t.character(at: r.range.location + r.range.length - 1)
        if last == 41 || last == 93 || last == 46 || last == 44 || last == 59 || last == 58 || last == 33 || last == 63 || last == 39 || last == 34 || last == 62 {
            add("autolink-ends-in-punctuation", r.range.location, 1)
        }
    }
    // 6. indented code that the lexer left plain: a line indented 4+ columns, directly after a code line or only blank lines after
    //    one, must itself be code (CommonMark). (Before the pending-blank-lines fix this fired 551 times in 91 documents.)
    var prevCode = false, gap = false
    for l in 1...li.starts.count {
        let lr = li.range(ofLine: l, in: t)
        var lo = 0, hi = runs.count
        while lo < hi { let m = (lo + hi) / 2; if runs[m].range.location + runs[m].range.length <= lr.location { lo = m + 1 } else { hi = m } }
        let k = lo
        let blank = lr.length == 0 || t.substring(with: lr).trimmingCharacters(in: .whitespaces).isEmpty
        let lead = lr.length > 0 ? t.character(at: lr.location) : 0
        let isCode = k < runs.count && runs[k].style.contains(.codeBlock) && !runs[k].style.contains(.codeFence) && (lead == 32 || lead == 9)
        if blank { if prevCode { gap = true }; continue }
        if gap && !isCode && lr.length >= 5 && t.substring(with: NSRange(location: lr.location, length: 4)) == "    " && k < runs.count && runs[k].style.isDisjoint(with: [.codeBlock, .codeFence, .html, .frontMatter]) {
            add("indented-after-code-not-code", lr.location, 1)
        }
        prevCode = isCode
        gap = false
    }
    return out
}

// MARK: - Edits modelled on real editing

func corpusEdit(_ r: inout RNG, _ t: NSString, _ lines: [Int]) -> Step {
    let n = t.length
    let k = r.int(100)
    func lineRange(_ i: Int) -> NSRange {
        let s = lines[i]
        let e = i + 1 < lines.count ? lines[i + 1] : n
        return NSRange(location: s, length: e - s)
    }
    if n > 0 && k < 18 && lines.count > 1 {           // duplicate a line somewhere else (copy / paste)
        let src = lineRange(r.int(lines.count))
        let text = src.length > 2000 ? "" : t.substring(with: src)
        return .edit(loc: lines[r.int(lines.count)], len: 0, repl: text.hasSuffix("\n") || text.isEmpty ? text : text + "\n", budget: 0)
    }
    if n > 0 && k < 32 && lines.count > 1 {           // delete a line or a few
        let i = r.int(lines.count)
        let j = min(lines.count - 1, i + r.range(0, 3))
        let a = lineRange(i).location, b = lineRange(j).location + lineRange(j).length
        return .edit(loc: a, len: b - a, repl: "", budget: 0)
    }
    if n > 0 && k < 40 {                              // open or close a fence / comment where a line starts
        let marker = r.pick(["```\n", "~~~\n", "<!--\n", "-->\n", "---\n", "> ", "- ", "    ", "1. "])
        return .edit(loc: lines[r.int(lines.count)], len: 0, repl: marker, budget: r.chance(0.3) ? 2000 : 0)
    }
    if n > 0 && k < 50 {                              // type a character in the middle of a line
        return .edit(loc: r.int(n + 1), len: 0, repl: r.pick(["a", " ", "*", "_", "`", "[", "]", "(", "|", "#", "\n", "é", "😀"]), budget: 0)
    }
    if n > 0 && k < 58 {                              // delete a character (backspace)
        return .edit(loc: max(0, r.int(n + 1) - 1), len: 1, repl: "", budget: 0)
    }
    return randomEdit(&r, t)
}

// MARK: - The runner

struct CorpusStats {
    var files = 0, bytes = 0, units = 0, runs = 0
    var invalidUTF8 = 0, bom = 0, crlf = 0, empty = 0
    var lexSeconds = 0.0, lexSecondsBig = 0.0, bytesBig = 0
    var invariantFailures: [String] = []
    var incrementalFailures: [String] = []
    var oracleFailed = 0
    var edits = 0
    var oddities: [Oddity] = []
    var oracleDiffs: [String: (count: Int, files: Set<String>, samples: [String])] = [:]
    var oracleTokensCompared = 0
    var oracleDiffTokens = 0
    var filesWithOracleDiff = 0
    var oracleFileDiffs: [(path: String, regions: Int, tokens: Int)] = []
}

private func nowSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func runRealCorpus(editsPerFile: Int, seed: UInt64, doOracle: Bool, doOddities: Bool, review: Int, limit: Int) {
    let t0 = nowSeconds()
    let files = loadCorpus(limit: limit)
    var st = CorpusStats()
    var rng = RNG(seed: seed)
    let styler = MarkdownStyler()
    var seenContents = Set<String>()
    print("corpus: \(files.count) files, \(files.reduce(0) { $0 + $1.bytes }) bytes (loaded in \(String(format: "%.2f", nowSeconds() - t0)) s)")
    for (fi, f) in files.enumerated() {
        let t = NSString(string: f.text)
        st.files += 1; st.bytes += f.bytes; st.units += t.length
        if f.invalidUTF8 { st.invalidUTF8 += 1 }
        if f.hasBOM { st.bom += 1 }
        if f.text.contains("\r\n") { st.crlf += 1 }
        if t.length == 0 { st.empty += 1; continue }

        // lexAll: best of 3 for timing
        var runs: [MDRun] = []
        var best = Double.infinity
        for _ in 0..<3 {
            let a = nowSeconds()
            runs = styler.lexAll(t)
            best = min(best, nowSeconds() - a)
        }
        st.lexSeconds += best
        if f.bytes >= 50_000 { st.lexSecondsBig += best; st.bytesBig += f.bytes }
        st.runs += runs.count
        let whole = MDResult(range: NSRange(location: 0, length: t.length), runs: runs)
        if let e = checkStructure(t, whole) { st.invariantFailures.append("\(shortPath(f.path)): \(e)") }

        // cold styleRuns over random ranges == slices of lexAll; and a whole-document pass in 8 KB slices on one styler
        do {
            let s2 = MarkdownStyler()
            var pos = 0
            var acc: [MDRun] = []
            while pos < t.length {
                let res = s2.styleRuns(in: NSRange(location: pos, length: min(8192, t.length - pos)), of: t)
                if let e = checkStructure(t, res, requested: NSRange(location: pos, length: min(8192, t.length - pos))) { st.invariantFailures.append("\(shortPath(f.path)) slice@\(pos): \(e)"); break }
                if sliceRuns(runs, to: res.range) != res.runs { st.invariantFailures.append("\(shortPath(f.path)) slice@\(pos): runs differ from lexAll"); break }
                acc += res.runs
                pos = res.range.location + res.range.length
            }
            for _ in 0..<3 {
                let loc = rng.int(t.length), len = rng.range(0, 3000)
                let res = MarkdownStyler().styleRuns(in: NSRange(location: loc, length: len), of: t)
                if sliceRuns(runs, to: res.range) != res.runs { st.invariantFailures.append("\(shortPath(f.path)) cold range \(loc)+\(len): runs differ from lexAll") }
            }
        }

        // incremental edits
        if editsPerFile > 0 {
            let config = rng.chance(0.5) ? FuzzConfig() : FuzzConfig.random(&rng)
            let shadow = NSMutableString(string: f.text)
            var steps: [Step] = [.query(loc: 0, len: min(shadow.length, 400))]
            let li = LineIndex(shadow)
            var lines = li.starts
            for e in 0..<editsPerFile {
                if e % 8 == 0 { lines = LineIndex(shadow).starts }
                let step = corpusEdit(&rng, shadow, lines)
                if case let .edit(l, nn, repl, _) = step {
                    let (loc, len) = normalizeEdit(shadow, l, nn)
                    shadow.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
                    let budget = rng.chance(0.25) ? rng.pick([1, 40, 300, 2000]) : 0
                    steps.append(.edit(loc: loc, len: len, repl: repl, budget: budget))
                    // line starts are stale after an edit: refresh lazily every few edits, clamp positions otherwise
                    lines = lines.map { min($0, shadow.length) }
                    st.edits += 1
                }
                for _ in 0..<(rng.chance(0.6) ? rng.range(0, 2) : 3) { steps.append(randomQuery(&rng, shadow.length)) }
            }
            if let (idx, msg) = runScenario(initial: f.text, config: config, steps: steps) {
                st.incrementalFailures.append("\(shortPath(f.path)) step \(idx) [\(config.text)]: \(msg)")
            }
        }

        let isDup = !seenContents.insert(f.text).inserted
        let skipForReview = (isDup && !corpusFlags.contains("dups")) || (isParserFixture(f.path) && !corpusFlags.contains("fixtures"))
        if doOddities && !skipForReview { st.oddities += detectOddities(file: shortPath(f.path), text: t, runs: runs) }

        if doOracle && !(corpusFlags.contains("real") && skipForReview) { oracleCompare(f, styler, &st) }
        if (fi + 1) % 200 == 0 { print("  … \(fi + 1) files (\(String(format: "%.1f", nowSeconds() - t0)) s)") }
    }
    let total = nowSeconds() - t0

    print("")
    print("== corpus statistics ==")
    print("files \(st.files) (empty \(st.empty), invalid UTF-8 \(st.invalidUTF8), BOM \(st.bom), CRLF \(st.crlf)), \(st.bytes) bytes, \(st.units) UTF-16 units, \(st.runs) runs (\(String(format: "%.1f", Double(st.bytes) / Double(max(1, st.runs)))) bytes/run)")
    let mbps = Double(st.bytes) / 1e6 / max(1e-9, st.lexSeconds)
    print(String(format: "lexAll: %.1f ms total (best of 3 per file) = %.0f MB/s over the whole corpus; files >= 50 KB: %.0f MB/s (%d KB); mean %.1f us per file",
                 st.lexSeconds * 1000, mbps, Double(st.bytesBig) / 1e6 / max(1e-9, st.lexSecondsBig), st.bytesBig / 1000, st.lexSeconds * 1e6 / Double(max(1, st.files))))
    print("structural invariant / cold-range failures: \(st.invariantFailures.count)")
    for m in st.invariantFailures.prefix(10) { print("   \(m)") }
    print("incremental == full: \(st.edits) random edits over \(st.files) files, failures: \(st.incrementalFailures.count)")
    for m in st.incrementalFailures.prefix(10) { print("   \(m)") }

    if doOddities {
        var byClass: [String: [Oddity]] = [:]
        for o in st.oddities { byClass[o.cls, default: []].append(o) }
        print("")
        print("== oddity classes (\(st.oddities.count) instances) ==")
        print("| class | instances | files |")
        print("|---|---|---|")
        for (c, l) in byClass.sorted(by: { $0.value.count > $1.value.count }) {
            print("| \(c) | \(l.count) | \(Set(l.map(\.file)).count) |")
        }
        if let dumpClass = corpusStringOpt("dump") {
            print("")
            print("== all \(dumpClass) instances ==")
            for o in (byClass[dumpClass] ?? []).sorted(by: { ($0.file, $0.line) < ($1.file, $1.line) }) { print("\(o.file):\(o.line)  \(o.excerpt)") }
        }
        print("")
        print("== top \(review) oddities for review (highest score per class, round robin) ==")
        var queues: [(String, [Oddity])] = byClass.map { ($0.key, $0.value.sorted { $0.score > $1.score }) }.sorted { $0.0 < $1.0 }
        var shown = 0
        var round = 0
        while shown < review && queues.contains(where: { $0.1.count > round }) {
            for (c, l) in queues where l.count > round && shown < review {
                let o = l[round]
                print("[\(c)] \(o.file):\(o.line)  \(o.excerpt)")
                shown += 1
            }
            round += 1
        }
        queues = []
    }
    if doOracle {
        print("")
        print("== cmark-gfm differential (letters and digits; block flags: code block, quote, table, heading level) ==")
        print("files compared \(st.files - st.oracleFailed), oracle could not parse \(st.oracleFailed); tokens compared \(st.oracleTokensCompared); differing tokens (lexer side) \(st.oracleDiffTokens); files with any difference \(st.filesWithOracleDiff)")
        print("files with differences (regions / differing tokens):")
        for x in st.oracleFileDiffs.sorted(by: { $0.tokens > $1.tokens }) { print("   \(x.regions) / \(x.tokens)  \(x.path)") }
        print("| difference class (oracle vs lexer) | regions | files |")
        print("|---|---|---|")
        for (c, v) in st.oracleDiffs.sorted(by: { $0.value.count > $1.value.count }).prefix(60) {
            print("| \(c) | \(v.count) | \(v.files.count) |")
        }
        print("")
        for (c, v) in st.oracleDiffs.sorted(by: { $0.value.count > $1.value.count }).prefix(40) {
            print("[\(c)]  \(v.count) regions")
            for s in v.samples { print("    \(s)") }
        }
    }
    print(String(format: "\ntotal wall time %.1f s", total))
}

/// Differential comparison of one file against the cmark-gfm oracle.
private func oracleCompare(_ f: CorpusFile, _ styler: MarkdownStyler, _ st: inout CorpusStats) {
    var text = f.text
    var t = NSString(string: text)
    var runs = styler.lexAll(t)
    // Front matter is not CommonMark: compare the body only.
    if let first = runs.first, first.style.contains(.frontMatter) {
        var end = 0
        for r in runs { if r.style.contains(.frontMatter) { end = r.range.location + r.range.length } else { break } }
        text = t.substring(from: end)
        t = NSString(string: text)
        runs = styler.lexAll(t)
    }
    guard var o = oracleTokens(text, alnumOnly: true) else { st.oracleFailed += 1; return }
    var l = lexerTokens(t, runs, alnumOnly: true)
    st.oracleTokensCompared += l.count
    // Whole documents are compared on BLOCK structure only (code block, quote, table, heading level) plus the text itself:
    // Foundation's attribute conversion loses inline facets in several situations (code or emphasis inside link text, nested
    // same-kind emphasis), which would drown the signal. Inline syntax is compared by the synthetic fuzz (--oracle-fuzz).
    // `inline` also compares emphasis / strong / code / strike (noisier: use it to hunt for prose defects, not as a pass / fail check).
    var mask: UInt16 = OFlag.codeBlock | OFlag.quote | OFlag.table | (7 << OFlag.headingShift)
    if corpusFlags.contains("inline") { mask |= OFlag.em | OFlag.strong | OFlag.code | OFlag.strike }
    if corpusFlags.contains("links") { mask = OFlag.link | OFlag.img }          // links / images only (bare URLs, autolinks, link text)
    for i in 0..<o.count { o[i].f &= mask }
    for i in 0..<l.count { l[i].f &= mask }
    let o2 = corpusFlags.contains("inline") ? tolerateOracleNesting(o, l) : o
    if o2 == l { return }
    let diffs = diffTokens(o2, l)
    if diffs.isEmpty { return }
    st.filesWithOracleDiff += 1
    st.oracleFileDiffs.append((f.path, diffs.count, diffs.reduce(0) { $0 + max($1.lexer.count, $1.oracle.count) }))
    let li = LineIndex(t)
    for d in diffs {
        st.oracleDiffTokens += d.lexer.count
        let sameChars = d.oracle.map(\.c) == d.lexer.map(\.c)
        func union(_ s: ArraySlice<OTok>) -> UInt16 { s.reduce(0) { $0 | $1.f } }
        let ou = union(d.oracle), lu = union(d.lexer)
        let key: String
        if sameChars {
            let onlyO = ou & ~lu, onlyL = lu & ~ou
            let hO = (ou >> OFlag.headingShift) & 7, hL = (lu >> OFlag.headingShift) & 7
            var on = OFlag.names(onlyO & 0x1FF), ln = OFlag.names(onlyL & 0x1FF)
            if hO != hL { on += " h\(hO)"; ln += " h\(hL)" }
            key = "flags: oracle \(on == "plain" ? "-" : on) / lexer \(ln == "plain" ? "-" : ln)"
        } else if d.oracle.isEmpty {
            key = "extra text in lexer (\(OFlag.names(lu)))"
        } else if d.lexer.isEmpty {
            key = "text missing in lexer (oracle \(OFlag.names(ou)))"
        } else {
            key = "text differs: oracle \(OFlag.names(ou)) / lexer \(OFlag.names(lu))"
        }
        var entry = st.oracleDiffs[key] ?? (0, [], [])
        entry.count += 1
        entry.files.insert(shortPath(f.path))
        if entry.samples.count < Int(corpusStringOpt("samples") ?? "4")! && !entry.files.isEmpty {
            let line = d.lexerOffset >= 0 ? li.line(of: d.lexerOffset) : 0
            let src = line > 0 ? clip(t.substring(with: li.range(ofLine: line, in: t)), 100) : ""
            entry.samples.append("\(shortPath(f.path)):\(line)  oracle \(tokString(d.oracle, max: 40)) | lexer \(tokString(d.lexer, max: 40))  ⟨\(src)⟩")
        }
        st.oracleDiffs[key] = entry
    }
}
