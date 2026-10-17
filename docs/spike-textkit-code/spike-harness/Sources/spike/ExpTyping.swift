import AppKit

/// Jump the view to `charLoc` (what Cmd-Down / a find-result / jump would do), then settle: layout, lazy style, layout, draw.
func jump(_ h: Harness, to charLoc: Int, doc: Doc, theme: Theme) -> (jumpMs: Double, styleMs: Double, settleMs: Double) {
    let t0 = nowMs()
    h.textView.scrollRangeToVisible(NSRange(location: charLoc, length: 0))
    h.layoutVisible()
    let t1 = nowMs()
    h.styleViewport(doc: doc, theme: theme)
    h.layoutVisible()
    let t2 = nowMs()
    h.textView.scrollRangeToVisible(NSRange(location: charLoc, length: 0))
    h.layoutVisible()
    _ = h.drawVisible()
    let t3 = nowMs()
    return (t1 - t0, t2 - t1, t3 - t2)
}

struct KeySample {
    var insert = 0.0, restyle = 0.0, layout = 0.0, draw = 0.0, dirtyDraw = 0.0
    var total: Double { insert + layout + draw }   // restyle is inside insert
}

func runTyping(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "all"))
    let corpora = arg("corpus", "1m,20m").split(separator: ",").map(String.init)
    let positions = arg("pos", "start,middle,end").split(separator: ",").map(String.init)
    let keys = Int(arg("keys", "60"))!
    let theme = Theme()
    let restyleModes: [Bool] = arg("restyle", "1") == "both" ? [false, true] : [arg("restyle", "1") == "1"]

    log("### typing latency (ms per keystroke; N=\(keys) after 10 warm-up keystrokes; total = insertText(incl. restyle) + layoutVisible + cacheDisplay(visible)) ")
    log("| corpus | engine | position | restyle | navigation to position (jump / style / settle ms) | total med | p95 | max | insertText med | of which restyle med | layout med | draw (cacheDisplay) med | dirty-rect draw (displayIfNeeded) med |")
    log("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for corpus in corpora {
        let text = Corpus.load(corpus)
        let doc = Doc(text)
        for engine in engines {
            for pos in positions {
                for restyle in restyleModes {
                    Watchdog.arm(seconds: 240, label: "typing \(corpus) \(engine.rawValue) \(pos)")
                    autoreleasepool {
                        let h = Harness(engine: engine)
                        let hc = HighlightController(theme: theme)
                        h.storage.delegate = hc
                        hc.enabled = false      // no restyle while loading
                        h.textView.font = theme.bodyFont
                        h.textView.textColor = Palette.text
                        h.textView.string = text
                        _ = h.snapshotRep
                        h.layoutVisible()
                        var target = 0
                        switch pos {
                        case "start": target = doc.lineStart(min(400, doc.length))
                        case "middle": target = doc.lineStart(doc.length / 2)
                        default: target = max(0, doc.lineStart(doc.length - 3000))
                        }
                        let nav = jump(h, to: target, doc: doc, theme: theme)
                        // put the caret on a line in the middle of the visible area
                        let r = h.visibleRect
                        let o = h.textView.textContainerOrigin
                        var idx = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 60, y: r.midY))
                        if pos == "end" { idx = max(0, doc.length - 20) }
                        h.textView.setSelectedRange(NSRange(location: idx, length: 0))
                        hc.enabled = restyle
                        var samples: [KeySample] = []
                        let chars = Array("the quick brown fox jumps over the lazy dog 0123456789 `code` **bold** ")
                        for k in 0..<(keys + 10) {
                            var s = KeySample()
                            let ch = String(chars[k % chars.count])
                            hc.restyleMs = 0
                            s.insert = ms { h.textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                            s.restyle = hc.restyleMs
                            s.layout = ms { h.layoutVisible() }
                            s.draw = h.drawVisible()
                            h.textView.setNeedsDisplay(h.textView.visibleRect)
                            s.dirtyDraw = ms { h.textView.displayIfNeeded() }
                            if k >= 10 { samples.append(s) }
                        }
                        let tot = Stats(samples.map { $0.total })
                        let sorted = tot.sorted
                        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                        func med(_ kp: (KeySample) -> Double) -> String { f2(Stats(samples.map(kp)).median) }
                        log("| \(corpus) | \(engine.rawValue) | \(pos) | \(restyle ? "yes" : "no") | \(f1(nav.jumpMs)) / \(f1(nav.styleMs)) / \(f1(nav.settleMs)) | **\(f2(tot.median))** | \(f2(p95)) | \(f2(tot.max)) | \(med { $0.insert }) | \(med { $0.restyle }) | \(med { $0.layout }) | \(med { $0.draw }) | \(med { $0.dirtyDraw }) |")
                        h.window.contentView = nil
                    }
                    Watchdog.disarm()
                }
            }
        }
    }
}
