import Foundation
import MarkdownKit

@inline(__always) func nowNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
func us(_ ns: UInt64) -> Double { Double(ns) / 1e3 }

struct Dist {
    var sorted: [UInt64]
    init(_ samples: [UInt64]) { sorted = samples.sorted() }
    func p(_ q: Double) -> UInt64 { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
    var line: String {
        String(format: "p50 %7.1f us   p90 %7.1f us   p99 %7.1f us   max %8.1f us   (n=%d)", us(p(0.5)), us(p(0.9)), us(p(0.99)), us(sorted.last ?? 0), sorted.count)
    }
}

/// Byte offset of the start of the line that is `lines` lines after the line containing `from`.
func offsetAfterLines(_ t: NSString, from: Int, lines: Int) -> Int {
    var i = from
    var n = 0
    let len = t.length
    var buf = [unichar](repeating: 0, count: 4096)
    while i < len && n < lines {
        let chunk = min(4096, len - i)
        buf.withUnsafeMutableBufferPointer { t.getCharacters($0.baseAddress!, range: NSRange(location: i, length: chunk)) }
        var j = 0
        while j < chunk && n < lines { if buf[j] == 10 { n += 1 }; j += 1 }
        i += j
    }
    return i
}

func lineStartAtOrAfter(_ t: NSString, _ p: Int) -> Int {
    var i = max(0, min(p, t.length))
    if i == 0 { return 0 }
    while i < t.length && t.character(at: i - 1) != 10 { i += 1 }
    return i
}

func benchLexAll(_ name: String, _ text: NSString, bytes: Int, runs: Int) {
    let s = MarkdownStyler()
    var best = UInt64.max
    var nruns = 0
    for _ in 0..<runs {
        let t0 = nowNS()
        let r = s.lexAll(text)
        let dt = nowNS() - t0
        nruns = r.count
        best = min(best, dt)
    }
    let mbps = Double(bytes) / 1e6 / (Double(best) / 1e9)
    print(String(format: "  lexAll %-24@ best of %d: %8.1f ms   %7.1f MB/s   (%d runs, %.1f bytes/run)", name as NSString, runs, ms(best), mbps, nruns, Double(bytes) / Double(max(1, nruns))))
}

func benchColdScreens(_ name: String, _ text: NSString) {
    let n = text.length
    print("  cold first-screen styleRuns (~80 lines) on \(name), fresh styler each time (min / median of 7):")
    for (label, frac) in [("start", 0.0), ("middle", 0.5), ("end", 1.0)] {
        var samples: [UInt64] = []
        var runCount = 0, regionLen = 0, cps = 0
        for _ in 0..<7 {
            let s = MarkdownStyler()
            var from = lineStartAtOrAfter(text, Int(Double(n) * frac))
            if frac == 1.0 {                                    // last ~80 lines
                var back = n
                var lines = 0
                while back > 0 && lines < 80 { back -= 1; if text.character(at: back) == 10 { lines += 1 } }
                from = back + 1
            }
            let to = offsetAfterLines(text, from: from, lines: 80)
            let t0 = nowNS()
            let r = s.styleRuns(in: NSRange(location: from, length: max(1, to - from)), of: text)
            samples.append(nowNS() - t0)
            runCount = r.runs.count; regionLen = r.range.length; cps = s.debugCheckpointCount
        }
        let d = Dist(samples)
        print(String(format: "    %-7@ min %8.2f ms   median %8.2f ms   (%d runs, %d units, %d checkpoints)", label as NSString, ms(d.sorted.first!), ms(d.p(0.5)), runCount, regionLen, cps))
    }
}

/// Simulate typing: insert `count` characters at `pos`, then delete them with backspace.
func benchTyping(_ label: String, _ base: NSString, at wantedPos: Int, count: Int, fullyLexed: Bool) {
    let text = NSMutableString(string: base as String)
    let s = MarkdownStyler()
    if fullyLexed { _ = s.styleRuns(in: NSRange(location: 0, length: text.length), of: text) }
    else { _ = s.styleRuns(in: NSRange(location: max(0, wantedPos - 2000), length: 4000), of: text) }
    // a position inside plain prose: right after the first " the " at or after wantedPos
    var pos = text.range(of: " the ", options: [], range: NSRange(location: wantedPos, length: min(5000, text.length - wantedPos))).location
    if pos == NSNotFound { pos = wantedPos }
    pos += 5
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz ")
    var ins: [UInt64] = [], del: [UInt64] = []
    var regionTotal = 0, runsTotal = 0
    for k in 0..<count {
        let ch = String(alphabet[k % alphabet.count])
        text.insert(ch, at: pos + k)
        let t0 = nowNS()
        let r = s.update(afterEdit: NSRange(location: pos + k, length: 1), changeInLength: 1, of: text)
        ins.append(nowNS() - t0)
        regionTotal += r.range.length; runsTotal += r.runs.count
    }
    for k in stride(from: count - 1, through: 0, by: -1) {
        text.deleteCharacters(in: NSRange(location: pos + k, length: 1))
        let t0 = nowNS()
        let r = s.update(afterEdit: NSRange(location: pos + k, length: 0), changeInLength: -1, of: text)
        del.append(nowNS() - t0)
        regionTotal += r.range.length; runsTotal += r.runs.count
    }
    print("    \(label) insert: \(Dist(ins).line)")
    print("    \(label) delete: \(Dist(del).line)")
    print(String(format: "    %@ mean re-lexed region %.0f units, %.0f runs per update", label, Double(regionTotal) / Double(2 * count), Double(runsTotal) / Double(2 * count)))
}

func runBenchmarks() {
    print("MarkdownKit benchmarks (release build)")
    var corpora: [(String, NSString, Int)] = []
    for (name, size) in [("1 MB", 1_000_000), ("10 MB", 10_000_000)] {
        let t0 = nowNS()
        let str = Corpus.make(bytes: size, seed: 42)
        let bytes = str.utf8.count
        let ns = NSMutableString(string: str)
        print(String(format: "corpus %@: %d bytes, %d UTF-16 units, %d lines (generated in %.0f ms)", name, bytes, ns.length, str.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }, ms(nowNS() - t0)))
        corpora.append((name, ns, bytes))
    }

    print("\n1. Full-lex throughput")
    for (name, text, bytes) in corpora { benchLexAll(name, text, bytes: bytes, runs: name == "1 MB" ? 10 : 5) }

    // UTF-16-backed immutable string variant (what getCharacters is fastest on) and bridged Swift string
    if let (_, t, bytes) = corpora.last {
        var units = [unichar](repeating: 0, count: t.length)
        units.withUnsafeMutableBufferPointer { t.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: t.length)) }
        let utf16 = NSString(characters: units, length: units.count)
        benchLexAll("10 MB NSString(characters:)", utf16, bytes: bytes, runs: 3)
        let bridged = NSString(string: t as String)
        benchLexAll("10 MB NSString(string:)", bridged, bytes: bytes, runs: 3)
    }

    print("\n2. Cold-start styling of the first screen")
    for (name, text, _) in corpora { benchColdScreens(name, text) }

    print("\n3. Incremental update latency (single-character typing / backspace)")
    if let (name, text, _) = corpora.last {
        print("  \(name), fully lexed:")
        let n = text.length
        benchTyping("start ", text, at: 200, count: 1000, fullyLexed: true)
        benchTyping("middle", text, at: n / 2, count: 1000, fullyLexed: true)
        benchTyping("end   ", text, at: n - 20_000, count: 1000, fullyLexed: true)
        print("  \(name), only the area around the cursor lexed (lazy open):")
        benchTyping("start ", text, at: 200, count: 1000, fullyLexed: false)
        benchTyping("middle", text, at: n / 2, count: 1000, fullyLexed: false)
        benchTyping("end   ", text, at: n - 20_000, count: 1000, fullyLexed: false)
    }
    if let (name, text, _) = corpora.first {
        print("  \(name), fully lexed:")
        benchTyping("middle", text, at: text.length / 2, count: 1000, fullyLexed: true)
    }

    print("\n3b. Idle fill: styling the whole 10 MB document front to back in 8 KB slices (as an idle-time filler would)")
    if let (name, text, bytes) = corpora.last {
        let s = MarkdownStyler()
        var lat: [UInt64] = []
        var pos = 0
        let t0 = nowNS()
        while pos < text.length {
            let t1 = nowNS()
            let r = s.styleRuns(in: NSRange(location: pos, length: min(8192, text.length - pos)), of: text)
            lat.append(nowNS() - t1)
            pos = max(pos + 1, r.range.location + r.range.length)
        }
        let total = nowNS() - t0
        let d = Dist(lat)
        print(String(format: "  %@: %d calls, total %.1f ms (%.1f MB/s)   per call p50 %.1f us  p99 %.1f us  max %.1f us   checkpoints %d (~%.0f KB)",
                     name as NSString, lat.count, ms(total), Double(bytes) / 1e6 / (Double(total) / 1e9), us(d.p(0.5)), us(d.p(0.99)), us(d.sorted.last!), s.debugCheckpointCount, Double(s.debugCheckpointCount * MemoryLayout<Int>.size * 5) / 1024))
    }

    print("\n4. Worst cases and pathological input")
    if let (_, text, _) = corpora.last {
        // Opening a code fence at the top of a 10 MB document without any fence below it.
        let plain = NSMutableString(string: String(repeating: "A paragraph with *emphasis*, `code` and a [link](http://x.y).\n\n- list item one\n- list item two\n\n", count: 90_000))
        let s = MarkdownStyler()
        let t0 = nowNS()
        _ = s.styleRuns(in: NSRange(location: 0, length: plain.length), of: plain)
        let tFull = nowNS() - t0
        plain.insert("```\n", at: 0)
        let t1 = nowNS()
        let r = s.update(afterEdit: NSRange(location: 0, length: 4), changeInLength: 4, of: plain)
        let tOpen = nowNS() - t1
        print(String(format: "  %.1f MB fully lexed in %.0f ms; typing a code fence at the top re-lexes %d units in %.1f ms (no re-convergence)", Double(plain.length) / 1e6, ms(tFull), r.range.length, ms(tOpen)))
        _ = text
    }
    func timeOne(_ label: String, _ str: String) {
        let t = NSString(string: str)
        let s = MarkdownStyler()
        let t0 = nowNS()
        let r = s.lexAll(t)
        let dt = nowNS() - t0
        let s2 = MarkdownStyler()
        let t1 = nowNS()
        _ = s2.styleRuns(in: NSRange(location: 0, length: min(2000, t.length)), of: t)
        let dt2 = nowNS() - t1
        // one keystroke in the middle (already-lexed first screen)
        let m = NSMutableString(string: str)
        _ = s2.styleRuns(in: NSRange(location: 0, length: m.length), of: m)
        let mid = m.length / 2
        m.insert("x", at: mid)
        let t2 = nowNS()
        _ = s2.update(afterEdit: NSRange(location: mid, length: 1), changeInLength: 1, of: m)
        let dt3 = nowNS() - t2
        print(String(format: "  %-44@ lexAll %8.1f ms (%d runs)   first screen %7.2f ms   keystroke %7.2f ms", label as NSString, ms(dt), r.count, ms(dt2), ms(dt3)))
    }
    let five = 5_000_000
    timeOne("5 MB single line of prose", String(repeating: "word *em* `code` [l](u) ", count: five / 24))
    timeOne("5 MB single line of '*'", String(repeating: "*", count: five))
    timeOne("5 MB single line of '`'", String(repeating: "`", count: five))
    timeOne("5 MB single line of '[' / '](' pairs", String(repeating: "[a](", count: five / 4))
    timeOne("5 MB single line of '<a '", String(repeating: "<a ", count: five / 3))
    timeOne("5 MB single line of '_a '", String(repeating: "_a ", count: five / 3))
    timeOne("1 MB of '> ' x 8 per line (deep quotes)", String(repeating: "> > > > > > > > text\n", count: 1_000_000 / 20))
    timeOne("1 MB of empty lines", String(repeating: "\n", count: 1_000_000))
    timeOne("1 MB paragraph, 40-char lines (no blanks)", String(repeating: "some words here with *em* and `x` in it\n", count: 1_000_000 / 40))
    timeOne("1 MB table rows", "| a | b |\n|---|---|\n" + String(repeating: "| *x* | `y` |\n", count: 1_000_000 / 14))
    timeOne("1 MB of nested list items", String(repeating: "- a\n  - b\n    - c\n      - d\n", count: 1_000_000 / 26))
    timeOne("1 MB of CRLF lines", String(repeating: "line with **bold** and _em_\r\n", count: 1_000_000 / 29))
    timeOne("1 MB of emoji text", String(repeating: "😀 *x* 👍🏽 `y` 日本語 \n", count: 1_000_000 / 30))
}

/// Tuning experiment: checkpoint stride vs update latency, region size, cold end-of-document styling, memory.
func runStrideSweep() {
    let str = Corpus.make(bytes: 10_000_000, seed: 42)
    let text = NSMutableString(string: str)
    let n = text.length
    print("stride sweep on a 10 MB corpus (units between checkpoints)")
    for stride in [256, 512, 1024, 2048, 4096, 8192, 16384] {
        func make() -> MarkdownStyler {
            let s = MarkdownStyler()
            s.debugConfigure(strideUnits: stride, maxParagraphLines: 256, maxParagraphUnits: 65536, frontMatterWindow: 16384)
            return s
        }
        // cold end-of-document first screen
        var cold: [UInt64] = []
        var cps = 0
        for _ in 0..<5 {
            let s = make()
            var back = n, lines = 0
            while back > 0 && lines < 80 { back -= 1; if text.character(at: back) == 10 { lines += 1 } }
            let t0 = nowNS()
            _ = s.styleRuns(in: NSRange(location: back + 1, length: n - back - 1), of: text)
            cold.append(nowNS() - t0)
            cps = s.debugCheckpointCount
        }
        // typing at the start (worst case for shifting the checkpoint tail)
        let work = NSMutableString(string: str)
        let s = make()
        _ = s.styleRuns(in: NSRange(location: 0, length: work.length), of: work)
        var pos = work.range(of: " the ", options: [], range: NSRange(location: 200, length: 20000)).location
        if pos == NSNotFound { pos = 400 }
        pos += 5
        var lat: [UInt64] = []
        var region = 0
        for k in 0..<1000 {
            work.insert("a", at: pos + k)
            let t0 = nowNS()
            let r = s.update(afterEdit: NSRange(location: pos + k, length: 1), changeInLength: 1, of: work)
            lat.append(nowNS() - t0)
            region += r.range.length
        }
        pos = 0
        let d = Dist(lat)
        print(String(format: "  stride %6d: cold-end %6.2f ms (%5d checkpoints, %5.0f KB)   typing@start p50 %5.1f us p99 %5.1f us   mean region %5.0f units",
                     stride, ms(Dist(cold).p(0.5)), cps, Double(cps * MemoryLayout<UInt64>.size * 6) / 1024, us(d.p(0.5)), us(d.p(0.99)), Double(region) / 1000))
    }
}
