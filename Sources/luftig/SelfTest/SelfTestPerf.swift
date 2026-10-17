#if LUFTIG_SELFTEST
// SelfTestPerf.swift - independent performance verification (the "perf" reviewer). Measurement scenarios (not part of `all`, they take
// a corpus with --input) and the shared helpers; the regression guard (part of `all`) is in SelfTestPerfGuard.swift.
//
//   luftig-SelfTest --selftest perf-ops    --input f.md [--name N] [--runs R]   open phases, first-screen styling, typing (insert / backspace at
//                                                                                start / middle / end), scroll steps, jumps, find, replace, select-all +
//                                                                                copy, big paste + undo, autosave, close; p50 / p95 / max, > 50 ms flagged
//   luftig-SelfTest --selftest perf-shape  --input f.md [--name N]              open + first edit + scroll + jump for ONE pathological file
//   luftig-SelfTest --selftest perf-memory --input f.md [--cycles C]            footprint before / after open / after close, C cycles
//   luftig-SelfTest --selftest perf-windows --input f.md [--count K]            K documents open at once: open time, footprint, typing, idle CPU
//   luftig-SelfTest --selftest perf-autosave --input f.md                       what an autosave of a big document costs (stall, CPU), idle CPU afterwards
//   luftig-SelfTest --selftest perf-reload --input f.md                         external rewrite of the open file: latency and main-thread stall
//   luftig-SelfTest --selftest perf-line   --kind prose|base64 [--lengths ...]  one very long line in an ordinary document
//   luftig-SelfTest --selftest perf-typeloop --input f.md [--seconds S] [--at first|middle|char:N] [--wait-for-sampler]   type for S seconds (for `sample`)
//   luftig-SelfTest --selftest perf-leak   --input f.md [--cycles C] [--edit] [--close doc|window|canclose] [--wait-before-close S]   are documents released?
//   luftig-SelfTest --selftest perf-fixing / perf-jump --input f.md              where the time of a far jump goes (AppKit's lazy attribute fixing)
//   luftig-SelfTest --selftest perf-idle   --input f.md [--window S]            idle CPU after open / typing / autosave / jump / select all / close
//   luftig-SelfTest --selftest perf-extent --input f.md [--png-prefix p]        how much text TextKit lays out; PNGs to compare variants byte for byte
//   luftig-SelfTest --selftest perf-decode-leak                                  TextCodec.decode of a 4 MB non-ASCII text 12x must not grow the footprint (FAILS on macOS 27.0.1 today)
//
// Limits of the review round (see the brief): documents <= ~20 MB, at most 3 big documents open at once, no special files, no network, no real pasteboard.
//
// Every operation is timed on the main thread with DispatchTime (ns resolution) and printed as `PERFOP <tag> <op> <ms>` (single
// samples and stalls) and summarised as p50 / p95 / max. A watchdog thread prints `WATCHDOG` lines while the main thread is stuck in
// one operation for more than 2 s (so a hang that is killed by the timeout still shows where it was). Documents are always CLONES of
// the input (an edited document may autosave); the clipboard is never touched (private named pasteboard).

import AppKit
import MarkdownKit
import Darwin

// MARK: - helpers

enum PerfLab {
    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    static func loadAverage() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    /// Physical footprint (what Activity Monitor calls "Memory"), bytes.
    static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    static var isRelease: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
    static func mb(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

    struct Stat { var n: Int; var min: Double; var p50: Double; var p95: Double; var max: Double }
    static func stat(_ a: [Double]) -> Stat {
        guard !a.isEmpty else { return Stat(n: 0, min: 0, p50: 0, p95: 0, max: 0) }
        let s = a.sorted()
        func q(_ p: Double) -> Double { s[Swift.min(s.count - 1, Int(Double(s.count) * p))] }
        return Stat(n: s.count, min: s[0], p50: q(0.5), p95: q(0.95), max: s[s.count - 1])
    }
    static func fmt(_ s: Stat) -> String { String(format: "n=%-4d min %8.2f  p50 %8.2f  p95 %8.2f  max %8.2f ms", s.n, s.min, s.p50, s.p95, s.max) }

    /// Bytes of a deterministic UTF-8 file for the guard / shape tests (same generator as the integrator's corpus).
    @MainActor static func clone(_ t: SelfTest.T, _ input: String, as name: String = "perf-input.md") throws -> URL {
        let dst = t.url(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: input), to: dst)
        return dst
    }
}

/// Prints a line while the main thread is stuck in ONE operation for more than 2 s (the hang may be killed by the timeout later).
final class PerfWatchdog: @unchecked Sendable {
    static let shared = PerfWatchdog()
    private let lock = NSLock()
    private var label: String?
    private var since = 0.0
    private var lastPrinted = 0.0
    private var started = false
    func enter(_ l: String) { lock.lock(); label = l; since = SelfTest.nowMs(); lastPrinted = 0; lock.unlock(); startIfNeeded() }
    func leave() { lock.lock(); label = nil; lock.unlock() }
    private func startIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        if started { return }
        started = true
        let th = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                lock.lock(); let l = label, d = SelfTest.nowMs() - since, lp = lastPrinted; lock.unlock()
                if let l, d > 2000, d - lp >= 2000 {
                    lock.lock(); lastPrinted = d; lock.unlock()
                    out(String(format: "WATCHDOG main thread still busy in '%@' after %.1f s", l, d / 1000))
                }
            }
        }
        th.qualityOfService = .utility
        th.start()
    }
}

/// Collects timings per operation; prints the singles and the stalls immediately, the summary at the end.
@MainActor final class PerfRecorder {
    let tag: String
    var stallThreshold = 50.0
    private(set) var order: [String] = []
    private(set) var data: [String: [Double]] = [:]
    init(tag: String) { self.tag = tag }

    func add(_ op: String, _ ms: Double, quiet: Bool = false) {
        if data[op] == nil { order.append(op) }
        data[op, default: []].append(ms)
        if !quiet || ms > stallThreshold { out(String(format: "PERFOP %@ %@ %.3f%@", tag, op, ms, ms > stallThreshold ? "   <== STALL > \(Int(stallThreshold)) ms" : "")) }
    }
    @discardableResult func measure(_ op: String, quiet: Bool = false, _ body: () -> Void) -> Double {
        PerfWatchdog.shared.enter("\(tag)/\(op)")
        let t0 = SelfTest.nowMs()
        body()
        let d = SelfTest.nowMs() - t0
        PerfWatchdog.shared.leave()
        add(op, d, quiet: quiet)
        return d
    }
    func stat(_ op: String) -> PerfLab.Stat { PerfLab.stat(data[op] ?? []) }
    func report(_ t: SelfTest.T, dropFirst: [String: Int] = [:]) {
        out("PERFSUMMARY \(tag)  load \(String(format: "%.2f", PerfLab.loadAverage())) / \(PerfLab.cores) cores")
        for op in order {
            var a = data[op] ?? []
            if let k = dropFirst[op] { a = Array(a.dropFirst(k)) }
            let s = PerfLab.stat(a)
            out("PERFSTAT \(tag) \(op.padding(toLength: 36, withPad: " ", startingAt: 0)) \(PerfLab.fmt(s))\(s.max > stallThreshold ? "   <== STALL > \(Int(stallThreshold)) ms" : "")")
        }
    }
}

extension SelfTestScenarios {
    static let perfScenarios: [SelfTest.Scenario] = [
        .init(name: "perf-guard", summary: "REGRESSION GUARD: generous (3x measured) budgets for open / typing / scroll / jump / find / copy / paste+undo on synthetic corpora and pathological shapes; skipped when the machine is loaded", run: { t in try await perfGuard(t) }),
        .init(name: "perf-ops", summary: "(measurement) every operation on one corpus: --input f.md [--name N] [--runs R]", run: { t in try await perfOps(t) }, inAll: false),
        .init(name: "perf-shape", summary: "(measurement) open + first edit + scroll + jump of ONE pathological file: --input f.md [--name N]", run: { t in try await perfShape(t) }, inAll: false),
        .init(name: "perf-memory", summary: "(measurement) footprint around open / close cycles: --input f.md [--cycles C]", run: { t in try await perfMemory(t) }, inAll: false),
        .init(name: "perf-windows", summary: "(measurement) K documents open at once: --input f.md [--count K]", run: { t in try await perfWindows(t) }, inAll: false),
        .init(name: "perf-autosave", summary: "(measurement) autosave of a big edited document: stall, CPU, idle afterwards: --input f.md", run: { t in try await perfAutosave(t) }, inAll: false),
        .init(name: "perf-line", summary: "(measurement) one very long line in an ordinary document: --kind prose|base64 [--lengths 10000,100000,...]", run: { t in try await perfLine(t) }, inAll: false),
        .init(name: "perf-typeloop", summary: "(measurement) type for --seconds S at --at first|middle|line:N (char offset) in --input f.md; with --wait-for-sampler prints the pid first (for `sample`)", run: { t in try await perfTypeLoop(t) }, inAll: false),
        .init(name: "perf-leak", summary: "(measurement) are a document, its window, text view and text storage released after close? --input f.md [--cycles C] [--edit] [--wait-for-sampler]", run: { t in try await perfLeak(t) }, inAll: false),
        .init(name: "perf-fixing", summary: "(measurement) AppKit's lazy attribute fixing: cost of far attribute lookups in a fresh big document: --input f.md", run: { t in try await perfFixing(t) }, inAll: false),
        .init(name: "perf-jump", summary: "(measurement) where the time of a far jump / scroller-thumb drag goes: --input f.md", run: { t in try await perfJump(t) }, inAll: false),
        .init(name: "perf-idle", summary: "(measurement) idle CPU (no meter running) after open / typing / select all / scrolling: --input f.md", run: { t in try await perfIdle(t) }, inAll: false),
        .init(name: "perf-decode-leak", summary: "REGRESSION TEST: decode a 4 MB non-ASCII UTF-8 file 12 times: the footprint must not grow (NSString(bytes:length:encoding:) leaks 2 bytes/char per decode on macOS 27.0.1; BulkDecode avoids it)", run: { t in try await perfDecodeLeak(t) }),
        .init(name: "perf-extent", summary: "(measurement) how much of the text TextKit really lays out (glyphs, line fragments, used height) after a full ensureLayout: --input f.md", run: { t in try await perfExtent(t) }, inAll: false),
        .init(name: "perf-reload", summary: "(measurement) external rewrite of the open file: latency + stall: --input f.md", run: { t in try await perfReload(t) }, inAll: false),
    ]

    // MARK: building blocks

    /// `openOnce` + what `T.attachWindow` does for the other scenarios: headless there are no events, so implicit (groupsByEvent) undo groups
    /// would never close and ONE undo would revert everything typed so far.
    @MainActor static func perfOpenOnce(_ url: URL, width: Double = 900, height: Double = 700) async throws -> (doc: MarkdownDocument, total: Double, read: Double, window: Double, layout: Double, draw: Double, stall: Double) {
        let r = try await openOnce(url, width: width, height: height)
        r.doc.undoManager?.groupsByEvent = false
        return r
    }

    /// Line start of roughly the middle of what is on screen: where "the user" types.
    @MainActor static func perfCaret(_ host: EditorViewController) -> Int {
        let tv = host.textView
        let vis = visibleRange(host)
        let loc = vis.location + min(vis.length / 2, 400)
        return ns(tv).lineRange(for: NSRange(location: min(loc, max(0, ns(tv).length - 1)), length: 0)).location
    }

    /// The edited line +- one line, full width (what AppKit repaints after a keystroke), converted to scroll view coordinates.
    @MainActor static func perfDirtyStrip(_ host: EditorViewController, at loc: Int) -> NSRect {
        let tv = host.textView
        var strip = tv.visibleRect
        if let lm = tv.layoutManager, lm.numberOfGlyphs > 0 {
            let g = lm.glyphIndexForCharacter(at: min(loc, max(0, ns(tv).length - 1)))
            let r = lm.lineFragmentRect(forGlyphAt: min(g, lm.numberOfGlyphs - 1), effectiveRange: nil).offsetBy(dx: 0, dy: tv.textContainerOrigin.y)
            strip = NSRect(x: 0, y: r.minY - r.height, width: tv.bounds.width, height: r.height * 3).intersection(tv.visibleRect)
        }
        return host.scrollView.convert(strip, from: tv)
    }
    @MainActor static func perfDraw(_ host: EditorViewController, _ rect: NSRect) {
        if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: rect) { host.scrollView.cacheDisplay(in: rect, to: rep) }
    }
    @MainActor static func perfLayoutVisible(_ host: EditorViewController) {
        let tv = host.textView
        _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
    }

    /// One real keystroke: insertText (+ restyle) + layout + redraw of the dirty strip. Returns (insert only, real) in ms.
    @MainActor static func perfKeystroke(_ t: SelfTest.T, _ host: EditorViewController, _ doc: MarkdownDocument, text: String, at loc: Int, backspace: Bool = false) -> (insert: Double, real: Double) {
        let t0 = SelfTest.nowMs()
        if backspace {
            let tv = host.textView
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            let um = tv.undoManager
            um?.beginUndoGrouping(); tv.deleteBackward(nil); tv.breakUndoCoalescing(); um?.endUndoGrouping()
        } else {
            t.typeText(text, into: doc, at: NSRange(location: loc, length: 0))
        }
        let t1 = SelfTest.nowMs()
        perfLayoutVisible(host)
        perfDraw(host, perfDirtyStrip(host, at: loc))
        return (t1 - t0, SelfTest.nowMs() - t0)
    }

    /// 70 inserts then 40 backspaces at `fraction` of the document. Records `type.<pos>.insert`, `.insert-only`, `.backspace`, and `jump.to-<pos>`.
    @MainActor static func perfTyping(_ t: SelfTest.T, _ rec: PerfRecorder, doc: MarkdownDocument, host: EditorViewController, position: String, fraction: Double, inserts: Int = 70, backspaces: Int = 40) {
        let tv = host.textView
        rec.measure("jump.to-\(position)") { t.scrollToTop(host, character: Int(Double(ns(tv).length) * fraction)) }
        let loc = perfCaret(host)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        for i in 0..<inserts {
            let r = perfKeystroke(t, host, doc, text: i % 11 == 10 ? "#" : "a", at: loc + i)
            if i >= 10 { rec.add("type.\(position).insert", r.real, quiet: true); rec.add("type.\(position).insert-only", r.insert, quiet: true) }
        }
        for j in 0..<backspaces {
            let r = perfKeystroke(t, host, doc, text: "", at: loc + inserts - j, backspace: true)
            if j >= 5 { rec.add("type.\(position).backspace", r.real, quiet: true) }
        }
    }

    // MARK: perf-ops

    @MainActor static func perfOps(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-ops --input f.md [--name N] [--runs R]"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 0
        let runs = Int(SelfTest.argument("runs") ?? "") ?? (size >= 5_000_000 ? 5 : 7)
        let rec = PerfRecorder(tag: name)
        let copy = try PerfLab.clone(t, input)
        out("PERFENV \(name): \(size) bytes, load \(String(format: "%.2f", PerfLab.loadAverage())) / \(PerfLab.cores) cores, release build: \(PerfLab.isRelease)")
        _ = try? Data(contentsOf: copy)                                   // file cache warm, like a recently used file

        // ---- 0. AppKit warm-up with a tiny document (the numbers below are "warm process" numbers; the cold ones are measured black-box)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)

        // ---- 1. open (fresh document each time), first-screen styling, close
        var keep: MarkdownDocument?
        for i in 0..<runs {
            PerfWatchdog.shared.enter("\(name)/open")
            let r = try await perfOpenOnce(copy)
            PerfWatchdog.shared.leave()
            rec.add("open.total (read+window+style+layout+draw)", r.total, quiet: true)
            rec.add("open.read+decode", r.read, quiet: true); rec.add("open.window+text view+load", r.window, quiet: true)
            rec.add("open.layout+style first screen", r.layout, quiet: true); rec.add("open.draw first screen", r.draw, quiet: true)
            if let host = r.doc.host as? EditorViewController {
                host.styler.reset()
                rec.measure("style.first-screen (lexer reset, cold lex)", quiet: true) { host.styler.styleVisible() }
            }
            if i == runs - 1 { keep = r.doc } else {
                rec.measure("close", quiet: true) { t.close(r.doc) }
                await t.spin(5)
            }
        }
        guard let doc0 = keep, let host0 = doc0.host as? EditorViewController else { t.check(false, "no document"); return }
        let len = ns(host0.textView).length
        t.note("\(name): \(len) UTF-16 units, \(host0.styler.styled.count) styled after open")
        t.close(doc0); await t.spin(10)

        // ---- 2. jumps on FRESH documents (cold lexer, cold layout): end first (Cmd-Down at open), then middle first
        for (first, label) in [("end", "A"), ("middle", "B")] {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController else { continue }
            let tv = host.textView
            func jump(_ kind: String, cold: Bool) {
                let op = "jump.\(kind).\(cold ? "cold" : "warm")"
                rec.measure(op) {
                    switch kind {
                    case "end": tv.moveToEndOfDocument(nil)
                    case "start": tv.moveToBeginningOfDocument(nil)
                    default: tv.setSelectedRange(NSRange(location: len / 2, length: 0)); tv.scrollRangeToVisible(NSRange(location: len / 2, length: 0))
                    }
                    perfLayoutVisible(host)
                }
                rec.measure(op + " +full redraw", quiet: true) { perfDraw(host, host.scrollView.bounds) }
            }
            if first == "end" { jump("end", cold: true); jump("middle", cold: true) } else { jump("middle", cold: true); jump("end", cold: true) }
            jump("start", cold: false)
            for _ in 0..<3 { jump("middle", cold: false); jump("end", cold: false); jump("start", cold: false) }
            t.close(r.doc); await t.spin(10)
            _ = label
        }

        // ---- 3. everything else on one document
        let (doc, host) = try await { () async throws -> (MarkdownDocument, EditorViewController) in
            let r = try await perfOpenOnce(copy); return (r.doc, r.doc.host as! EditorViewController) }()
        let tv = host.textView
        let sv = host.scrollView

        // scroll steps from the top: 100 steps of 350 pt (half a page)
        t.scrollToTop(host, character: 0)
        var y = sv.contentView.bounds.origin.y
        for i in 0..<100 {
            y += 350
            let t0 = SelfTest.nowMs()
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)      // boundsDidChange -> styleVisible
            let t1 = SelfTest.nowMs()
            perfLayoutVisible(host)
            let t2 = SelfTest.nowMs()
            perfDraw(host, sv.bounds)
            let t3 = SelfTest.nowMs()
            rec.add("scroll.step (scroll + lazy styling)", t1 - t0, quiet: true)
            rec.add("scroll.step +layout", t2 - t0, quiet: true)
            rec.add("scroll.step +full redraw (upper bound)", t3 - t0, quiet: true)
            if i == 0 { _ = 0 }
        }
        // a drag of the scroller thumb: 30 big jumps through the document
        for k in 1...30 {
            let frac = Double((k * 37) % 30) / 30
            let top = max(0, (tv.frame.height - sv.contentView.bounds.height) * frac)
            rec.measure("scroll.thumb-jump (scroll + styling + layout)", quiet: true) {
                sv.contentView.scroll(to: NSPoint(x: 0, y: top)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host)
            }
        }

        // typing at start / middle / end
        rec.measure("first keystroke after open (captures the merge base)") {
            t.scrollToTop(host, character: 0)
            t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))
        }
        perfTyping(t, rec, doc: doc, host: host, position: "start", fraction: 0.0)
        perfTyping(t, rec, doc: doc, host: host, position: "middle", fraction: 0.5)
        perfTyping(t, rec, doc: doc, host: host, position: "end", fraction: 0.97)

        // typing a fence at the very top: everything below becomes code (bounded re-lex + stale tail), then removing it again
        t.scrollToTop(host, character: 0)
        let st0 = host.styler.staleEvents
        rec.measure("fence typed at the top (```\\n)") { t.typeText("```\n", into: doc, at: NSRange(location: 0, length: 0)) }
        rec.measure("... + layout + visible restyle") { perfLayoutVisible(host); host.styler.styleVisible(); perfLayoutVisible(host); perfDraw(host, sv.bounds) }
        rec.measure("fence removed again (backspace x4)") { for k in 0..<4 { _ = perfKeystroke(t, host, doc, text: "", at: 4 - k, backspace: true) } }
        rec.measure("... + layout + visible restyle ") { perfLayoutVisible(host); host.styler.styleVisible(); perfLayoutVisible(host); perfDraw(host, sv.bounds) }
        t.note("fence at the top: stale events \(host.styler.staleEvents - st0)")

        // find (proxy for NSTextFinder: NSString search + select + scroll + styling + layout; the find pasteboard is never written)
        let ns0 = ns(tv)
        func landing(_ r: NSRange) {
            tv.setSelectedRange(r); tv.scrollRangeToVisible(r); perfLayoutVisible(host); host.styler.styleVisible()
        }
        var tail = ns0.length > 400 ? ns0.substring(with: NSRange(location: ns0.length - 300, length: 200)) : ""
        tail = String(tail.drop(while: { $0 != "\n" }).dropFirst().prefix(60))
        if tail.count < 20 { tail = ns0.length > 100 ? ns0.substring(with: NSRange(location: ns0.length / 2, length: 24)) : "x" }
        var hit = NSRange(location: NSNotFound, length: 0)
        rec.measure("find.hit-far  literal scan from 0") { hit = ns0.range(of: tail, options: [], range: NSRange(location: 0, length: ns0.length)) }
        if hit.location != NSNotFound { t.note("find needle first occurs at \(Int(Double(hit.location) / Double(max(1, ns0.length)) * 100)) % of the text") }
        rec.measure("find.hit-far  case-insensitive scan from 0") { _ = ns0.range(of: tail, options: [.caseInsensitive], range: NSRange(location: 0, length: ns0.length)) }
        if hit.location != NSNotFound { rec.measure("find.landing (select + scroll + style + layout)") { landing(hit) } }
        rec.measure("find.miss literal (whole text)") { _ = ns0.range(of: "zzqxqzzq", options: [], range: NSRange(location: 0, length: ns0.length)) }
        rec.measure("find.miss case-insensitive (whole text)") { _ = ns0.range(of: "zzqxqzzq", options: [.caseInsensitive], range: NSRange(location: 0, length: ns0.length)) }
        t.scrollToTop(host, character: 0)
        var pos = 0
        for _ in 0..<40 {
            var r = NSRange(location: NSNotFound, length: 0)
            rec.measure("find.next (common word 'the', scan)", quiet: true) { r = ns0.range(of: "the", options: [.caseInsensitive], range: NSRange(location: pos, length: ns0.length - pos)) }
            guard r.location != NSNotFound else { break }
            rec.measure("find.next landing", quiet: true) { landing(r) }
            pos = NSMaxRange(r)
        }

        // replace: one word (typed path), then "replace all" of a frequent word: batched (one beginEditing) and one by one
        t.scrollToTop(host, character: len / 2)
        for _ in 0..<20 {
            let loc = perfCaret(host)
            let line = ns(tv).lineRange(for: NSRange(location: loc, length: 0))
            let w = ns(tv).rangeOfCharacter(from: .letters, options: [], range: line)
            guard w.location != NSNotFound else { break }
            var wordEnd = NSMaxRange(w)
            while wordEnd < NSMaxRange(line), let u = Optional(ns(tv).character(at: wordEnd)), CharacterSet.letters.contains(UnicodeScalar(u) ?? " ") { wordEnd += 1 }
            let r = NSRange(location: w.location, length: wordEnd - w.location)
            let t0 = SelfTest.nowMs()
            t.typeText("replacement", into: doc, at: r)
            perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: r.location))
            rec.add("replace.word (insertText over a word, +layout +strip)", SelfTest.nowMs() - t0, quiet: true)
        }
        do {
            let text = ns(tv)
            var matches: [NSRange] = []
            rec.measure("replace.all  collect matches ('the', max 20000)") {
                var p = 0
                while matches.count < 20_000 {
                    let r = text.range(of: "the", options: [], range: NSRange(location: p, length: text.length - p))
                    if r.location == NSNotFound { break }
                    matches.append(r); p = NSMaxRange(r)
                }
            }
            t.note("replace-all candidates: \(matches.count) matches")
            if matches.count > 10, let ts = tv.textStorage, let um = tv.undoManager {
                let lengthBefore = ts.length
                t.note("undo manager before replace-all: levels \(um.levelsOfUndo) (0 = unlimited), grouping level \(um.groupingLevel), canUndo \(um.canUndo), isUndoRegistrationEnabled \(um.isUndoRegistrationEnabled)")
                // (a) the multi-range protocol (what NSTextFinder's replace all uses on an NSTextView): ONE shouldChangeText for all ranges,
                //     one begin/endEditing, one didChangeText -> one undo entry
                let values = matches.map { NSValue(range: $0) }
                let reps = [String](repeating: "THE", count: matches.count)
                rec.measure("replace.all  apply, multi-range protocol, batched") {
                    um.beginUndoGrouping()
                    if tv.shouldChangeText(inRanges: values, replacementStrings: reps) {
                        ts.beginEditing()
                        for r in matches.reversed() { ts.replaceCharacters(in: r, with: "THE") }
                        ts.endEditing()
                        tv.didChangeText()
                    }
                    um.endUndoGrouping()
                }
                rec.measure("replace.all  ... + layout + restyle + redraw") { perfLayoutVisible(host); host.styler.styleVisible(); perfDraw(host, sv.bounds) }
                t.note("replace-all: text length \(lengthBefore) -> \(ts.length) (can undo: \(um.canUndo))")
                t.note("undo manager after the batched replace-all: action '\(um.undoActionName)', grouping level \(um.groupingLevel)")
                rec.measure("replace.all  undo (multi-range)") { um.undo() }
                t.note("after that undo: length \(ts.length)")
                rec.measure("replace.all  ... + layout + restyle + redraw ") { perfLayoutVisible(host); host.styler.styleVisible(); perfDraw(host, sv.bounds) }
                t.check(ts.length == lengthBefore, "\(name): undo of the batched replace-all restores the text length (\(ts.length) vs \(lengthBefore))")
                rec.measure("replace.all  redo (multi-range)") { um.redo() }
                rec.measure("replace.all  undo again") { um.undo() }
                // (b) one by one: every replacement is its own edit cycle (shouldChangeText, replace, didChangeText) in ONE undo group
                let few = Array(matches.prefix(2000))
                let tOne = SelfTest.nowMs()
                PerfWatchdog.shared.enter("\(name)/replace.all one-by-one")
                um.beginUndoGrouping()
                for r in few.reversed() {
                    if tv.shouldChangeText(in: r, replacementString: "THE") { ts.replaceCharacters(in: r, with: "THE"); tv.didChangeText() }
                }
                um.endUndoGrouping()
                PerfWatchdog.shared.leave()
                let oneMs = SelfTest.nowMs() - tOne
                rec.add("replace.all  one-by-one, \(few.count) matches (total)", oneMs)
                rec.add("replace.all  one-by-one per match", oneMs / Double(max(1, few.count)), quiet: true)
                rec.measure("replace.all  one-by-one undo (\(few.count) steps)") { um.undo() }
                t.check(ts.length == lengthBefore, "\(name): undo of the one-by-one replace-all restores the text length (\(ts.length) vs \(lengthBefore))")
            }
        }

        // select all + copy (private pasteboard) and a big paste + undo/redo
        let pb = NSPasteboard(name: NSPasteboard.Name("local.luftig.perf.\(getpid())"))
        defer { pb.releaseGlobally() }
        t.scrollToTop(host, character: len / 2)
        rec.measure("selectAll") { tv.selectAll(nil) }
        rec.measure("selectAll  + layout + full redraw") { perfLayoutVisible(host); perfDraw(host, sv.bounds) }
        pb.clearContents()
        var wrote = false
        rec.measure("copy  writeSelection (whole text) to a private pasteboard") {
            let types = tv.writablePasteboardTypes
            pb.declareTypes(types, owner: nil)
            wrote = tv.writeSelection(to: pb, types: types)
        }
        let copied = pb.string(forType: .string)
        t.check(wrote && copied?.utf16.count == ns(tv).length, "\(name): select-all + copy put the whole text (\(ns(tv).length) units) on the pasteboard (got \(copied?.utf16.count ?? -1))")
        pb.clearContents()
        tv.setSelectedRange(NSRange(location: 0, length: 0))

        for (label, units) in [("250 KB", 250_000), ("1 MB", 1_000_000), ("5 MB", 5_000_000)] where ns(tv).length > units * 2 && ns(tv).length + units <= 21_000_000 && (units != 250_000 || ns(tv).length < 3_000_000) {   // never beyond ~20 MB of text
            let chunkStart = ns(tv).lineRange(for: NSRange(location: ns(tv).length / 5, length: 0)).location
            let chunk = ns(tv).substring(with: NSRange(location: chunkStart, length: units))
            pb.clearContents(); pb.setString(chunk, forType: .string)
            let where_ = ns(tv).lineRange(for: NSRange(location: ns(tv).length / 2, length: 0)).location
            t.scrollToTop(host, character: where_)
            tv.setSelectedRange(NSRange(location: where_, length: 0))
            let lenBefore = ns(tv).length
            let um = tv.undoManager
            rec.measure("paste.\(label)  readSelection(from:)") {
                um?.beginUndoGrouping(); _ = tv.readSelection(from: pb, type: .string); tv.breakUndoCoalescing(); um?.endUndoGrouping()
            }
            let grew = ns(tv).length - lenBefore
            if grew != units { rec.measure("paste.\(label)  (readSelection did nothing: insertText fallback)") { t.typeText(chunk, into: doc, at: NSRange(location: where_, length: 0)) } }
            rec.measure("paste.\(label)  ... + layout + styling + full redraw") { perfLayoutVisible(host); host.styler.styleVisible(); perfDraw(host, sv.bounds) }
            // is the visible text styled WITHOUT anything calling styleVisible() (what the user sees right after pasting)?
            await t.spin(20)
            let vis = visibleRange(host)
            t.note("after pasting \(label) (+ a run loop turn): visible range \(NSStringFromRange(vis)) styled: \(host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)))")
            rec.measure("paste.\(label)  undo") { um?.undo() }
            rec.measure("paste.\(label)  undo ... + layout + styling + full redraw") { perfLayoutVisible(host); host.styler.styleVisible(); perfDraw(host, sv.bounds) }
            await t.spin(20)
            let vis2 = visibleRange(host)
            t.note("after undoing the paste (+ a run loop turn): visible range styled without a manual styleVisible(): \(host.styler.styled.contains(integersIn: vis2.location..<NSMaxRange(vis2)))")
            rec.measure("paste.\(label)  redo") { um?.redo() }
            rec.measure("paste.\(label)  redo ... + layout + styling + full redraw") { perfLayoutVisible(host); host.styler.styleVisible(); perfDraw(host, sv.bounds) }
            rec.measure("paste.\(label)  undo again") { um?.undo() }
            t.check(ns(tv).length == lenBefore, "\(name): paste \(label) then undo restores the text length (\(ns(tv).length) vs \(lenBefore))")
        }
        pb.clearContents()

        // autosave of the edited big document (the synchronous cost: encode + write), then close
        let meter = StallMeter(); meter.start()
        PerfWatchdog.shared.enter("\(name)/autosave")
        let tA = SelfTest.nowMs()
        let err = await t.autosave(doc)
        let autosaveMs = SelfTest.nowMs() - tA
        PerfWatchdog.shared.leave()
        let gap = meter.stop()
        rec.add("autosave (encode + write + completion)", autosaveMs)
        rec.add("autosave longest main-thread gap", gap)
        t.check(err == nil, "\(name): autosave of the edited document succeeded: \(err.map { "\($0)" } ?? "ok")")
        rec.measure("close (edited, saved)") { t.close(doc) }
        await t.spin(30)

        rec.report(t, dropFirst: [:])
        t.check(true, "\(name): perf-ops finished")
    }

    // MARK: perf-shape

    @MainActor static func perfShape(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-shape --input f.md [--name N]"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 0
        let rec = PerfRecorder(tag: name)
        let copy = try PerfLab.clone(t, input)
        out("PERFENV \(name): \(size) bytes, load \(String(format: "%.2f", PerfLab.loadAverage())) / \(PerfLab.cores) cores")
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)

        PerfWatchdog.shared.enter("\(name)/open")
        let r = try await perfOpenOnce(copy)
        PerfWatchdog.shared.leave()
        rec.add("open.total", r.total); rec.add("open.read+decode", r.read, quiet: true); rec.add("open.window+load", r.window, quiet: true)
        rec.add("open.layout+style", r.layout, quiet: true); rec.add("open.draw", r.draw, quiet: true)
        guard let host = r.doc.host as? EditorViewController else { t.check(false, "no host"); return }
        let doc = r.doc, tv = host.textView, sv = host.scrollView
        let len = ns(tv).length
        t.note("\(name): \(len) units; styled after open \(host.styler.styled.count)")

        rec.measure("first edit: type 'x' at the start") { t.typeText("x", into: doc, at: NSRange(location: 0, length: 0)) }
        rec.measure("... + layout + dirty-strip redraw") { perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: 0)) }
        let loc = perfCaret(host)
        rec.measure("second edit: type 'y' in the first screen") { t.typeText("y", into: doc, at: NSRange(location: loc, length: 0)) }
        rec.measure("... + layout + dirty-strip redraw ") { perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: loc)) }
        for i in 0..<20 {
            let k0 = SelfTest.nowMs()
            t.typeText("z", into: doc, at: NSRange(location: loc + 1 + i, length: 0))
            let k1 = SelfTest.nowMs()
            perfLayoutVisible(host)
            let k2 = SelfTest.nowMs()
            perfDraw(host, perfDirtyStrip(host, at: loc + 1 + i))
            let k3 = SelfTest.nowMs()
            rec.add("keystroke x20 (real)", k3 - k0, quiet: true)
            rec.add("keystroke x20: insertText + restyle", k1 - k0, quiet: true)
            rec.add("keystroke x20: layout of the visible part", k2 - k1, quiet: true)
            rec.add("keystroke x20: dirty-strip redraw", k3 - k2, quiet: true)
        }
        // scroll
        t.scrollToTop(host, character: 0)
        var y = sv.contentView.bounds.origin.y
        for _ in 0..<30 {
            y += 350
            let t0 = SelfTest.nowMs()
            PerfWatchdog.shared.enter("\(name)/scroll")
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host); perfDraw(host, sv.bounds)
            PerfWatchdog.shared.leave()
            rec.add("scroll.step 350pt (+styling +layout +full redraw)", SelfTest.nowMs() - t0, quiet: true)
        }
        rec.measure("jump to end (Cmd-Down) + layout") { tv.moveToEndOfDocument(nil); perfLayoutVisible(host) }
        rec.measure("... full redraw") { perfDraw(host, sv.bounds) }
        let endLoc = perfCaret(host)
        rec.measure("type at the end") { t.typeText("e", into: doc, at: NSRange(location: min(endLoc, ns(tv).length), length: 0)); perfLayoutVisible(host); perfDraw(host, perfDirtyStrip(host, at: endLoc)) }
        rec.measure("jump to start (Cmd-Up) + layout") { tv.moveToBeginningOfDocument(nil); perfLayoutVisible(host) }
        rec.measure("jump to middle + layout") { tv.setSelectedRange(NSRange(location: ns(tv).length / 2, length: 0)); tv.scrollRangeToVisible(NSRange(location: ns(tv).length / 2, length: 0)); perfLayoutVisible(host) }
        rec.measure("select all + redraw") { tv.selectAll(nil); perfLayoutVisible(host); perfDraw(host, sv.bounds) }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        // post-op idle: anything running in the background? (CPU first with ONE wake-up, the stall meter's 1 ms timer would measure itself)
        let cpu0 = ProcessMetrics.cpuSeconds()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        rec.add("idle 1 s afterwards: CPU ms", (ProcessMetrics.cpuSeconds() - cpu0) * 1000)
        let meter = StallMeter(); meter.start()
        try? await Task.sleep(nanoseconds: 500_000_000)
        rec.add("idle 0.5 s afterwards: longest main-thread gap", meter.stop())
        rec.measure("close") { t.close(doc) }
        rec.report(t)
        t.check(true, "\(name): perf-shape finished")
    }

    // MARK: perf-memory

    @MainActor static func perfMemory(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-memory --input f.md [--cycles C]"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 1
        let cycles = Int(SelfTest.argument("cycles") ?? "") ?? 3
        let copy = try PerfLab.clone(t, input)
        // warm-up with a tiny document so that "baseline" already contains AppKit's one-time allocations
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(100)
        let base = PerfLab.footprintBytes()
        out(String(format: "MEM %@ baseline (after a tiny doc was opened and closed): %.1f MB", name, PerfLab.mb(base)))
        var afterClose: [Int] = []
        for c in 0..<cycles {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController else { continue }
            let open = PerfLab.footprintBytes()
            // visit five places like the integrator does
            for frac in [0.5, 0.25, 0.75, 0.9, 0.0] { t.scrollToTop(host, character: Int(Double(size) * frac)) }
            let scrolled = PerfLab.footprintBytes()
            // edit once (captures the 3-way-merge base: a copy of the whole text)
            t.typeText("x", into: r.doc, at: NSRange(location: 0, length: 0))
            let edited = PerfLab.footprintBytes()
            await perfCloseLikeUser(t, r.doc)
            await t.spin(200)
            let closed = PerfLab.footprintBytes()
            afterClose.append(closed)
            out(String(format: "MEM %@ cycle %d: after open %+.1f MB, after visiting 5 places %+.1f MB, after one edit %+.1f MB, after close + 200 ms %+.1f MB (all relative to the baseline; %.1f MB of text -> %.1f MB per MB of text while open)",
                       name, c + 1, PerfLab.mb(open - base), PerfLab.mb(scrolled - base), PerfLab.mb(edited - base), PerfLab.mb(closed - base), Double(size) / 1e6, PerfLab.mb(edited - base) / (Double(size) / 1e6)))
        }
        // does it keep growing? (leak) - compare the last cycle with the first
        if let a = afterClose.first, let b = afterClose.last, afterClose.count > 1 {
            out(String(format: "MEM %@ residual after close: cycle 1 %+.1f MB, last cycle %+.1f MB (growth %+.1f MB over %d cycles)", name, PerfLab.mb(a - base), PerfLab.mb(b - base), PerfLab.mb(b - a), afterClose.count - 1))
        }
        if let hold = Double(SelfTest.argument("hold") ?? "") {       // keep the process alive for `vmmap` / `leaks` / `heap` (pid printed)
            out("MEM pid \(getpid()) holding for \(hold) s")
            await t.spin(hold * 1000)
        }
        t.check(true, "\(name): perf-memory finished")
    }

    // MARK: perf-windows

    @MainActor static func perfWindows(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-windows --input f.md [--count K]"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        // Safety limit of the review round: at most 3 big documents (>= 2 MB) open at once.
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 0
        let count = min(Int(SelfTest.argument("count") ?? "") ?? 3, size >= 2_000_000 ? 3 : 10)
        let rec = PerfRecorder(tag: "\(name)x\(count)")
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(100)
        let base = PerfLab.footprintBytes()
        var docs: [(MarkdownDocument, EditorViewController)] = []
        for i in 0..<count {
            let copy = try PerfLab.clone(t, input, as: "win-\(i).md")
            let r = try await perfOpenOnce(copy)
            rec.add("open #\(i + 1) (total)", r.total)
            if let h = r.doc.host as? EditorViewController { docs.append((r.doc, h)) }
        }
        let open = PerfLab.footprintBytes()
        out(String(format: "MEM %d documents of %@ open: footprint %+.1f MB over the baseline (%.1f MB per document)", docs.count, name, PerfLab.mb(open - base), PerfLab.mb(open - base) / Double(max(1, docs.count))))
        // typing in the first, a middle and the last window
        for idx in [0, docs.count / 2, docs.count - 1] where idx < docs.count {
            let (doc, host) = docs[idx]
            perfTyping(t, rec, doc: doc, host: host, position: "win\(idx + 1)", fraction: 0.5, inserts: 40, backspaces: 0)
        }
        // idle with all of them open (every document has a kqueue monitor + file presenter)
        await t.sleep(1500)
        let checks0 = docs.reduce(0) { $0 + $1.0.stats.checks }
        let cpu0 = ProcessMetrics.cpuSeconds(); let t0 = SelfTest.nowMs()
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let wall = (SelfTest.nowMs() - t0) / 1000, cpu = ProcessMetrics.cpuSeconds() - cpu0
        let checks = docs.reduce(0) { $0 + $1.0.stats.checks } - checks0
        out(String(format: "IDLE %d windows: %.1f ms CPU in %.2f s (%.3f %% of a core), file-monitor checks %d", docs.count, cpu * 1000, wall, cpu / wall * 100, checks))
        // close them all
        let tc = SelfTest.nowMs()
        for (d, _) in docs { t.close(d) }
        await t.spin(300)
        out(String(format: "CLOSE %d documents: %.1f ms, footprint afterwards %+.1f MB over the baseline", docs.count, SelfTest.nowMs() - tc, PerfLab.mb(PerfLab.footprintBytes() - base)))
        rec.report(t)
        t.check(true, "\(name): perf-windows finished")
    }

    // MARK: perf-autosave

    @MainActor static func perfAutosave(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-autosave --input f.md"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let copy = try PerfLab.clone(t, input)
        let rec = PerfRecorder(tag: name)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(100)
        let r = try await perfOpenOnce(copy)
        guard r.doc.host is EditorViewController else { return }
        let doc = r.doc
        await t.sleep(2000)                                   // the xattr echo of the open settles
        NSDocumentController.shared.autosavingDelay = 3       // what AppDelegate sets in the real app
        let mtime0 = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date) ?? Date.distantPast
        t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))
        let tEdit = SelfTest.nowMs()
        out("AUTOSAVE \(name): edited at t=0; document edited flag \(doc.isDocumentEdited); waiting for the real autosave timer (3 s) + the file monitor echo")
        let meter = StallMeter(); meter.start()
        let cpu0 = ProcessMetrics.cpuSeconds()
        var savedAt: Double?
        var lastGap = 0.0
        while SelfTest.nowMs() - tEdit < 9000 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if savedAt == nil, !doc.isDocumentEdited { savedAt = SelfTest.nowMs() - tEdit }
        }
        lastGap = meter.stop()
        let cpu = ProcessMetrics.cpuSeconds() - cpu0
        let mtime1 = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date) ?? Date.distantPast
        out(String(format: "AUTOSAVE %@: file %@, edited flag cleared after %@ ms; longest main-thread gap during the 9 s: %.1f ms; CPU used in the 9 s (autosave + echo): %.1f ms; monitor checks %d (hash-unchanged %d, reloads %d)",
                   name, mtime1 > mtime0 ? "was rewritten" : "was NOT rewritten", savedAt.map { String(format: "%.0f", $0) } ?? "never", lastGap, cpu * 1000, doc.stats.checks, doc.stats.hashUnchanged, doc.stats.silentReloads))
        // steady state afterwards: 4 s of idle
        let cpu1 = ProcessMetrics.cpuSeconds(); let t1 = SelfTest.nowMs()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        out(String(format: "AUTOSAVE %@: idle afterwards: %.2f ms CPU in %.1f s", name, (ProcessMetrics.cpuSeconds() - cpu1) * 1000, (SelfTest.nowMs() - t1) / 1000))
        // an explicit save (Cmd-S) of the dirty document: stall
        t.typeText("y", into: doc, at: NSRange(location: 0, length: 0))
        let m2 = StallMeter(); m2.start()
        let tS = SelfTest.nowMs()
        let err = await t.autosave(doc)
        out(String(format: "AUTOSAVE %@: explicit autosave call: %.1f ms total, longest main-thread gap %.1f ms (%@)", name, SelfTest.nowMs() - tS, m2.stop(), err == nil ? "ok" : "\(err!)"))
        rec.measure("close") { t.close(doc) }
        t.check(true, "\(name): perf-autosave finished")
    }

    // MARK: perf-line

    /// An ordinary ~100 KB document with ONE very long line in the middle (prose with inline markup, or a base64 data URI in an image link).
    static func lineDocument(kind: String, length: Int) -> (text: String, lineStart: Int) {
        let head = SelfTestCorpus.markdown(bytes: 60_000, seed: 21) + "\n"
        var long = ""
        long.reserveCapacity(length + 100)
        if kind == "base64" {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            var r = TestRNG(5)
            long = "![screenshot](data:image/png;base64,"
            while long.utf16.count < length { long.append(alphabet[r.int(64)]) }
            long += ")"
        } else {
            var r = TestRNG(6)
            let w = ["alpha", "**bold**", "*em*", "`code`", "bravo", "[link](http://x.y/z)", "charlie", "delta", "~~gone~~", "echo"]
            while long.utf16.count < length { long += r.pick(w) + " " }
        }
        let tail = "\n\n" + SelfTestCorpus.markdown(bytes: 40_000, seed: 22)
        return (head + long + tail, (head as NSString).length)
    }

    @MainActor static func perfLine(_ t: SelfTest.T) async throws {
        let kind = SelfTest.argument("kind") ?? "prose"
        let lengths = (SelfTest.argument("lengths") ?? "10000,30000,64000,100000,300000,1000000").split(separator: ",").compactMap { Int($0) }
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)
        for L in lengths {
            let (text, lineStart) = lineDocument(kind: kind, length: L)
            let url = t.write(text, to: "line-\(kind)-\(L).md")
            let rec = PerfRecorder(tag: "line-\(kind)-\(L)")
            PerfWatchdog.shared.enter("line \(L)/open")
            let r = try await perfOpenOnce(url)
            PerfWatchdog.shared.leave()
            guard let host = r.doc.host as? EditorViewController else { continue }
            let tv = host.textView, sv = host.scrollView, doc = r.doc
            rec.add("open.total", r.total)
            // typing in the first screen (far from the long line)
            for i in 0..<30 {
                let k = perfKeystroke(t, host, doc, text: "a", at: 10 + i)
                if i >= 5 { rec.add("keystroke elsewhere (first screen)", k.real, quiet: true) }
            }
            // jump to the long line (its start), then type inside it
            rec.measure("jump to the long line (start) + layout") { t.scrollToTop(host, character: lineStart); perfLayoutVisible(host) }
            for i in 0..<20 {
                let at = lineStart + min(L / 2, 5000) + i
                let k = perfKeystroke(t, host, doc, text: "z", at: at)
                rec.add("keystroke INSIDE the long line", k.real, quiet: true)
                rec.add("keystroke INSIDE: insertText + restyle", k.insert, quiet: true)
            }
            // scroll through the long line
            t.scrollToTop(host, character: lineStart)
            var y = sv.contentView.bounds.origin.y
            for _ in 0..<15 {
                y += 350
                let t0 = SelfTest.nowMs()
                PerfWatchdog.shared.enter("line \(L)/scroll")
                sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host); perfDraw(host, sv.bounds)
                PerfWatchdog.shared.leave()
                rec.add("scroll step 350 pt inside/near the long line", SelfTest.nowMs() - t0, quiet: true)
            }
            // jump to the END of the long line / of the document
            rec.measure("jump to the middle of the long line") { t.scrollToTop(host, character: lineStart + L / 2); perfLayoutVisible(host) }
            rec.measure("Cmd-Down") { tv.moveToEndOfDocument(nil); perfLayoutVisible(host) }
            t.close(doc); await t.spin(10)
            rec.report(t)
        }
        t.check(true, "perf-line \(kind) finished")
    }

    // MARK: perf-typeloop

    @MainActor static func perfTypeLoop(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-typeloop --input f.md [--seconds S] [--at first|middle|char:N] [--wait-for-sampler]"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let seconds = Double(SelfTest.argument("seconds") ?? "") ?? 6
        let copy = try PerfLab.clone(t, input)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController else { return }
        let tv = host.textView, doc = r.doc
        let at = SelfTest.argument("at") ?? "first"
        var loc = 10
        if at == "middle" { loc = ns(tv).length / 2 } else if at.hasPrefix("char:"), let v = Int(at.dropFirst(5)) { loc = v }
        t.scrollToTop(host, character: loc); perfLayoutVisible(host)
        if SelfTest.flag("wait-for-sampler") { out("PERFTYPELOOP pid \(getpid()): attach `sample \(getpid()) 5 -file out.txt`; typing starts in 5 s"); await t.sleep(5000) }
        var times: [Double] = []
        let end = SelfTest.nowMs() + seconds * 1000
        var i = 0
        while SelfTest.nowMs() < end {
            let k = perfKeystroke(t, host, doc, text: "a", at: loc + i)
            times.append(k.real); i += 1
            if i % 50 == 0 { await t.spin(1) }
        }
        let s = PerfLab.stat(times)
        out("PERFTYPELOOP \(name) at \(at): \(times.count) keystrokes: \(PerfLab.fmt(s))")
        t.close(doc)
        t.check(true, "perf-typeloop finished")
    }

    // MARK: perf-leak

    @MainActor static func perfLeak(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-leak --input f.md [--cycles C] [--edit]"); return }
        let cycles = Int(SelfTest.argument("cycles") ?? "") ?? 3
        let copy = try PerfLab.clone(t, input)
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 0
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(100)
        let base = PerfLab.footprintBytes()
        final class WeakBox { weak var doc: MarkdownDocument?; weak var storage: NSTextStorage?; init(_ d: MarkdownDocument?, _ s: NSTextStorage?) { doc = d; storage = s } }
        var boxes: [WeakBox] = []
        for c in 0..<cycles {
            weak var wDoc: MarkdownDocument?
            weak var wHost: EditorViewController?
            weak var wTV: NSTextView?
            weak var wStorage: NSTextStorage?
            weak var wWindow: NSWindow?
            weak var wWC: NSWindowController?
            weak var wLM: NSLayoutManager?
            weak var wStyler: LazyStyler?
            do {
                let r = try await perfOpenOnce(copy)
                wDoc = r.doc
                let host = r.doc.host as? EditorViewController
                boxes.append(WeakBox(r.doc, host?.textView.textStorage))
                wHost = host; wTV = host?.textView; wStorage = host?.textView.textStorage; wLM = host?.textView.layoutManager; wStyler = host?.styler
                wWC = r.doc.windowControllers.first; wWindow = wWC?.window
                if SelfTest.flag("edit") {
                    if SelfTest.argument("edit-kind") == "count" { r.doc.updateChangeCount(.changeDone) }       // dirty without touching the text
                    else { t.typeText("x", into: r.doc, at: NSRange(location: 0, length: 0)) }
                }
                out("LEAK note: before close: document edited \(r.doc.isDocumentEdited), syncState \(r.doc.syncState)")
                let waitBeforeClose = Double(SelfTest.argument("wait-before-close") ?? "") ?? 0       // e.g. 4 = let the 3 s autosave fire first
                if waitBeforeClose > 0 { await t.spin(waitBeforeClose * 1000) }
                let open = PerfLab.footprintBytes()
                if SelfTest.argument("close") == "window", let win = wWindow {
                    // what Cmd-W does: windowShouldClose -> NSDocument.canClose (autosave in place for a dirty document) -> close
                    win.performClose(nil)
                    for _ in 0..<100 where !r.doc.isClosed { await t.spin(50) }
                    if !r.doc.isClosed { out("LEAK note: the window did not close within 5 s via performClose; closing via the harness") ; t.close(r.doc) }
                } else if SelfTest.argument("close") == "canclose" {
                    // the document half of Cmd-W without the window: canClose (autosave in place of a dirty document) -> close
                    let probe = CloseProbe()
                    let c0 = SelfTest.nowMs()
                    r.doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
                    _ = await t.waitFor(5000) { probe.result != nil }
                    out(String(format: "LEAK note: canClose answered %@ after %.0f ms (document edited: %@)", probe.result.map { $0 ? "shouldClose" : "do not close" } ?? "NOTHING within 5 s", SelfTest.nowMs() - c0, r.doc.isDocumentEdited ? "yes" : "no"))
                    r.doc.close()
                } else {
                    t.close(r.doc)
                }
                out(String(format: "LEAK cycle %d: footprint after open %+.1f MB; documents registered after close: %d; NSApp.windows: %d", c + 1, PerfLab.mb(open - base), NSDocumentController.shared.documents.count, NSApp.windows.count))
            }
            await t.spin(300)
            autoreleasepool { }
            await t.spin(300)
            out(String(format: "LEAK cycle %d after 600 ms + autoreleasepool: footprint %+.1f MB over the baseline (text %.1f MB)  alive: document=%@ editorVC=%@ textView=%@ textStorage=%@ layoutManager=%@ styler=%@ windowController=%@ window=%@",
                       c + 1, PerfLab.mb(PerfLab.footprintBytes() - base), Double(size) / 1e6, wDoc != nil ? "YES" : "no", wHost != nil ? "YES" : "no", wTV != nil ? "YES" : "no", wStorage != nil ? "YES" : "no", wLM != nil ? "YES" : "no", wStyler != nil ? "YES" : "no", wWC != nil ? "YES" : "no", wWindow != nil ? "YES" : "no"))
        }
        let lateSeconds = Double(SelfTest.argument("late") ?? "") ?? 0
        if lateSeconds > 0 {
            let f0 = PerfLab.footprintBytes()
            await t.sleep(lateSeconds * 1000)
            out(String(format: "LEAK after %.0f s more of waiting: footprint %+.1f MB over the baseline (was %+.1f MB); documents of the %d cycles still alive: %d, text storages still alive: %d",
                       lateSeconds, PerfLab.mb(PerfLab.footprintBytes() - base), PerfLab.mb(f0 - base), boxes.count, boxes.filter { $0.doc != nil }.count, boxes.filter { $0.storage != nil }.count))
        }
        if SelfTest.flag("wait-for-sampler") { out("LEAK pid \(getpid()): run `leaks \(getpid())` / `heap \(getpid())` now (60 s)"); await t.sleep(60_000) }
        t.check(true, "perf-leak finished")
    }

    // MARK: perf-fixing

    /// Why does the first jump into a never-visited region of a big document cost ~2.5 ms per MB of distance? Probe: raw attribute lookups
    /// (what NSLayoutManager does inside glyphRange(forBoundingRect:)) at various places of a fresh document, and the structure of the
    /// attribute runs. Findings are printed as `FIXING` lines.
    @MainActor static func perfFixing(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-fixing --input f.md"); return }
        let copy = try PerfLab.clone(t, input)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)
        func ms(_ body: () -> Void) -> Double { let a = SelfTest.nowMs(); body(); return SelfTest.nowMs() - a }
        // each experiment: a FRESH document, then raw attribute lookups at the given offsets (MB); prints the cost of each
        let experiments: [(String, [Double])] = [
            ("E1 end first", [19.9, 10, 5]),
            ("E2 forward in 1 MB steps", [1, 2, 3, 4, 5, 6]),
            ("E3 10 MB, then below, then just above", [10, 9, 5, 0.5, 10.5, 11]),
            ("E4 backward from the end", [19.9, 15, 10, 5, 1]),
            ("E5 two far apart then between", [2, 18, 10, 14]),
        ]
        for (label, mbs) in experiments {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController, let ts = host.textView.textStorage else { return }
            let len = ts.length
            var parts: [String] = []
            for mb in mbs {
                let pos = min(len - 1, Int(mb * 1_000_000 * Double(len) / 20_000_000))
                let c = ms { _ = ts.attribute(.font, at: pos, effectiveRange: nil) }
                parts.append(String(format: "%.1fM: %.1f ms", mb, c))
            }
            out("FIXING \(label.padding(toLength: 38, withPad: " ", startingAt: 0)) (doc \(len / 1_000_000) M units)  " + parts.joined(separator: "  |  "))
            t.close(r.doc); await t.spin(5)
        }
        // longestEffectiveRange and the paragraph style attribute (what NSLayoutManager looks up): same lazy fixing?
        do {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController, let ts = host.textView.textStorage else { return }
            let len = ts.length
            var e = NSRange(location: 0, length: 0)
            let a = ms { _ = ts.attribute(.paragraphStyle, at: len / 2, effectiveRange: &e) }
            out("FIXING paragraphStyle at the middle of a fresh doc: \(String(format: "%.1f", a)) ms, run \(NSStringFromRange(e))")
            let b = ms { _ = ts.attributes(at: len - 100, longestEffectiveRange: &e, in: NSRange(location: 0, length: len)) }
            out("FIXING attributes(at: end, longestEffectiveRange: whole): \(String(format: "%.1f", b)) ms, run \(NSStringFromRange(e))")
            // explicit fixing cost per MB (what the lazy fixing does)
            let c = ms { ts.fixAttributes(in: NSRange(location: 4_000_000, length: 1_000_000)) }
            let d = ms { ts.fixAttributes(in: NSRange(location: 4_000_000, length: 1_000_000)) }
            out("FIXING explicit fixAttributes(in: 1 MB): first \(String(format: "%.1f", c)) ms, again \(String(format: "%.1f", d)) ms")
            t.close(r.doc)
        }
        // pre-fixing in slices: does it make the later lookups free? (ensureAttributesAreFixed(in:) is the lazy mechanism's own entry point)
        for (label, useEnsure) in [("ensureAttributesAreFixed(in:)", true), ("fixAttributes(in:)", false)] {
            let r = try await perfOpenOnce(copy)
            guard let host = r.doc.host as? EditorViewController, let ts = host.textView.textStorage else { return }
            let len = ts.length
            let upto = min(len, 10_000_000)
            var worst = 0.0, total = 0.0, n = 0
            var loc = 0
            while loc < upto {
                let slice = NSRange(location: loc, length: min(256_000, upto - loc))
                let c = ms { if useEnsure { ts.ensureAttributesAreFixed(in: slice) } else { ts.fixAttributes(in: slice) } }
                worst = max(worst, c); total += c; n += 1; loc += slice.length
            }
            let look10 = ms { _ = ts.attribute(.font, at: upto - 50, effectiveRange: nil) }
            let look5 = ms { _ = ts.attribute(.font, at: 5_000_000, effectiveRange: nil) }
            let look12 = ms { _ = ts.attribute(.font, at: 12_000_000, effectiveRange: nil) }
            out(String(format: "FIXING pre-fix 0..10 MB in %d slices of 256 K with %@: total %.1f ms (worst slice %.2f ms); lookup at 10 MB afterwards %.2f ms, at 5 MB %.2f ms, at 12 MB (not pre-fixed) %.2f ms", n, label as NSString, total, worst, look10, look5, look12))
            t.close(r.doc); await t.spin(5)
        }
        t.check(true, "perf-fixing finished")
    }

    // MARK: perf-jump

    @MainActor static func perfJump(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-jump --input f.md"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let copy = try PerfLab.clone(t, input)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController else { return }
        let tv = host.textView, sv = host.scrollView, lm = tv.layoutManager!, tc = tv.textContainer!
        let len = ns(tv).length
        let rec = PerfRecorder(tag: name)
        out("PERFJUMP \(name): \(len) units; each row = one scroller-thumb jump to a fraction of the document height")
        let waitSampler = SelfTest.flag("wait-for-sampler")
        if waitSampler { out("PERFJUMP pid \(getpid()): attach `sample \(getpid()) 6 -file out.txt` now; starting in 6 s"); await t.sleep(6000) }
        let rounds = Int(SelfTest.argument("rounds") ?? "") ?? 1
        for round in 0..<rounds {
            for k in 1...30 {
                let frac = Double((k * 37 + round * 11) % 30) / 30
                let top = max(0, (tv.frame.height - sv.contentView.bounds.height) * frac)
                // (1) the clip view moves: boundsDidChange -> LazyStyler.styleVisible() (visible range via layout, lex, setAttributes)
                let t0 = SelfTest.nowMs()
                sv.contentView.scroll(to: NSPoint(x: 0, y: top))
                let t1 = SelfTest.nowMs()
                sv.reflectScrolledClipView(sv.contentView)
                let t2 = SelfTest.nowMs()
                lm.ensureLayout(forBoundingRect: tv.visibleRect, in: tc)
                let t3 = SelfTest.nowMs()
                perfDraw(host, sv.bounds)
                let t4 = SelfTest.nowMs()
                rec.add("clip.scroll(to:) (incl. boundsDidChange -> styleVisible)", t1 - t0, quiet: true)
                rec.add("reflectScrolledClipView", t2 - t1, quiet: true)
                rec.add("ensureLayout(visibleRect)", t3 - t2, quiet: true)
                rec.add("full redraw", t4 - t3, quiet: true)
                rec.add("TOTAL jump", t4 - t0, quiet: true)
            }
        }
        // the same far positions again: everything already laid out and styled
        for k in 1...30 {
            let frac = Double((k * 37) % 30) / 30
            let top = max(0, (tv.frame.height - sv.contentView.bounds.height) * frac)
            let t0 = SelfTest.nowMs()
            sv.contentView.scroll(to: NSPoint(x: 0, y: top)); sv.reflectScrolledClipView(sv.contentView); perfLayoutVisible(host)
            rec.add("REVISIT (same positions again) scroll + layout", SelfTest.nowMs() - t0, quiet: true)
        }
        // style only: how much of the jump is the lexer / attribute application (jump with a hidden viewport: prestyle by hand)
        for k in 1...15 {
            let loc = Int(Double(len) * Double((k * 53) % 29 + 1) / 31)
            host.styler.reset()
            rec.measure("prestyle(aroundCharacter:) alone (fresh styler)", quiet: true) { host.styler.prestyle(aroundCharacter: loc) }
        }
        rec.report(t)
        t.close(r.doc)
        t.check(true, "perf-jump finished")
    }

    // MARK: perf-idle

    @MainActor static func perfIdle(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-idle --input f.md"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let copy = try PerfLab.clone(t, input)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(10)
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController else { return }
        let doc = r.doc, tv = host.textView, sv = host.scrollView
        let len = ns(tv).length
        let window = Double(SelfTest.argument("window") ?? "")       // --window 10: every sample takes 10 s (default: 2-3 s)
        func idle(_ label: String, seconds secs: Double = 3) async {
            let seconds = window ?? secs
            let c0 = ProcessMetrics.cpuSeconds(); let t0 = SelfTest.nowMs()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))            // ONE wake-up
            let wall = (SelfTest.nowMs() - t0) / 1000, cpu = ProcessMetrics.cpuSeconds() - c0
            out(String(format: "IDLE %@ %@: %.2f ms CPU in %.2f s = %.3f %% of a core", name, label, cpu * 1000, wall, cpu / wall * 100))
        }
        await idle("right after open (first 3 s: includes the xattr echo of NSDocument)")
        await idle("3-6 s after open")
        for i in 0..<30 { t.typeText("a", into: doc, at: NSRange(location: i, length: 0)) }
        await idle("after 30 keystrokes (autosave not yet due)", seconds: 2)
        await t.spin(4000)                                                  // the 3 s autosave fires (write + file monitor echo) ...
        await idle("after the autosave of those keystrokes (typing stopped 4 s ago)", seconds: 3)
        t.scrollToTop(host, character: len / 2); perfLayoutVisible(host)
        await idle("after a far jump", seconds: 2)
        tv.selectAll(nil); perfLayoutVisible(host); perfDraw(host, sv.bounds)
        await idle("after select all + redraw", seconds: 2)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await idle("after deselect", seconds: 2)
        t.close(doc)
        await idle("after closing the document", seconds: 2)
        t.check(true, "perf-idle finished")
    }

    // MARK: perf-decode-leak

    /// `TextCodec.decode` of a big non-ASCII text, over and over, without any document / window involved. On macOS 27.0.1 (26A434) `NSString(bytes:length:encoding:)`
    /// leaves ~2 bytes per character of freed memory resident for every call on inputs above ~1-2 MB that are not pure ASCII ("Malloc Large (empty)" in vmmap,
    /// nothing in `leaks`); every open and every auto-reload of such a file then costs memory for ever. The check: after 2 warm-up decodes, 12 more must not
    /// grow the footprint by more than 24 MB (a leaking build grows ~8 MB per decode of this 4 MB text = ~96 MB; a fixed one stays flat).
    @MainActor static func perfDecodeLeak(_ t: SelfTest.T) async throws {
        let file = t.corpusFile(bytes: 4_000_000, nonASCII: true)
        let data = try Data(contentsOf: file)
        t.check(!(String(decoding: data, as: UTF8.self).utf8.allSatisfy { $0 < 0x80 }), "the corpus is not pure ASCII")
        func decodeOnce() { autoreleasepool { _ = try? TextCodec.decode(data) } }
        for _ in 0..<2 { decodeOnce() }
        await t.spin(100)
        let base = PerfLab.footprintBytes()
        var samples: [Double] = []
        for _ in 0..<12 { decodeOnce(); samples.append(PerfLab.mb(PerfLab.footprintBytes() - base)) }
        let growth = samples.last ?? 0
        out("DECODELEAK footprint over 12 decodes of a \(data.count / 1_000_000) MB non-ASCII file: " + samples.map { String(format: "%+.1f", $0) }.joined(separator: " ") + " MB")
        t.check(growth <= 24, String(format: "decode of a 4 MB non-ASCII text 12 times: footprint grew %.1f MB (<= 24 MB; ~96 MB when NSString(bytes:length:encoding:) leaks)", growth))
        // and the text is right
        if let d = try? TextCodec.decode(data) { t.check(d.text.length > 3_000_000 && d.format.encoding == .utf8, "decoded as UTF-8, \(d.text.length) units") }
    }

    // MARK: perf-extent

    /// Does the layout manager lay out ALL the text? (`limitsLayoutForSuspiciousContents` may truncate very long paragraphs.) Forces a full layout, then reports
    /// the number of glyphs / line fragments / used height, and the character range that is covered by the last laid-out line fragment.
    @MainActor static func perfExtent(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-extent --input f.md"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let copy = try PerfLab.clone(t, input)
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController, let lm = host.textView.layoutManager, let tc = host.textView.textContainer else { return }
        let len = ns(host.textView).length
        let t0 = SelfTest.nowMs()
        lm.ensureLayout(for: tc)
        let dt = SelfTest.nowMs() - t0
        var frags = 0, covered = 0, idx = 0
        let glyphs = lm.numberOfGlyphs
        while idx < glyphs { var gr = NSRange(); _ = lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &gr); frags += 1; idx = NSMaxRange(gr); if gr.length == 0 { break } }
        covered = lm.characterRange(forGlyphRange: NSRange(location: 0, length: glyphs), actualGlyphRange: nil).length
        out(String(format: "EXTENT %@: limitsLayoutForSuspiciousContents=%@ chars %d, glyphs %d, characters covered by glyphs %d, line fragments %d, used height %.0f pt, full ensureLayout %.0f ms",
                   name, lm.limitsLayoutForSuspiciousContents ? "true" : "false", len, glyphs, covered, frags, lm.usedRect(for: tc).height, dt))
        // pictures of the first screen and of a screen at 25 % / 50 % / 99 % of the text, to compare variants byte for byte (`--png-prefix /path/x`)
        if let prefix = SelfTest.argument("png-prefix") {
            for (label, frac) in [("top", 0.0), ("q1", 0.25), ("mid", 0.5), ("end", 0.99)] {
                t.scrollToTop(host, character: Int(Double(len) * frac)); perfLayoutVisible(host)
                let b = host.scrollView.bounds
                if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: b) {
                    host.scrollView.cacheDisplay(in: b, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(label).png")) }
                }
            }
        }
        t.close(r.doc)
        t.check(true, "perf-extent finished")
    }

    // MARK: perf-reload

    @MainActor static func perfReload(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest perf-reload --input f.md"); return }
        let name = SelfTest.argument("name") ?? URL(fileURLWithPath: input).lastPathComponent
        let copy = try PerfLab.clone(t, input)
        let tiny = t.write("# warm\n\ntext\n", to: "tiny.md")
        let r0 = try await perfOpenOnce(tiny); t.close(r0.doc); await t.spin(100)
        let r = try await perfOpenOnce(copy)
        guard let host = r.doc.host as? EditorViewController else { return }
        let doc = r.doc
        await t.sleep(2500)
        // the writer: another process rewriting the file with an atomic replace (mv of a temp file), like a build tool / an agent
        func rewrite(_ label: String, transform: String) async {
            let before = ns(host.textView).length
            let fp0 = PerfLab.footprintBytes()
            let meter = StallMeter(); meter.start()
            let tmp = copy.appendingPathExtension("tmp")
            let tW0 = SelfTest.nowMs()
            let tDone = await t.sh("\(transform) < \(t.q(copy)) > \(t.q(tmp)) && mv \(t.q(tmp)) \(t.q(copy))")
            let ok = await t.waitFor(8000) { ns(host.textView).length != before }
            let tSeen = SelfTest.nowMs()
            await t.sleep(300)
            let gap = meter.stop()
            out(String(format: "RELOAD %@ %@: writer finished at +%.0f ms (incl. process start), text updated %@ at +%.0f ms (latency after the write %.0f ms); longest main-thread gap %.1f ms; silent reloads so far %d; text %d -> %d units; footprint %+.1f MB (a leaking decode shows ~2 bytes/char here)",
                       name, label, tDone - tW0, ok ? "yes" : "NO", tSeen - tW0, tSeen - tDone, gap, doc.stats.silentReloads, before, ns(host.textView).length, PerfLab.mb(PerfLab.footprintBytes() - fp0)))
        }
        await rewrite("append one line", transform: "(cat; echo 'appended by the writer')")
        await rewrite("change one line (sed on line 1000)", transform: "sed '1000s/.*/changed by the writer/'")
        await rewrite("delete every 10th line", transform: "awk 'NR % 10 != 0'")
        await rewrite("rewrite every line (prefix 'x ')", transform: "sed 's/^/x /'")
        rec_close(t, doc)
        t.check(true, "\(name): perf-reload finished")
    }
    @MainActor private static func rec_close(_ t: SelfTest.T, _ doc: MarkdownDocument) { t.close(doc) }

    /// Close the way Cmd-W does: let the run loop turn once (a real Cmd-W is a separate event; closing in the SAME turn as the last keystroke blocks in
    /// NSDocument's serialization semaphore), then canClose (autosave in place of a dirty document) and close. `T.close` (`.changeCleared` + `close()`) skips
    /// canClose and leaves NSDocument's autosave event monitor retaining a document that was edited a moment before: a harness artifact, not an app leak
    /// (measured: documents closed this way are released; see perf-leak --close).
    @MainActor static func perfCloseLikeUser(_ t: SelfTest.T, _ doc: MarkdownDocument) async {
        await t.spin(60)
        let probe = CloseProbe()
        doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        _ = await t.waitFor(5000) { probe.result != nil }
        doc.close()
    }
}
#endif
