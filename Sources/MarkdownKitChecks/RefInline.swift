import Foundation
import MarkdownKit

// A deliberately naive, spec-literal reference for the inline subset {backslash escapes, code spans, `*` / `_` emphasis}.
// It follows the CommonMark "process emphasis" procedure WITHOUT the openers_bottom optimisation (the spec presents the bound
// as an optimisation only), so it is an independent check of the lexer's optimised implementation, in particular of the
// `openersBottom` key and the rule of three. Input: one paragraph (lines joined by "\n"), ASCII punctuation + letters + spaces.

private struct RDelim {
    var ch: UInt16
    var start: Int        // index of the first remaining delimiter char (inner side moves)
    var count: Int
    var orig: Int
    var canOpen: Bool
    var canClose: Bool
    var removed = false
    var origStart: Int
}

func referenceInlineTokens(_ s: String) -> [OTok] {
    let u = Array(s.utf16)
    let n = u.count
    func isWS(_ c: UInt16) -> Bool { c == 32 || c == 10 || c == 9 || c == 13 }
    func isPunct(_ c: UInt16) -> Bool { (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126) }
    var visible = [Bool](repeating: true, count: n)        // shown as text (not syntax)
    var code = [Bool](repeating: false, count: n)
    var em = [Int](repeating: 0, count: n)
    var strong = [Int](repeating: 0, count: n)
    var delims: [RDelim] = []

    var i = 0
    while i < n {
        let c = u[i]
        if c == 92 && i + 1 < n && isPunct(u[i + 1]) { visible[i] = false; i += 2; continue }
        if c == 96 {
            var j = i
            while j < n && u[j] == 96 { j += 1 }
            let len = j - i
            // look for a closing run of exactly `len` backticks (escapes do not apply inside code spans)
            var p = j
            var found = -1
            while p < n {
                if u[p] == 96 {
                    var q = p
                    while q < n && u[q] == 96 { q += 1 }
                    if q - p == len { found = p; break }
                    p = q
                } else { p += 1 }
            }
            if found >= 0 {
                for k in i..<j { visible[k] = false }
                for k in found..<(found + len) { visible[k] = false }
                if j < found { for k in j..<found { code[k] = true } }
                i = found + len
            } else { i = j }
            continue
        }
        if c == 42 || c == 95 {
            var j = i
            while j < n && u[j] == c { j += 1 }
            let prev: UInt16 = i > 0 ? u[i - 1] : 32
            let next: UInt16 = j < n ? u[j] : 32
            // a line start / end counts as whitespace
            let pW = isWS(prev), nW = isWS(next), pP = isPunct(prev), nP = isPunct(next)
            let left = !nW && (!nP || pW || pP)
            let right = !pW && (!pP || nW || nP)
            var canOpen = left, canClose = right
            if c == 95 { canOpen = left && (!right || pP); canClose = right && (!left || nP) }
            if canOpen || canClose { delims.append(RDelim(ch: c, start: i, count: j - i, orig: j - i, canOpen: canOpen, canClose: canClose, origStart: i)) }
            i = j
            continue
        }
        i += 1
    }

    // process emphasis, naive: every closer looks back over ALL earlier delimiters
    var ci = 0
    while ci < delims.count {
        if delims[ci].removed || !delims[ci].canClose { ci += 1; continue }
        var found = -1
        var o = ci - 1
        while o >= 0 {
            let d = delims[o]
            if !d.removed && d.ch == delims[ci].ch && d.canOpen {
                let c = delims[ci]
                let odd = (c.canOpen || d.canClose) && c.orig % 3 != 0 && (d.orig + c.orig) % 3 == 0
                if !odd { found = o; break }
            }
            o -= 1
        }
        if found < 0 {
            if !delims[ci].canOpen { delims[ci].removed = true }
            ci += 1
            continue
        }
        let use = (delims[ci].count >= 2 && delims[found].count >= 2) ? 2 : 1
        let openerInnerEnd = delims[found].start + delims[found].count       // chars [openerInnerEnd - use, openerInnerEnd) become markers
        let closerStart = delims[ci].start                                   // chars [closerStart, closerStart + use) become markers
        for k in (openerInnerEnd - use)..<openerInnerEnd { visible[k] = false }
        for k in closerStart..<(closerStart + use) { visible[k] = false }
        if openerInnerEnd < closerStart {
            for k in openerInnerEnd..<closerStart { if use == 2 { strong[k] += 1 } else { em[k] += 1 } }
        }
        var t = found + 1
        while t < ci { delims[t].removed = true; t += 1 }
        delims[found].count -= use
        delims[ci].count -= use
        delims[ci].start += use
        if delims[found].count == 0 { delims[found].removed = true }
        if delims[ci].count == 0 { delims[ci].removed = true; ci += 1 }
    }

    var out: [OTok] = []
    var k = 0
    while k < n {
        let c = u[k]
        if visible[k] && !isWS(c) {
            var f: UInt16 = 0
            if code[k] { f |= OFlag.code }
            if em[k] > 0 { f |= OFlag.em }
            if strong[k] > 0 { f |= OFlag.strong }
            out.append(OTok(c: UInt32(c), f: f, off: Int32(k)))
        }
        k += 1
    }
    return out
}

enum RefSoup {
    static let letters = ["a", "b", "x", "foo", "é", "日", "я"]
    static let punct = [".", ",", "!", "?", ":", ";", "-", "'", "\"", "(", ")", "/", "+", "=", "%", "@", "&", "$", "#", "<", ">", "[", "]", "{", "}", "|", "^", "~"]
    static let stars = ["*", "**", "***", "****", "_", "__", "___", "____"]
    static func paragraph(_ r: inout RNG, heavy: Bool) -> String {
        let nLines = r.chance(0.75) ? 1 : r.range(2, 3)
        var lines: [String] = []
        for _ in 0..<nLines {
            var s = "w"
            for _ in 0..<r.range(2, heavy ? 22 : 16) {
                let k = r.int(100)
                if k < (heavy ? 18 : 25) { s += r.pick(letters) }
                else if k < (heavy ? 28 : 38) { s += r.pick(punct) }
                else if k < (heavy ? 78 : 66) { s += r.pick(stars) }
                else if k < (heavy ? 82 : 72) { s += r.pick(["`", "``", "```"]) }
                else if k < (heavy ? 84 : 76) { s += r.pick(["\\*", "\\_", "\\`", "\\\\"]) }
                else { s += " " }
                if r.chance(0.3) { s += " " }
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }
}

func referenceMismatch(_ p: String, _ styler: MarkdownStyler) -> Bool {
    // every line must start with a letter, otherwise the text would open a block (list, heading, quote, ...) rather than stay a paragraph
    for line in p.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let c = line.unicodeScalars.first, (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) else { return false }
    }
    let t = NSString(string: p)
    let l = lexerTokens(t, styler.lexAll(t), alnumOnly: false)
    let r = referenceInlineTokens(p)
    // the lexer styles `[`, `<`, `&`... constructs we excluded by construction, so skip anything that could start one
    return r != l
}

/// `mdkit-checks --ref-fuzz <paragraphs> <seed> [show]`
func runRefFuzzCommand(count: Int, seed: UInt64, show: Int) {
    var rng = RNG(seed: seed)
    let styler = MarkdownStyler()
    var bad: [String] = []
    var compared = 0
    for q in 0..<count {
        var p = RefSoup.paragraph(&rng, heavy: q % 2 == 0)
        // constructs outside the reference's subset: links, images, autolinks, html, entities, bare URLs, strike, footnotes, refs
        p = p.replacingOccurrences(of: "[", with: "x").replacingOccurrences(of: "]", with: "x").replacingOccurrences(of: "<", with: "x")
            .replacingOccurrences(of: "&", with: "x").replacingOccurrences(of: "~", with: "x").replacingOccurrences(of: "http", with: "x")
        compared += 1
        if referenceMismatch(p, styler) { bad.append(p) }
    }
    print("reference fuzz seed \(seed): \(compared) paragraphs, \(bad.count) mismatches")
    var seen = Set<String>()
    var shown = 0
    for p in bad {
        if shown >= show { break }
        // minimise
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
                    if !cand.isEmpty && referenceMismatch(String(cand), styler) { cur = cand; changed = true } else { i += chunk }
                }
                if chunk == 1 { break }
                chunk /= 2
            }
        }
        let m = String(cur)
        if !seen.insert(m).inserted { continue }
        shown += 1
        let t = NSString(string: m)
        print("MISMATCH \"\(visible(m))\"")
        print("   reference: \(tokString(referenceInlineTokens(m)[...], max: 200))")
        print("   lexer:     \(tokString(lexerTokens(t, styler.lexAll(t), alnumOnly: false)[...], max: 200))")
        print("   lexer runs: \(renderAll(m))")
    }
}
