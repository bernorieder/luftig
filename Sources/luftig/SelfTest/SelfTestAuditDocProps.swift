#if LUFTIG_SELFTEST
// SelfTestAuditDocProps.swift - property tests of the document layer's pure logic (Foundation only, no AppKit, no SelfTest.T):
//
//   * TextDiff.edits   round trip, ordering, coordinates, no split surrogate pairs, edits stay inside the changed lines
//   * TextDiff.map     bounds, monotonic, identity on unchanged text, snapped (mapSnapped): no split surrogate pairs
//   * Diff3.merge      constructed cases (exact expected text; nil EXACTLY when two edits touch), random cases against an
//                      independent reference implementation, symmetry, idempotence, "never invents a line", CRLF texts
//   * TextCodec        random byte strings: a decode either throws or round-trips byte-exactly (the "bytes in, bytes out" law)
//
// All inputs are seeded (reproducible: the failure message names the seed and case) and failing cases are MINIMISED (delta debugging)
// before they are reported. The same file is compiled by a stand-alone harness (swiftc, no AppKit) for quick iteration.

import Foundation

struct AuditRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func range(_ r: ClosedRange<Int>) -> Int { r.lowerBound + int(r.count) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

enum AuditDocProps {

    struct Result {
        var name: String
        var cases = 0
        var failures = 0
        var examples: [String] = []
        init(_ name: String) { self.name = name }
        mutating func fail(_ s: @autoclosure () -> String) { failures += 1; if examples.count < 3 { examples.append(s()) } }
    }

    typealias U = [UInt16]

    // MARK: helpers

    static func ns(_ u: U) -> NSString { NSString(characters: u, length: u.count) }
    static func units(_ s: NSString) -> U {
        var a = U(repeating: 0, count: s.length)
        if s.length > 0 { a.withUnsafeMutableBufferPointer { s.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: s.length)) } }
        return a
    }
    static func u(_ s: String) -> U { Array(s.utf16) }
    @inline(__always) static func isHigh(_ x: UInt16) -> Bool { x >= 0xD800 && x <= 0xDBFF }
    @inline(__always) static func isLow(_ x: UInt16) -> Bool { x >= 0xDC00 && x <= 0xDFFF }

    /// Readable, escaped rendering of a unit array for failure messages.
    static func show(_ a: U) -> String { showLimited(a, 160) }
    static func showLimited(_ a: U, _ limit: Int) -> String {
        var s = "\""
        for x in a.prefix(limit) {
            switch x {
            case 10: s += "\\n"
            case 13: s += "\\r"
            case 0x20...0x7E: s += String(UnicodeScalar(UInt8(x)))
            default: s += String(format: "\\u{%04X}", x)
            }
        }
        return s + (a.count > limit ? "\"... (\(a.count) units)" : "\"")
    }

    /// true when every surrogate is part of a well-formed pair (the generators only produce such texts, the minimiser must keep it so)
    static func wellFormed(_ a: U) -> Bool {
        var i = 0
        while i < a.count {
            if isHigh(a[i]) { if i + 1 < a.count && isLow(a[i + 1]) { i += 2; continue }; return false }
            if isLow(a[i]) { return false }
            i += 1
        }
        return true
    }

    /// Delta-debugging minimiser: removes chunks from every input while `fails` stays true. Bounded: at most `maxTrials` (200) evaluations of
    /// `fails` in total, so a defect that fires in thousands of cases cannot make the shrinking expensive (the result is then merely
    /// "small", not 1-minimal).
    static func minimise(_ inputs: [U], keepWellFormed: Bool = true, maxTrials: Int = 200, fails userFails: ([U]) -> Bool) -> [U] {
        var cur = inputs
        var trials = 0
        func fails(_ t: [U]) -> Bool {
            if keepWellFormed && !t.allSatisfy(wellFormed) { return false }
            trials += 1
            return userFails(t)
        }
        var changed = true
        while changed && trials < maxTrials {
            changed = false
            for i in 0..<cur.count {
                var chunk = max(1, cur[i].count / 2)
                while chunk >= 1 && trials < maxTrials {
                    var pos = 0
                    while pos < cur[i].count && trials < maxTrials {
                        var trial = cur
                        let end = min(cur[i].count, pos + chunk)
                        trial[i].removeSubrange(pos..<end)
                        if fails(trial) { cur = trial; changed = true } else { pos += chunk }
                    }
                    if chunk == 1 { break }
                    chunk /= 2
                }
            }
        }
        return cur
    }

    // MARK: random text generators

    static let tokensPlain: [U] = [u("a"), u("b"), u("c"), u("\n"), u("\n"), u("\n"), u(" "), u("ab\n"), u("é")]
    static let tokensRich: [U] = tokensPlain + [[0xD83D, 0xDE00], [0xD83D, 0xDE01], [0xD83C, 0xDE00], [0xD83C, 0xDFFB], [0xD83C, 0xDFFD],
                                                  u("\r\n"), u("\r"), u("日本"), u("x\n")]

    static func randomText(_ r: inout AuditRNG, tokens: [U], maxTokens: Int) -> U {
        var out = U()
        for _ in 0..<r.range(0...maxTokens) { out += r.pick(tokens) }
        return out
    }

    /// `base` with up to `k` random replacements (token granularity, so valid pairs stay valid pairs).
    static func mutate(_ r: inout AuditRNG, _ base: U, tokens: [U], edits k: Int) -> U {
        var t = base
        for _ in 0..<r.range(0...k) {
            let p = r.int(t.count + 1), q = min(t.count, p + r.range(0...6))
            var p2 = p, q2 = q
            if p2 > 0 && p2 < t.count && isHigh(t[p2 - 1]) && isLow(t[p2]) { p2 -= 1 }      // keep valid pairs whole
            if q2 > 0 && q2 < t.count && isHigh(t[q2 - 1]) && isLow(t[q2]) { q2 += 1 }
            t.replaceSubrange(p2..<q2, with: randomText(&r, tokens: tokens, maxTokens: 3))
        }
        return t
    }

    // MARK: TextDiff.edits

    /// nil = all properties hold.
    static func checkEdits(old: U, new: U, options: TextDiff.Options) -> String? {
        let edits = TextDiff.edits(old: ns(old), new: ns(new), options: options)
        if old == new { return edits.isEmpty ? nil : "equal texts produced edits \(edits)" }
        if edits.isEmpty { return "different texts produced no edits" }
        var prevOldEnd = 0, delta = 0
        var result = old
        var total = 0
        for e in edits {
            let o = e.oldRange, n = e.newRange
            if o.location < prevOldEnd { return "edits overlap or are not ascending: \(edits)" }
            if o.location < 0 || NSMaxRange(o) > old.count || n.location < 0 || NSMaxRange(n) > new.count { return "edit out of bounds: \(e) (old \(old.count), new \(new.count))" }
            if n.location != o.location + delta { return "newRange.location \(n.location) != oldRange.location \(o.location) + delta \(delta): \(edits)" }
            if o.length == 0 && n.length == 0 { return "empty edit \(e)" }
            for b in [o.location, NSMaxRange(o)] where b > 0 && b < old.count && isHigh(old[b - 1]) && isLow(old[b]) { return "edit \(e) splits a surrogate pair of the OLD text at \(b)" }
            for b in [n.location, NSMaxRange(n)] where b > 0 && b < new.count && isHigh(new[b - 1]) && isLow(new[b]) { return "edit \(e) splits a surrogate pair of the NEW text at \(b)" }
            prevOldEnd = NSMaxRange(o); delta += n.length - o.length
            total += o.length + n.length
        }
        for e in edits.reversed() { result.replaceSubrange(e.oldRange.location..<NSMaxRange(e.oldRange), with: new[e.newRange.location..<NSMaxRange(e.newRange)]) }
        if result != new { return "applying the edits gives \(show(result)) instead of \(show(new)); edits=\(edits)" }
        // The edits stay inside the line-aligned changed region: no line outside the lines that differ is ever touched (one unit of slack at each end for
        // a surrogate pair). (NOT "never more units than one replacement": a line diff can legitimately replace more units than one unit-level replacement
        // of the changed middle when lines moved - seed 7, case 40607 - which is the price of keeping distant hunks apart.)
        var p = 0
        while p < old.count && p < new.count && old[p] == new[p] { p += 1 }
        var sfx = 0
        while sfx < old.count - p && sfx < new.count - p && old[old.count - 1 - sfx] == new[new.count - 1 - sfx] { sfx += 1 }
        var lo = p; while lo > 0 && old[lo - 1] != 10 { lo -= 1 }
        var hi = old.count - sfx; while hi < old.count && old[hi] != 10 { hi += 1 }
        hi = min(old.count, hi + 1)
        lo = max(0, lo - 1); hi = min(old.count, hi + 1)
        for e in edits where e.oldRange.location < lo || NSMaxRange(e.oldRange) > hi { return "edit \(e) reaches outside the changed lines [\(lo), \(hi)): \(edits)" }
        return nil
    }

    /// Positions: bounds, monotone, identity on unchanged text; the snapped variant never lands inside a surrogate pair.
    static func checkMap(old: U, new: U, options: TextDiff.Options) -> String? {
        let edits = TextDiff.edits(old: ns(old), new: ns(new), options: options)
        let nsNew = ns(new)
        var prev = -1, prevSnapped = -1
        for p in 0...old.count {
            let m = TextDiff.map(p, through: edits)
            if m < 0 || m > new.count { return "map(\(p)) = \(m) out of bounds 0...\(new.count); edits=\(edits)" }
            if m < prev { return "map is not monotonic: map(\(p - 1)) = \(prev) > map(\(p)) = \(m); edits=\(edits)" }
            prev = m
            let inZone = edits.contains { e in p >= e.oldRange.location && p < max(NSMaxRange(e.oldRange), e.oldRange.location + 1) }
            if !inZone && p < old.count && (m >= new.count || new[m] != old[p]) { return "position \(p) is in unchanged text (\(String(format: "%04X", old[p]))) but maps to \(m) which holds \(m < new.count ? String(format: "%04X", new[m]) : "end"); edits=\(edits)" }
            let sm = TextDiff.mapSnapped(p, through: edits, in: nsNew)
            if sm < 0 || sm > new.count { return "mapSnapped(\(p)) = \(sm) out of bounds" }
            if sm > 0 && sm < new.count && isHigh(new[sm - 1]) && isLow(new[sm]) { return "mapSnapped(\(p)) = \(sm) is inside a surrogate pair; edits=\(edits)" }
            if sm < prevSnapped { return "mapSnapped is not monotonic at \(p)" }
            prevSnapped = sm
            if m == sm || !(m > 0 && m < new.count && isHigh(new[m - 1]) && isLow(new[m])) { if sm != m { return "mapSnapped(\(p)) = \(sm) differs from map = \(m) although map did not split a pair" } }
        }
        // ranges
        for _ in 0..<3 {
            let a = (old.count * 1) / 3, b = (old.count * 2) / 3
            let r = TextDiff.mapSnapped(NSRange(location: a, length: b - a), through: edits, in: nsNew)
            if r.location < 0 || NSMaxRange(r) > new.count || r.length < 0 { return "mapSnapped(range) out of bounds: \(r)" }
        }
        return nil
    }

    static func runDiffProps(cases: Int, seed: UInt64) -> [Result] {
        var rEdits = Result("edits: round trip / order / coordinates / no split pair / edits stay inside the changed lines")
        var rLine = Result("edits (line diff forced, small caps): same properties")
        var rMap = Result("map: bounds, monotonic, identity on unchanged text, snapped never splits a pair")
        var rBig = Result("edits (>= 4096 units: the default line-diff path): same properties")
        var rng = AuditRNG(seed)
        let forced = TextDiff.Options(maxHunks: 8, maxLineEditDistance: 40, lineDiffThresholdUnits: 0)
        let defaults = TextDiff.Options()
        func run(_ r: inout Result, _ old: U, _ new: U, _ opts: TextDiff.Options, _ check: (U, U, TextDiff.Options) -> String?, _ label: String, _ i: Int) {
            r.cases += 1
            if let why = check(old, new, opts) {
                if r.examples.count >= 3 { r.failures += 1; return }          // (the first three are minimised and printed, the rest only counted)
                let min = minimise([old, new]) { check($0[0], $0[1], opts) != nil }
                r.fail("seed \(seed) case \(i) [\(label)]: \(check(min[0], min[1], opts) ?? why)\n      old=\(show(min[0])) new=\(show(min[1]))")
            }
        }
        for i in 0..<cases {
            let tokens = rng.chance(50) ? tokensRich : tokensPlain
            let old = randomText(&rng, tokens: tokens, maxTokens: rng.chance(10) ? 80 : 24)
            let new = rng.chance(75) ? mutate(&rng, old, tokens: tokens, edits: 4) : randomText(&rng, tokens: tokens, maxTokens: 24)
            run(&rEdits, old, new, defaults, checkEdits, "default", i)
            run(&rLine, old, new, forced, checkEdits, "forced", i)
            if i % 2 == 0 {
                run(&rMap, old, new, forced, checkMap, "map forced", i)
                run(&rMap, old, new, defaults, checkMap, "map default", i)
            }
        }
        // the astral-character cases that broke the hunk path: two pairs sharing the low surrogate, in a changed line
        for (a, b) in [(U([0xD83D, 0xDE00]), U([0xD83C, 0xDE00])), (U([0xD83C, 0xDFFB]), U([0xD83C, 0xDFFD])), (U([0xD83D, 0xDE00]), U([0xD83D, 0xDE01]))] {
            for pre in [u(""), u("one\n"), u("one\ntwo\n")] {
                for post in [u(""), u("\n"), u("\nthree\nfour\n"), u("x\n")] {
                    run(&rLine, pre + a + post, pre + b + post, forced, checkEdits, "astral pair", -1)
                    run(&rMap, pre + a + post, pre + b + post, forced, checkMap, "astral pair map", -1)
                }
            }
        }
        // large texts: the DEFAULT options (4096-unit threshold) with scattered changes
        for i in 0..<max(20, cases / 5000) {
            var lines: [U] = []
            let n = rng.range(300...900)
            for j in 0..<n { lines.append(u("line \(j) \(rng.int(50)) ") + rng.pick(tokensRich) + u("\n")) }
            var changed = lines
            for _ in 0..<rng.range(1...6) {
                let k = rng.int(changed.count)
                switch rng.int(3) {
                case 0: changed[k] = u("changed \(rng.int(1000)) ") + rng.pick(tokensRich) + u("\n")
                case 1: changed.insert(u("inserted \(rng.int(1000))\n"), at: k)
                default: changed.remove(at: k); if changed.isEmpty { changed = [u("\n")] }
                }
            }
            let old = lines.flatMap { $0 }, new = changed.flatMap { $0 }
            run(&rBig, old, new, defaults, checkEdits, "big", i)
            if i % 4 == 0 { run(&rMap, old, new, defaults, checkMap, "big map", i) }
        }
        // exhaustive: every pair of texts over {a, b, \n} up to length 5, line diff forced
        var all: [U] = [[]]
        var frontier: [U] = [[]]
        for _ in 0..<5 { var next: [U] = []; for t in frontier { for c in [u("a"), u("b"), u("\n")] { next.append(t + c) } }; all += next; frontier = next }
        var rExh = Result("edits: EVERY pair of texts over {a,b,\\n} up to length 5 (\(all.count * all.count) pairs), line diff forced")
        for old in all { for new in all { run(&rExh, old, new, forced, checkEdits, "exhaustive", -1) } }
        return [rEdits, rLine, rBig, rMap, rExh]
    }

    // MARK: Diff3.merge

    /// Splits keeping the terminator ("\n"); the last line may have none.
    static func splitLines(_ a: U) -> [U] {
        var out: [U] = []; var cur = U()
        for x in a { cur.append(x); if x == 10 { out.append(cur); cur = [] } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Reference merge: the SAME block trimming as Diff3.merge (common prefix / suffix of all three, line aligned - which decides how
    /// duplicate lines are aligned), but an independent conflict test (pairwise, closed intervals touch) and a straight application.
    static func refMerge(base: U, mine: U, theirs: U) -> U?? {
        if mine == base { return .some(theirs) }
        if theirs == base || mine == theirs { return .some(mine) }
        func prefix(_ a: U, _ b: U) -> Int { var i = 0; while i < a.count && i < b.count && a[i] == b[i] { i += 1 }; return i }
        func suffix(_ a: U, _ b: U, _ maxLen: Int) -> Int { var i = 0; while i < maxLen && i < a.count && i < b.count && a[a.count - 1 - i] == b[b.count - 1 - i] { i += 1 }; return i }
        let p = min(prefix(base, mine), prefix(base, theirs))
        let s = min(suffix(base, mine, min(base.count, mine.count, theirs.count) - p), suffix(base, theirs, min(base.count, mine.count, theirs.count) - p))
        var ls = 0
        if p > 0 { var i = p - 1; while i >= 0 && base[i] != 10 { i -= 1 }; ls = i + 1 }
        var bEnd = base.count - s
        var q = bEnd; while q < base.count && base[q] != 10 { q += 1 }
        bEnd = q == base.count ? base.count : q + 1
        let suf = base.count - bEnd
        let mEnd = mine.count - suf, tEnd = theirs.count - suf
        if mEnd < ls || tEnd < ls || bEnd < ls { return .some(nil) }
        let B = TextDiff.Lines(units: Array(base[ls..<bEnd])), M = TextDiff.Lines(units: Array(mine[ls..<mEnd])), T = TextDiff.Lines(units: Array(theirs[ls..<tEnd]))
        guard let ha = TextDiff.myers(B, M, maxD: 1_000_000), let hb = TextDiff.myers(B, T, maxD: 1_000_000) else { return .none }
        func repl(_ side: Int, _ h: TextDiff.Hunk) -> U {
            let L = side == 0 ? M : T
            return Array(L.units[L.starts[h.bStart]..<L.starts[h.bEnd]])
        }
        for a in ha { for b in hb where a.aStart <= b.aEnd && b.aStart <= a.aEnd {
            if !(a.aStart == b.aStart && a.aEnd == b.aEnd && repl(0, a) == repl(1, b)) { return .some(nil) }
        } }
        var ops: [(h: TextDiff.Hunk, side: Int)] = ha.map { ($0, 0) } + hb.map { ($0, 1) }
        ops.sort { ($0.h.aStart, $0.h.aEnd, $0.side) < ($1.h.aStart, $1.h.aEnd, $1.side) }
        var out = Array(base[0..<ls]); var cursor = 0; var lastIdentical: TextDiff.Hunk? = nil
        for op in ops {
            if let l = lastIdentical, l.aStart == op.h.aStart, l.aEnd == op.h.aEnd { lastIdentical = nil; continue }    // second copy of an identical change
            if op.h.aStart > cursor { out += B.units[B.starts[cursor]..<B.starts[op.h.aStart]] }
            out += repl(op.side, op.h)
            cursor = op.h.aEnd
            lastIdentical = op.h
        }
        if cursor < B.count { out += B.units[B.starts[cursor]..<B.starts[B.count]] }
        out += base[bEnd...]
        return .some(out)
    }

    /// Properties that need no oracle: idempotence, symmetry, never invents a line, matches the reference implementation.
    static func checkMerge(_ base: U, _ mine: U, _ theirs: U) -> String? {
        let got = Diff3.merge(base: ns(base), mine: ns(mine), theirs: ns(theirs)).map { units($0) }
        if mine == base { if got != theirs { return "mine == base must give theirs, got \(got.map(show) ?? "nil")" }; return nil }
        if theirs == base || mine == theirs { if got != mine { return "theirs == base (or mine == theirs) must give mine, got \(got.map(show) ?? "nil")" }; return nil }
        let swapped = Diff3.merge(base: ns(base), mine: ns(theirs), theirs: ns(mine)).map { units($0) }
        if (got == nil) != (swapped == nil) { return "not symmetric: merge(b,m,t) = \(got.map(show) ?? "nil"), merge(b,t,m) = \(swapped.map(show) ?? "nil")" }
        if let g = got, let s = swapped, g != s { return "not symmetric: merge(b,m,t) = \(show(g)), merge(b,t,m) = \(show(s))" }
        if let ref = refMerge(base: base, mine: mine, theirs: theirs) {
            if got != ref { return "differs from the reference merge: got \(got.map(show) ?? "nil"), reference \(ref.map(show) ?? "nil")" }
        }
        if let g = got {
            let known = Set((splitLines(base) + splitLines(mine) + splitLines(theirs)).map { $0 })
            for l in splitLines(g) where !known.contains(l) { return "merge invented the line \(show(l)): \(show(g))" }
        }
        return nil
    }

    /// Constructed merge cases: unique lines, separated (or deliberately touching) edit sites; the expected result is built, not computed.
    struct Constructed { var base: U; var mine: U; var theirs: U; var expected: U?; var note: String }

    private struct Op { var a: Int; var k: Int; var fresh: [U]; var side: Int; var dup = false }   // replaces base lines a..<a+k by `fresh`; closed interval [a, a+k]

    static func constructed(_ r: inout AuditRNG, conflict: Bool, crlf: Bool) -> Constructed {
        let term = crlf ? u("\r\n") : u("\n")
        let n = r.range(0...14)
        var baseLines: [U] = (0..<n).map { u("L\($0)") + term }
        let noFinalNewline = n > 0 && r.chance(20)
        if noFinalNewline { baseLines[n - 1] = u("L\(n - 1)") }
        var ops: [Op] = []
        var gap = 0
        var serial = 0
        func fresh(_ side: Int, _ m: Int) -> [U] { (0..<m).map { _ in serial += 1; return u(side == 0 ? "M\(serial)" : "T\(serial)") + term } }
        while gap <= n {
            // a missing final newline makes "insert after the last line" a change of that line, not an independent edit
            if r.chance(35) && !(noFinalNewline && gap == n) {
                let side = r.int(2)
                let k = gap < n ? r.range(0...min(3, n - gap)) : 0
                let m = k == 0 ? r.range(1...2) : r.range(0...2)
                ops.append(Op(a: gap, k: k, fresh: fresh(side, m), side: side))
                gap += k + 1            // the next site starts strictly after this one's closed interval [a, a+k]
            } else { gap += 1 }
        }
        var note = "\(ops.count) separated edit(s)"
        var expectNil = false
        if !conflict && !ops.isEmpty && r.chance(20) {
            let o = ops[r.int(ops.count)]
            ops.append(Op(a: o.a, k: o.k, fresh: o.fresh, side: 1 - o.side, dup: true))     // the SAME change on both sides is accepted
            note += " + an identical change on both sides"
        }
        func touches(_ x: Op, _ y: Op) -> Bool { x.a <= y.a + y.k && y.a <= x.a + x.k }
        if conflict && !ops.isEmpty {
            let victim = ops[r.int(ops.count)]
            let side = 1 - victim.side
            // a site of the OTHER side whose closed interval touches the victim's
            let lo = max(0, victim.a - 3), hi = min(n, victim.a + victim.k + 1)
            let a = r.range(lo...hi)
            var k = a < n ? r.range(0...min(3, n - a)) : 0
            if a + k < victim.a { k = min(n - a, victim.a - a) }
            let m = k == 0 ? r.range(1...2) : r.range(0...2)
            // two deletions of exactly the same lines are an IDENTICAL change (accepted): give it content
            let identicalDeletion = k > 0 && m == 0 && a == victim.a && k == victim.k && victim.fresh.isEmpty
            let extra = Op(a: a, k: k, fresh: fresh(side, identicalDeletion ? 1 : m), side: side)
            if !(noFinalNewline && a == n) && touches(victim, extra) {
                ops.removeAll { $0.side == side && touches($0, extra) }           // keep each side's own edits disjoint
                ops.append(extra)
                expectNil = true
                note = "touching sites: \(victim.side == 0 ? "mine" : "theirs") [\(victim.a),\(victim.a + victim.k)] vs \(side == 0 ? "mine" : "theirs") [\(a),\(a + k)]"
            }
        }
        func build(_ side: Int?) -> U {
            let sorted = ops.filter { side == nil ? !$0.dup : $0.side == side }.sorted { ($0.a, $0.k) < ($1.a, $1.k) }
            var out: [U] = []
            var oi = 0, i = 0
            while i < n || oi < sorted.count {
                if oi < sorted.count && sorted[oi].a == i {
                    let op = sorted[oi]; oi += 1
                    out += op.fresh
                    i += op.k
                } else if i < n { out.append(baseLines[i]); i += 1 } else { break }
            }
            return out.flatMap { $0 }
        }
        return Constructed(base: baseLines.flatMap { $0 }, mine: build(0), theirs: build(1), expected: expectNil ? nil : build(nil), note: note)
    }

    static func runMergeProps(cases: Int, seed: UInt64) -> [Result] {
        var rSep = Result("merge: separated edits (constructed, unique lines): exact expected text")
        var rTouch = Result("merge: touching/overlapping edits (constructed): nil exactly when two edits touch")
        var rRand = Result("merge: random texts with duplicate lines vs the independent reference merge, symmetric, idempotent, never invents a line")
        var rCRLF = Result("merge: the same with CRLF line ends and a missing final newline")
        var rExh = Result("merge: EVERY triple of texts over {a\\n, b\\n, \\n} up to 4 lines")
        var rng = AuditRNG(seed)
        func fail(_ r: inout Result, _ why: String, _ inputs: [U], label: String, i: Int) {
            if r.examples.count >= 3 { r.failures += 1; return }
            let min = minimise(inputs) { checkMerge($0[0], $0[1], $0[2]) != nil }
            r.fail("seed \(seed) case \(i) [\(label)]: \(checkMerge(min[0], min[1], min[2]) ?? why)\n      base=\(show(min[0])) mine=\(show(min[1])) theirs=\(show(min[2]))")
        }
        for i in 0..<cases {
            for crlf in [false, true] {
                // constructed, separated: exact
                let c = constructed(&rng, conflict: false, crlf: crlf)
                var r = crlf ? rCRLF : rSep
                r.cases += 1
                let got = Diff3.merge(base: ns(c.base), mine: ns(c.mine), theirs: ns(c.theirs)).map { units($0) }
                if got != c.expected {
                    r.fail("seed \(seed) case \(i): \(c.note): got \(got.map(show) ?? "nil") expected \(c.expected.map(show) ?? "nil")\n      base=\(show(c.base)) mine=\(show(c.mine)) theirs=\(show(c.theirs))")
                }
                if crlf { rCRLF = r } else { rSep = r }
                // constructed, touching: nil
                let t = constructed(&rng, conflict: true, crlf: crlf)
                rTouch.cases += 1
                let tg = Diff3.merge(base: ns(t.base), mine: ns(t.mine), theirs: ns(t.theirs)).map { units($0) }
                if tg != t.expected {
                    rTouch.fail("seed \(seed) case \(i): \(t.note): got \(tg.map(show) ?? "nil") expected \(t.expected.map(show) ?? "nil")\n      base=\(show(t.base)) mine=\(show(t.mine)) theirs=\(show(t.theirs))")
                }
            }
            // random with duplicates
            let lineTokens: [U] = [u("a\n"), u("b\n"), u("\n"), u("c\n"), u("a b\n"), u("a\n"), u("\n"), u("- item\n"), u("x")]
            let crlfTokens: [U] = [u("a\r\n"), u("b\r\n"), u("\r\n"), u("a\n"), u("c\r\n"), u("x")]
            for (tokens, label) in [(lineTokens, "random"), (crlfTokens, "random crlf")] {
                let base = randomText(&rng, tokens: tokens, maxTokens: 14)
                let mine = mutate(&rng, base, tokens: tokens, edits: 3), theirs = mutate(&rng, base, tokens: tokens, edits: 3)
                rRand.cases += 1
                if let why = checkMerge(base, mine, theirs) { fail(&rRand, why, [base, mine, theirs], label: label, i: i) }
            }
        }
        // exhaustive over line vocabulary
        var texts: [U] = [[]]
        var frontier: [U] = [[]]
        for _ in 0..<4 { var next: [U] = []; for t in frontier { for l in [u("a\n"), u("b\n"), u("\n")] { next.append(t + l) } }; texts += next; frontier = next }
        for b in texts { for m in texts { for t in texts {
            rExh.cases += 1
            if let why = checkMerge(b, m, t) { fail(&rExh, why, [b, m, t], label: "exhaustive", i: -1) }
        } } }
        return [rSep, rTouch, rCRLF, rRand, rExh]
    }

    // MARK: huge inputs: the diff / merge budget

    /// 10 MB / 150 000 lines: scattered edits must be reproduced EXACTLY (edits applied == new text, merge == the two edit sets applied together) and
    /// finish far inside a second; texts that differ everywhere / repeat one line must give up cheaply (one replacement / nil), never hang the main thread.
    static func runBudgetProps(seed: UInt64) -> [Result] {
        var r = Result("budget: 10 MB, 150 000 lines: scattered edits / merges exact and fast; hopeless diffs give up cheaply")
        var rng = AuditRNG(seed)
        let n = 150_000
        let base = (0..<n).map { "Line \($0) - the quick brown fox jumps over the lazy dog \($0 * 7919 % 10007) and more words to fill it up\n" }
        func join(_ l: [String]) -> NSString { l.joined() as NSString }
        func timed(_ label: String, limitMs: Double, _ f: () -> String?) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let bad = f()
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
            r.cases += 1
            if let bad { r.fail("\(label): \(bad)") } else if ms > limitMs { r.fail("\(label): took \(Int(ms)) ms (budget \(Int(limitMs)) ms)") }
        }
        let oldNS = join(base)
        // a few distant lines changed: the line diff gives a few small edits
        var few = base
        for _ in 0..<5 { few[rng.int(n)] = "CHANGED \(rng.int(1_000_000))\n" }
        let fewNS = join(few)
        timed("5 scattered changed lines", limitMs: 2000) {
            let e = TextDiff.edits(old: oldNS, new: fewNS)
            let storage = NSMutableString(string: oldNS as String)
            for x in e.reversed() { storage.replaceCharacters(in: x.oldRange, with: fewNS.substring(with: x.newRange)) }
            return storage.isEqual(to: fewNS as String) && e.count >= 1 && e.count <= 5 && e.reduce(0, { $0 + $1.oldRange.length + $1.newRange.length }) < 2000 ? nil : "edits do not rebuild the text or are not small (\(e.count) edits)"
        }
        // 300 + 300 scattered edits on both sides, separated: merged == both applied
        var mine = base, theirs = base, both = base
        for i in 0..<300 { let a = (i * 997) % n, b = (i * 997 + 500) % n; mine[a] = "MINE \(i)\n"; both[a] = mine[a]; theirs[b] = "THEIRS \(i)\n"; both[b] = theirs[b] }
        timed("merge: 300 + 300 separated scattered edits", limitMs: 2000) {
            guard let m = Diff3.merge(base: oldNS, mine: join(mine), theirs: join(theirs)) else { return "merge returned nil" }
            return m.isEqual(to: join(both) as String) ? nil : "merged text differs from both edit sets applied"
        }
        // the same with one pair of touching edits: nil
        var touch = theirs
        touch[(5 * 997)] = "THEIRS TOUCH\n"
        timed("merge: one pair of overlapping edits among 600", limitMs: 2000) { Diff3.merge(base: oldNS, mine: join(mine), theirs: join(touch)) == nil ? nil : "overlapping edits must give nil" }
        // hopeless: completely different texts; 1M identical lines with 1500 scattered changes
        let other = (0..<n).map { "Other \($0) - something else entirely, nothing in common with the first text at all\n" }
        timed("two completely different texts", limitMs: 3000) {
            let e = TextDiff.edits(old: oldNS, new: join(other))
            return e.count == 1 ? nil : "expected ONE replacement, got \(e.count)"
        }
        let rep = [String](repeating: "x\n", count: 1_000_000)
        var repChanged = rep
        for _ in 0..<1500 { repChanged[rng.int(rep.count)] = "y\n" }
        timed("1 M identical lines, 1500 scattered changes", limitMs: 3000) {
            let e = TextDiff.edits(old: join(rep), new: join(repChanged))
            let storage = NSMutableString(string: join(rep) as String)
            for x in e.reversed() { storage.replaceCharacters(in: x.oldRange, with: join(repChanged).substring(with: x.newRange)) }
            return storage.isEqual(to: join(repChanged) as String) ? nil : "edits do not rebuild the text"
        }
        return [r]
    }

    // MARK: TextCodec: bytes in, bytes out

    /// decode either throws (the file is refused, nothing can be lost) or encode(decode(x)) == x, byte for byte.
    static func checkCodec(_ bytes: [UInt8]) -> String? {
        let d = Data(bytes)
        guard let dec = try? TextCodec.decode(d) else { return nil }
        guard let back = try? TextCodec.encode(dec.text, format: dec.format) else { return "decoded as \(dec.format) but cannot be encoded again" }
        if back != d { return "decoded as \(dec.format) (\(dec.text.length) units) and encoded back to different bytes (\(back.count) vs \(d.count))" }
        return nil
    }

    /// encode / decode around the 1 MiB chunk boundaries of `TextCodec.utf8Bytes` (an astral character must never be cut in two) and on a 5 MB mixed text.
    static func runCodecBoundaryProps(seed: UInt64) -> [Result] {
        var r = Result("codec: astral / multi-byte characters at the 1 MiB chunk boundaries, CRLF expansion, a 5 MB mixed text")
        let chunk = 1 << 20
        for off in [chunk - 3, chunk - 2, chunk - 1, chunk, chunk + 1, 2 * chunk - 1, 2 * chunk, 2 * chunk + 1, 3 * chunk - 1] {
            for glyph in ["😀", "é", "日", "a"] {
                let prefix = String(repeating: "a", count: off)
                let s = prefix + glyph + "b😀c"
                r.cases += 1
                guard let enc = try? TextCodec.encode(s as NSString, format: TextFormat()), enc == Data(s.utf8) else { r.fail("encode at offset \(off) glyph \(glyph) differs from String.utf8"); continue }
                guard let dec = try? TextCodec.decode(enc), (dec.text as String) == s else { r.fail("decode at offset \(off) glyph \(glyph)"); continue }
                var f = TextFormat(); f.lineEnding = .crlf
                let s2 = prefix + "\n" + glyph + "\nx"
                guard let e2 = try? TextCodec.encode(s2 as NSString, format: f), let d2 = try? TextCodec.decode(e2), (d2.text as String) == s2, d2.format.lineEnding == .crlf else { r.fail("CRLF round trip at offset \(off) glyph \(glyph)"); continue }
            }
        }
        var rng = AuditRNG(seed)
        let pool: [Unicode.Scalar] = ["a", "b", "\n", " ", "é", "ß", "日", "本", "😀", "🇩", "\u{200D}", "\u{FEFF}", "\u{FFFD}", "\u{10FFFF}"]
        var big = String.UnicodeScalarView()
        for _ in 0..<2_500_000 { big.append(pool[rng.int(pool.count)]) }
        let bs = String(big)
        r.cases += 1
        if let e = try? TextCodec.encode(bs as NSString, format: TextFormat()), e == Data(bs.utf8), let d = try? TextCodec.decode(e), (d.text as String) == bs {} else { r.fail("5 MB mixed text does not round-trip") }
        return [r]
    }

    static func runCodecProps(cases: Int, seed: UInt64) -> [Result] {
        var rng = AuditRNG(seed)
        var r = Result("codec: random byte strings round-trip byte-exactly or are refused")
        var rBom = Result("codec: BOM / UTF-16 / UTF-32 / CR / LF structured byte strings")
        let pool: [UInt8] = [0x41, 0x0A, 0x0D, 0x20, 0x80, 0xA9, 0xBF, 0xC2, 0xC3, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80, 0xFF, 0xC0, 0xED, 0xA0, 0xF4, 0x90, 0xEF, 0xBB, 0xBD, 0xFE, 0x00, 0x81, 0x9D]
        for i in 0..<cases {
            var b = [UInt8]()
            for _ in 0..<rng.range(0...16) { b.append(rng.chance(30) ? UInt8(rng.int(256)) : rng.pick(pool)) }
            r.cases += 1
            if let why = checkCodec(b) {
                let min = r.examples.count >= 3 ? b : minimise([b.map { UInt16($0) }]) { checkCodec($0[0].map { UInt8($0) }) != nil }[0].map { UInt8($0) }
                r.fail("seed \(seed) case \(i): bytes \(min.map { String(format: "%02X", $0) }.joined(separator: " ")): \(checkCodec(min) ?? why)")
            }
            // structured: optional BOM + units in a wide encoding or bytes with line ends
            var s = [UInt8]()
            switch rng.int(6) {
            case 0: s = [0xEF, 0xBB, 0xBF]
            case 1: s = [0xFF, 0xFE]
            case 2: s = [0xFE, 0xFF]
            case 3: s = [0xFF, 0xFE, 0, 0]
            case 4: s = [0, 0, 0xFE, 0xFF]
            default: break
            }
            for _ in 0..<rng.range(0...10) { s.append(rng.chance(25) ? rng.pick([0x0D, 0x0A, 0x00, 0xA9, 0xEF, 0xBB, 0xBF]) : UInt8(rng.int(256))) }
            rBom.cases += 1
            if let why = checkCodec(s) {
                let min = rBom.examples.count >= 3 ? s : minimise([s.map { UInt16($0) }]) { checkCodec($0[0].map { UInt8($0) }) != nil }[0].map { UInt8($0) }
                rBom.fail("seed \(seed) case \(i): bytes \(min.map { String(format: "%02X", $0) }.joined(separator: " ")): \(checkCodec(min) ?? why)")
            }
        }
        return [r, rBom]
    }
}
#endif
