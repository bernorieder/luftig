import AppKit

struct Mitigation {
    var name: String
    var uniform: Bool           // uniform (fixed) line heights + whole-doc base paragraph style
    var prestyle: Bool          // style target region BEFORE scrolling/laying out (for jumps)
    var compensate: Bool        // after lazily styling, shift the clip origin so the anchor line does not move
    var onlyNew: Bool = false   // style only not-yet-styled ranges (styled-range cache)
    var noStyle: Bool = false   // never style during the session (pure scrolling of unstyled text)
}

extension Mitigation {
    static let m0 = Mitigation(name: "M0 natural heights", uniform: false, prestyle: false, compensate: false)
    static let m0c = Mitigation(name: "M0 + anchor compensation", uniform: false, prestyle: false, compensate: true)
    static let m1 = Mitigation(name: "M1 uniform heights", uniform: true, prestyle: false, compensate: false)
    static let m1c = Mitigation(name: "M1 + compensation", uniform: true, prestyle: false, compensate: true)
    static let m1p = Mitigation(name: "M1 + pre-style target + styled-range cache", uniform: true, prestyle: true, compensate: false, onlyNew: true)
    static let m0p = Mitigation(name: "M0 + pre-style target + styled-range cache", uniform: false, prestyle: true, compensate: false, onlyNew: true)
    static let m0n = Mitigation(name: "M0 + styled-range cache", uniform: false, prestyle: false, compensate: false, onlyNew: true)
    static let m1n = Mitigation(name: "M1 + styled-range cache", uniform: true, prestyle: false, compensate: false, onlyNew: true)
    static let m0x = Mitigation(name: "M0 NO styling at all", uniform: false, prestyle: false, compensate: false, noStyle: true)
    static let m1x = Mitigation(name: "M1 NO styling at all", uniform: true, prestyle: false, compensate: false, noStyle: true)
}

func makeTheme(_ m: Mitigation) -> Theme {
    m.uniform ? Theme(uniformLineHeight: 21, uniformHeadings: true) : Theme()
}

final class ScrollRig {
    let h: Harness
    let doc: Doc
    let theme: Theme
    let mit: Mitigation

    init(engine: Engine, text: String, doc: Doc, mitigation: Mitigation, options: HarnessOptions = HarnessOptions()) {
        h = Harness(engine: engine, options: options)
        self.doc = doc
        mit = mitigation
        theme = makeTheme(mitigation)
        h.textView.font = theme.bodyFont
        h.textView.textColor = Palette.text
        h.textView.string = text
        if mitigation.uniform {
            // single-run base attributes over the whole document: fixed line height everywhere before any styling
            h.storage.beginEditing()
            h.storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: h.storage.length))
            h.storage.endEditing()
        }
        _ = h.snapshotRep
        h.layoutVisible()
        styleVis()
        h.layoutVisible()
        _ = h.drawVisible()
    }

    @discardableResult
    func styleVis() -> (NSRange, Int, Double, Double) {
        if mit.noStyle { return (NSRange(location: 0, length: 0), 0, 0, 0) }
        return h.styleViewport(doc: doc, theme: theme, onlyNew: mit.onlyNew)
    }

    deinit { h.window.contentView = nil }

    /// y (view coordinates) of a character's line, engine independent.
    func yOfChar(_ idx: Int) -> CGFloat {
        let len = max(0, min(1, h.storage.length - idx))
        let sr = h.textView.firstRect(forCharacterRange: NSRange(location: idx, length: len), actualRange: nil)
        let wr = h.window.convertFromScreen(sr)
        let vr = h.textView.convert(wr, from: nil)
        return vr.minY
    }

    var thumb: Double { h.scroll.verticalScroller?.doubleValue ?? -1 }
    var knob: Double { Double(h.scroll.verticalScroller?.knobProportion ?? -1) }
    var charFraction: Double {
        let r = h.visibleCharRange()
        return Double(r.location) / Double(max(1, doc.length))
    }

    /// A character in the middle of a line (never a line-boundary insertion point, which is ambiguous between two lines).
    func anchorChar(at y: CGFloat, origin o: NSPoint) -> Int {
        let i = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 40, y: y))
        return min(max(0, i), max(0, h.storage.length - 1))
    }

    var debugSteps = false

    struct Step {
        var ms = 0.0
        var hBefore = 0.0, hAfter = 0.0
        var jump = 0.0           // visual displacement of the anchor vs intended scroll (points)
        var clamped = false
        var thumbDelta = 0.0
    }

    /// One user scroll step of `dy` points followed by lazy styling of the viewport and a redraw.
    func step(dy: CGFloat) -> Step {
        var s = Step()
        let o = h.textView.textContainerOrigin
        let vis0 = h.visibleRect
        let anchor = anchorChar(at: vis0.midY + dy / 2, origin: o)   // stays well inside the clip after the scroll
        let yA0 = yOfChar(anchor)
        s.hBefore = h.docHeight
        let thumb0 = thumb
        let t0 = nowMs()
        h.scrollTo(y: vis0.minY + dy)
        let vis1 = h.visibleRect
        s.clamped = (dy < 0 && vis0.minY < 0.5) || (dy > 0 && vis0.maxY > h.docHeight - 0.5)   // at a document limit: nothing to measure
        h.layoutVisible()
        let yAfterScroll = yOfChar(anchor)
        let (_, nRuns, _, _) = styleVis()
        h.layoutVisible()
        if debugSteps { log("      anchor y: before=\(f1(yA0)) afterScrollLayout=\(f1(yAfterScroll)) afterStyle=\(f1(yOfChar(anchor))) runs=\(nRuns) clipY=\(f1(h.visibleRect.minY))") }
        if mit.compensate {
            let yA1 = yOfChar(anchor)
            // intended: the anchor keeps its view-space y (the clip moved by dy); any displacement is due to re-layout
            let delta = yA1 - yA0
            if abs(delta) > 0.5 && !s.clamped {
                h.scrollTo(y: h.visibleRect.minY + delta)
                h.layoutVisible()
            }
        }
        _ = h.drawVisible()
        s.ms = nowMs() - t0
        let vis2 = h.visibleRect
        let yA1 = yOfChar(anchor)
        s.hAfter = h.docHeight
        // anchor position inside the clip, before vs after, compared with the intended motion dy
        let p0 = yA0 - vis0.minY
        let p1 = yA1 - vis2.minY
        s.jump = p1 - (p0 - dy)
        s.thumbDelta = thumb - thumb0
        return s
    }
}

func scrollSummary(_ steps: [ScrollRig.Step]) -> (stepMed: Double, stepP95: Double, stepMax: Double, maxDH: Double, maxJump: Double, jumpSteps: Int, n: Int, hDrift: Double, thumbMin: Double, thumbMax: Double, thumbNonMono: Int) {
    let valid = steps.filter { !$0.clamped }
    let ms = Stats(valid.map { $0.ms })
    let sorted = ms.sorted
    let p95 = sorted.isEmpty ? .nan : sorted[Int(Double(sorted.count - 1) * 0.95)]
    let maxDH = valid.map { abs($0.hAfter - $0.hBefore) }.max() ?? 0
    let maxJump = valid.map { abs($0.jump) }.max() ?? 0
    let jumpSteps = valid.filter { abs($0.jump) > 0.5 }.count
    let hDrift = (steps.last?.hAfter ?? 0) - (steps.first?.hBefore ?? 0)
    let td = valid.map { $0.thumbDelta }
    return (ms.median, p95, ms.max, maxDH, maxJump, jumpSteps, valid.count, hDrift, td.min() ?? 0, td.max() ?? 0, 0)
}

struct JumpResult {
    var callMs = 0.0, settleMs = 0.0
    var topFraction = 0.0            // char fraction of the first visible char after settling
    var targetVisible = false
    var atBottom = false             // clip bottom == doc bottom
    var lastLineVisible = false
    var hChange = 0.0                // doc height change across the jump (before vs after settle)
    var reflowShift = 0.0            // anchor displacement caused by lazy styling after landing
    var passes = 1
    var thumb = 0.0
}

func runScroll(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "tk1n,tk2"))
    let corpora = arg("corpus", "5m,20m").split(separator: ",").map(String.init)
    let steps = Int(arg("steps", "100"))!
    let part = arg("part", "all")
    let mitNames = arg("mit", "m0,m0c,m1,m1c")
    let mitMap: [String: Mitigation] = ["m0": .m0, "m0c": .m0c, "m1": .m1, "m1c": .m1c, "m1p": .m1p, "m0p": .m0p, "m0n": .m0n, "m1n": .m1n, "m0x": .m0x, "m1x": .m1x]
    let mits = mitNames.split(separator: ",").compactMap { mitMap[String($0)] }

    for corpus in corpora {
        let text = Corpus.load(corpus)
        let doc = Doc(text)
        let n = doc.length

        if part == "all" || part == "steps" {
            log("\n#### scroll steps, corpus \(corpus) (\(n) UTF-16 units); step = 350 pt (half a page); lazily style visible +/- 60 lines each step")
            log("| engine | mitigation | scenario | step ms med / p95 / max | max |ΔH| per step (pt) | H drift over session (pt) | max visual jump (pt) | steps with jump > 0.5 pt | thumb Δ min / max per step |")
            log("|---|---|---|---|---|---|---|---|---|")
            for engine in engines {
                for mit in mits {
                    for scenario in ["down from top", "up from end"] {
                        Watchdog.arm(seconds: 400, label: "scroll steps \(engine.rawValue) \(corpus) \(mit.name) \(scenario)")
                        autoreleasepool {
                            let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: mit)
                            rig.debugSteps = rest.contains("--debug")
                            var dy: CGFloat = 350
                            if scenario == "up from end" {
                                dy = -350
                                rig.h.textView.scrollRangeToVisible(NSRange(location: n, length: 0))
                                rig.h.layoutVisible()
                                rig.styleVis()
                                rig.h.layoutVisible()
                                // settle: second pass (Cmd-Down twice) so we really are at the end
                                rig.h.textView.scrollRangeToVisible(NSRange(location: n, length: 0))
                                rig.h.layoutVisible()
                                _ = rig.h.drawVisible()
                            }
                            var all: [ScrollRig.Step] = []
                            for i in 0..<steps {
                                let st = rig.step(dy: dy)
                                all.append(st)
                                if rest.contains("--debug") && i < 14 { log("   step \(i): ms=\(f1(st.ms)) H \(f1(st.hBefore)) -> \(f1(st.hAfter)) jump=\(f1(st.jump)) clamped=\(st.clamped) clip=\(f1(rig.h.visibleRect.minY)) thumb=\(String(format: "%.4f", rig.thumb))") }
                            }
                            let s = scrollSummary(all)
                            log("| \(engine.rawValue) | \(mit.name) | \(scenario) | \(f2(s.stepMed)) / \(f2(s.stepP95)) / \(f2(s.stepMax)) | \(f1(s.maxDH)) | \(f1(s.hDrift)) | \(f1(s.maxJump)) | \(s.jumpSteps)/\(s.n) | \(String(format: "%.5f / %.5f", s.thumbMin, s.thumbMax)) |")
                        }
                        Watchdog.disarm()
                    }
                }
            }
        }

        if part == "all" || part == "jumps" {
            log("\n#### jumps, corpus \(corpus)")
            log("| engine | mitigation | jump | call ms | settle ms | target visible | at bottom | last line visible | top char fraction | thumb | ΔH across jump (pt) | reflow shift after styling (pt) | passes needed |")
            log("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
            for engine in engines {
                for mit in mits where mit.compensate == false {
                    for jumpName in ["Cmd-Down (scrollRangeToVisible end)", "Cmd-Down (moveToEndOfDocument)", "jump to middle (scrollRangeToVisible)", "jump to middle (thumb drag y = H/2)", "jump to 25% (scrollRangeToVisible)"] where arg("only", "").isEmpty || jumpName.contains(arg("only", "")) {
                        Watchdog.arm(seconds: 400, label: "jump \(engine.rawValue) \(corpus) \(mit.name) \(jumpName)")
                        autoreleasepool {
                            let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: mit)
                            let h = rig.h
                            var r = JumpResult()
                            let isEnd = jumpName.contains("Cmd-Down")
                            let target: Int
                            if isEnd { target = n }
                            else if jumpName.contains("25%") { target = doc.lineStart(n / 4) }
                            else { target = doc.lineStart(n / 2) }
                            let hBefore = h.docHeight
                            if mit.prestyle {
                                // style the target region first (no layout involved: purely attribute application)
                                let rg = doc.range(around: min(target, max(0, n - 1)), before: 80, after: 80)
                                Styler.style(doc: doc, range: rg, storage: h.storage, theme: rig.theme)
                                h.styledSet.formUnion(IndexSet(integersIn: rg.location..<NSMaxRange(rg)))
                            }
                            let t0 = nowMs()
                            if jumpName.contains("moveToEndOfDocument") {
                                h.textView.moveToEndOfDocument(nil)
                            } else if jumpName.contains("thumb drag") {
                                h.scrollTo(y: (h.docHeight - h.visibleRect.height) * 0.5)
                            } else {
                                h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
                            }
                            h.layoutVisible()
                            r.callMs = nowMs() - t0
                            // settle: lazily style what is visible, re-layout; measure how much the anchor moved because of styling
                            let t1 = nowMs()
                            let o = h.textView.textContainerOrigin
                            let anchor = rig.anchorChar(at: h.visibleRect.midY, origin: o)
                            let yA0 = rig.yOfChar(anchor) - h.visibleRect.minY
                            rig.styleVis()
                            h.layoutVisible()
                            let yA1 = rig.yOfChar(anchor) - h.visibleRect.minY
                            r.reflowShift = yA1 - yA0
                            // passes: repeat the jump until the target is really visible / bottom reached
                            var passes = 1
                            func targetVisible() -> Bool {
                                if jumpName.contains("thumb drag") { return true }
                                let vr = h.visibleCharRange()
                                return target >= vr.location - 100 && target <= NSMaxRange(vr) + 100
                            }
                            func atBottom() -> Bool { h.visibleRect.maxY >= h.docHeight - 1 }
                            while passes < 4 && ((isEnd && !atBottom()) || (!isEnd && !targetVisible())) {
                                h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
                                h.layoutVisible()
                                rig.styleVis()
                                h.layoutVisible()
                                passes += 1
                            }
                            _ = h.drawVisible()
                            r.settleMs = nowMs() - t1
                            r.passes = passes
                            r.targetVisible = targetVisible()
                            r.atBottom = atBottom()
                            // is the last character's line fully inside the visible rect?
                            let lastY = rig.yOfChar(max(0, n - 1))
                            r.lastLineVisible = lastY >= h.visibleRect.minY && lastY <= h.visibleRect.maxY
                            r.topFraction = rig.charFraction
                            r.thumb = rig.thumb
                            r.hChange = h.docHeight - hBefore
                            log("| \(engine.rawValue) | \(mit.name) | \(jumpName) | \(f1(r.callMs)) | \(f1(r.settleMs)) | \(r.targetVisible) | \(r.atBottom) | \(r.lastLineVisible) | \(String(format: "%.3f", r.topFraction)) | \(String(format: "%.3f", r.thumb)) | \(f1(r.hChange)) | \(f1(r.reflowShift)) | \(r.passes) |")
                        }
                        Watchdog.disarm()
                    }
                }
            }
        }
    }
}

/// Ground truth document heights: style everything, lay out everything, compare with the estimate at open.
func runTruth(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "tk1n,tk2"))
    let corpora = arg("corpus", "1m,5m").split(separator: ",").map(String.init)
    let mits: [Mitigation] = [.m0, .m1]
    log("| corpus | engine | mitigation | H at open (estimate, first screen styled) | H after full style + full layout (truth) | estimate error | full layout time s |")
    log("|---|---|---|---|---|---|---|")
    for corpus in corpora {
        let text = Corpus.load(corpus)
        let doc = Doc(text)
        for engine in engines {
            for mit in mits {
                Watchdog.arm(seconds: 600, label: "truth \(corpus) \(engine.rawValue) \(mit.name)")
                autoreleasepool {
                    let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: mit)
                    let h = rig.h
                    let hOpen = h.docHeight
                    let runs = doc.lex(NSRange(location: 0, length: doc.length))
                    Styler.apply(runs, to: h.storage, theme: rig.theme)
                    let t0 = nowMs()
                    if let lm = h.layoutManager1 { lm.ensureLayout(for: h.container) }
                    else if let tlm = h.textLayoutManager2 { tlm.ensureLayout(for: tlm.documentRange) }
                    h.layoutVisible()
                    let dt = (nowMs() - t0) / 1000
                    let truth = h.docHeight
                    log("| \(corpus) | \(engine.rawValue) | \(mit.name) | \(f1(hOpen)) | \(f1(truth)) | \(String(format: "%+.1f%%", (hOpen - truth) / truth * 100)) | \(f1(dt)) |")
                }
                Watchdog.disarm()
            }
        }
    }
}
