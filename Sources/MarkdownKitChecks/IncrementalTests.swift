import Foundation
import MarkdownKit

/// A document with an incremental styler and a fresh-lex oracle, for scripted scenarios.
final class IncDoc {
    let text: NSMutableString
    let styler = MarkdownStyler()
    var label: String

    init(_ s: String, _ label: String) { text = NSMutableString(string: s); self.label = label }

    @discardableResult
    func check(_ r: MDResult, _ what: String, requested: NSRange? = nil) -> MDResult {
        if let e = checkStructure(text, r, requested: requested) { Harness.fail("\(label): \(what): \(e)"); return r }
        let all = MarkdownStyler().lexAll(text)
        let exp = sliceRuns(all, to: r.range)
        if exp != r.runs { Harness.fail("\(label): \(what): differs from fresh lex: \(describeDiff(text, expected: exp, actual: r.runs))") }
        else { Harness.checks += 1 }
        return r
    }

    @discardableResult
    func style(_ loc: Int, _ len: Int) -> MDResult {
        let q = NSRange(location: loc, length: len)
        return check(styler.styleRuns(in: q, of: text), "styleRuns(\(loc),\(len))", requested: q)
    }

    @discardableResult
    func edit(_ loc: Int, _ len: Int, _ repl: String) -> MDResult {
        let rl = (repl as NSString).length
        text.replaceCharacters(in: NSRange(location: loc, length: len), with: repl)
        let r = styler.update(afterEdit: NSRange(location: loc, length: rl), changeInLength: rl - len, of: text)
        return check(r, "update(edit \(loc),\(len) -> \"\(visible(repl))\")")
    }

    func offset(of s: String, nth: Int = 0) -> Int {
        var from = 0
        var r = NSRange(location: NSNotFound, length: 0)
        for _ in 0...nth {
            r = text.range(of: s, options: [], range: NSRange(location: from, length: text.length - from))
            from = r.location + max(1, r.length)
        }
        return r.location
    }
    var length: Int { text.length }
}

func runIncrementalTests() {
    Harness.group("incremental")

    // 1. Opening a fence near the top restyles everything below it (until the state re-converges: never).
    do {
        let d = IncDoc(String(repeating: "para with *x* and `y`\n\n- item\n\n", count: 1500), "open fence")
        d.style(0, d.length)
        let r = d.edit(0, 0, "```\n")
        Harness.expect(r.range.location == 0 && r.range.length == d.length, "open fence: region should reach the end, got \(r.range) of \(d.length)")
        // Closing it again converges quickly.
        let r2 = d.edit(0, 4, "")
        Harness.expect(r2.range.length == d.length, "close fence: region \(r2.range)")
    }

    // 1b. A fence opened in a realistic document is closed again by the document's own fences: the
    //     block state re-converges after the first code block and the region stays small.
    do {
        let d = IncDoc(Corpus.make(bytes: 40_000, seed: 1), "open fence (realistic)")
        d.style(0, d.length)
        let r = d.edit(0, 0, "```\n")
        Harness.expect(r.range.length < d.length, "open fence (realistic): expected re-convergence before the end")
    }

    // 2. A local edit in the middle of a large, fully styled document re-lexes a small region.
    do {
        let d = IncDoc(Corpus.make(bytes: 400_000, seed: 2), "local edit")
        d.style(0, d.length)
        let mid = d.length / 2
        let r = d.edit(mid, 0, "x")
        Harness.expect(r.range.length < 16_000, "local edit: region too large: \(r.range.length)")
        Harness.expect(r.range.location <= mid && r.range.location + r.range.length >= mid + 1, "local edit: region \(r.range) misses edit at \(mid)")
        let r2 = d.edit(mid, 1, "")
        Harness.expect(r2.range.length < 16_000, "local delete: region too large: \(r2.range.length)")
    }

    // 3. Setext underline restyles the preceding line.
    do {
        let d = IncDoc(Corpus.make(bytes: 3_000, seed: 3) + "\nHello world\nsecond line\n", "setext")
        d.style(0, d.length)
        let end = d.length
        let r = d.edit(end, 0, "===\n")
        let helloAt = d.offset(of: "Hello world")
        Harness.expect(r.range.location <= helloAt, "setext: region \(r.range) must include the paragraph start at \(helloAt)")
        Harness.expect(r.runs.contains { $0.style.headingLevel == 1 }, "setext: heading level 1 expected")
        let r2 = d.edit(end, 4, "")
        Harness.expect(!r2.runs.contains { $0.style.headingLevel > 0 && $0.range.location >= helloAt }, "setext: heading removed again")
    }

    // 4. Deleting a blank line merges two paragraphs (emphasis can now span them).
    do {
        let d = IncDoc("one *two\n\nthree* four\n", "merge")
        d.style(0, d.length)
        let r = d.edit(9, 1, "")
        Harness.expect(r.runs.contains { $0.style.contains(.italic) && $0.range.location + $0.range.length > 9 }, "merge: emphasis spans the former blank line")
    }

    // 5. A table delimiter row restyles the header row above it.
    do {
        let d = IncDoc("intro\n\n| a | b |\n", "table")
        d.style(0, d.length)
        let r = d.edit(d.length, 0, "|---|---|\n")
        Harness.expect(r.range.location <= d.offset(of: "| a"), "table: region must include the header row")
        Harness.expect(r.runs.contains { $0.style.contains(.tableHeader) }, "table: header row styled")
    }

    // 6. Removing a closing fence turns the rest of the document into code.
    do {
        let d = IncDoc("```\ncode\n```\n" + String(repeating: "para with *x* and `y`\n\n- item\n\n", count: 800), "unclose")
        d.style(0, d.length)
        let r = d.edit(d.offset(of: "```\n", nth: 1), 4, "")
        Harness.expect(r.range.location + r.range.length == d.length, "unclose: region should reach the end")
    }

    // 7. CR / LF handling when an edit splits or joins a CRLF pair.
    do {
        let d = IncDoc("a\rb\rc\r", "crlf")
        d.style(0, d.length)
        d.edit(2, 0, "\n")           // "a\r" + "\n" + "b..." -> a CRLF
        d.edit(2, 1, "")             // split it again
        d.edit(1, 1, "\n")           // "\r" -> "\n"
        d.edit(1, 0, "\r")
        d.edit(d.length, 0, "\n")
        d.edit(d.length - 1, 1, "")
    }

    // 8. Delete everything / start again.
    do {
        let d = IncDoc("# a\n- b\n", "empty")
        d.style(0, d.length)
        let r = d.edit(0, d.length, "")
        Harness.expect(r.runs.isEmpty && r.range.length == 0, "empty: no runs for empty text")
        d.edit(0, 0, "x *y*")
        d.style(0, 5)
    }

    // 9. Frontier behaviour: style the end first (cold), then the start, then the middle, in odd orders.
    do {
        let d = IncDoc(Corpus.make(bytes: 300_000, seed: 5), "frontier")
        let n = d.length
        d.style(n - 100, 100)
        d.style(0, 500)
        d.style(n / 2, 2000)
        d.style(n / 3, 0)
        d.style(n, 0)
        d.style(n - 1, 5)
        d.style(0, n)
        Harness.expect(d.styler.debugFrontier == n, "frontier should be at the end of the text after lexing everything, is \(d.styler.debugFrontier)")
    }

    // 10. Editing beyond the frontier (only the start has been styled).
    do {
        let d = IncDoc(Corpus.make(bytes: 200_000, seed: 6), "beyond frontier")
        d.style(0, 1000)
        let f = d.styler.debugFrontier
        Harness.expect(f < d.length / 2, "frontier after styling the first screen should be small: \(f)")
        let r = d.edit(d.length - 50, 3, "**x**")
        Harness.expect(r.range.length < 20_000, "beyond frontier: region too large (\(r.range.length))")
        d.edit(d.length / 2, 0, "```\n")
        d.style(d.length / 2 - 100, 400)
        d.style(0, 100)
    }

    // 11. Wholesale replacement -> reset.
    do {
        let d = IncDoc(Corpus.make(bytes: 50_000, seed: 7), "reset")
        d.style(0, d.length)
        d.text.setString(Corpus.make(bytes: 30_000, seed: 8))
        d.styler.reset()
        d.style(0, 200)
        d.style(d.length - 200, 200)
    }

    // 12. Misuse: wrong delta / missing update must still produce correct output (self-healing).
    do {
        let d = IncDoc(Corpus.make(bytes: 20_000, seed: 9), "misuse")
        d.style(0, d.length)
        d.text.replaceCharacters(in: NSRange(location: 100, length: 0), with: "# inserted\n")
        let r = d.styler.update(afterEdit: NSRange(location: 100, length: 11), changeInLength: 3, of: d.text)   // wrong delta
        d.check(r, "update with wrong delta")
        d.text.replaceCharacters(in: NSRange(location: 50, length: 0), with: "```\n")
        d.style(0, 300)     // update() was never called; length changed -> styler resets itself
        d.style(d.length - 300, 300)
    }

    // 13. Front matter lookahead: typing the closing delimiter styles lines above it.
    do {
        let d = IncDoc("---\ntitle: x\nbody text\n", "front matter")
        d.style(0, d.length)
        let r = d.edit(d.length, 0, "---\n")
        Harness.expect(r.range.location == 0 && r.runs.first?.style.contains(.frontMatter) == true, "front matter: restyled from the top")
        d.edit(0, 1, "")
    }

    // 14. Emoji / surrogate pairs through edits.
    do {
        let d = IncDoc("😀 *a* 👍🏽\n> 𝒳 `b`\n", "emoji")
        d.style(0, d.length)
        d.edit(2, 0, "😀")
        d.edit(0, 2, "")
        d.edit(d.length - 3, 0, "𝒳")
    }

    // 15. Checkpoint count stays bounded under many edits at the same place.
    do {
        let d = IncDoc(Corpus.make(bytes: 200_000, seed: 10), "cp growth")
        d.style(0, d.length)
        let before = d.styler.debugCheckpointCount
        let mid = d.length / 2
        for i in 0..<300 { d.text.replaceCharacters(in: NSRange(location: mid, length: 0), with: "a"); _ = d.styler.update(afterEdit: NSRange(location: mid, length: 1), changeInLength: 1, of: d.text); if i % 100 == 0 { Harness.checks += 1 } }
        let after = d.styler.debugCheckpointCount
        Harness.expect(after < before * 2 + 10, "checkpoint count grew from \(before) to \(after)")
        d.style(mid - 100, 400)
    }
}

func runAPITests() {
    Harness.group("api")
    // MDStyle value semantics
    var s = MDStyle([.bold, .marker])
    s.headingLevel = 3
    Harness.expect(s.headingLevel == 3 && s.contains(.bold) && s.contains(.marker), "heading level must not disturb facets")
    s.headingLevel = 9
    Harness.expect(s.headingLevel == 6, "heading level clamps to 6")
    s.headingLevel = 0
    Harness.expect(s == [.bold, .marker], "clearing the heading level restores the facet-only value")
    var q = MDStyle()
    q.quoteDepth = 2
    Harness.expect(q.quoteDepth == 2 && q.contains(.blockquote), "quote depth sets .blockquote")
    q.quoteDepth = 7
    Harness.expect(q.quoteDepth == 3, "quote depth saturates at 3")
    q.quoteDepth = 0
    Harness.expect(q.isEmpty, "quote depth 0 clears .blockquote")
    Harness.expect(MDStyle.heading(2).headingLevel == 2 && MDStyle.quote(depth: 1).contains(.blockquote), "convenience constructors")
    Harness.expect((MDStyle([.bold, .italic]).facets) == [.bold, .italic], "facets mask")
    Harness.expect(MDStyle([.italic, .marker]).description == "italic·marker", "description")
    Harness.expect(Set([MDStyle.bold, MDStyle.bold, MDStyle.italic]).count == 2, "Hashable")

    // styleRuns starts at the beginning of the paragraph that contains the requested range
    do {
        let d = IncDoc("intro\n\nline one *with\nline two* emphasis\nline three\n\nnext\n", "block start")
        let r = d.style(d.offset(of: "two"), 2)
        Harness.expect(r.range.location == d.offset(of: "line one"), "result starts at the paragraph start, got \(r.range.location)")
        let r2 = d.style(0, 3)
        Harness.expect(r2.range.location == 0, "result for the first line starts at 0")
    }
    // empty text and degenerate ranges
    do {
        let st = MarkdownStyler()
        let e = NSString(string: "")
        Harness.expect(st.styleRuns(in: NSRange(location: 0, length: 0), of: e).runs.isEmpty, "empty text")
        Harness.expect(st.styleRuns(in: NSRange(location: 5, length: 100), of: e).runs.isEmpty, "empty text, out-of-range request")
        Harness.expect(st.update(afterEdit: NSRange(location: 0, length: 0), changeInLength: 0, of: e).runs.isEmpty, "empty update")
        let t = NSString(string: "a *b*\nc\n")
        for q in [NSRange(location: -5, length: 3), NSRange(location: 100, length: 5), NSRange(location: 3, length: Int.max), NSRange(location: NSNotFound, length: 0), NSRange(location: 2, length: -1)] {
            let r = MarkdownStyler().styleRuns(in: q, of: t)
            if let err = checkStructure(t, r) { Harness.fail("degenerate range \(q): \(err)") } else { Harness.checks += 1 }
        }
    }
    // The same styler can serve different texts in sequence (reset between)
    do {
        let st = MarkdownStyler()
        let a = NSString(string: "# one\n*x*\n"), b = NSString(string: "- two\n`y`\n> z\n")
        _ = st.styleRuns(in: NSRange(location: 0, length: a.length), of: a)
        st.reset()
        let r = st.styleRuns(in: NSRange(location: 0, length: b.length), of: b)
        Harness.expectEqual(render(b, r.runs), render(b, MarkdownStyler().lexAll(b)), "styler reuse after reset")
    }
    // lexAll does not disturb cached incremental state
    do {
        let d = IncDoc(Corpus.make(bytes: 30_000, seed: 12), "lexAll interleave")
        d.style(0, 2000)
        let other = NSString(string: "# unrelated *text*\n")
        _ = d.styler.lexAll(other)
        d.style(d.length / 2, 500)
        d.edit(100, 0, "x")
    }
}
