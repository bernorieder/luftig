import Foundation
import MarkdownKit

/// Concatenate results of ranged calls into a map style-per-unit and compare with a reference run list.
private func styleAt(_ runs: [MDRun], _ n: Int) -> [UInt32] {
    var a = [UInt32](repeating: 0, count: n)
    for r in runs { for i in r.range.location..<(r.range.location + r.range.length) { a[i] = r.style.rawValue } }
    return a
}

func runLargeConsistencyTests() {
    Harness.group("large documents")

    // 1. Sequential "idle fill" over a 2 MB document in 4 KB slices equals one full lex; the window slides many times.
    do {
        let str = Corpus.make(bytes: 2_000_000, seed: 77)
        let t = NSString(string: str)
        let n = t.length
        let ref = MarkdownStyler().lexAll(t)
        let refMap = styleAt(ref, n)
        let s = MarkdownStyler()
        var got = [UInt32](repeating: 0, count: n)
        var covered = 0
        var pos = 0
        var ok = true
        while pos < n && ok {
            let r = s.styleRuns(in: NSRange(location: pos, length: min(4096, n - pos)), of: t)
            if let e = checkStructure(t, r, requested: NSRange(location: pos, length: min(4096, n - pos))) { Harness.fail("idle fill at \(pos): \(e)"); ok = false; break }
            for run in r.runs { for i in run.range.location..<(run.range.location + run.range.length) { got[i] = run.style.rawValue } }
            covered = max(covered, r.range.location + r.range.length)
            pos = max(pos + 1, r.range.location + r.range.length)
        }
        Harness.expect(ok && covered == n, "idle fill covered \(covered) of \(n)")
        Harness.expect(got == refMap, "idle fill (4 KB slices) differs from lexAll over 2 MB")
        Harness.expect(s.debugFrontier == n, "frontier after idle fill: \(s.debugFrontier)")
    }

    // 2. Random ranged calls (cold stylers) on a 3 MB document equal slices of the full lex.
    do {
        let str = Corpus.make(bytes: 3_000_000, seed: 78)
        let t = NSString(string: str)
        let n = t.length
        let ref = MarkdownStyler().lexAll(t)
        var rng = RNG(seed: 5)
        let warm = MarkdownStyler()
        for i in 0..<300 {
            let loc = rng.int(n), len = rng.chance(0.3) ? rng.range(0, 100) : rng.range(100, 60_000)
            let s = i % 3 == 0 ? MarkdownStyler() : warm
            let q = NSRange(location: loc, length: min(len, n - loc))
            let r = s.styleRuns(in: q, of: t)
            if let e = checkStructure(t, r, requested: q) { Harness.fail("random range \(q): \(e)"); break }
            if sliceRuns(ref, to: r.range) != r.runs { Harness.fail("random range \(q) differs from lexAll"); break }
            Harness.checks += 1
        }
    }

    // 3. Very long lines: window growth (300 KB line, 2 MB line) and inline cap degradation.
    do {
        for (name, str) in [("300 KB line", String(repeating: "word *em* `c` [l](u) ", count: 15_000) + "\nnext *line*\n"),
                            ("2 MB line", String(repeating: "x ", count: 1_000_000) + "\n# heading\n"),
                            ("300 KB with a short tail", "# h\n" + String(repeating: "abc ", count: 75_000) + "\n\n- item\n")] {
            let t = NSString(string: str)
            let ref = MarkdownStyler().lexAll(t)
            let s = MarkdownStyler()
            let r = s.styleRuns(in: NSRange(location: t.length - 10, length: 5), of: t)
            Harness.expect(sliceRuns(ref, to: r.range) == r.runs, "\(name): tail styling differs")
            let r2 = s.styleRuns(in: NSRange(location: 0, length: 10), of: t)
            Harness.expect(sliceRuns(ref, to: r2.range) == r2.runs, "\(name): head styling differs")
            if let e = checkStructure(t, MDResult(range: NSRange(location: 0, length: t.length), runs: ref)) { Harness.fail("\(name): \(e)") }
        }
        // a >64K-unit paragraph is not inline-lexed (degrades to plain), a short one is
        let big = NSString(string: String(repeating: "*a* ", count: 40_000))
        let rb = MarkdownStyler().lexAll(big)
        Harness.expect(rb.count == 1 && rb[0].style.isEmpty, "paragraph beyond the inline cap must be plain, got \(rb.count) runs")
        let small = NSString(string: String(repeating: "*a* ", count: 4_000))
        Harness.expect(MarkdownStyler().lexAll(small).count > 1000, "paragraph below the cap must be styled")
    }

    // 4. Edits at many places in a 1 MB document, checking against a fresh lex periodically.
    do {
        let d = IncDoc(Corpus.make(bytes: 1_000_000, seed: 79), "large edits")
        d.style(0, d.length)
        var rng = RNG(seed: 6)
        for i in 0..<60 {
            let loc = rng.int(d.length)
            let repl = rng.pick(["a", "*", "`", "\n", "# ", "```\n", "> ", "- ", "|", "x\n\n", "---\n"])
            let len = rng.chance(0.5) ? 0 : min(rng.range(1, 30), d.length - loc)
            let rl = (repl as NSString).length
            d.text.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
            let r = d.styler.update(afterEdit: NSRange(location: loc, length: rl), changeInLength: rl - len, of: d.text)
            if i % 6 == 0 { d.check(r, "large edit \(i)") }
            else if let e = checkStructure(d.text, r) { Harness.fail("large edit \(i): \(e)") }
        }
        // after all the edits: a full sweep must equal a fresh lex
        let ref = MarkdownStyler().lexAll(d.text)
        let got = d.styler.styleRuns(in: NSRange(location: 0, length: d.length), of: d.text)
        Harness.expect(sliceRuns(ref, to: got.range) == got.runs && got.range.length == d.length, "after 60 random edits the full styling differs from a fresh lex")
    }

    // 5. Bounded update: typing a fence near the top of a fence-free document.
    do {
        let line = "A paragraph with *emphasis*, `code` and a [link](http://x.y).\n\n- list item\n\n"
        let d = IncDoc(String(repeating: line, count: 20_000), "bounded")
        d.style(0, d.length)
        let before = d.styler.debugFrontier
        d.text.insert("```\n", at: 0)
        let r = d.styler.update(afterEdit: NSRange(location: 0, length: 4), changeInLength: 4, of: d.text, maxRegion: 20_000)
        Harness.expect(r.range.length < 40_000, "bounded update: region \(r.range.length) exceeds the budget by too much")
        Harness.expect(r.staleFrom != nil && r.staleFrom! >= r.range.location + r.range.length, "bounded update: staleFrom \(String(describing: r.staleFrom))")
        Harness.expect(d.styler.debugFrontier == r.staleFrom && d.styler.debugFrontier < before, "bounded update: frontier should drop to the stale point")
        d.check(r, "bounded update region")
        // the rest is re-lexed lazily and correctly
        d.style(d.length - 500, 400)
        d.style(r.staleFrom!, 5000)
        // an unbounded update after that works as usual
        d.edit(0, 4, "")
        Harness.expect(d.styler.debugFrontier <= d.length, "frontier within text")
    }
}
