import Foundation
import MarkdownKit

/// Cases that exercise documented deviations or Foundation artefacts rather than the lexer: reference links without
/// definitions (`][`), links with an empty destination (Foundation drops the link attribute), lone `~` (GFM allows
/// one tilde, the lexer needs two).
func skipInlineCase(_ p: String) -> Bool {
    if p.contains("][") || p.contains("()") || p.contains("( )") || p.contains("~") { return true }
    return false
}

private func inlineMismatch(_ p: String, _ styler: MarkdownStyler) -> Bool {
    if skipInlineCase(p) { return false }
    guard let o = oracleTokens(p, alnumOnly: false) else { return false }
    let t = NSString(string: p)
    let l = lexerTokens(t, styler.lexAll(t), alnumOnly: false)
    return tolerateOracleNesting(o, l) != l
}

/// Greedy character-level minimiser of a mismatching paragraph.
private func minimizeInline(_ p: String, _ styler: MarkdownStyler) -> String {
    var cur = Array(p)
    var changed = true
    while changed {
        changed = false
        var chunk = max(1, cur.count / 2)
        while chunk >= 1 {
            var i = 0
            while i < cur.count {
                var cand = cur
                cand.removeSubrange(i..<min(cur.count, i + chunk))
                if !cand.isEmpty && inlineMismatch(String(cand), styler) { cur = cand; changed = true } else { i += chunk }
            }
            if chunk == 1 { break }
            chunk /= 2
        }
    }
    return String(cur)
}

/// `mdkit-checks --oracle-fuzz <paragraphs> <seed>`: inline differential fuzz against cmark-gfm (Foundation).
func runOracleFuzzCommand(count: Int, seed: UInt64, show: Int) {
    let bad = runInlineOracleFuzz(count: count, seed: seed, verbose: true)
    let styler = MarkdownStyler()
    var seen = Set<String>()
    var shown = 0
    for (p, _) in bad {
        if shown >= show { break }
        let m = minimizeInline(p, styler)
        if !seen.insert(m).inserted { continue }
        shown += 1
        let t = NSString(string: m)
        let l = lexerTokens(t, styler.lexAll(t), alnumOnly: false)
        let o = tolerateOracleNesting(oracleTokens(m, alnumOnly: false) ?? [], l)
        print("MISMATCH \"\(visible(m))\"")
        print("   oracle: \(tokString(o[...], max: 200))")
        print("   lexer:  \(tokString(l[...], max: 200))")
        print("   lexer runs: \(renderAll(m))")
    }
    print("distinct minimal mismatches shown: \(shown) of \(bad.count) mismatching paragraphs")
}

/// `mdkit-checks --oracle-file <path> [from-line to-line] [blockonly]`: print the differences against cmark-gfm for one file.
func runOracleFileCommand(path: String, from: Int, to: Int, blockOnly: Bool) {
    guard let d = FileManager.default.contents(atPath: path) else { print("cannot read \(path)"); return }
    var text = String(decoding: d, as: UTF8.self)
    var lines = text.components(separatedBy: "\n")
    if from > 0 && to >= from {
        lines = Array(lines[max(0, from - 1)..<min(lines.count, to)])
        text = lines.joined(separator: "\n") + "\n"
    }
    let t = NSString(string: text)
    let styler = MarkdownStyler()
    let runs = styler.lexAll(t)
    guard var o = oracleTokens(text, alnumOnly: true) else { print("oracle failed"); return }
    var l = lexerTokens(t, runs, alnumOnly: true)
    if blockOnly {
        let mask: UInt16 = OFlag.codeBlock | OFlag.quote | OFlag.table | (7 << OFlag.headingShift)
        for i in 0..<o.count { o[i].f &= mask }
        for i in 0..<l.count { l[i].f &= mask }
    }
    o = tolerateOracleNesting(o, l)
    let li = LineIndex(t)
    let diffs = diffTokens(o, l)
    print("oracle tokens \(o.count), lexer tokens \(l.count), regions \(diffs.count)")
    for dd in diffs.prefix(60) {
        let line = dd.lexerOffset >= 0 ? li.line(of: dd.lexerOffset) : 0
        print("line \(line + max(0, from - 1)):  oracle \(tokString(dd.oracle, max: 80))")
        print("            lexer  \(tokString(dd.lexer, max: 80))")
        if line > 0 { print("            src    \(visible(t.substring(with: li.range(ofLine: line, in: t))).prefix(160))") }
    }
}
