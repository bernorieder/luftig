import Foundation
import MarkdownKit

// MARK: - RNG

struct RNG {
    var s: UInt64
    init(seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func range(_ lo: Int, _ hi: Int) -> Int { lo + int(hi - lo + 1) }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000.0 < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

// MARK: - Generator

enum Gen {
    static let paragraphs = [
        "Some plain text here", "text with *em* and **strong** words", "snake_case_name and _under_ and __dunder__",
        "`code` and ``dou`ble`` ticks", "unclosed `tick here", "unclosed *star here", "a * b * c", "~~strike~~ and ~~un",
        "[link](http://x.com 'title') and [ref][r] and [r][] and [^1]", "![img](a.png \"t\") ![alt][r]",
        "<https://a.b/c> and <me@x.org> and http://bare.url/p_a_t_h. and www.example.com/x", "<span class=\"a\">html</span> <b>x</b>",
        "<!-- inline --> text", "a \\* b \\` c \\\\ d", "&amp; &#35; &#x1F600; &bogus", "😀 emoji 👍🏽 text 𝒳 and 日本語のテキスト",
        "***both*** and **_mixed_** and *__mixed2__*", "**bold *nested em* bold** end", "foo**bar**baz and foo__bar__baz",
        "[a](b) [c](<d e> \"f\") [g](h (i)) [unclosed](", "[[nested]] ]] [[ [x]", "line ending with two spaces  ", "tab\tinside\ttext",
        "https://example.com/a(b)c)d and (http://x.y)", "see www.x.org/a&hl; and [ http://y.org/b&amp; z", "[a www.x.org](u) [x] http://z.org <!--> c <!---> d", "x", "e\u{301} *é\u{301}* 👨‍👩‍👧 *👨‍👩‍👧* \u{A0}*nb*\u{A0}", "a\u{0}b `\u{0}` \u{2028} x", "a|b|c", "\\", "`", "``", "*", "**", "_", "~~", "[", "]", "![", "<", ">", "&",
    ]
    static let blocks = [
        "# Title", "## Sub **bold**", "### ", "#", "####### seven", "#nospace", "# closing ##", "###### six #",
        "> quote", ">> nested", "> ", ">", "> - item in quote", "> > deep *em*", ">     code in quote",
        "- item", "* item", "+ item", "1. one", "2) two", "10. ten", "- [ ] task", "- [x] done", "* [X] Done", "  - nested", "    - deeper",
        "-", "1.", "- ", "   - three", "      - six", "1. - mixed", "- > quote in list", "- # heading in list", "- ```", "  ```",
        "```", "```swift", "~~~", "~~~~~", "````", "``` x `", "```` y", "  ```", "> ```", "- ~~~ lang",
        "---", "***", "___", "- - -", "* * *", "===", "--", "==", "=", "-",
        "| a | b |", "|---|---|", "a | b", "--- | ---", ":-: | --:", "| x |", "|-|", "| a | b | c |", "|:--|--:|:-:|", "\\| esc | x",
        "<div>", "</div>", "<!--", "-->", "<pre>", "</pre>", "<br>", "<?php", "?>", "<img src=x>", "<script>", "</script>", "<p>", "<custom-tag>",
        "    code", "\tcode", "        deep", "  two", "   three",
        "[r]: http://x.com", "[r]: <u> 'title'", "[^1]: footnote text", "[^1]:", "[r]:", "[bad]: x y z",
        "title: x", "key: value", "...",
    ]
    static let separators = ["\n", "\n", "\n", "\n", "\n", "\n", "\r\n", "\r"]
    /// Multi-line fragments around indented code with blank lines (the pending-blank-lines state), inside lists and quotes too.
    static let codeComposites = [
        "    one\n\n    two", "    one\n  \n\n\t\n    two", ">     one\n>\n>     two", "- a\n\n      one\n\n      two\n- b",
        "1. a\n\n       one\n\n       two", "    one\n\npara\n\n    two", "    one\n\n\n> q\n\n    two", "-     one\n\n      two\n",
        "> a\n>\n>     one\n\n>     two", "- [ ] t\n\n      one", "[^1]: a\n\n          one\n\n          two", "    one\n\n\t\ttwo\n\n  \n\tthree",
        // empty list items followed by a blank line (the item ends there), and lone HTML tags on lazy continuation lines
        "-\n\n    one", "1.\n\n      two", "> -\n>\n>     x", "-\n    a\n\n    b", "- a\n  -\n\n    b", "- a\n\n  -\n\n      c", "* -\n\n    x", "-  \n\n  y",
        "- item\n<br>\ntext", "> q\n<span>\nmore", "1. a\n</pre>\n*x*", "> a\n> <br>\n> b", "- a\n<div>\nb"]

    static func fragment(_ r: inout RNG) -> String {
        r.chance(0.55) ? r.pick(blocks) : r.pick(paragraphs)
    }

    static func document(_ r: inout RNG) -> String {
        var s = ""
        let lines = r.chance(0.12) ? r.range(150, 500) : r.range(2, 110)
        let crlf = r.chance(0.12)
        if r.chance(0.18) { s += "---\n" + r.pick(["title: x\n", "a: b\nc: d\n", ""]) + r.pick(["---\n", "...\n", ""]) }
        for _ in 0..<lines {
            let k = r.int(100)
            if k < 12 { s += "" }                                        // blank line
            else if k < 14 { s += "  " }
            else if k < 20 {                                            // indent + fragment
                s += String(repeating: " ", count: r.range(1, 6)) + fragment(&r)
            } else if k < 26 {                                          // several fragments on a line
                s += fragment(&r) + " " + fragment(&r) + " " + fragment(&r)
            } else if k < 32 {
                s += r.pick(codeComposites)
            } else {
                s += fragment(&r)
            }
            s += crlf ? "\r\n" : (r.chance(0.05) ? r.pick(separators) : "\n")
        }
        if r.chance(0.3), s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    static let exotic: [String] = ["\u{0}", "\u{2028}", "\u{A0}", "\u{3000}", "e\u{301}", "👨‍👩‍👧", "🇩🇪", "\u{200B}", "𝒳", "\u{FEFF}", "\u{7F}", "\u{1}"]
    static let specialChars: [String] = ["*", "_", "`", "#", ">", "-", "|", "~", "[", "]", "(", ")", "<", "\n", " ", ":", "=", "!", "\\", "&", "\t", "+", "1", ".", "x", "\r", "\r\n", "😀", "é", "^", "$", "\"", "'", "/", "{", ";"]

    static func insertion(_ r: inout RNG) -> String {
        let k = r.int(100)
        if k < 40 { return r.pick(specialChars) }
        if k < 70 { return fragment(&r) + (r.chance(0.6) ? "\n" : "") }
        if k < 80 { return r.pick(specialChars) + r.pick(specialChars) }
        if k < 88 { return "\n" }
        if k < 94 { return String(repeating: r.pick(["`", "~", "*", "-", " ", ">", "#", "|"]), count: r.range(2, 5)) }
        if k < 97 { return r.pick(exotic) }
        return r.pick(["\n\n", "\r\n", "  ", "```\n", "---\n", "> ", "- ", "| a | b |\n|---|---|\n", "<!--", "-->"])
    }
}

// MARK: - Scenario

nonisolated(unsafe) var fuzzOracleUnits = 0
nonisolated(unsafe) var fuzzOracleRuns = 0
nonisolated(unsafe) var fuzzSteps = 0
nonisolated(unsafe) var fuzzOracleCount = 0

enum Step {
    case edit(loc: Int, len: Int, repl: String, budget: Int)   // budget > 0: bounded update(maxRegion:)
    case query(loc: Int, len: Int)
    case reset

    var text: String {
        switch self {
        case let .edit(l, n, r, b): return "edit(loc: \(l), len: \(n), repl: \"\(visible(r))\"" + (b > 0 ? ", maxRegion: \(b)" : "") + ")"
        case let .query(l, n): return "query(loc: \(l), len: \(n))"
        case .reset: return "reset"
        }
    }
}

struct FuzzConfig {
    var stride = 2048, maxLines = 256, maxUnits = 65536, fmWindow = 16384
    var chunk = 0, slideMin = 131072, slideLow = 16384, poison = false
    var text: String { "stride=\(stride) maxParaLines=\(maxLines) maxParaUnits=\(maxUnits) fmWindow=\(fmWindow) chunk=\(chunk) slideMin=\(slideMin) slideLow=\(slideLow) poison=\(poison)" }
    static func random(_ r: inout RNG) -> FuzzConfig {
        var c = FuzzConfig()
        if r.chance(0.2) { return c }
        c.stride = r.pick([1, 8, 32, 128, 512, 2048])
        c.maxLines = r.pick([2, 3, 5, 12, 256, 256])
        c.maxUnits = r.pick([12, 40, 120, 65536, 65536])
        c.fmWindow = r.pick([24, 60, 200, 16384, 16384])
        c.poison = r.chance(0.5)
        if r.chance(0.5) {                      // tiny windows: exercise window growth and sliding
            c.chunk = r.pick([1, 3, 8, 16, 64, 200])
            c.slideMin = r.pick([0, 8, 32, 100])
            c.slideLow = r.pick([4, 16, 64, 1000])
        }
        return c
    }
}

func makeStyler(_ c: FuzzConfig) -> MarkdownStyler {
    let s = MarkdownStyler()
    s.debugConfigure(strideUnits: c.stride, maxParagraphLines: c.maxLines, maxParagraphUnits: c.maxUnits, frontMatterWindow: c.fmWindow,
                     chunk: c.chunk, slideMin: c.slideMin, slideLow: c.slideLow, poison: c.poison)
    return s
}

/// Clamp an edit so it is valid for `t` and does not split a surrogate pair.
func normalizeEdit(_ t: NSString, _ loc: Int, _ len: Int) -> (Int, Int) {
    let n = t.length
    var a = max(0, min(loc, n))
    var b = max(a, min(a + max(0, len), n))
    if a > 0 && a < n {
        let p = t.character(at: a - 1), c = t.character(at: a)
        if p >= 0xD800 && p <= 0xDBFF && c >= 0xDC00 && c <= 0xDFFF { a -= 1 }
    }
    if b > 0 && b < n {
        let p = t.character(at: b - 1), c = t.character(at: b)
        if p >= 0xD800 && p <= 0xDBFF && c >= 0xDC00 && c <= 0xDFFF { b += 1 }
    }
    return (a, b - a)
}

/// Executes steps against a styler and a fresh-lex oracle; returns the index of the failing step and a message.
func runScenario(initial: String, config: FuzzConfig, steps: [Step]) -> (Int, String)? {
    let text = NSMutableString(string: initial)
    let styler = makeStyler(config)
    // The oracle shares only the semantic limits (paragraph caps, front matter window); stride / window
    // size / sliding are non-semantic tuning knobs and deliberately differ.
    let oracle = MarkdownStyler()
    oracle.debugConfigure(strideUnits: 2048, maxParagraphLines: config.maxLines, maxParagraphUnits: config.maxUnits, frontMatterWindow: config.fmWindow)
    var oracleRuns: [MDRun]? = nil
    var applied = [Int64](repeating: -1, count: text.length)   // simulated attributes in the app, -1 = unknown

    func getOracle() -> [MDRun] {
        if let o = oracleRuns { return o }
        let o = oracle.lexAll(text)
        fuzzOracleUnits += text.length
        fuzzOracleCount += 1
        fuzzOracleRuns += o.count
        oracleRuns = o
        return o
    }

    func verify(_ res: MDResult, requested: NSRange?, label: String, stale: Int? = nil) -> String? {
        if let e = checkStructure(text, res, requested: requested) { return "\(label): structure: \(e)" }
        let exp = sliceRuns(getOracle(), to: res.range)
        if exp != res.runs {
            return "\(label): runs differ from fresh lexAll over \(res.range)\n      \(describeDiff(text, expected: exp, actual: res.runs))"
        }
        // simulate the app applying the attributes
        for r in res.runs {
            let v = Int64(r.style.rawValue)
            for i in r.range.location..<(r.range.location + r.range.length) { applied[i] = v }
        }
        if let sf = stale {
            if sf < res.range.location + res.range.length || sf > text.length { return "\(label): staleFrom \(sf) overlaps result \(res.range) or is out of bounds" }
            for i in sf..<applied.count { applied[i] = -1 }
        }
        // everything the app believes must still be right
        let all = getOracle()
        var k = 0
        for i in 0..<applied.count where applied[i] >= 0 {
            while k < all.count && all[k].range.location + all[k].range.length <= i { k += 1 }
            if k >= all.count || Int64(all[k].style.rawValue) != applied[i] {
                let ts = NSRange(location: max(0, i - 6), length: min(12, text.length - max(0, i - 6)))
                return "\(label): stale attribute at \(i) (near \"\(visible(text.substring(with: ts)))\"), app has \(MDStyle(rawValue: UInt32(applied[i]))) but fresh lex says \(k < all.count ? all[k].style.description : "-")"
            }
        }
        return nil
    }

    for (idx, step) in steps.enumerated() {
        fuzzSteps += 1
        switch step {
        case let .edit(l, n, repl, budget):
            let (loc, len) = normalizeEdit(text, l, n)
            let replLen = (repl as NSString).length
            text.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
            oracleRuns = nil
            applied.replaceSubrange(loc..<(loc + len), with: [Int64](repeating: -1, count: replLen))
            let res = styler.update(afterEdit: NSRange(location: loc, length: replLen), changeInLength: replLen - len, of: text, maxRegion: budget > 0 ? budget : nil)
            if text.length == 0 {
                if !res.runs.isEmpty { return (idx, "empty text must give no runs") }
                continue
            }
            if budget == 0 && res.staleFrom != nil { return (idx, "unbounded update reported staleFrom") }
            if let e = verify(res, requested: nil, label: "update after \(step.text)", stale: res.staleFrom) { return (idx, e) }
            if res.range.location > min(loc, text.length - 1) || res.range.location + res.range.length < min(loc + replLen, text.length) {
                return (idx, "update region \(res.range) does not cover edit [\(loc), \(loc + replLen))")
            }
        case let .query(l, n):
            if text.length == 0 {
                let res = styler.styleRuns(in: NSRange(location: 0, length: 0), of: text)
                if !res.runs.isEmpty { return (idx, "empty text must give no runs") }
                continue
            }
            let q = NSRange(location: max(0, min(l, text.length)), length: max(0, n))
            let res = styler.styleRuns(in: q, of: text)
            if let e = verify(res, requested: q, label: "styleRuns(\(q.location), \(q.length))") { return (idx, e) }
        case .reset:
            styler.reset()
            applied = [Int64](repeating: -1, count: text.length)
        }
    }
    return nil
}

/// Produces a random edit step for the current text.
func randomEdit(_ r: inout RNG, _ t: NSString) -> Step {
    let n = t.length
    func lineStarts() -> [Int] {
        var a = [0]
        var i = 0
        while i < n {
            let c = t.character(at: i)
            if c == 10 { a.append(i + 1) }
            else if c == 13 { if i + 1 < n && t.character(at: i + 1) == 10 { i += 1 }; a.append(i + 1) }
            i += 1
        }
        return a
    }
    var loc: Int
    let pk = r.int(100)
    if n == 0 { loc = 0 }
    else if pk < 40 { loc = r.int(n + 1) }
    else if pk < 70 { let ls = lineStarts(); loc = r.pick(ls) }
    else if pk < 90 {
        let ls = lineStarts(); let s = r.pick(ls)
        var e = s
        while e < n && t.character(at: e) != 10 && t.character(at: e) != 13 { e += 1 }
        loc = e
    } else { loc = r.chance(0.5) ? 0 : n }
    let kind = r.int(100)
    if kind < 48 || n == 0 {
        return .edit(loc: loc, len: 0, repl: Gen.insertion(&r), budget: 0)
    } else if kind < 75 {
        var len = r.int(100) < 70 ? r.range(1, 4) : (r.chance(0.7) ? r.range(5, 40) : r.range(40, 400))
        if r.chance(0.2) {                                           // delete a whole line
            var e = loc
            while e < n && t.character(at: e) != 10 { e += 1 }
            len = min(n, e + 1) - loc
        }
        return .edit(loc: loc, len: len, repl: "", budget: 0)
    } else {
        let len = r.range(1, 8)
        return .edit(loc: loc, len: len, repl: Gen.insertion(&r), budget: 0)
    }
}

func randomQuery(_ r: inout RNG, _ n: Int) -> Step {
    if n == 0 { return .query(loc: 0, len: 0) }
    let k = r.int(100)
    if k < 10 { return .query(loc: 0, len: n) }
    if k < 20 { return .query(loc: n, len: 0) }
    if k < 25 { return .query(loc: n - 1, len: 1) }
    let loc = r.int(n)
    return .query(loc: loc, len: r.chance(0.3) ? 0 : r.range(1, 300))
}

func stepsDescription(_ steps: [Step]) -> String {
    steps.enumerated().map { "      \($0.offset): \($0.element.text)" }.joined(separator: "\n")
}

/// Greedy delta-debugging of a failing scenario: repeatedly remove chunks of steps and of initial text,
/// and simplify edit payloads, until nothing more can be removed (or the replay budget is exhausted).
func minimize(initial: String, config: FuzzConfig, steps: [Step]) -> (String, [Step]) {
    var units = Array(initial.utf16)
    var st = steps
    var budget = 60000
    func fails(_ u: [UInt16], _ s: [Step]) -> Bool {
        budget -= 1
        let str = String(decoding: u, as: UTF16.self)
        if str.utf16.count != u.count { return false }       // do not introduce lone surrogates
        return runScenario(initial: str, config: config, steps: s) != nil
    }
    var changed = true
    while changed && budget > 0 {
        changed = false
        // steps
        var chunk = max(1, st.count / 2)
        while budget > 0 {
            var i = 0
            while i < st.count && budget > 0 {
                var cand = st
                cand.removeSubrange(i..<min(st.count, i + chunk))
                if fails(units, cand) { st = cand; changed = true } else { i += chunk }
            }
            if chunk == 1 { break }
            chunk = max(1, chunk / 2)
        }
        // initial text
        chunk = max(1, units.count / 2)
        while budget > 0 {
            var i = 0
            while i < units.count && budget > 0 {
                var cand = units
                cand.removeSubrange(i..<min(units.count, i + chunk))
                if fails(cand, st) { units = cand; changed = true } else { i += chunk }
            }
            if chunk == 1 { break }
            chunk = max(1, chunk / 2)
        }
        // edit payloads: drop budgets, shorten replacements
        for k in 0..<st.count where budget > 0 {
            if case let .edit(l, n, r, b) = st[k] {
                if b > 0 { var c = st; c[k] = .edit(loc: l, len: n, repl: r, budget: 0); if fails(units, c) { st = c; changed = true } }
                if r.utf16.count > 1 { var c = st; c[k] = .edit(loc: l, len: n, repl: String(r.prefix(1)), budget: b); if fails(units, c) { st = c; changed = true } }
                if n > 1 { var c = st; c[k] = .edit(loc: l, len: 1, repl: r, budget: b); if fails(units, c) { st = c; changed = true } }
            }
        }
    }
    return (String(decoding: units, as: UTF16.self), st)
}

@discardableResult
func runFuzz(iterations: Int, seed: UInt64, verbose: Bool) -> Bool {
    var rng = RNG(seed: seed)
    var edits = 0
    var docs = 0
    let t0 = Date()
    while edits < iterations {
        docs += 1
        let config = FuzzConfig.random(&rng)
        let initial = Gen.document(&rng)
        let editsInDoc = rng.range(20, 200)
        // Build the step list on the fly against a shadow text, then run the scenario for real.
        let shadow = NSMutableString(string: initial)
        var steps: [Step] = [.query(loc: 0, len: min(shadow.length, 400))]
        for _ in 0..<min(editsInDoc, iterations - edits) {
            let e = randomEdit(&rng, shadow)
            if case let .edit(l, n, repl, _) = e {
                let (loc, len) = normalizeEdit(shadow, l, n)
                shadow.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
                let budget = rng.chance(0.25) ? rng.pick([1, 40, 300, 2000]) : 0
                steps.append(.edit(loc: loc, len: len, repl: repl, budget: budget))
            }
            edits += 1
            let nq = rng.int(100) < 70 ? rng.range(0, 2) : rng.range(3, 5)
            for _ in 0..<nq { steps.append(randomQuery(&rng, shadow.length)) }
            if rng.chance(0.01) { steps.append(.reset) }
        }
        if let (idx, msg) = runScenario(initial: initial, config: config, steps: steps) {
            print("FUZZ FAILURE seed=\(seed) doc=\(docs) editsSoFar=\(edits) config: \(config.text)")
            print("  \(msg)")
            let (mi, ms) = minimize(initial: initial, config: config, steps: Array(steps[0...idx]))
            print("  minimal reproduction (config: \(config.text)):")
            print("    initial text: \"\(visible(mi))\"")
            print("    steps:\n\(stepsDescription(ms))")
            if let (_, mmsg) = runScenario(initial: mi, config: config, steps: ms) { print("  failure on minimal case: \(mmsg)") }
            explainScenario(initial: mi, config: config, steps: ms)
            var plain = config; plain.poison = false; plain.chunk = 0; plain.slideMin = 131072; plain.slideLow = 16384
            print("  same minimal case with default window settings: \(runScenario(initial: mi, config: plain, steps: ms) == nil ? "passes" : "also fails")")
            var defaults = FuzzConfig(); defaults.maxLines = config.maxLines; defaults.maxUnits = config.maxUnits; defaults.fmWindow = config.fmWindow
            print("  same minimal case with default stride too: \(runScenario(initial: mi, config: defaults, steps: ms) == nil ? "passes" : "also fails")")
            return false
        }
        if verbose && docs % 100 == 0 {
            print(String(format: "  seed %llu: %d edits, %d documents, %.1fs", seed, edits, docs, Date().timeIntervalSince(t0)))
        }
    }
    if verbose {
        print(String(format: "fuzz OK: seed=%llu, %d random edits over %d documents in %.1fs (%d scenario steps, mean text %d UTF-16 units, %d runs per fresh lex)", seed, edits, docs, Date().timeIntervalSince(t0), fuzzSteps, fuzzOracleUnits / max(1, fuzzOracleCount), fuzzOracleRuns / max(1, fuzzOracleCount)))
    }
    return true
}


/// Replays a failing scenario and dumps the checkpoint list and result range of the last update.
func explainScenario(initial: String, config: FuzzConfig, steps: [Step]) {
    let text = NSMutableString(string: initial)
    let styler = makeStyler(config)
    for (i, step) in steps.enumerated() {
        let last = i == steps.count - 1
        switch step {
        case let .edit(l, n, repl, budget):
            let (loc, len) = normalizeEdit(text, l, n)
            let rl = (repl as NSString).length
            text.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
            if last {
                print("  --- before the last update: text length \(text.length - rl + len), frontier \(styler.debugFrontier)")
                let ts0 = text as NSString
                for c in styler.debugDumpCheckpoints() {
                    let off = Int(c.split(separator: " ")[0]) ?? 0
                    var e = off
                    while e < ts0.length && ts0.character(at: e) != 10 && ts0.character(at: e) != 13 { e += 1 }
                    print("      cp \(c)   | \(visible(ts0.substring(with: NSRange(location: off, length: min(50, e - off)))))")
                }
            }
            let r = styler.update(afterEdit: NSRange(location: loc, length: rl), changeInLength: rl - len, of: text, maxRegion: budget > 0 ? budget : nil)
            if last {
                print("  --- last update at \(loc) len \(len) -> \(rl): region \(r.range) staleFrom \(String(describing: r.staleFrom)) converged-state frontier \(styler.debugFrontier)")
                for c in styler.debugDumpCheckpoints() { print("      cp \(c)") }
                let ts = text as NSString
                let lo = max(0, r.range.location - 80), hi = min(ts.length, r.range.location + r.range.length + 40)
                print("  --- text [\(lo), \(hi)): \"\(visible(ts.substring(with: NSRange(location: lo, length: hi - lo))))\"")
            }
        case let .query(l, n):
            if text.length > 0 { _ = styler.styleRuns(in: NSRange(location: max(0, min(l, text.length)), length: max(0, n)), of: text) }
        case .reset:
            styler.reset()
        }
    }
}
