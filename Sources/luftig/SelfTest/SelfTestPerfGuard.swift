#if LUFTIG_SELFTEST
// SelfTestPerfGuard.swift - REGRESSION GUARD for the performance budget (scenario `perf-guard`, part of `--selftest all`, ~20 s).
//
// Every budget (enum `Budgets` at the end) is 3x the WORST of seven runs on the reference machine (Apple M5 Pro, 18 cores, release build, load ~4), rounded up,
// with a floor of 4 ms, and never above the DESIGN.md row where there is one (open 1 MB < 100 ms, open 10 MB < 400 ms, keystroke p50 < 8 ms / 16 ms in the
// 10 MB document). The point: a future change cannot silently make luftig slow - a 3x slowdown of any guarded path fails this scenario, noise does not
// (the seven reference runs varied by 1-10 %, the odd p95 outlier by 2x).
//
//   * load aware: when the 1-minute load average is above half the cores (`--max-load N` overrides) the scenario SKIPS and says why, asserting nothing:
//     timing assertions on a busy machine only measure the machine. Debug builds skip too.
//   * a row that is over budget by less than 3x is measured ONCE MORE before it fails (a scheduler hiccup is not a regression); both numbers are printed.
//     3x over is a regression: no second look.
//   * fail fast: after 6 rows over budget (or 150 s of running, a healthy run takes ~20 s) the rest is skipped and the scenario says so.
//   * `--budget-scale X` multiplies every budget (X < 1 shows what a failure looks like, X > 1 for a slower machine).
//   * generated inputs only (the corpus generator of the other scenarios + pathological shapes built in memory): nothing outside the work directory.
//   * the printed `PERFGUARD` lines are the current numbers: re-baseline the table when a deliberate change moves them.
//   * rows: open / typing (start, middle, end; p50 and p95) / scroll step / scroller-thumb jump / Cmd-Down / jump to the middle / find / select all + copy
//     / paste + undo + redo / undo of a replace-all / autosave on a 1 MB and a 10 MB document; open, first edit, scroll, Cmd-Down and typing on eight
//     pathological shapes; idle CPU of an open 5 MB document; footprint growth over open / edit / close cycles (ASCII text: for NON-ASCII texts above
//     ~2 MB macOS 27.0.1 leaks the decode, see `perf-decode-leak`).
//
//   luftig-SelfTest --selftest perf-guard [--max-load N] [--budget-scale X]

import AppKit
import MarkdownKit

extension SelfTestScenarios {

    /// One guarded number: measured (ms), budget (ms). `budget` is 3x the reference measurement, rounded up (and <= the DESIGN.md row).
    struct PerfRow {
        let name: String
        let budget: Double
        let measure: () async throws -> Double
    }

    // MARK: in-memory pathological shapes (the same kinds as the perf review's corpora, smaller so that the guard stays fast)

    static func guardShape(_ kind: String) -> String {
        var r = TestRNG(99)
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "markdown", "editor", "native"]
        func w(_ n: Int) -> String { (0..<n).map { _ in r.pick(words) }.joined(separator: " ") }
        var s = ""
        switch kind {
        case "table-5000-rows":
            s = "# Table\n\n| id | name | value | note | flag |\n|---:|:-----|:-----:|------|------|\n"
            for i in 0..<5000 { s += "| \(i) | \(r.pick(words)) | \(r.int(99999)) | \(w(4)) | **\(r.pick(["yes", "no"]))** |\n" }
        case "list-100k-items":
            s.reserveCapacity(4_000_000)
            for i in 0..<100_000 { s += i % 10 == 0 ? "1. numbered \(i) \(w(3))\n" : (i % 10 < 3 ? "  - nested \(i) \(w(3))\n" : "- item \(i) \(w(4))\n") }
        case "headings-20k":
            for i in 0..<20_000 { s += String(repeating: "#", count: 1 + i % 6) + " Heading \(i) \(w(3))\n\n\(w(8))\n\n" }
        case "single-line-2MB":
            while s.utf8.count < 2_000_000 { let k = r.int(6); let x = r.pick(words); s += (k == 0 ? "**\(x)**" : k == 1 ? "*\(x)*" : k == 2 ? "`\(x)`" : k == 3 ? "[\(x)](https://e.x/\(x))" : x) + " " }
            s += "\n"
        case "fences-50k-x3lines":
            for i in 0..<50_000 { s += "```\nlet a\(i) = \(i)\nlet b = a\(i) + 1\n```\n\n" }
        case "paragraph-3MB-wrapped":
            var line = ""
            while s.utf8.count < 3_000_000 { for x in 0..<14 { _ = x; let t = r.pick(words); if line.count + t.count + 1 > 78 { s += line + "\n"; line = t } else { line += (line.isEmpty ? "" : " ") + t } } }
            s += line + "\n"
        case "emoji-dense-3MB":
            let e = ["😀", "🎉", "👩‍💻", "👨‍👩‍👧‍👦", "🇩🇪", "👍🏽", "𝔘𝔫𝔦", "𠮷", "❤️", "日本語"]
            while s.utf8.count < 3_000_000 { for _ in 0..<40 { s += r.pick(e) }; s += " " + r.pick(words) + "\n" }
        case "hash-comments-5MB":
            var i = 0
            while s.utf8.count < 5_000_000 { s += "# comment \(i): \(w(6))\n"; i += 1 }
        default: break
        }
        return s
    }

    // MARK: probes

    /// Open + first edit + 20 scroll steps + jump to end; returns the individual numbers (ms).
    @MainActor static func guardShapeProbe(_ t: SelfTest.T, _ url: URL) async throws -> (open: Double, edit: Double, scrollP95: Double, jumpEnd: Double, typeEnd: Double) {
        let r = try await perfOpenOnce(url)
        guard let host = r.doc.host as? EditorViewController else { throw NSError(domain: "perf", code: 1) }
        let tv = host.textView, sv = host.scrollView
        let t0 = SelfTest.nowMs()
        t.typeText("x", into: r.doc, at: NSRange(location: 0, length: 0))
        perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: 0))
        let edit = SelfTest.nowMs() - t0
        var steps: [Double] = []
        var y = sv.contentView.bounds.origin.y
        for _ in 0..<20 {
            y += 350
            let s0 = SelfTest.nowMs()
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host); perfDraw(host, sv.bounds)
            steps.append(SelfTest.nowMs() - s0)
        }
        let j0 = SelfTest.nowMs()
        tv.moveToEndOfDocument(nil); perfLayoutVisible(host)
        let jump = SelfTest.nowMs() - j0
        let loc = perfCaret(host)
        let e0 = SelfTest.nowMs()
        t.typeText("e", into: r.doc, at: NSRange(location: min(loc, ns(tv).length), length: 0))
        perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: loc))
        let typeEnd = SelfTest.nowMs() - e0
        t.close(r.doc)
        await t.spin(5)
        return (r.total, edit, PerfLab.stat(steps).p95, jump, typeEnd)
    }

    struct PerfCorpusNumbers {
        var open = 0.0, typeStartP50 = 0.0, typeStartP95 = 0.0, typeMidP50 = 0.0, typeEndP50 = 0.0, typeEndP95 = 0.0
        var scrollP95 = 0.0, thumbP50 = 0.0, jumpEndCold = 0.0, jumpMidCold = 0.0, findMiss = 0.0, copyAll = 0.0
        var pasteUndoRedo = 0.0, replaceAllUndo = 0.0, autosave = 0.0
    }

    /// The broad probe on one synthetic corpus file: opens it twice (first: cold jumps; second: everything else).
    @MainActor static func guardCorpusProbe(_ t: SelfTest.T, _ src: URL, tag: String) async throws -> PerfCorpusNumbers {
        var n = PerfCorpusNumbers()
        let copy = t.url("guard-\(tag).md")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        var opens: [Double] = []
        for _ in 0..<5 { let r = try await perfOpenOnce(copy); opens.append(r.total); t.close(r.doc); await t.spin(3) }
        n.open = PerfLab.stat(opens).p50

        // cold jumps on a fresh document
        do {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController else { throw NSError(domain: "perf", code: 2) }
            let tv = host.textView, len = ns(tv).length
            let a = SelfTest.nowMs(); tv.moveToEndOfDocument(nil); perfLayoutVisible(host); n.jumpEndCold = SelfTest.nowMs() - a
            let b = SelfTest.nowMs(); tv.setSelectedRange(NSRange(location: len / 2, length: 0)); tv.scrollRangeToVisible(NSRange(location: len / 2, length: 0)); perfLayoutVisible(host); n.jumpMidCold = SelfTest.nowMs() - b
            t.close(r.doc); await t.spin(3)
        }
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController else { throw NSError(domain: "perf", code: 3) }
        let doc = r.doc, tv = host.textView, sv = host.scrollView
        let len = ns(tv).length
        // scroll steps (350 pt, styling + layout + full redraw) and thumb jumps
        var steps: [Double] = []
        var y = 0.0
        for _ in 0..<60 {
            y += 350
            let s0 = SelfTest.nowMs()
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host); perfDraw(host, sv.bounds)
            steps.append(SelfTest.nowMs() - s0)
        }
        n.scrollP95 = PerfLab.stat(steps).p95
        var thumbs: [Double] = []
        for k in 1...15 {
            let top = max(0, (tv.frame.height - sv.contentView.bounds.height) * Double((k * 37) % 30) / 30)
            let s0 = SelfTest.nowMs()
            sv.contentView.scroll(to: NSPoint(x: 0, y: top)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host)
            thumbs.append(SelfTest.nowMs() - s0)
        }
        n.thumbP50 = PerfLab.stat(thumbs).p50
        // typing
        t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))            // first keystroke (captures the merge base) is not part of the stats
        for (pos, frac) in [("start", 0.0), ("mid", 0.5), ("end", 0.97)] {
            t.scrollToTop(host, character: Int(Double(len) * frac))
            let loc = perfCaret(host)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            var real: [Double] = []
            for i in 0..<50 { let k = perfKeystroke(t, host, doc, text: i % 11 == 10 ? "#" : "a", at: loc + i); if i >= 10 { real.append(k.real) } }
            let s = PerfLab.stat(real)
            switch pos {
            case "start": n.typeStartP50 = s.p50; n.typeStartP95 = s.p95
            case "mid": n.typeMidP50 = s.p50
            default: n.typeEndP50 = s.p50; n.typeEndP95 = s.p95
            }
        }
        // find (miss over the whole text), select all + copy to a private pasteboard
        let text = ns(tv)
        let f0 = SelfTest.nowMs(); _ = text.range(of: "zzqxqzzq", options: [.caseInsensitive], range: NSRange(location: 0, length: text.length)); n.findMiss = SelfTest.nowMs() - f0
        let pb = NSPasteboard(name: NSPasteboard.Name("local.luftig.perfguard.\(getpid())"))
        defer { pb.releaseGlobally() }
        let c0 = SelfTest.nowMs()
        tv.selectAll(nil); pb.clearContents(); let types = tv.writablePasteboardTypes; pb.declareTypes(types, owner: nil); _ = tv.writeSelection(to: pb, types: types)
        n.copyAll = SelfTest.nowMs() - c0
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        // paste ~1 MB (or a quarter of a small document) + undo + redo, then undo again
        let units = min(1_000_000, len / 4)
        let chunkStart = text.lineRange(for: NSRange(location: len / 5, length: 0)).location
        pb.clearContents(); pb.setString(text.substring(with: NSRange(location: chunkStart, length: units)), forType: .string)
        let at = text.lineRange(for: NSRange(location: len / 2, length: 0)).location
        t.scrollToTop(host, character: at)
        tv.setSelectedRange(NSRange(location: at, length: 0))
        let um = tv.undoManager
        let lenBefore = ns(tv).length
        let p0 = SelfTest.nowMs()
        um?.beginUndoGrouping(); _ = tv.readSelection(from: pb, type: .string); tv.breakUndoCoalescing(); um?.endUndoGrouping()
        perfLayoutVisible(host); host.styler.styleVisible()
        um?.undo(); perfLayoutVisible(host); host.styler.styleVisible()
        um?.redo(); perfLayoutVisible(host); host.styler.styleVisible()
        n.pasteUndoRedo = SelfTest.nowMs() - p0
        um?.undo()
        if ns(tv).length != lenBefore { t.check(false, "perf-guard \(tag): paste + undo + redo + undo restores the text (\(ns(tv).length) vs \(lenBefore))") }
        // replace-all of a frequent word with the multi-range protocol, then undo
        var matches: [NSRange] = []
        var p = 0
        while matches.count < 20_000 {
            let m = ns(tv).range(of: "the", options: [], range: NSRange(location: p, length: ns(tv).length - p))
            if m.location == NSNotFound { break }
            matches.append(m); p = NSMaxRange(m)
        }
        if matches.count > 10, let ts = tv.textStorage, let um = um {
            let values = matches.map { NSValue(range: $0) }, reps = [String](repeating: "THE", count: matches.count)
            um.beginUndoGrouping()
            if tv.shouldChangeText(inRanges: values, replacementStrings: reps) {
                ts.beginEditing(); for m in matches.reversed() { ts.replaceCharacters(in: m, with: "THE") }; ts.endEditing(); tv.didChangeText()
            }
            um.endUndoGrouping()
            perfLayoutVisible(host); host.styler.styleVisible()
            let u0 = SelfTest.nowMs(); um.undo(); perfLayoutVisible(host); host.styler.styleVisible(); n.replaceAllUndo = SelfTest.nowMs() - u0
        }
        // autosave (encode + write) of the edited document
        let meter = StallMeter(); meter.start()
        _ = await t.autosave(doc)
        n.autosave = meter.stop()
        t.close(doc); await t.spin(5)
        return n
    }

    // MARK: the scenario

    @MainActor static func perfGuard(_ t: SelfTest.T) async throws {
        let load = PerfLab.loadAverage(), limit = Double(SelfTest.argument("max-load") ?? "") ?? Double(PerfLab.cores) / 2
        // `--budget-scale X` multiplies every budget (X < 1 shows what a failure looks like; X > 1 for a slower machine). Default 1.
        let scale = Double(SelfTest.argument("budget-scale") ?? "") ?? 1
        guard PerfLab.isRelease else { t.note("perf-guard SKIPPED: this is a debug build, timings are meaningless (use Scripts/build-app.sh --selftest, which builds release)"); return }
        guard load <= limit else {
            t.note(String(format: "perf-guard SKIPPED: load average %.2f is above cores/2 (%.1f of %d cores). Timing assertions on a busy machine only measure the machine; run `--selftest perf-guard` again when it is quiet.", load, limit, PerfLab.cores))
            return
        }
        t.note(String(format: "perf-guard: load average %.2f (limit %.1f), %d cores; every budget is 3x the reference measurement (never above the DESIGN.md row)", load, limit, PerfLab.cores))
        // inputs
        let small = t.corpusFile(bytes: 1_000_000), big = t.corpusFile(bytes: 10_000_000)
        func probe(_ file: URL, _ tag: String) async throws -> PerfCorpusNumbers { try await guardCorpusProbe(t, file, tag: tag) }

        // A catastrophic regression (everything 10x slower) would otherwise make this scenario run for minutes before it fails: after 6 rows over budget
        // the remaining rows are skipped (they would only repeat the same message) and the scenario reports it.
        var failures = 0
        let maxFailures = 6
        let started = SelfTest.nowMs()
        // a healthy run takes ~20 s; far beyond that something is badly wrong (or the machine is not what it seems): stop and say so
        func overTime() -> Bool {
            if SelfTest.nowMs() - started > 150_000 && failures < maxFailures { failures = maxFailures; t.check(false, "perf-guard: still running after 150 s (a healthy run takes ~20 s) - stopped") }
            return failures >= maxFailures
        }
        func check(_ name: String, _ budgetRow: Double, _ measured: Double, again: () async throws -> Double) async throws {
            if overTime() { return }
            let budget = budgetRow * scale
            var m = measured
            if m > budget && m < 3 * budget {       // borderline: one more measurement (a scheduler hiccup is not a regression); 3x over is a regression, no second look
                let second = try await again()
                t.note(String(format: "perf-guard %@: first measurement %.2f ms over budget %.1f ms, measured once more: %.2f ms", name, m, budget, second))
                m = min(m, second)
            }
            out(String(format: "PERFGUARD %-46@ measured %9.2f ms   budget %8.1f ms   %@", name as NSString, m, budget, m <= budget ? "ok" : "OVER"))
            t.check(m <= budget, String(format: "%@: %.2f ms <= budget %.1f ms", name, m, budget))
            if m > budget { failures += 1; if failures == maxFailures { t.check(false, "perf-guard: \(maxFailures) rows are over budget - the remaining rows are skipped (fix the regression, then run `--selftest perf-guard` again for the full table)") } }
        }

        // ---- broad probes on the synthetic corpora (budget = 3x reference, <= DESIGN.md)
        for (label, file, b) in [("1 MB", small, Budgets.small), ("10 MB", big, Budgets.big)] {
            if overTime() { break }
            let n = try await probe(file, label)
            func again(_ kp: KeyPath<PerfCorpusNumbers, Double>) -> () async throws -> Double { { try await probe(file, label)[keyPath: kp] } }
            try await check("\(label) open (first screen styled + drawn)", b.open, n.open, again: again(\.open))
            try await check("\(label) keystroke at start, p50", b.typeP50, n.typeStartP50, again: again(\.typeStartP50))
            try await check("\(label) keystroke at start, p95", b.typeP95, n.typeStartP95, again: again(\.typeStartP95))
            try await check("\(label) keystroke in the middle, p50", b.typeMidP50, n.typeMidP50, again: again(\.typeMidP50))
            try await check("\(label) keystroke at the end, p50", b.typeEndP50, n.typeEndP50, again: again(\.typeEndP50))
            try await check("\(label) keystroke at the end, p95", b.typeEndP95, n.typeEndP95, again: again(\.typeEndP95))
            try await check("\(label) scroll step 350 pt (+layout +redraw), p95", b.scrollP95, n.scrollP95, again: again(\.scrollP95))
            try await check("\(label) scroller-thumb jump, p50", b.thumb, n.thumbP50, again: again(\.thumbP50))
            try await check("\(label) Cmd-Down on a fresh document", b.jumpEnd, n.jumpEndCold, again: again(\.jumpEndCold))
            try await check("\(label) jump to the middle on a fresh document", b.jumpMid, n.jumpMidCold, again: again(\.jumpMidCold))
            try await check("\(label) find miss over the whole text (NSString)", b.find, n.findMiss, again: again(\.findMiss))
            try await check("\(label) select all + copy to a pasteboard", b.copy, n.copyAll, again: again(\.copyAll))
            try await check("\(label) paste + undo + redo (with restyle)", b.paste, n.pasteUndoRedo, again: again(\.pasteUndoRedo))
            try await check("\(label) undo of a multi-range replace-all", b.replaceUndo, n.replaceAllUndo, again: again(\.replaceAllUndo))
            try await check("\(label) autosave (main-thread time)", b.autosave, n.autosave, again: again(\.autosave))
        }

        // ---- pathological shapes: open, first edit, scroll, jump to the end
        for (kind, b) in Budgets.shapes {
            if overTime() { break }
            let url = t.write(guardShape(kind), to: "shape-\(kind).md")
            let first = try await guardShapeProbe(t, url)
            func again(_ pick: @escaping ((open: Double, edit: Double, scrollP95: Double, jumpEnd: Double, typeEnd: Double)) -> Double) -> () async throws -> Double { { pick(try await guardShapeProbe(t, url)) } }
            try await check("shape \(kind): open", b.open, first.open, again: again { $0.open })
            try await check("shape \(kind): first edit (+layout +redraw)", b.edit, first.edit, again: again { $0.edit })
            try await check("shape \(kind): scroll step, p95", b.scroll, first.scrollP95, again: again { $0.scrollP95 })
            try await check("shape \(kind): Cmd-Down", b.jumpEnd, first.jumpEnd, again: again { $0.jumpEnd })
            try await check("shape \(kind): keystroke at the end", b.typeEnd, first.typeEnd, again: again { $0.typeEnd })
        }

        // ---- steady state (budgets in ms of CPU / MB of footprint, not latency)
        if overTime() { return }
        let ascii = t.corpusFile(bytes: 5_000_000, nonASCII: false)
        let tiny = t.write("# warm\n\ntext\n", to: "guard-tiny.md")
        let w0 = try await perfOpenOnce(tiny); t.close(w0.doc); await t.spin(100)
        // idle CPU of an open 5 MB document: after the NSDocument echo has settled nothing may run (no polling, no idle styling loop)
        func idleCPU() async throws -> Double {
            let r = try await perfOpenOnce(ascii)
            await t.spin(3500)
            let c0 = ProcessMetrics.cpuSeconds()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let ms = (ProcessMetrics.cpuSeconds() - c0) * 1000
            t.close(r.doc); await t.spin(50)
            return ms
        }
        do {
            let first = try await idleCPU()
            let m = first > 30 ? min(first, try await idleCPU()) : first
            out(String(format: "PERFGUARD %-46@ measured %9.2f ms   budget %8.1f ms   %@", "idle CPU of an open 5 MB document, 3 s" as NSString, m, 30.0, m <= 30 ? "ok" : "OVER"))
            t.check(m <= 30, String(format: "idle CPU of an open 5 MB document: %.2f ms in 3 s <= 30 ms (a document at rest must not poll or restyle)", m))
        }
        // no footprint creep when documents are opened, edited and closed (an ASCII text: the decode of a NON-ASCII text above ~2 MB is a known Foundation leak, see the perf review)
        do {
            var closed: [Int] = []
            let base = PerfLab.footprintBytes()
            for _ in 0..<6 {
                let r = try await perfOpenOnce(ascii)
                if let host = r.doc.host as? EditorViewController { for frac in [0.5, 0.9, 0.0] { t.scrollToTop(host, character: Int(5_000_000 * frac)) } }
                t.typeText("x", into: r.doc, at: NSRange(location: 0, length: 0))
                t.close(r.doc); await t.spin(300)
                closed.append(PerfLab.footprintBytes())
            }
            let growth = PerfLab.mb(closed[5] - closed[1])
            out(String(format: "PERFGUARD %-46@ measured %9.2f MB   budget %8.1f MB   %@", "footprint growth over 4 open/edit/close cycles" as NSString, growth, 8.0, growth <= 8 ? "ok" : "OVER"))
            t.check(growth <= 8, String(format: "5 MB ASCII document: footprint grew %.1f MB over 4 further open/edit/close cycles (<= 8 MB; a leaked text view / storage would be 5-20 MB per cycle); cycle 1..6 vs baseline: %@", growth, closed.map { String(format: "%+.1f", PerfLab.mb($0 - base)) }.joined(separator: " ")))
        }
    }
}

/// The budgets (ms). Each is 3x the WORST of seven runs on the reference machine (Apple M5 Pro, 18 cores, release build, load average ~4), rounded up,
/// with a floor of 4 ms (a 0.8 ms keystroke must not fail on one scheduler hiccup). Where DESIGN.md has a row the budget never exceeds it: open 1 MB < 100 ms,
/// open 10 MB < 400 ms, keystroke p50 < 8 ms (<= 16 ms in the 10 MB document); a p95 may be 50 % above the p50 row.
/// To re-baseline after a deliberate change run `--selftest perf-guard` a few times on a quiet machine and use the PERFGUARD lines (the measured column).
enum Budgets {
    struct Corpus { var open, typeP50, typeP95, typeMidP50, typeEndP50, typeEndP95, scrollP95, thumb, jumpEnd, jumpMid, find, copy, paste, replaceUndo, autosave: Double }
    //                                   worst measured:  17.2   3.65    4.01    1.59     2.85     5.49     6.95   11.8    9.1    18.5   3.6   2.1    45.6   87.6      21.2
    static var small = Corpus(open: 55, typeP50: 8, typeP95: 12, typeMidP50: 5, typeEndP50: 8, typeEndP95: 12, scrollP95: 25, thumb: 40, jumpEnd: 30, jumpMid: 60, find: 15, copy: 7, paste: 140, replaceUndo: 270, autosave: 65)
    //                                   worst measured:  36.2   3.86    5.52    2.43     2.04     2.46     6.65   33.7   16.7    71.5  34.3  11.7    91.4  298.4     84.1
    static var big = Corpus(open: 110, typeP50: 15, typeP95: 24, typeMidP50: 8, typeEndP50: 7, typeEndP95: 8, scrollP95: 20, thumb: 110, jumpEnd: 55, jumpMid: 220, find: 110, copy: 35, paste: 280, replaceUndo: 900, autosave: 260)

    /// open, first edit (+layout +redraw), scroll step p95, Cmd-Down, keystroke at the end. The 2 MB single line is a KNOWN slow shape (TextKit lays the whole
    /// paragraph out again after every edit, ~0.5 s): its budget only keeps it from getting worse.
    struct Shape { var open, edit, scroll, jumpEnd, typeEnd: Double }
    static var shapes: [(String, Shape)] = [
        ("table-5000-rows",       Shape(open: 55,   edit: 15,   scroll: 15, jumpEnd: 25, typeEnd: 9)),
        ("list-100k-items",       Shape(open: 50,   edit: 9,    scroll: 10, jumpEnd: 40, typeEnd: 4)),
        ("headings-20k",          Shape(open: 45,   edit: 7,    scroll: 10, jumpEnd: 25, typeEnd: 4)),
        ("single-line-2MB",       Shape(open: 1710, edit: 1500, scroll: 7,  jumpEnd: 40, typeEnd: 1510)),
        ("fences-50k-x3lines",    Shape(open: 60,   edit: 9,    scroll: 15, jumpEnd: 40, typeEnd: 4)),
        ("paragraph-3MB-wrapped", Shape(open: 45,   edit: 9,    scroll: 9,  jumpEnd: 20, typeEnd: 15)),
        ("emoji-dense-3MB",       Shape(open: 190,  edit: 55,   scroll: 20, jumpEnd: 30, typeEnd: 30)),
        ("hash-comments-5MB",     Shape(open: 50,   edit: 8,    scroll: 9,  jumpEnd: 30, typeEnd: 4)),
    ]
}
#endif
