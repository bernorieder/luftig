import Foundation
import MarkdownKit

// Independent CommonMark 0.31 / GFM conformance suite (written from the specification, not from the lexer source).
//
// Every case has a KIND:
//   .spec   - what CommonMark / GFM mandates, as far as a syntax highlighter can express it
//   .judge  - highlighter judgement (what a writer wants to see; the spec is silent or a renderer-only concern)
// and a verdict:
//   pass      actual == expected
//   deviation actual == `accept` : a documented, deliberate deviation (the expectation still states the ideal)
//   fail      anything else (a lexer defect, or a wrong expectation)
//   bad       the expectation text itself does not re-assemble to the input (typo in the suite)
//
// Expectations use the harness run notation `[facet·facet:text]`; facet ORDER is irrelevant (compared as sets) and adjacent
// runs with equal facets are merged before comparison, so the suite does not depend on how a run is split.

enum SpecKind: String { case spec, judge }
enum SpecVerdict: String { case pass, deviation, fail, bad }

nonisolated(unsafe) var specGroup = ""
nonisolated(unsafe) var specTally: [String: [SpecVerdict: Int]] = [:]       // key "kind"
nonisolated(unsafe) var specGroupTally: [String: [SpecVerdict: Int]] = [:]  // key "group|kind"
nonisolated(unsafe) var specDeviations: [String] = []
nonisolated(unsafe) var specFailures: [String] = []
nonisolated(unsafe) var specCaseCount = 0

private typealias NRun = (facets: Set<String>, text: String)

private func isFacetChar(_ c: Unicode.Scalar) -> Bool {
    (c.value >= 97 && c.value <= 122) || (c.value >= 48 && c.value <= 57) || c == "·"
}

private func facetNames(_ s: MDStyle) -> Set<String> {
    Set(s.description.split(separator: "·").map(String.init))
}

private func parseNotation(_ s: String) -> [NRun]? {
    let c = Array(s.unicodeScalars)
    let n = c.count
    var i = 0
    var out: [NRun] = []
    while i < n {
        guard c[i] == "[" else { return nil }
        var j = i + 1
        while j < n && isFacetChar(c[j]) { j += 1 }
        guard j < n, c[j] == ":" else { return nil }
        let names = String(String.UnicodeScalarView(c[(i + 1)..<j]))
        var k = j + 1
        var found = false
        while k < n {
            if c[k] == "]" {
                if k + 1 == n { found = true; break }
                if c[k + 1] == "[" {
                    var m = k + 2
                    while m < n && isFacetChar(c[m]) { m += 1 }
                    if m < n && c[m] == ":" { found = true; break }
                }
            }
            k += 1
        }
        guard found else { return nil }
        let text = String(String.UnicodeScalarView(c[(j + 1)..<k]))
        let f = Set(names.split(separator: "·").map(String.init))
        if let last = out.last, last.facets == f { out[out.count - 1].text += text } else { out.append((f, text)) }
        i = k + 1
    }
    return out
}

private func actualRuns(_ t: NSString, _ runs: [MDRun]) -> [NRun] {
    var out: [NRun] = []
    for r in runs {
        let f = facetNames(r.style)
        let txt = visible(t.substring(with: r.range))
        if let last = out.last, last.facets == f { out[out.count - 1].text += txt } else { out.append((f, txt)) }
    }
    return out
}

private func show(_ r: [NRun]) -> String {
    r.map { "[\($0.facets.sorted().joined(separator: "·")):\($0.text)]" }.joined()
}

private func same(_ a: [NRun], _ b: [NRun]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.facets == $1.facets && $0.text == $1.text }
}

private func record(_ kind: SpecKind, _ v: SpecVerdict) {
    specCaseCount += 1
    specTally[kind.rawValue, default: [:]][v, default: 0] += 1
    specGroupTally["\(specGroup)|\(kind.rawValue)", default: [:]][v, default: 0] += 1
}

func specGroupStart(_ name: String) { specGroup = name }

/// Run the lexer the way the app would: whole text via lexAll, plus a cold styleRuns over the whole text; both must agree
/// and satisfy the structural invariants. Returns the runs (or nil with a message).
private func lexChecked(_ input: String) -> (NSString, [MDRun], String?) {
    let t = NSString(string: input)
    let runs = MarkdownStyler().lexAll(t)
    var problem: String? = nil
    if t.length > 0 {
        let r = MDResult(range: NSRange(location: 0, length: t.length), runs: runs)
        if let e = checkStructure(t, r) { problem = "structure: \(e)" }
        let cold = MarkdownStyler().styleRuns(in: NSRange(location: 0, length: t.length), of: t)
        if cold.runs != runs { problem = (problem ?? "") + " cold styleRuns != lexAll" }
    }
    return (t, runs, problem)
}

/// Exact expectation in run notation. `accept`, when given, is the documented deviating output (same notation).
func sx(_ kind: SpecKind, _ input: String, _ expected: String, accept: String? = nil, _ note: String = "") {
    let (t, runs, problem) = lexChecked(input)
    let act = actualRuns(t, runs)
    let label = "[\(specGroup)/\(kind.rawValue)] \"\(visible(input))\" \(note)"
    guard let exp = parseNotation(expected), exp.map(\.text).joined() == visible(input) else {
        record(kind, .bad)
        let m = "BAD EXPECTATION (does not re-assemble to the input) \(label)\n      expected: \(expected)"
        specFailures.append(m); Harness.fail(m); return
    }
    if let p = problem { record(kind, .fail); let m = "\(label) \(p)"; specFailures.append(m); Harness.fail(m); return }
    if same(act, exp) { record(kind, .pass); Harness.checks += 1; return }
    if let a = accept, let acc = parseNotation(a), acc.map(\.text).joined() == visible(input), same(act, acc) {
        record(kind, .deviation); Harness.checks += 1
        specDeviations.append("\(label)\n      ideal:    \(show(exp))\n      accepted: \(show(acc))")
        return
    }
    record(kind, .fail)
    let m = "\(label)\n      expected: \(show(exp))\n      actual:   \(show(act))"
    specFailures.append(m); Harness.fail(m)
}

/// Substring-level facet assertions. Each check is "+facet[,facet] substring", "-facet[,facet] substring" or "plain substring"
/// (no facet at all apart from heading level / quote depth). `substring#2` selects the 2nd occurrence.
/// `+x` requires every UTF-16 unit of the substring to carry all listed facets; `-x` requires every unit to carry none of them.
func sh(_ kind: SpecKind, _ input: String, _ checks: [String], accept: [String]? = nil, _ note: String = "") {
    let (t, runs, problem) = lexChecked(input)
    let label = "[\(specGroup)/\(kind.rawValue)] \"\(visible(input))\" \(note)"
    if let p = problem { record(kind, .fail); let m = "\(label) \(p)"; specFailures.append(m); Harness.fail(m); return }
    var perUnit: [Set<String>] = []
    perUnit.reserveCapacity(t.length)
    for r in runs {
        let f = facetNames(r.style)
        for _ in 0..<r.range.length { perUnit.append(f) }
    }
    func evaluate(_ list: [String]) -> [String] {
        var bad: [String] = []
        for c in list {
            guard let sp = c.firstIndex(of: " ") else { bad.append("malformed check \(c)"); continue }
            let op = String(c[c.startIndex..<sp])
            var sub = String(c[c.index(after: sp)...])
            var nth = 1
            if sub.count > 3, sub[sub.index(sub.endIndex, offsetBy: -3)] == "@", sub[sub.index(sub.endIndex, offsetBy: -2)] == "@", let k = Int(sub.suffix(1)) { nth = k; sub = String(sub.dropLast(3)) }
            var loc = -1, from = 0
            for _ in 0..<nth {
                let r = t.range(of: sub, options: [], range: NSRange(location: from, length: t.length - from))
                if r.location == NSNotFound { loc = -1; break }
                loc = r.location; from = r.location + max(1, r.length)
            }
            if loc < 0 { bad.append("substring '\(sub)' (#\(nth)) not found"); continue }
            let range = loc..<(loc + (sub as NSString).length)
            if op == "plain" {
                func isHQ(_ n: String) -> Bool { n.count == 2 && (n.hasPrefix("h") || n.hasPrefix("q")) && n.last!.isNumber }
                if let u = range.first(where: { !perUnit[$0].filter({ !isHQ($0) }).isEmpty }) { bad.append("'\(sub)' should be plain but has \(perUnit[u].sorted().joined(separator: "·"))") }
            } else if op.hasPrefix("+") || op.hasPrefix("-") {
                let want = Set(op.dropFirst().split(separator: ",").flatMap { $0.split(separator: "·") }.map(String.init))
                for u in range {
                    let has = want.isSubset(of: perUnit[u]), none = want.isDisjoint(with: perUnit[u])
                    if op.hasPrefix("+") && !has { bad.append("'\(sub)' lacks \(want.sorted().joined(separator: "·")) at unit \(u - loc) (has \(perUnit[u].sorted().joined(separator: "·")))"); break }
                    if op.hasPrefix("-") && !none { bad.append("'\(sub)' should not have \(want.sorted().joined(separator: "·")) at unit \(u - loc)"); break }
                }
            } else { bad.append("unknown op \(op)") }
        }
        return bad
    }
    let bad = evaluate(checks)
    if bad.isEmpty { record(kind, .pass); Harness.checks += 1; return }
    if let a = accept, evaluate(a).isEmpty {
        record(kind, .deviation); Harness.checks += 1
        specDeviations.append("\(label)\n      ideal checks not met: \(bad.joined(separator: "; "))")
        return
    }
    record(kind, .fail)
    let m = "\(label)\n      \(bad.joined(separator: "\n      "))\n      actual: \(show(actualRuns(t, runs)))"
    specFailures.append(m); Harness.fail(m)
}

/// Whole text must carry no inline / block facet at all (pure prose), e.g. file names with underscores.
func spPlain(_ kind: SpecKind, _ input: String, accept: String? = nil, _ note: String = "") {
    let t = NSString(string: input)
    let st = MarkdownStyler().lexAll(t)
    // expected: the whole text in a single run without facets
    let exp = "[:\(visible(input))]"
    _ = st
    sx(kind, input, exp, accept: accept, note)
}

func printConformanceTable(verbose: Bool) {
    func cell(_ kind: String) -> (Int, Int, Int, Int, Int) {
        let d = specTally[kind] ?? [:]
        let p = d[.pass] ?? 0, v = d[.deviation] ?? 0, f = d[.fail] ?? 0, b = d[.bad] ?? 0
        return (p + v + f + b, p, v, f, b)
    }
    print("")
    print("CommonMark / GFM conformance (independent suite)")
    print("| group | spec cases | pass | deviation | fail | judgement cases | pass | deviation | fail |")
    print("|---|---|---|---|---|---|---|---|---|")
    var groups: [String] = []
    for k in specGroupTally.keys { let g = String(k.split(separator: "|")[0]); if !groups.contains(g) { groups.append(g) } }
    groups.sort()
    for g in groups {
        func c(_ kind: String) -> (Int, Int, Int, Int) {
            let d = specGroupTally["\(g)|\(kind)"] ?? [:]
            let p = d[.pass] ?? 0, v = d[.deviation] ?? 0, f = (d[.fail] ?? 0) + (d[.bad] ?? 0)
            return (p + v + f, p, v, f)
        }
        let s = c("spec"), j = c("judge")
        print("| \(g) | \(s.0) | \(s.1) | \(s.2) | \(s.3) | \(j.0) | \(j.1) | \(j.2) | \(j.3) |")
    }
    let s = cell("spec"), j = cell("judge")
    print("| **total** | \(s.0) | \(s.1) | \(s.2) | \(s.3 + s.4) | \(j.0) | \(j.1) | \(j.2) | \(j.3 + j.4) |")
    if verbose && !specDeviations.isEmpty {
        print("\nDocumented deviations (\(specDeviations.count)):")
        for d in specDeviations { print("  - \(d)") }
    }
}
