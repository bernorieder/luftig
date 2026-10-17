import AppKit

/// Split every run at whitespace boundaries: emulates a naive "one run per token" highlighter.
func explodeToTokens(_ runs: [Run], _ u16: [UInt16]) -> [Run] {
    var out: [Run] = []
    out.reserveCapacity(runs.count * 6)
    for r in runs {
        var i = r.loc
        let end = r.loc + r.len
        while i < end {
            var j = i
            let isSpace = u16[i] == 32
            while j < end && (u16[j] == 32) == isSpace { j += 1 }
            out.append(Run(loc: i, len: j - i, style: r.style))
            i = j
        }
    }
    return out
}

/// Choose a line-aligned range starting at `loc` containing about `targetRuns` coalesced runs.
func sliceWithRuns(doc: Doc, at loc: Int, targetRuns: Int) -> (NSRange, [Run], Int) {
    var lines = 20
    while true {
        let r = doc.range(fromLineAt: loc, lines: lines)
        let runs = doc.lex(r)
        if runs.count >= targetRuns || r.location + r.length >= doc.length {
            return (r, runs, lines)
        }
        lines += 20
    }
}

struct AttrSample {
    var loop = 0.0, end = 0.0, layout = 0.0, draw = 0.0
    var apply: Double { loop + end }
    var total: Double { loop + end + layout + draw }
}

enum SliceVariant: String {
    case setBatched = "setAttributes batched"
    case addBatched = "addAttributes batched"
    case setUnbatched = "setAttributes UNbatched"
    case setBatchedTokens = "setAttributes batched, per-token runs"
}

func resetAndFlush(_ h: Harness, _ range: NSRange, _ theme: Theme) {
    h.storage.beginEditing()
    h.storage.setAttributes(theme.baseAttributes, range: range)
    h.storage.endEditing()
    h.layoutVisible()
    _ = h.drawVisible()
}

func measureSlice(_ h: Harness, runs: [Run], range: NSRange, theme: Theme, variant: SliceVariant) -> AttrSample {
    var s = AttrSample()
    let storage = h.storage
    let t0 = nowMs()
    switch variant {
    case .setBatched, .setBatchedTokens:
        storage.beginEditing()
        for r in runs { storage.setAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
        let t1 = nowMs()
        storage.endEditing()
        s.loop = t1 - t0; s.end = nowMs() - t1
    case .addBatched:
        storage.beginEditing()
        for r in runs { storage.addAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
        let t1 = nowMs()
        storage.endEditing()
        s.loop = t1 - t0; s.end = nowMs() - t1
    case .setUnbatched:
        for r in runs { storage.setAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
        s.loop = nowMs() - t0
    }
    s.layout = ms { h.layoutVisible() }
    s.draw = h.drawVisible()
    return s
}

func runAttrs(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "all"))
    let corpora = arg("corpus", "1m,5m,20m").split(separator: ",").map(String.init)
    let reps = Int(arg("runs", "5"))!
    let whole = arg("whole", "1") == "1"
    let slices = arg("slices", "1") == "1"
    let theme = Theme()

    for corpus in corpora {
        let text = Corpus.load(corpus)
        let doc = Doc(text)
        log("\n#### corpus \(corpus): \(doc.length) UTF-16 units; Doc prep: UTF-16 copy \(f1(doc.buildU16Ms)) ms, fence scan \(f1(doc.buildFenceMs)) ms (\(doc.fences.starts.count) fences)")

        if slices {
            let probeRange = doc.range(fromLineAt: 0, lines: 150)
            let probeRuns = doc.lex(probeRange)
            log("150 lines at top = \(probeRange.length) UTF-16 units, \(probeRuns.count) coalesced runs")
            let (sliceRange, sliceRuns, lines) = sliceWithRuns(doc: doc, at: 0, targetRuns: 1000)
            log("viewport-slice used: \(lines) lines, \(sliceRange.length) units, \(sliceRuns.count) runs")

            log("| engine | placement | variant | runs | loop ms | endEditing ms | layout ms | draw ms | total ms |")
            log("|---|---|---|---|---|---|---|---|---|")
            for engine in engines {
                let h = Harness(engine: engine)
                h.textView.font = theme.bodyFont
                h.textView.textColor = Palette.text
                h.textView.string = text
                _ = h.snapshotRep
                h.layoutVisible()
                _ = h.drawVisible()
                let visibleChars = h.visibleRect
                _ = visibleChars

                // placements: visible (top), just below the viewport, far away (middle of the document)
                let vis = (sliceRange, sliceRuns)
                let belowStart = doc.lineEnd(NSMaxRange(sliceRange) + 4000)
                let (belowRange, belowRuns, _) = sliceWithRuns(doc: doc, at: belowStart, targetRuns: 1000)
                let midStart = doc.lineStart(doc.length / 2)
                let (midRange, midRuns, _) = sliceWithRuns(doc: doc, at: midStart, targetRuns: 1000)
                let placements: [(String, NSRange, [Run])] = [("visible", vis.0, vis.1), ("below viewport", belowRange, belowRuns), ("middle of doc", midRange, midRuns)]

                for (pname, range, runs) in placements {
                    let tokenRuns = explodeToTokens(runs, doc.u16)
                    for variant in [SliceVariant.setBatched, .addBatched, .setBatchedTokens, .setUnbatched] {
                        let use = variant == .setBatchedTokens ? tokenRuns : runs
                        var samples: [AttrSample] = []
                        let n = variant == .setUnbatched ? max(2, reps / 2) : reps
                        for _ in 0..<n {
                            resetAndFlush(h, range, theme)
                            samples.append(measureSlice(h, runs: use, range: range, theme: theme, variant: variant))
                        }
                        func m(_ kp: (AttrSample) -> Double) -> String { f2(Stats(samples.map(kp)).median) }
                        log("| \(engine.rawValue) | \(pname) | \(variant.rawValue) | \(use.count) | \(m { $0.loop }) | \(m { $0.end }) | \(m { $0.layout }) | \(m { $0.draw }) | **\(m { $0.total })** |")
                    }
                }
                h.window.contentView = nil
            }
        }

        if whole {
            log("\nWhole-document styling (lex everything, setAttributes for every run, one beginEditing/endEditing):")
            log("| engine | corpus | runs | lex ms | apply loop ms | endEditing ms | layout visible ms | draw ms | idle 1s max stall ms | RSS Δ MB |")
            log("|---|---|---|---|---|---|---|---|---|---|")
            let allRange = NSRange(location: 0, length: doc.length)
            var allRuns: [Run] = []
            let lexMs = ms { allRuns = doc.lex(allRange) }
            let nrep = corpus == "20m" ? 1 : (corpus == "5m" ? 2 : 3)
            for engine in engines {
                var loops: [Double] = [], ends: [Double] = [], lays: [Double] = [], draws: [Double] = [], stalls: [Double] = [], rss: [Double] = []
                for _ in 0..<nrep {
                    Watchdog.arm(seconds: 300, label: "whole-doc styling \(engine.rawValue) \(corpus)")
                    autoreleasepool {
                        let r0 = rssMB()
                        let h = Harness(engine: engine)
                        h.textView.font = theme.bodyFont
                        h.textView.textColor = Palette.text
                        h.textView.string = text
                        _ = h.snapshotRep
                        h.layoutVisible()
                        let s = measureSlice(h, runs: allRuns, range: allRange, theme: theme, variant: .setBatched)
                        loops.append(s.loop); ends.append(s.end); lays.append(s.layout); draws.append(s.draw)
                        let (gap, _) = h.spin(1.0)
                        stalls.append(gap)
                        rss.append(rssMB() - r0)
                        h.window.contentView = nil
                    }
                    Watchdog.disarm()
                }
                log("| \(engine.rawValue) | \(corpus) | \(allRuns.count) | \(f1(lexMs)) | \(f1(Stats(loops).median)) | \(f1(Stats(ends).median)) | \(f1(Stats(lays).median)) | \(f1(Stats(draws).median)) | \(f1(Stats(stalls).max)) | \(f1(Stats(rss).median)) |")
            }
        }
    }
}
