import Foundation
import MarkdownKit

/// Is `p` a line start in `t` (0, after "\n", after a lone "\r", after "\r\n"), or the end of text?
func isLineStart(_ t: NSString, _ p: Int) -> Bool {
    let n = t.length
    if p == 0 || p == n { return true }
    if p < 0 || p > n { return false }
    let prev = t.character(at: p - 1)
    if prev == 10 { return true }
    if prev == 13 { return t.character(at: p) != 10 }
    return false
}

/// Structural invariants of an MDResult. Returns a description of the first violation, or nil.
func checkStructure(_ text: NSString, _ r: MDResult, requested: NSRange? = nil) -> String? {
    let n = text.length
    let range = r.range
    if range.location < 0 || range.length < 0 || range.location + range.length > n {
        return "range \(range) out of bounds (len \(n))"
    }
    if !isLineStart(text, range.location) { return "range start \(range.location) is not a line start" }
    if !isLineStart(text, range.location + range.length) { return "range end \(range.location + range.length) is not a line start" }
    if let q = requested, n > 0 {
        var a = max(0, min(q.location, n))
        if a >= n { a = n - 1 }
        let b = max(a + 1, min(q.location + q.length, n))
        if range.location > a { return "result \(range) does not cover requested start \(a)" }
        if range.location + range.length < b { return "result \(range) does not cover requested end \(b)" }
    }
    var pos = range.location
    var prevStyle: MDStyle? = nil
    for (i, run) in r.runs.enumerated() {
        if run.range.length <= 0 { return "run \(i) is empty: \(run.range)" }
        if run.range.location != pos { return "run \(i) starts at \(run.range.location), expected \(pos)" }
        if let p = prevStyle, p == run.style { return "runs \(i - 1) and \(i) have equal style \(run.style) (not coalesced)" }
        pos += run.range.length
        prevStyle = run.style
        if pos < n && pos > 0 {
            let a = text.character(at: pos - 1), b = text.character(at: pos)
            if a >= 0xD800 && a <= 0xDBFF && b >= 0xDC00 && b <= 0xDFFF { return "run \(i) boundary at \(pos) splits a surrogate pair" }
        }
    }
    if pos != range.location + range.length { return "runs end at \(pos), range ends at \(range.location + range.length)" }
    return nil
}

/// Slice of reference runs clipped to `range`.
func sliceRuns(_ runs: [MDRun], to range: NSRange) -> [MDRun] {
    var out: [MDRun] = []
    let lo = range.location, hi = range.location + range.length
    // binary search first run with end > lo
    var a = 0, b = runs.count
    while a < b {
        let m = (a + b) / 2
        if runs[m].range.location + runs[m].range.length > lo { b = m } else { a = m + 1 }
    }
    var i = a
    while i < runs.count && runs[i].range.location < hi {
        let r = runs[i]
        let s = max(lo, r.range.location), e = min(hi, r.range.location + r.range.length)
        if e > s {
            if let last = out.last, last.style == r.style, last.range.location + last.range.length == s {
                out[out.count - 1].range.length += e - s
            } else {
                out.append(MDRun(range: NSRange(location: s, length: e - s), style: r.style))
            }
        }
        i += 1
    }
    return out
}

func describeDiff(_ text: NSString, expected: [MDRun], actual: [MDRun], limit: Int = 12) -> String {
    var i = 0
    while i < min(expected.count, actual.count) && expected[i] == actual[i] { i += 1 }
    func ctx(_ runs: [MDRun]) -> String {
        let lo = max(0, i - 2), hi = min(runs.count, i + 4)
        if lo >= hi { return "(none)" }
        return render(text, Array(runs[lo..<hi]))
    }
    return "first difference at run \(i)\n      expected: \(ctx(expected))\n      actual:   \(ctx(actual))"
}

func runInvariantTests() {
    Harness.group("invariants")
    let samples = [
        "", "\n", "a", "a\n", "\n\n\n", "# h\n", "```\nx", "> a\n> b\n", "- a\n  - b\n", "| a | b |\n|---|---|\n| 1 | 2 |\n",
        "😀 *a*\n", "a\r\nb\rc\nd", "---\nx: y\n---\nbody", "<!-- c\n\n-->\n", "    code\n\tcode\n", "[a]: b\n[^1]: c\n",
        "plain text with **unclosed and `unclosed\n", "x\u{0}y\n", String(repeating: "ab ", count: 1000),
    ]
    for s in samples {
        let t = NSString(string: s)
        let st = MarkdownStyler()
        let all = st.lexAll(t)
        let r = MDResult(range: NSRange(location: 0, length: t.length), runs: all)
        if t.length == 0 {
            Harness.expect(all.isEmpty, "empty text must give no runs")
        } else if let err = checkStructure(t, r) {
            Harness.fail("lexAll(\(visible(s.prefix(40).description))): \(err)")
        } else {
            Harness.checks += 1
        }
        // styleRuns over several ranges
        for q in [NSRange(location: 0, length: 0), NSRange(location: 0, length: t.length), NSRange(location: max(0, t.length - 1), length: 1)] {
            let st2 = MarkdownStyler()
            let res = st2.styleRuns(in: q, of: t)
            if t.length == 0 { Harness.expect(res.runs.isEmpty && res.range.length == 0, "empty text result"); continue }
            if let err = checkStructure(t, res, requested: q) { Harness.fail("styleRuns(\(q)) of \(visible(s.prefix(40).description)): \(err)") }
            else if sliceRuns(all, to: res.range) != res.runs { Harness.fail("styleRuns(\(q)) differs from lexAll for \(visible(s.prefix(40).description))") }
            else { Harness.checks += 1 }
        }
    }
}
