#if LUFTIG_SELFTEST
// SelfTestIndentAB.swift - what the hanging-indent feature costs, and a signature of the attributes of a document, for comparing two builds.
//
// Everything here uses only API that the build WITHOUT the feature has as well, so the same file runs in both and the numbers are comparable:
//
//   indent-bench   Theme.styledRuns on 300 lines of plain paragraphs / bullets / nested + ordered items / hard-wrapped items; the restyle of a screenful
//                  (reset + styleVisible) in a 1 MB corpus and in a 1 MB document that is nothing but lists; a keystroke in a list line of that document
//   indent-dump    one line per source line with every attribute run of it: `--input f.md --out sig.txt [--font-size N] [--width W]`

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let indentABScenarios: [SelfTest.Scenario] = [
        .init(name: "indent-bench", summary: "(measurement) styledRuns with / without lists, restyle of a screenful and a keystroke in 1 MB documents (same file runs before / after the feature)", run: { t in try await indentBench(t) }, inAll: false),
        .init(name: "indent-dump", summary: "(internal) signature of every attribute run of a document: --input f.md --out sig.txt", run: { t in try await indentDump(t) }, inAll: false),
    ]

    private static func indentLineCount(_ s: NSString) -> Int {
        var n = 0, loc = 0
        while loc < s.length { loc = NSMaxRange(s.lineRange(for: NSRange(location: loc, length: 0))); n += 1 }
        return n
    }

    private static func indentMedian(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    /// A document that is nothing but list items of every kind (nested, ordered, tasks, quoted, hard-wrapped, long).
    static func listHeavy(bytes: Int, seed: UInt64) -> String {
        var r = TestRNG(seed)
        var out = "# Lists\n\n"
        var n = 0
        while out.utf8.count < bytes {
            n += 1
            let indent = String(repeating: "  ", count: r.int(4))
            let marker = r.pick(["- ", "* ", "+ ", "1. ", "9. ", "10. ", "100. ", "- [ ] ", "- [x] ", "> - ", "> 1. "])
            out += indent + marker + "item \(n) " + r.pick(["with **bold** and `code` and a [link](https://example.com/\(n))", "that goes on for a while and has to wrap in a narrow window, with plenty of words", "short", "with *emphasis* and ~~strike~~"]) + "\n"
            if r.chance(20) { out += indent + "  a hard-wrapped second line of item \(n) with `code`\n" }
            if r.chance(8) { out += "\n" }
        }
        return out
    }

    @MainActor static func indentBench(_ t: SelfTest.T) async throws {
        let theme = Theme(baseSize: 16)
        func styledRunsBench(_ label: String, _ text: String, rounds: Int = 40) -> Double {
            let ns = text as NSString
            let runs = MarkdownStyler().lexAll(ns)
            _ = theme.styledRuns(runs, text: ns)           // warm the caches
            var times: [Double] = []
            for _ in 0..<rounds {
                let t0 = SelfTest.nowMs()
                let styled = theme.styledRuns(runs, text: ns)
                times.append(SelfTest.nowMs() - t0)
                if styled.isEmpty { t.check(false, "no runs") }
            }
            let lines = indentLineCount(ns)
            t.note(String(format: "styledRuns  %-22@ %6d chars %5d lexer runs %5d lines: median %.3f ms = %4.0f ns per line", label as NSString, ns.length, runs.count, lines, indentMedian(times), indentMedian(times) * 1e6 / Double(max(1, lines))))
            return indentMedian(times)
        }
        let paragraphs = (0..<300).map { "Paragraph \($0) with some words in it that go on, with `code` and **bold** and a [link](u).\n" }.joined()
        let lists = (0..<300).map { "- item \($0) with some words in it that go on, with `code` and **bold** and a [link](u).\n" }.joined()
        let nested = (0..<300).map { String(repeating: "  ", count: $0 % 4) + ($0 % 3 == 0 ? "\($0 + 1). " : "- ") + "item \($0) with `code` and **bold** text.\n" }.joined()
        let hard = (0..<150).map { "- item \($0) first line\n  second line of the item with `code`\n  third line\n" }.joined()
        let a = styledRunsBench("paragraphs", paragraphs), b = styledRunsBench("bullet list", lists), c = styledRunsBench("nested + ordered", nested), d = styledRunsBench("hard-wrapped items", hard)
        t.note(String(format: "list lines cost %.2fx / %.2fx / %.2fx the paragraph lines", b / a, c / a, d / a))
        let corpus = SelfTestCorpus.markdown(bytes: 60_000, seed: 7) as NSString
        _ = styledRunsBench("corpus 60 KB", corpus as String)

        // the restyle of a screenful, and a keystroke, in a real editor
        for (label, text) in [("corpus 1 MB", SelfTestCorpus.markdown(bytes: 1_000_000, seed: 3)), ("lists only, 1 MB", listHeavy(bytes: 1_000_000, seed: 5))] {
            let (doc, host, _) = try await openEditor(t, text: text, name: "indent-bench.md", size: NSSize(width: 860, height: 1000))
            let tv = host.textView
            let len = (tv.string as NSString).length
            t.scrollToTop(host, character: len / 2)
            host.styler.styleVisible()
            var restyle: [Double] = []
            for _ in 0..<40 {
                host.styler.reset()
                let t0 = SelfTest.nowMs()
                host.styler.styleVisible()
                restyle.append(SelfTest.nowMs() - t0)
            }
            // a keystroke inside a line near the middle (restyle of the line through didProcessEditing + layout of the dirty lines)
            var keys: [Double] = []
            var loc = (tv.string as NSString).lineRange(for: NSRange(location: len / 2, length: 0)).location
            for i in 0..<120 {
                let t0 = SelfTest.nowMs()
                t.typeText(i % 2 == 0 ? "x" : "y", into: doc, at: NSRange(location: loc + 3, length: 0))
                _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                keys.append(SelfTest.nowMs() - t0)
                if i % 40 == 39 { loc = (tv.string as NSString).lineRange(for: NSRange(location: loc + 400, length: 0)).location }
            }
            t.note(String(format: "%@: restyle of a screenful (reset + styleVisible) median %.3f ms (min %.3f, %d runs applied); keystroke in the middle median %.2f ms (p90 %.2f)",
                          label, indentMedian(restyle), restyle.min() ?? 0, host.styler.appliedRunCount, indentMedian(keys), keys.sorted()[keys.count * 9 / 10]))
            t.close(doc)
        }
        t.check(true, "measured")
    }

    // MARK: indent-dump

    /// One line per attribute run: range, font, colour, every paragraph style property, the custom keys. Same text -> same signature, in any build.
    @MainActor static func indentDump(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input"), let out = SelfTest.argument("out") else { t.check(false, "usage: --selftest indent-dump --input f.md --out sig.txt [--font-size N] [--width W]"); return }
        let savedSize = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = savedSize }
        if let fs = SelfTest.argument("font-size"), let v = Double(fs) { EditorPreferences.fontSize = CGFloat(v) }
        let copy = t.write(data: try Data(contentsOf: URL(fileURLWithPath: input)), to: "dump-input.md")
        let doc = try await t.open(copy, size: NSSize(width: Double(SelfTest.argument("width") ?? "") ?? 860, height: 700))
        guard let host = doc.host as? EditorViewController, let ts = host.textView.textStorage else { t.check(false, "no editor"); return }
        host.styler.styleEverything()
        let ns = ts.string as NSString
        var lines: [String] = []
        var loc = 0, lineNo = 0
        while loc < ns.length {
            let lr = ns.lineRange(for: NSRange(location: loc, length: 0))
            var p = lr.location
            var sig: [String] = []
            while p < NSMaxRange(lr) {
                var eff = NSRange(location: 0, length: 0)
                let a = ts.attributes(at: p, longestEffectiveRange: &eff, in: lr)
                let f = a[.font] as? NSFont
                let ps = a[.paragraphStyle] as? NSParagraphStyle
                var para = "none"
                if let ps {
                    para = "first \(ps.firstLineHeadIndent) head \(ps.headIndent) tail \(ps.tailIndent) h \(ps.minimumLineHeight)/\(ps.maximumLineHeight) before \(ps.paragraphSpacingBefore) after \(ps.paragraphSpacing) lead \(ps.lineSpacing) align \(ps.alignment.rawValue) dir \(ps.baseWritingDirection.rawValue) wrap \(ps.lineBreakMode.rawValue) tabs \(ps.tabStops.map { $0.location }) deftab \(ps.defaultTabInterval)"
                }
                let keys = a.keys.map { $0.rawValue }.sorted().joined(separator: ",")
                sig.append("[\(p - lr.location)+\(eff.length) \(f?.fontName ?? "nil")@\(f?.pointSize ?? 0) \((a[.foregroundColor] as? NSColor)?.description ?? "nil") block=\(a[.luftigBlock].map { "\($0)" } ?? "-") panel=\(a[.luftigPanel].map { "\($0)" } ?? "-") inline=\(a[.luftigInline] != nil) und=\(a[.underlineStyle].map { "\($0)" } ?? "-") strike=\(a[.strikethroughStyle].map { "\($0)" } ?? "-") keys=\(keys) para(\(para))]")
                p = NSMaxRange(eff)
            }
            lines.append("\(lineNo)\t\(ns.substring(with: NSRange(location: lr.location, length: min(40, lr.length))).debugDescription)\t\(sig.joined())")
            loc = NSMaxRange(lr); lineNo += 1
        }
        try lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        t.check(true, "dumped \(lines.count) lines -> \(out)")
        t.close(doc)
    }
}
#endif
