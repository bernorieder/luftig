#if LUFTIG_SELFTEST
// SelfTestIndent.swift - hanging indents of list items and indented continuation lines (HangingIndent.swift).
//
//   indent-attrs  attribute level: every line of a sample document has the head indent an INDEPENDENT reading of the text + the stored
//                 fonts gives; lines that are not list items / indented text are unchanged (head indent == first line indent)
//   indent-diff   2 x 1000 random edits that create / destroy list markers, change nesting, switch ordered numbers 9 -> 10 -> 100, toggle
//                 task markers, add / remove quote markers, open / close fences: styled == a fresh lex after them, one paragraph style per line
//
// The layout level (continuation lines start where the text starts, at several font sizes, lazily styled) is SelfTestIndentLayout.swift.
// The measurements (indent-bench) and the signature dump for comparing two builds (indent-dump) are SelfTestIndentAB.swift: they use only
// API that the build before this feature has as well, so the same file runs in both.

import AppKit
import MarkdownKit

// MARK: - the independent reading of a line

enum IndentOracle {
    /// What a person reads as the PREFIX of a source line: white space, block quote markers (`>` and the space after it), list markers (`-` `*` `+`,
    /// `1.` `1)` followed by a space), a task marker `[ ]` / `[x]` after a list marker, and the white space after each of them. Returns the length of
    /// the prefix in UTF-16 units when the line has text after it and the prefix holds a list marker or white space beyond the quote markers (the line
    /// hangs); nil otherwise. Written from the specification, not from HangingIndent.swift (which reads the lexer's runs).
    static func prefixLength(_ line: NSString) -> Int? {
        let n = line.length
        var i = 0
        var sawMarker = false, sawWhitespace = false, afterListMarker = false
        func ch(_ k: Int) -> unichar { line.character(at: k) }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        scan: while i < n {
            let c = ch(i)
            if c == 0x20 || c == 0x09 {
                while i < n, ch(i) == 0x20 || ch(i) == 0x09 { i += 1 }
                sawWhitespace = true
                continue
            }
            if c == 0x3E { i += 1; if i < n, ch(i) == 0x20 { i += 1 }; afterListMarker = false; continue }
            if c == 0x2D || c == 0x2A || c == 0x2B, i + 1 < n, ch(i + 1) == 0x20 || ch(i + 1) == 0x09 { i += 1; sawMarker = true; afterListMarker = true; continue }
            if isDigit(c) {
                var j = i
                while j < n, isDigit(ch(j)) { j += 1 }
                if j - i <= 9, j + 1 < n, ch(j) == 0x2E || ch(j) == 0x29, ch(j + 1) == 0x20 { i = j + 1; sawMarker = true; afterListMarker = true; continue }
            }
            if afterListMarker, c == 0x5B, i + 3 < n, ch(i + 2) == 0x5D, ch(i + 3) == 0x20, ch(i + 1) == 0x20 || ch(i + 1) == 0x78 || ch(i + 1) == 0x58 { i += 3; afterListMarker = false; continue }
            break scan
        }
        guard i < n, sawMarker || sawWhitespace else { return nil }
        return i
    }

    /// Number of block quote markers in the first `length` units of the line.
    static func quoteDepth(_ line: NSString, prefix length: Int) -> Int {
        var d = 0
        for k in 0..<length where line.character(at: k) == 0x3E { d += 1 }
        return min(3, d)
    }

    /// x position (from the left edge of the text container) at which the text of the line starts: the line's own indent plus the width of the prefix,
    /// summed from the advances of the fonts STORED on the prefix characters (NSAttributedString.size: not the CoreText calls of the implementation),
    /// tabs jumping to the next multiple of 28 pt. The text starts where its FIRST GLYPH is drawn: a family that kerns the space before a T (Avenir Next)
    /// moves it, so the last segment is measured with the first character and that character's own width is taken off again.
    static func textStartX(_ ts: NSTextStorage, lineStart: Int, prefix: Int, quoteDepth: Int) -> CGFloat {
        var x: CGFloat = quoteDepth > 0 ? DecorationMetrics.quoteIndent(depth: quoteDepth) : 0
        var k = lineStart
        let end = lineStart + prefix
        let text = ts.string as NSString
        while k < end {
            if text.character(at: k) == 0x09 { x = ((x / 28).rounded(.down) + 1) * 28; k += 1; continue }
            var j = k
            while j < end, text.character(at: j) != 0x09 { j += 1 }
            if j == end, end < text.length {
                let first = text.rangeOfComposedCharacterSequence(at: end)
                x += ts.attributedSubstring(from: NSRange(location: k, length: NSMaxRange(first) - k)).size().width - ts.attributedSubstring(from: first).size().width
            } else {
                x += ts.attributedSubstring(from: NSRange(location: k, length: j - k)).size().width
            }
            k = j
        }
        return x
    }

    /// Lines of a document with their ranges (including the line break).
    static func lines(of text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var loc = 0
        while loc < text.length { let r = text.lineRange(for: NSRange(location: loc, length: 0)); out.append(r); loc = NSMaxRange(r) }
        return out
    }

    /// Every line must carry ONE paragraph style over all its characters, including the line break (ARCHITECTURE.md, invariant 8). Returns the lines that do not.
    static func lineStyleIssues(_ ts: NSTextStorage, in range: NSRange? = nil, maxReport: Int = 4) -> [String] {
        let text = ts.string as NSString
        var issues: [String] = []
        let whole = range ?? NSRange(location: 0, length: ts.length)
        var loc = whole.location
        while loc < NSMaxRange(whole) && issues.count < maxReport {
            let lr = text.lineRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(lr)
            let first = ts.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle
            var p = lr.location
            while p < NSMaxRange(lr) {
                var eff = NSRange(location: 0, length: 0)
                let ps = ts.attribute(.paragraphStyle, at: p, longestEffectiveRange: &eff, in: lr) as? NSParagraphStyle
                if ps == nil || !(ps!.isEqual(first)) { issues.append("line \(NSStringFromRange(lr)) \(text.substring(with: NSRange(location: lr.location, length: min(24, lr.length))).debugDescription): style differs at \(p)"); break }
                p = NSMaxRange(eff)
            }
        }
        return issues
    }
}

// MARK: - the sample

enum IndentSample {
    /// (source line, `true`: the oracle reads it; `false`: it is not a plain line, so it must NOT hang).
    static let lines: [(String, Bool)] = [
        ("---", false), ("title: Hanging sample", false), ("tags: [a, b]", false), ("  - nested: front matter, never hanging", false), ("---", false),
        ("", false),
        ("# A heading that is long enough to wrap around the window edge", false),
        ("", false),
        ("A plain paragraph without any indent that is long enough to wrap around the right edge of a narrow window and still start at the left.", true),
        ("", false),
        ("- bullet minus", true),
        ("* bullet star", true),
        ("+ bullet plus", true),
        ("- Tango: the space before a T, A, V, W or Y is kerned by some families", true),
        ("1. Value, Wave and Yes: so is this one", true),
        ("- [ ] Task and Aim", true),
        ("- **bold** `code` [link](https://example.com/a) *italic* ~~strike~~ ![image](x.png) text", true),
        ("  hard-wrapped continuation of the item above (two spaces)", true),
        ("    - nested by four spaces", true),
        ("  - nested by two spaces", true),
        ("\t- nested by a tab", true),
        ("\t\t- nested by two tabs", true),
        ("", false),
        ("1. ordered one", true),
        ("2) ordered paren", true),
        ("9. ordered nine", true),
        ("10. ordered ten", true),
        ("99. ordered ninety nine", true),
        ("100. ordered hundred", true),
        ("999. ordered nine hundred ninety nine", true),
        ("", false),
        ("- [ ] open task", true),
        ("- [x] done task", true),
        ("- [X] done task, capital X", true),
        ("  - [ ] nested open task", true),
        ("1. [ ] ordered task", true),
        ("- - two markers", true),
        ("-   three spaces after the marker", true),
        ("", false),
        ("> - quoted bullet", true),
        ("> 1. quoted ordered", true),
        ("> > - doubly quoted bullet", true),
        ("> > 1. doubly quoted ordered", true),
        ("> - [ ] quoted task", true),
        (">   quoted continuation, two spaces beyond the marker", true),
        ("> plain quote line without indent", true),
        ("> > plain nested quote line", true),
        ("", false),
        ("   a paragraph indented by three spaces", true),
        ("   ", false),
        ("- ", false),
        ("", false),
        ("```swift", false), ("- not a list item inside a fence", false), ("  nor is this", false), ("\t- or this", false), ("```", false),
        ("", false),
        ("    - indented code that looks like a nested list item", false),
        ("", false),
        ("| a | - b |", false), ("|---|---|", false), ("| - c | 1. d |", false),
        ("", false),
        ("***", false),
        ("", false),
        ("- - -", false),
        ("", false),
        ("* * *", false),
        ("", false),
        ("<div>", false), ("  <p>- an HTML block is never hanging</p>", false), ("</div>", false),
        ("", false),
        ("Setext title that is long enough to wrap around the window edge", false), ("====================", false),
        ("", false),
        ("- # a heading inside a list item", false),
        ("", false),
        ("مرحبا بكم في luftig هذا نص عربي طويل من اليمين إلى اليسار", false),
        ("- عنصر قائمة بالعربية طويل جدا من اليمين إلى اليسار", false),
        ("  - عنصر متداخل بالعربية", false),
        ("", false),
        ("The last paragraph.", true),
    ]

    static var text: String { lines.map { $0.0 }.joined(separator: "\n") + "\n" }
}

// MARK: - scenarios

extension SelfTestScenarios {
    static let indentScenarios: [SelfTest.Scenario] = [
        .init(name: "indent-attrs", summary: "hanging indents: every list / indented line has the head indent the text and the stored fonts give (independent oracle); other lines unchanged", run: { t in try await indentAttrs(t) }),
        .init(name: "indent-diff", summary: "hanging indents: 2 x 1000 random edits (markers, nesting, 9 -> 10 -> 100, tasks, quotes, fences): styled == fresh lex, one paragraph style per line", run: { t in try await indentDiff(t) }),
        .init(name: "indent-layout", summary: "hanging indents in the real layout: wrapped lines start where the text starts (bullets, 1-3 digits, nested, tasks, quotes, inline styles; 11 / 16 / 28 pt; lazily styled); other lines unchanged", run: { t in try await indentLayout(t) }),
    ] + indentABScenarios

    // MARK: indent-attrs

    @MainActor static func indentAttrs(_ t: SelfTest.T) async throws {
        let text = IndentSample.text
        let (doc, host, _) = try await openEditor(t, text: text, name: "indent-attrs.md", size: NSSize(width: 860, height: 700))
        guard let ts = host.textView.textStorage else { t.check(false, "no storage"); return }
        host.styler.styleEverything()
        let ns = ts.string as NSString
        let lineRanges = IndentOracle.lines(of: ns)
        t.equal(lineRanges.count, IndentSample.lines.count, "the sample has \(IndentSample.lines.count) lines")

        var checkedHang = 0, checkedPlain = 0, wrong: [String] = [], distinct = Set<Int>(), firstLineChanged = 0
        for (i, lr) in lineRanges.enumerated() where i < IndentSample.lines.count {
            let (src, plain) = IndentSample.lines[i]
            let line = ns.substring(with: NSRange(location: lr.location, length: lr.length - 1)) as NSString        // without the newline
            guard let ps = ts.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle else { wrong.append("line \(i): no paragraph style"); continue }
            // the first line of every line looks as it did before this feature: the indent of its quote, else 0
            var depth = 0
            for k in 0..<line.length { let c = line.character(at: k); if c == 0x3E { depth += 1 } else if c != 0x20 { break } }
            let baselineFirst: CGFloat = depth > 0 ? DecorationMetrics.quoteIndent(depth: min(3, depth)) : 0
            if abs(ps.firstLineHeadIndent - baselineFirst) > 0.001 { firstLineChanged += 1; wrong.append("line \(i) \(src.debugDescription): first line indent \(ps.firstLineHeadIndent), expected \(baselineFirst)") }
            if plain, let prefix = IndentOracle.prefixLength(line) {
                let want = IndentOracle.textStartX(ts, lineStart: lr.location, prefix: prefix, quoteDepth: IndentOracle.quoteDepth(line, prefix: prefix))
                checkedHang += 1
                distinct.insert(Int((ps.headIndent * 2).rounded()))
                if abs(ps.headIndent - want) > 0.3 { wrong.append("line \(i) \(src.debugDescription): head indent \(ps.headIndent), the fonts say \(String(format: "%.2f", want))") }
                if ps.headIndent <= ps.firstLineHeadIndent { wrong.append("line \(i) \(src.debugDescription): hangs by nothing") }
                if ps.tabStops.count != 0 || ps.defaultTabInterval != 28 { wrong.append("line \(i): tab grid \(ps.tabStops.count) stops, interval \(ps.defaultTabInterval)") }
            } else {
                checkedPlain += 1
                if ps.headIndent != ps.firstLineHeadIndent { wrong.append("line \(i) \(src.debugDescription): head indent \(ps.headIndent) != first line indent \(ps.firstLineHeadIndent) (this line must not hang)") }
            }
        }
        t.check(wrong.isEmpty, "\(checkedHang) hanging lines have the head indent the stored fonts give (+- 0.3 pt), \(checkedPlain) other lines have head indent == first line indent \(wrong.prefix(4))")
        t.equal(firstLineChanged, 0, "the first line of every line keeps the indent it had (quote indent or 0)")
        t.check(checkedHang >= 30, "the sample exercises \(checkedHang) hanging lines with \(distinct.count) different head indents")
        t.check(IndentOracle.lineStyleIssues(ts).isEmpty, "every line has ONE paragraph style over all its runs incl. the newline \(IndentOracle.lineStyleIssues(ts, maxReport: 2))")

        // the facts the layout test relies on
        func indent(of needle: String) -> CGFloat {
            let r = ns.range(of: needle)
            return (ts.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
        }
        let b = indent(of: "- bullet minus"), o1 = indent(of: "1. ordered one"), o2 = indent(of: "10. ordered ten"), o3 = indent(of: "100. ordered hundred")
        t.check(b > 0 && o1 > b && o2 > o1 && o3 > o2, String(format: "the indent grows with the marker: `- ` %.1f < `1. ` %.1f < `10. ` %.1f < `100. ` %.1f pt", b, o1, o2, o3))
        let n2 = indent(of: "  - nested by two spaces"), n4 = indent(of: "    - nested by four spaces"), nt = indent(of: "\t- nested by a tab")
        t.check(n2 > b && n4 > n2 && nt > b, String(format: "nesting: 2 spaces %.1f, 4 spaces %.1f, a tab %.1f pt (top level %.1f)", n2, n4, nt, b))
        t.check(indent(of: "- [ ] open task") > b && indent(of: "- [x] done task") > indent(of: "- [ ] open task"), "a task marker widens the prefix further ([x] is semibold)")
        let q1 = indent(of: "> - quoted bullet"), q2 = indent(of: "> > - doubly quoted bullet")
        t.check(q1 > DecorationMetrics.quoteIndent(depth: 1) + b - 0.01 && q2 > q1, String(format: "quoted lists: `> - ` %.1f, `> > - ` %.1f pt (the quote markers are part of the prefix)", q1, q2))

        // the cap: a prefix of 60 spaces (and one of 200) would leave no room in a narrow window
        do {
            let wide = "- " + String(repeating: "word ", count: 6) + "\n" + String(repeating: " ", count: 60) + "text that is long\n" + String(repeating: " ", count: 200) + "text\n" + String(repeating: "\t", count: 40) + "tabs\n"
            let (d2, h2, _) = try await openEditor(t, text: wide, name: "indent-cap.md")
            h2.styler.styleEverything()
            let ts2 = h2.textView.textStorage!, ns2 = ts2.string as NSString
            let limit = h2.theme.hangLimit
            var heads: [CGFloat] = []
            for lr in IndentOracle.lines(of: ns2) { heads.append((ts2.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1) }
            t.check(heads.count == 4 && heads[1] > 0 && heads.allSatisfy { $0 <= limit + 0.001 }, "very wide prefixes (60 spaces, 200 spaces, 40 tabs) hang by at most 10 em = \(limit) pt: \(heads)")
            t.close(d2)
        }
        t.close(doc)

        // mixed line endings (kept as they are in the storage): `\r\n` lines hang like `\n` lines, one paragraph style per line
        do {
            let mixed = "- first item\r\n  continuation of it\n- second item\r\n    - nested\n\ttab\r\nplain\n"
            let (d3, h3, _) = try await openEditor(t, text: mixed, name: "indent-crlf.md")
            h3.styler.styleEverything()
            let ts3 = h3.textView.textStorage!, ns3 = ts3.string as NSString
            t.check(ns3.range(of: "\r\n").location != NSNotFound, "setup: the storage keeps the CRLF line endings of a mixed document")
            var heads: [(String, CGFloat, CGFloat)] = []
            for lr in IndentOracle.lines(of: ns3) {
                let ps = ts3.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle
                heads.append((ns3.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines), ps?.headIndent ?? -1, ps?.firstLineHeadIndent ?? -1))
            }
            t.check(heads.count == 6 && heads.prefix(5).allSatisfy { $0.1 > $0.2 } && heads[5].1 == heads[5].2, "CRLF / LF lines: items and indented lines hang, the plain line does not \(heads)")
            t.check(IndentOracle.lineStyleIssues(ts3).isEmpty, "CRLF / LF lines: one paragraph style per line \(IndentOracle.lineStyleIssues(ts3, maxReport: 2))")
            assertMatchesFreshLex(t, h3, "mixed line endings")
            t.close(d3)
        }
    }

    // MARK: indent-diff

    private static let indentMarkers = ["- ", "* ", "+ ", "1. ", "2) ", "9. ", "10. ", "100. ", "- [ ] ", "- [x] ", "> ", "> > ", "  ", "    ", "\t", "  - ", "    - ", "\t- ", "> - ", "1. [ ] "]
    private static let indentNumbers = ["1", "9", "10", "99", "100", "999", "1000"]

    @MainActor static func indentDiff(_ t: SelfTest.T) async throws {
        for (label, seed, bound) in [("A (default re-lex bound)", UInt64(31), 60_000), ("B (small re-lex bound: stale tails)", UInt64(47), 800)] {
            try await indentDiffRun(t, label: label, seed: seed, maxEditRegion: bound, edits: 1000)
        }
        if let n = SelfTest.argument("indent-seeds").flatMap({ Int($0) }) {
            for i in 0..<n { try await indentDiffRun(t, label: "soak seed \(200 + i)", seed: UInt64(200 + i), maxEditRegion: i % 2 == 0 ? 60_000 : 800, edits: 2000) }
        }
    }

    @MainActor static func indentDiffRun(_ t: SelfTest.T, label: String, seed: UInt64, maxEditRegion: Int, edits: Int) async throws {
        // a list-heavy document: the sample, then generated lists, then more of the sample
        var text = IndentSample.text
        var gen = TestRNG(seed)
        for n in 0..<60 {
            let depth = gen.int(4)
            let marker = gen.pick(["- ", "* ", "1. ", "10. ", "- [ ] ", "> - ", "> 1. "])
            text += String(repeating: "  ", count: depth) + marker + "item \(n) " + gen.pick(["with **bold** and `code`", "with a [link](u) and more words", "plain words that go on for a while", "short"]) + "\n"
            if gen.chance(15) { text += "  continuation line of item \(n)\n" }
            if gen.chance(10) { text += "\n" }
        }
        text += IndentSample.text
        let (doc, host, _) = try await openEditor(t, text: text, name: "indent-diff-\(seed).md", size: NSSize(width: 860, height: 600))
        host.provider.maxEditRegion = maxEditRegion
        let tv = host.textView
        host.styler.styleEverything()                      // everything styled: the edits below restyle incrementally, the oracle compares all of it
        var rng = TestRNG(seed &* 7919)
        var undone = 0, structural = 0, numbers = 0, tasks = 0, quotes = 0, fences = 0, scrolls = 0
        var seenIndents = Set<Int>()
        var maxHanging = 0
        var oracleFailures = 0
        let t0 = SelfTest.nowMs()

        func lineStarts(_ s: NSString) -> [Int] { IndentOracle.lines(of: s).map { $0.location } }
        func oracleCheck(_ what: String, full: Bool) {
            guard let ts = tv.textStorage else { return }
            if full { host.styler.styleEverything() }
            let r = AuditEd.styledMismatches(host)
            let issues = IndentOracle.lineStyleIssues(ts, in: nil, maxReport: 3)
            if r.bad > 0 || !issues.isEmpty {
                oracleFailures += 1
                t.check(false, "\(label) \(what): \(r.bad) of \(r.compared) styled runs differ from a fresh lex \(r.first.map { "\(NSStringFromRange($0.range)) expected [\($0.expected)] actual [\($0.actual)]" }); line-style issues \(issues)")
            }
            // which head indents exist right now (so that the run shows the prefix widths really change)
            let s = ts.string as NSString
            var loc = 0, hangingNow = 0
            while loc < s.length {
                let lr = s.lineRange(for: NSRange(location: loc, length: 0))
                if let ps = ts.attribute(.paragraphStyle, at: lr.location, effectiveRange: nil) as? NSParagraphStyle, ps.headIndent > ps.firstLineHeadIndent { seenIndents.insert(Int((ps.headIndent * 2).rounded())); hangingNow += 1 }
                loc = NSMaxRange(lr)
            }
            maxHanging = max(maxHanging, hangingNow)
        }

        for step in 0..<edits {
            if oracleFailures > 2 { break }
            let s = ns(tv)
            let len = s.length
            let starts = lineStarts(s)
            let ls = starts.isEmpty ? 0 : rng.pick(starts)
            let lr = s.lineRange(for: NSRange(location: min(ls, max(0, len - 1)), length: 0))
            let lineEndNoBreak = max(lr.location, NSMaxRange(lr) - (len > 0 && lr.length > 0 && s.character(at: NSMaxRange(lr) - 1) == 0x0A ? 1 : 0))
            switch rng.int(100) {
            case 0..<24:       // a marker / indentation / quote marker at the start of a line
                t.typeText(rng.pick(indentMarkers), into: doc, at: NSRange(location: lr.location, length: 0)); structural += 1
            case 24..<36:      // delete 1...4 characters at the start of a line
                let n = min(1 + rng.int(4), max(0, lineEndNoBreak - lr.location))
                if n > 0 { t.typeText("", into: doc, at: NSRange(location: lr.location, length: n)); structural += 1 }
            case 36..<48:      // ordered numbers: 9 -> 10 -> 100 ... (the prefix gets wider / narrower)
                var k = lr.location
                while k < lineEndNoBreak, s.character(at: k) == 0x20 || s.character(at: k) == 0x09 || s.character(at: k) == 0x3E { k += 1 }
                var j = k
                while j < lineEndNoBreak, s.character(at: j) >= 0x30, s.character(at: j) <= 0x39 { j += 1 }
                if j > k { t.typeText(rng.pick(indentNumbers), into: doc, at: NSRange(location: k, length: j - k)); numbers += 1 }
                else { t.typeText(rng.pick(["9. ", "10. ", "100. "]), into: doc, at: NSRange(location: lr.location, length: 0)); numbers += 1 }
            case 48..<58:      // task markers: toggle [ ] <-> [x], or add one after a marker
                let r = s.range(of: "[", options: [], range: NSRange(location: lr.location, length: lineEndNoBreak - lr.location))
                if r.location != NSNotFound, r.location + 2 < len, s.character(at: r.location + 2) == 0x5D {
                    t.typeText(s.character(at: r.location + 1) == 0x20 ? "x" : " ", into: doc, at: NSRange(location: r.location + 1, length: 1)); tasks += 1
                } else {
                    let m = s.range(of: "- ", options: [], range: NSRange(location: lr.location, length: lineEndNoBreak - lr.location))
                    if m.location != NSNotFound { t.typeText("[ ] ", into: doc, at: NSRange(location: NSMaxRange(m), length: 0)); tasks += 1 }
                }
            case 58..<66:      // quote markers: add one, or remove the first
                if lr.location < len, s.character(at: lr.location) == 0x3E { t.typeText("", into: doc, at: NSRange(location: lr.location, length: min(2, lineEndNoBreak - lr.location))) }
                else { t.typeText("> ", into: doc, at: NSRange(location: lr.location, length: 0)) }
                quotes += 1
            case 66..<76:      // typing inside the line, deleting inside the line, splitting and joining lines
                let at = lr.location + rng.int(max(1, lineEndNoBreak - lr.location + 1))
                switch rng.int(4) {
                case 0: t.typeText(rng.pick(["a", " ", "word ", "**", "`", "[", "-", "1."]), into: doc, at: NSRange(location: min(at, len), length: 0))
                case 1: let n = min(1 + rng.int(8), max(0, lineEndNoBreak - at)); if n > 0 { t.typeText("", into: doc, at: NSRange(location: at, length: n)) }
                case 2: t.typeText("\n", into: doc, at: NSRange(location: min(at, len), length: 0))
                default: if lineEndNoBreak < len { t.typeText("", into: doc, at: NSRange(location: lineEndNoBreak, length: 1)) }       // join with the next line
                }
            case 76..<80:      // fences open / close everything below them (code lines never hang): half the time one is opened, half the time the next one is removed
                if rng.chance(50) { t.typeText(rng.pick(["```\n", "~~~\n"]), into: doc, at: NSRange(location: lr.location, length: 0)) }
                else {
                    var k = ls, found: NSRange? = nil, wrapped = false
                    while found == nil {
                        if k >= len { if wrapped { break }; wrapped = true; k = 0; continue }
                        let r = s.lineRange(for: NSRange(location: k, length: 0))
                        let head = s.substring(with: NSRange(location: r.location, length: min(3, r.length)))
                        if head == "```" || head == "~~~" { found = r } else { k = NSMaxRange(r) }
                    }
                    if let found { t.typeText("", into: doc, at: found) }
                }
                fences += 1
            case 80..<86:      // a paste of a few lines of the sample
                t.typeText((0..<(1 + rng.int(6))).map { _ in rng.pick(IndentSample.lines).0 }.joined(separator: "\n") + "\n", into: doc, at: NSRange(location: lr.location, length: 0))
            case 86..<92:
                if let um = tv.undoManager { if rng.chance(70) { if um.canUndo { um.undo(); undone += 1 } } else if um.canRedo { um.redo() } }
            default:           // scrolling styles other parts lazily; restyles after an edit near unstyled text
                if len > 0 { let target = rng.int(len); if rng.chance(50) { t.scrollToTop(host, character: target) } else { tv.scrollRangeToVisible(NSRange(location: target, length: 0)); host.styler.styleVisible() }; scrolls += 1 }
            }
            if step % 25 == 24 { await t.spin(1) }
            if step % 100 == 99 { oracleCheck("step \(step)", full: false) }
        }
        await t.spin(30)
        host.styler.styleVisible()
        t.note(String(format: "%@: %d edits (%d structural, %d number switches, %d task toggles, %d quote changes, %d fence edits, %d undos, %d scrolls) in %.0f ms; %d different head indents seen, %d stale tails",
                      label, edits, structural, numbers, tasks, quotes, fences, undone, scrolls, SelfTest.nowMs() - t0, seenIndents.count, host.styler.staleEvents))
        t.check(seenIndents.count >= 8, "\(label): the run produced \(seenIndents.count) different head indents (prefix widths really changed)")
        t.check(maxHanging >= 40, "\(label): up to \(maxHanging) lines hung at the same time during the run (the fences did not turn the document into one code block)")
        assertMatchesFreshLex(t, host, range: visibleRange(host), "\(label): the visible part, before any forced fill")
        host.styler.styleEverything()
        assertMatchesFreshLex(t, host, "\(label): whole document after \(edits) edits")
        t.check(IndentOracle.lineStyleIssues(tv.textStorage!).isEmpty, "\(label): every line has ONE paragraph style incl. its newline \(IndentOracle.lineStyleIssues(tv.textStorage!, maxReport: 2))")
        t.close(doc)
    }
}
#endif
