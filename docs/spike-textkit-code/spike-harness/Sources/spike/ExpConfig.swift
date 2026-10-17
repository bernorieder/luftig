import AppKit

/// Typing micro-benchmark on a freshly opened document: caret at the middle of the first screen, N characters typed.
func typingBench(engine: Engine, text: String, keys: Int = 60, options: HarnessOptions = HarnessOptions(), theme: Theme, firstResponder: Bool = false, spinBetween: Bool = false) -> (total: Stats, insert: Stats, stall: Double) {
    var totals: [Double] = [], inserts: [Double] = []
    var stall = 0.0
    autoreleasepool {
        let h = Harness(engine: engine, options: options)
        let hc = HighlightController(theme: theme)
        h.storage.delegate = hc
        h.textView.font = theme.bodyFont
        h.textView.textColor = Palette.text
        h.textView.string = text
        let lexer = MiniLexer()
        var buf = [UInt16]()
        let r = firstScreenRange(h.storage)
        Styler.apply(lexFromStorage(h.storage, range: r, inFence: false, lexer: lexer, buf: &buf), to: h.storage, theme: theme)
        _ = h.snapshotRep
        if firstResponder { h.window.makeFirstResponder(h.textView) }
        h.layoutVisible()
        let o = h.textView.textContainerOrigin
        let idx = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 60, y: h.visibleRect.midY))
        h.textView.setSelectedRange(NSRange(location: idx, length: 0))
        let chars = Array("the quick brown fox jumps over the lazy dog 0123456789 'quote' \"dq\" -- http://example.com ")
        for k in 0..<(keys + 10) {
            let ch = String(chars[k % chars.count])
            let t0 = nowMs()
            h.textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0))
            let t1 = nowMs()
            h.layoutVisible()
            _ = h.drawVisible()
            let t2 = nowMs()
            if k >= 10 { totals.append(t2 - t0); inserts.append(t1 - t0) }
            if spinBetween { let (gap, _) = h.spin(0.004); stall = max(stall, gap) }
        }
        h.window.contentView = nil
    }
    return (Stats(totals), Stats(inserts), stall)
}

func runConfig(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let part = arg("part", "all")
    let theme = Theme()
    let engines: [Engine] = Engine.parse(arg("engine", "tk1n,tk2"))

    typealias Variant = (String, (SpikeTextView) -> Void)
    let variants: [Variant] = [
        ("recommended (plain text, all substitutions off)", { _ in }),
        ("isRichText = true", { $0.isRichText = true }),
        ("allowsUndo = false", { $0.allowsUndo = false }),
        ("continuous spell checking on", { $0.isContinuousSpellCheckingEnabled = true }),
        ("spell + grammar + autocorrect on", { $0.isContinuousSpellCheckingEnabled = true; $0.isGrammarCheckingEnabled = true; $0.isAutomaticSpellingCorrectionEnabled = true }),
        ("automatic link detection on", { $0.isAutomaticLinkDetectionEnabled = true }),
        ("automatic data detection on", { $0.isAutomaticDataDetectionEnabled = true }),
        ("smart quotes + dashes + text replacement on", { $0.isAutomaticQuoteSubstitutionEnabled = true; $0.isAutomaticDashSubstitutionEnabled = true; $0.isAutomaticTextReplacementEnabled = true }),
        ("usesFindBar + incremental searching", { $0.usesFindBar = true; $0.isIncrementalSearchingEnabled = true }),
        ("usesRuler / inspector bar / font panel on", { $0.usesRuler = true; $0.usesInspectorBar = true; $0.usesFontPanel = true }),
        ("everything a stock NSTextView has on", { $0.isRichText = true; $0.isContinuousSpellCheckingEnabled = true; $0.isGrammarCheckingEnabled = true; $0.isAutomaticSpellingCorrectionEnabled = true; $0.isAutomaticLinkDetectionEnabled = true; $0.isAutomaticDataDetectionEnabled = true; $0.isAutomaticQuoteSubstitutionEnabled = true; $0.isAutomaticDashSubstitutionEnabled = true; $0.isAutomaticTextReplacementEnabled = true; $0.usesFindBar = true; $0.usesRuler = true; $0.usesFontPanel = true; $0.smartInsertDeleteEnabled = true }),
    ]

    if part == "all" || part == "typing" {
        log("### 6a. typing latency per NSTextView switch (1 MB doc, caret in first screen, 60 keystrokes; total = insertText + layout + full visible redraw; first responder set; run loop spun 4 ms between keys)")
        log("| engine | variant | total med ms | p95 | insertText med ms | max run-loop stall while spinning ms |")
        log("|---|---|---|---|---|---|")
        let text = Corpus.load("1m")
        for engine in engines {
            for (name, cfg) in variants {
                var o = HarnessOptions(); o.configure = cfg
                let r = typingBench(engine: engine, text: text, options: o, theme: theme, firstResponder: true, spinBetween: true)
                let s = r.total.sorted
                log("| \(engine.rawValue) | \(name) | \(f2(r.total.median)) | \(f2(s[Int(Double(s.count - 1) * 0.95)])) | \(f2(r.insert.median)) | \(f1(r.stall)) |")
            }
            // undo off/on separately for memory-ish evidence is in the table above
        }
    }

    if part == "all" || part == "open" {
        log("\n### 6b. open time per switch (total to first styled screen, median of 5, ms; idle = 0.5 s run-loop spin, max stall)")
        log("| corpus | engine | variant | open total med | max stall in idle ms |")
        log("|---|---|---|---|---|")
        for corpus in ["1m", "20m"] {
            let text = Corpus.load(corpus)
            for engine in engines {
                for (name, cfg) in variants {
                    var o = HarnessOptions(); o.configure = cfg
                    var tot: [Double] = [], stalls: [Double] = []
                    for _ in 0..<5 {
                        let s = measureOpen(engine: engine, text: text, mode: .stringProperty, theme: theme, styled: true, idle: 0.5, options: o)
                        tot.append(s.total); stalls.append(s.stallMs)
                    }
                    log("| \(corpus) | \(engine.rawValue) | \(name) | \(f1(Stats(Array(tot.dropFirst())).median)) | \(f1(Stats(stalls).max)) |")
                }
            }
        }
    }

    if part == "all" || part == "bg" {
        log("\n### 6c. TK1 backgroundLayoutEnabled")
        log("| corpus | engine | backgroundLayoutEnabled | open total med ms | max stall in 1 s idle ms | docH after open -> after idle |")
        log("|---|---|---|---|---|---|")
        for (corpus, eng) in [("5m", Engine.tk1c), ("5m", .tk1n), ("20m", .tk1n)] {
            let text = Corpus.load(corpus)
            for bg in [true, false] {
                var o = HarnessOptions(); o.tk1BackgroundLayout = bg
                var samples: [OpenSample] = []
                for _ in 0..<4 { samples.append(measureOpen(engine: eng, text: text, mode: .stringProperty, theme: theme, styled: true, idle: 1.0, options: o)) }
                let w = Array(samples.dropFirst())
                log("| \(corpus) | \(eng.rawValue) | \(bg) | \(f1(Stats(w.map { $0.total }).median)) | \(f1(Stats(w.map { $0.stallMs }).max)) | \(f1(w[0].docHeight)) -> \(f1(w[0].heightAfterIdle)) |")
            }
        }
    }

    if part == "all" || part == "find" {
        log("\n### 6d. find: cost of the string search NSTextFinder performs (NSString.range(of:), whole document, miss = worst case); the find pasteboard is NOT touched")
        log("| corpus | needle | options | time ms |")
        log("|---|---|---|---|")
        for corpus in ["1m", "5m", "20m"] {
            let text = Corpus.load(corpus)
            let h = Harness(engine: .tk1n)
            h.textView.string = text
            let ns = h.storage.string as NSString
            for (needle, label) in [("zzzqqq-not-present", "miss"), ("𝒳", "rare hit (non-BMP)")] {
                for (opt, oname) in [(NSString.CompareOptions([]), "literal"), (.caseInsensitive, "caseInsensitive"), ([.caseInsensitive, .diacriticInsensitive], "case+diacritic insensitive")] {
                    let t = ms { _ = ns.range(of: needle, options: opt, range: NSRange(location: 0, length: ns.length)) }
                    log("| \(corpus) | \(label) | \(oname) | \(f1(t)) |")
                }
            }
            h.window.contentView = nil
        }
        // usesFindBar flag itself
        var o = HarnessOptions(); o.configure = { $0.usesFindBar = true; $0.isIncrementalSearchingEnabled = true }
        _ = o
    }

    if part == "all" || part == "resize" {
        runResizeBench(engines: engines, theme: theme)
    }
}

/// Readable-column layout: inset computed from the clip view width. Returns the inset applied.
func applyReadableColumn(_ h: Harness, maxColumn: CGFloat = 720, minInset: CGFloat = 28, vInset: CGFloat = 16) {
    let w = h.clip.bounds.width
    let inset = max(minInset, ((w - maxColumn) / 2).rounded(.down))
    if abs(h.textView.textContainerInset.width - inset) > 0.5 {
        h.textView.textContainerInset = NSSize(width: inset, height: vInset)
    }
}

func runResizeBench(engines: [Engine], theme: Theme) {
    log("\n### 6e. window resize with a readable max column (inset computed from the clip width): per 1-pt step 900 -> 860 -> 900, ms per step (setContentSize + inset + layout visible + redraw)")
    log("| corpus | engine | position | inset update | step med | p95 | max |")
    log("|---|---|---|---|---|---|---|")
    for corpus in ["1m", "20m"] {
        let text = Corpus.load(corpus)
        let doc = Doc(text)
        for engine in engines {
            for pos in ["top", "middle"] {
                for useInset in [false, true] {
                    var samples: [Double] = []
                    autoreleasepool {
                        let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: .m1n)
                        let h = rig.h
                        if pos == "middle" {
                            let target = doc.lineStart(doc.length / 2)
                            Styler.style(doc: doc, range: doc.range(around: target, before: 80, after: 80), storage: h.storage, theme: rig.theme)
                            h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
                            h.layoutVisible()
                        }
                        if useInset { applyReadableColumn(h) }
                        var w: CGFloat = 900
                        var dir: CGFloat = -1
                        for i in 0..<80 {
                            w += dir
                            if i == 39 { dir = 1 }
                            let t0 = nowMs()
                            h.window.setContentSize(NSSize(width: w, height: 700))
                            if useInset { applyReadableColumn(h) }
                            h.layoutVisible()
                            _ = h.drawVisible()
                            samples.append(nowMs() - t0)
                        }
                        h.window.contentView = nil
                    }
                    let s = Stats(samples)
                    let sorted = s.sorted
                    log("| \(corpus) | \(engine.rawValue) | \(pos) | \(useInset ? "yes" : "no") | \(f2(s.median)) | \(f2(sorted[Int(Double(sorted.count - 1) * 0.95)])) | \(f2(s.max)) |")
                }
            }
        }
    }

    log("\n### 6f. where is the viewport after a resize? (20 MB doc, scrolled to the middle; width 900 -> 600; top visible char as fraction of the document)")
    log("| engine | before | after resize (nothing done) | after resize + anchor restore | restore ms |")
    log("|---|---|---|---|---|")
    let text = Corpus.load("20m")
    let doc = Doc(text)
    for engine in engines {
        let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: .m1n)
        let h = rig.h
        let target = doc.lineStart(doc.length / 2)
        Styler.style(doc: doc, range: doc.range(around: target, before: 80, after: 80), storage: h.storage, theme: rig.theme)
        h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        h.layoutVisible()
        h.styleViewport(doc: doc, theme: rig.theme, onlyNew: true)
        h.layoutVisible()
        let o = h.textView.textContainerOrigin
        let anchor = rig.anchorChar(at: h.visibleRect.minY + 100, origin: o)
        let yBefore = rig.yOfChar(anchor) - h.visibleRect.minY
        let fracBefore = Double(h.visibleCharRange().location) / Double(doc.length)
        h.window.setContentSize(NSSize(width: 600, height: 700))
        h.layoutVisible()
        let fracAfter = Double(h.visibleCharRange().location) / Double(doc.length)
        let t = ms {
            // restore: keep the anchor character at the same offset from the top of the clip view
            let y = rig.yOfChar(anchor) - yBefore
            h.scrollTo(y: y)
            h.layoutVisible()
        }
        let fracRestored = Double(h.visibleCharRange().location) / Double(doc.length)
        log("| \(engine.rawValue) | \(String(format: "%.5f", fracBefore)) | \(String(format: "%.5f", fracAfter)) | \(String(format: "%.5f", fracRestored)) | \(f1(t)) |")
        h.window.contentView = nil
    }
}
