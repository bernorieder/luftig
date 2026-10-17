#if LUFTIG_SELFTEST
// SelfTestFixScroll.swift - scrolling in a full-screen-sized window, driven the way a trackpad drives it (fix-scroll, fix-scroll-bench).
// (The user reported "in full screen mode, scrolling is sometimes very choppy and then suddenly smooth again". This is the measurement that looked for it and
// the guard that keeps scrolling where it was measured; the stall itself was not reproduced headless, see docs/ARCHITECTURE.md, section 7.)
//
//   luftig-SelfTest --selftest fix-scroll-bench --input f.md [--size 1512x982] [--fonts default|fira|serif] [--step 30] [--events 500] [--display strip|full|none]
//                                               [--pace 8.33] [--passes 2] [--label L] [--sample-wait]
//
// The REAL stack: an EditorWindowController window of the given content size (1512 x 982 pt is a MacBook's native full screen; 2056 x 1329 a bigger
// display) at the backing scale of this machine, the real editor, the real NSScrollView, scrolled by `scrollWheel:` events (a CGEvent with pixel
// deltas, converted to an NSEvent: `hasPreciseScrollingDeltas`, like a trackpad's; no scroll phase, see `fixScrollPass`) at 120 Hz, so the clip view's bounds notification, the LazyStyler, the
// layout of what scrolls in and the drawing run as they do for a user. Every step is timed on the main thread INCLUDING its display pass (the headless
// process cannot display a window: the display pass is `cacheDisplay` of the strip of rows the step exposed, which is what AppKit draws after it moved the
// rest of the pixels; `--display full` draws the whole visible rect every step, an upper bound). Between two steps the run loop turns (idle work, background
// layout, our own async restyles run there); a step that starts later than scheduled is blocked by something else on the main thread: reported as `late`.
//
// A pass over text that was never laid out is COLD, the second pass over the same text WARM.

import AppKit
import MarkdownKit

extension SelfTestScenarios {

    static let fixScrollScenarios: [SelfTest.Scenario] = [
        .init(name: "fix-scroll-bench", summary: "(measurement) trackpad-style scrolling in a full-screen-sized window: --input f.md [--size WxH] [--fonts default|fira|serif] [--step N] [--events N] [--display strip|full|none] [--pace ms] [--passes N]",
              run: { t in try await fixScrollBench(t) }, inAll: false),
        .init(name: "fix-scroll", summary: "REGRESSION GUARD: scrolling a real-size document in a full-screen-sized window (default fonts, Fira Code, a serif font): per-step budgets, no stall while scrolling over fresh text; skipped on a loaded machine",
              run: { t in try await fixScroll(t) }),
        .init(name: "fix-scroll-path", summary: "REGRESSION GUARD: the editor opts out of responsive scrolling (NSScrollView agrees), so a trackpad scroll takes the synchronous path that fix-scroll measures; a stock NSTextView opts in",
              run: { t in try await fixScrollPath(t) }),
        .init(name: "fix-probe-overdraw", summary: "(probe) what AppKit's responsive-scrolling overdraw costs over fresh text in a full-screen-sized window: prepareContent(in:) of 1-2 screens ahead, the restyle on arrival, and the same with the text styled first: [--input f.md] [--fonts default|fira|serif]",
              run: { t in try await fixProbeOverdraw(t) }, inAll: false),
    ]

    // MARK: responsive scrolling

    /// NSScrollView's own verdict (a private method, read here in the self-test only): does this scroll view qualify for concurrent (responsive) scrolling?
    /// nil when this macOS has no such method.
    @MainActor static func concurrentScrollingCompatible(_ sv: NSScrollView) -> Bool? {
        let sel = NSSelectorFromString("_isConcurrentScrollingCompatible")
        guard sv.responds(to: sel) else { return nil }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(sv.method(for: sel), to: F.self)(sv, sel)
    }

    @MainActor static func fixScrollPath(_ t: SelfTest.T) async throws {
        t.check(!LuftigEditorTextView.isCompatibleWithResponsiveScrolling, "LuftigEditorTextView opts out of responsive scrolling")
        t.check(NSTextView.isCompatibleWithResponsiveScrolling, "a stock NSTextView opts in (the override is what makes the difference)")
        let (doc, host, _) = try await openEditor(t, text: String(repeating: "# Heading\n\nSome text.\n\n", count: 300), name: "scroll-path.md")
        defer { t.close(doc) }
        // the control: the same stack with a stock NSTextView qualifies, so NSScrollView's verdict is meaningful
        let control = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        control.documentView = NSTextView(frame: control.bounds)
        guard let stock = concurrentScrollingCompatible(control), let ours = concurrentScrollingCompatible(host.scrollView) else {
            t.note("NSScrollView has no _isConcurrentScrollingCompatible on this macOS: only the class property is checked"); return
        }
        t.check(stock, "control: NSScrollView finds a stock NSTextView compatible with concurrent scrolling")
        t.check(!ours, "the editor's scroll view: NSScrollView finds it NOT compatible with concurrent scrolling (trackpad scrolls take the synchronous path)")
        // the public side of it: nothing beyond the visible rect is ever prepared
        host.textView.layoutSubtreeIfNeeded()
        host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 500)); host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        await t.spin(30)
        let prepared = host.textView.preparedContentRect, visible = host.textView.visibleRect
        t.check(prepared.isEmpty || prepared.height <= visible.height + 0.5, "preparedContentRect \(NSStringFromRect(prepared)) is no larger than the visible rect \(NSStringFromRect(visible))")
    }

    /// Simulates what the responsive-scrolling path does to the editor, headless (AppKit's scroll thread cannot run here, but `prepareContent(in:)` is
    /// NSTextView's own and can be called with the overdraw rect AppKit would hand it): at three fresh places of a document, the cost of
    /// (1) the synchronous path: style the screen that arrived, lay it out once; (2) the overdraw path: lay out 1 / 2 screens ahead unstyled, then on
    /// arrival restyle and lay out again; (3) the overdraw path with the text styled first. Prints ms, characters laid out unstyled, height revisions.
    @MainActor static func fixProbeOverdraw(_ t: SelfTest.T) async throws {
        let input = SelfTest.argument("input").map { URL(fileURLWithPath: $0) } ?? t.corpusFile(bytes: 1_000_000, seed: 5)
        let fonts = SelfTest.argument("fonts") ?? "default"
        try await preservingSettings {
            fixScrollApplyFonts(fonts)
            let clone = try PerfLab.clone(t, input.path, as: "overdraw.md")
            let r = try await perfOpenOnce(clone, width: 1512, height: 982)
            guard let host = r.doc.host as? EditorViewController, let window = host.view.window else { throw NSError(domain: "overdraw", code: 1) }
            defer { t.close(r.doc) }
            window.setContentSize(NSSize(width: 1512, height: 982)); window.contentView?.layoutSubtreeIfNeeded()
            let sv = host.scrollView, tv = host.textView, clip = sv.contentView
            guard let lm = tv.layoutManager, let tc = tv.textContainer, let ts = tv.textStorage else { return }
            out("OVERDRAW \(fonts): LuftigEditorTextView.isCompatibleWithResponsiveScrolling = \(LuftigEditorTextView.isCompatibleWithResponsiveScrolling); NSScrollView: concurrent scrolling compatible = \(concurrentScrollingCompatible(sv).map { "\($0)" } ?? "unknown"); text \(ts.length) chars, window \(Int(host.view.bounds.width)) x \(Int(host.view.bounds.height)) pt")
            let defaultMargin = host.styler.marginLines
            @MainActor func goto(_ frac: Double) { clip.scroll(to: NSPoint(x: 0, y: (tv.frame.height * frac).rounded())); sv.reflectScrolledClipView(clip) }
            @MainActor func heightRevisions(_ body: () -> Void) -> (ms: Double, revised: Double) {
                let h0 = tv.frame.height
                let ms = perfMs(body)
                return (ms, Double(tv.frame.height - h0))
            }
            // nine fresh places, three per variant, interleaved so that no variant gets the easier text
            let places: [Double] = [0.12, 0.15, 0.18, 0.42, 0.45, 0.48, 0.72, 0.75, 0.78]
            for (i, frac) in places.enumerated() {
                let variant = i % 3
                goto(frac)
                let vis = tv.visibleRect
                let origin = tv.textContainerOrigin
                switch variant {
                case 0:
                    // (1) the synchronous path: a screen arrives (the clip view's bounds notification styles it + the margin), it is laid out once
                    let a = heightRevisions { goto(frac + 0.001); perfLayoutVisible(host) }
                    out(String(format: "OVERDRAW   at %.0f%%: synchronous path, one screen: scroll (styles) + layout %.2f ms, height revised by %.0f pt", frac * 100, a.ms, a.revised))
                default:
                    for factor in [1.0, 2.0] {
                        goto(frac + Double(factor) * 0.001)
                        let v = tv.visibleRect
                        perfLayoutVisible(host)                                                               // the screen itself is styled and laid out: only the overdraw is fresh
                        let over = NSRect(x: v.minX, y: v.minY, width: v.width, height: v.height * (1 + factor))
                        var styledFirst = (ms: 0.0, revised: 0.0)
                        if variant == 2 {
                            // (3) style the overdraw first (what a look-ahead would do): the margin is widened to cover `factor` screens below
                            host.styler.marginLines = defaultMargin + Int((v.height * factor) / 18)       // (18 pt per line: a rough line count for `factor` screens)
                            styledFirst = heightRevisions { host.styler.prestyle(aroundCharacter: NSMaxRange(host.styler.visibleCharacterRange(tv)) - 1) }
                            host.styler.marginLines = defaultMargin
                        }
                        let prep = heightRevisions { tv.prepareContent(in: over) }
                        // what the overdraw laid out below the visible rect, and how much of it had no styling
                        let strip = NSRect(x: 0, y: v.maxY - origin.y, width: tc.size.width, height: v.height * factor)
                        let g = lm.glyphRange(forBoundingRect: strip, in: tc)
                        let cr = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                        var unstyled = IndexSet(integersIn: cr.location..<NSMaxRange(cr)); unstyled.subtract(host.styler.styled)
                        // the user scrolls one screen into the prepared area: the bounds notification styles it, the layout is redone where attributes changed
                        let arrive = heightRevisions { clip.scroll(to: NSPoint(x: 0, y: v.minY + v.height)); sv.reflectScrolledClipView(clip); perfLayoutVisible(host) }
                        let laidOutAgain = (vis.height > 0) ? lm.glyphRange(forBoundingRect: tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc).length : 0
                        out(String(format: "OVERDRAW   at %.0f%%: overdraw of %.0f screen(s) ahead%@: prepareContent %.2f ms (height revised by %.0f pt; %d chars laid out below the screen, %d of them unstyled)%@; then arriving one screen down: restyle + layout %.2f ms (height revised by %.0f pt; %d glyphs on screen)",
                                   frac * 100, factor, variant == 2 ? ", text styled first" : "", prep.ms, prep.revised, cr.length, unstyled.count,
                                   variant == 2 ? String(format: " [styling %d screen(s) ahead first: %.2f ms, height revised by %.0f pt]", Int(factor), styledFirst.ms, styledFirst.revised) : "",
                                   arrive.ms, arrive.revised, laidOutAgain))
                    }
                }
            }
            t.check(true, "probe ran")
        }
    }

    // MARK: scroll events

    /// A trackpad scroll event: pixel deltas, with the scroll phase (and the momentum phase after the fingers lifted). dy < 0 scrolls DOWN through the document.
    @MainActor static func fixScrollEvent(dy: Double, phase: Int, momentum: Int) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))         // 1 began, 2 changed, 4 ended
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))    // 1 begin, 2 continue, 3 end
        return NSEvent(cgEvent: cg)
    }

    struct FixScrollCase {
        var label = "case"
        var url: URL
        var size = NSSize(width: 1512, height: 982)
        var fonts = "default"                  // default | fira | serif
        var step = 30.0                        // points per event (a slow swipe ~10, a flick ~60)
        var events = 500
        var display = "layer"                  // layer | strip | full | none
        var pace = 1000.0 / 120.0              // ms between events
        var passes = 2
    }

    struct FixScrollStep {
        var index = 0
        var y = 0.0
        var work = 0.0                         // scroll event + display, ms
        var scroll = 0.0                       // the scrollWheel call (bounds change -> styleVisible -> layout)
        var layout = 0.0                       // ensureLayout of what is visible after the step
        var draw = 0.0
        var late = 0.0                         // how long after its time the step could start (the main thread was busy with something else)
        var cpu = 0.0                          // thread CPU time of the step, ms: wall >> cpu means the thread was descheduled or waiting, not computing
        var drawnPoints = 0.0                  // display "layer": area AppKit asked the text view to draw in this step, in points^2 / 1000
        var drawnRects = 0
        var heightChanged = false              // the text view's frame height changed in this step
        var moved = 0.0                        // how far the clip view really moved (the event asked for `step`): a difference is TextKit re-estimating heights
        var docHeight = 0.0                    // the text view's height after the step (non-contiguous layout refines it as text is laid out)
        var probe = LazyStyler.Probe()
    }

    /// Rects (count, area) the text view was asked to draw since the pass began (display "layer").
    nonisolated(unsafe) static var fixScrollDrawn: (points: Double, rects: Int) = (0, 0)

    struct FixScrollPass {
        var steps: [FixScrollStep] = []
        var work: [Double] { steps.map { $0.work } }
        var latency: [Double] { steps.map { $0.late + $0.work } }
    }

    @MainActor static func fixScrollApplyFonts(_ fonts: String) {
        let P = EditorPreferences.self
        switch fonts {
        case "fira":
            let fira = FontFactory.resolve("Fira Code") != nil ? "Fira Code" : (anyFamily(monospaced: true) ?? "Menlo")
            P.colorSchemeID = "github-dark"; P.bodyFontFamily = fira; P.codeFontFamily = fira; P.fontSize = 14; P.lineHeightFactor = 1.1
        case "serif":
            P.bodyFontFamily = installedFamilies(["Georgia", "Times", "Palatino"]).first ?? anyFamily(); P.fontSize = 16
        default: break
        }
    }

    /// One pass: `events` scroll steps down from the current position (a swipe: began, changed ..., ended, then momentum is not simulated beyond the last
    /// delta). The steps are paced at `pace` ms with the run loop turning between them.
    @MainActor static func fixScrollPass(_ t: SelfTest.T, host: EditorViewController, window: NSWindow, c: FixScrollCase) async -> FixScrollPass {
        let sv = host.scrollView, tv = host.textView
        var result = FixScrollPass()
        result.steps.reserveCapacity(c.events)
        if c.display == "layer" {
            window.contentView?.wantsLayer = true                                   // as in a displayed window: AppKit layer-backs the hierarchy
            LuftigEditorTextView.drawLog = { r in fixScrollDrawn.points += Double(r.width * r.height); fixScrollDrawn.rects += 1 }
            window.contentView?.layoutSubtreeIfNeeded()
            // a window that is on a Retina screen backs its layers at 2x; this one is on no screen and would draw at 1x (a quarter of the pixels)
            let scale = window.backingScaleFactor
            for layer in [tv.layer, sv.layer, sv.contentView.layer] { layer?.contentsScale = scale }
            tv.layer?.setNeedsDisplay()
            tv.layer?.displayIfNeeded(); sv.layer?.displayIfNeeded()                 // the first screen
            fixScrollDrawn = (0, 0)
        }
        defer { LuftigEditorTextView.drawLog = nil }
        var lastHeight = Double(tv.frame.height)
        let t0 = SelfTest.nowMs()
        let deltas = c.events
        for i in 0..<deltas {
            // wait for the schedule (the run loop runs: timers, async blocks, background layout)
            let due = t0 + Double(i) * c.pace
            while SelfTest.nowMs() < due - 0.3 { try? await Task.sleep(nanoseconds: 300_000) }
            let started = SelfTest.nowMs()
            let before = tv.visibleRect
            // (events WITH a scroll phase cannot be driven here: AppKit's gesture machinery takes the first `began` event asynchronously and drops the `changed`
            // events that follow in a process without a window server session; phase-less pixel-delta events run the same scrollWheel: -> clip view ->
            // bounds notification -> styling -> layout -> display path synchronously. fix-probe-scroll shows both.)
            guard let ev = fixScrollEvent(dy: -c.step, phase: 0, momentum: 0) else { t.check(false, "could not make a scroll event"); return result }
            LazyStyler.probe.reset()
            let cpu0 = Self.threadCPUms()
            let a = SelfTest.nowMs()
            sv.scrollWheel(with: ev)
            let b = SelfTest.nowMs()
            _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
            let l = SelfTest.nowMs()
            let drawnBefore = fixScrollDrawn
            switch c.display {
            case "none": break
            case "layer":
                // AppKit's OWN display cycle for a layer-backed text view (the window is never on screen, so the layer is told to display itself): the rects it
                // draws are what it decided to invalidate after the scroll step, the drawing goes into the layer's backing store like a displayed window's
                tv.layer?.displayIfNeeded()
                sv.layer?.displayIfNeeded(); sv.contentView.layer?.displayIfNeeded()
            case "full": perfDrawRect(sv, sv.bounds)
            default:
                let after = tv.visibleRect
                var strip = after
                if after.minY > before.minY { strip.origin.y = max(before.maxY, after.minY); strip.size.height = after.maxY - strip.origin.y }
                else { strip.size.height = max(0, before.minY - after.minY) }
                if strip.height > 0 { perfDrawRect(sv, sv.convert(strip, from: tv)) }
            }
            let d = SelfTest.nowMs()
            var s = FixScrollStep()
            s.cpu = Self.threadCPUms() - cpu0
            s.drawnPoints = (fixScrollDrawn.points - drawnBefore.points) / 1000; s.drawnRects = fixScrollDrawn.rects - drawnBefore.rects
            s.heightChanged = abs(Double(tv.frame.height) - lastHeight) > 0.5; lastHeight = Double(tv.frame.height)
            s.moved = Double(tv.visibleRect.minY - before.minY); s.docHeight = Double(tv.frame.height)
            s.index = i; s.y = Double(tv.visibleRect.minY); s.work = d - a; s.scroll = b - a; s.layout = l - b; s.draw = d - l; s.late = max(0, started - due); s.probe = LazyStyler.probe
            result.steps.append(s)
            _ = before
        }
        return result
    }

    /// CPU time consumed by the calling thread so far, ms.
    static func threadCPUms() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1e6
    }

    @MainActor static func perfDrawRect(_ view: NSView, _ rect: NSRect) {
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
    }

    /// The step the pass asked for (the mode of the distances actually moved).
    static func stepOf(_ pass: FixScrollPass) -> Double {
        var counts: [Int: Int] = [:]
        for s in pass.steps.dropFirst() { counts[Int(s.moved.rounded()), default: 0] += 1 }
        return Double(counts.max { $0.value < $1.value }?.key ?? 0)
    }

    static func fixScrollSummary(_ label: String, _ pass: FixScrollPass) -> String {
        let w = PerfLab.stat(pass.work)
        func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))] }
        let work = pass.work, lat = pass.latency
        let over83 = work.filter { $0 > 8.3 }.count, over166 = work.filter { $0 > 16.6 }.count, over333 = work.filter { $0 > 33.3 }.count
        let l83 = lat.filter { $0 > 8.3 }.count, l166 = lat.filter { $0 > 16.6 }.count
        let slow = pass.steps.filter { $0.work > 8.3 }
        let visibleArea = 1512.0 * 982.0 / 1000
        let fullRedraws = pass.steps.filter { $0.drawnPoints > 0.6 * visibleArea }.count
        let hc = pass.steps.filter { $0.heightChanged }
        let hcFull = hc.filter { $0.drawnPoints > 0.6 * visibleArea }.count
        let hcWork = hc.isEmpty ? 0 : hc.reduce(0) { $0 + $1.work } / Double(hc.count)
        let nhc = pass.steps.filter { !$0.heightChanged }
        let nhcWork = nhc.isEmpty ? 0 : nhc.reduce(0) { $0 + $1.work } / Double(nhc.count)
        let computeBound = slow.filter { $0.cpu >= 0.8 * $0.work }.count
        let cpuP99 = { () -> Double in let a = pass.steps.map { $0.cpu }.sorted(); return a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * 0.99))] }()
        let sum = pass.steps.reduce(LazyStyler.Probe()) { var r = $0; r.visibleNs += $1.probe.visibleNs; r.viewportNs += $1.probe.viewportNs; r.lexNs += $1.probe.lexNs; r.applyNs += $1.probe.applyNs; r.endEditingNs += $1.probe.endEditingNs; r.slices += $1.probe.slices; r.runs += $1.probe.runs; r.chars += $1.probe.chars; return r }
        let n = Double(max(1, work.count))
        let irregular = pass.steps.dropFirst().filter { abs($0.moved - stepOf(pass)) > 0.5 }.count
        let heightJumps = zip(pass.steps, pass.steps.dropFirst()).filter { abs($1.docHeight - $0.docHeight) > 1 }.count
        let bigHeight = zip(pass.steps, pass.steps.dropFirst()).map { abs($1.docHeight - $0.docHeight) }.max() ?? 0
        let layerLine = pass.steps.contains { $0.drawnRects > 0 } ? String(format: "SCROLLBENCH %@  AppKit's own display: %d steps redrew (nearly) the whole visible rect; of the %d steps where the text view's height changed, %d did; mean step %.2f ms with a height change vs %.2f ms without\n", label, fullRedraws, hc.count, hcFull, hcWork, nhcWork) : ""
        return layerLine + String(format: "SCROLLBENCH %@  scroll regularity: %d of %d steps moved by other than the requested amount; the document height changed in %d steps (largest %.0f pt)\n", label, irregular, max(0, pass.steps.count - 1), heightJumps, bigHeight) + String(format: "SCROLLBENCH %@  n=%d  work ms: mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f | steps >8.3: %d >16.6: %d >33: %d | latency(late+work) >8.3: %d >16.6: %d p99 %.2f max %.2f | of the %d steps >8.3 ms, %d were compute-bound (thread CPU time >= 80%% of wall); CPU-time p99 %.2f ms | per step: scroll %.2f layout %.2f draw %.2f | styler: %d slices, %d runs, %.0f chars; viewport %.2f ms, lex %.2f ms, apply %.2f ms, endEditing %.2f ms per step",
                      label, work.count, work.reduce(0, +) / n, w.p50, w.p95, pct(work, 0.99), w.max, over83, over166, over333, l83, l166, pct(lat, 0.99), lat.max() ?? 0, slow.count, computeBound, cpuP99,
                      pass.steps.reduce(0) { $0 + $1.scroll } / n, pass.steps.reduce(0) { $0 + $1.layout } / n, pass.steps.reduce(0) { $0 + $1.draw } / n,
                      sum.slices, sum.runs, Double(sum.chars), Double(sum.viewportNs) / 1e6 / n, Double(sum.lexNs) / 1e6 / n, Double(sum.applyNs) / 1e6 / n, Double(sum.endEditingNs) / 1e6 / n)
    }

    /// Open `c.url`, run the passes, print. Returns each pass.
    @MainActor static func fixScrollRun(_ t: SelfTest.T, _ c: FixScrollCase, worst: Int = 6, quiet: Bool = false) async throws -> [FixScrollPass] {
        var passes: [FixScrollPass] = []
        try await preservingSettings {
            fixScrollApplyFonts(c.fonts)
            let clone = try PerfLab.clone(t, c.url.path, as: "scroll-\(c.label).md")
            let r = try await perfOpenOnce(clone, width: c.size.width, height: c.size.height)
            guard let host = r.doc.host as? EditorViewController, let window = host.view.window else { throw NSError(domain: "fixscroll", code: 1) }
            window.setContentSize(c.size)
            window.contentView?.layoutSubtreeIfNeeded()
            // --spell: continuous spell checking ON (off by default in luftig; View > Toggle Spell Checking remembers it): AppKit then checks the text that
            // scrolls in, asynchronously, and marks misspelled words on the main thread - work between the steps, reported as `late`
            if SelfTest.flag("spell") { host.textView.isContinuousSpellCheckingEnabled = true }
            host.styler.styleVisible()
            perfLayoutVisible(host)
            perfDrawRect(host.scrollView, host.scrollView.bounds)                  // the first screen is drawn once, as at open
            await t.sleep(50)
            if SelfTest.flag("sample-wait") { out("SCROLLBENCH pid \(getpid()) waiting 8 s for `sample`"); await t.sleep(8000) }
            if !quiet { out(String(format: "SCROLLBENCH %@ open %.1f ms; window %.0f x %.0f pt, backing scale %.0f; load %.2f; text %d chars; fonts %@ %@ %.0f pt; spell checking %@", c.label, r.total, host.view.bounds.width, host.view.bounds.height, window.backingScaleFactor, PerfLab.loadAverage(), host.textView.textStorage?.length ?? 0, c.fonts, host.theme.bodyFamily ?? "system", host.theme.baseSize, host.textView.isContinuousSpellCheckingEnabled ? "on" : "off")) }
            for p in 0..<c.passes {
                let pass = await fixScrollPass(t, host: host, window: window, c: c)
                passes.append(pass)
                if !quiet {
                    out(fixScrollSummary("\(c.label) pass \(p + 1) \(p == 0 ? "COLD" : "warm")", pass))
                    for s in pass.steps.sorted(by: { $0.work > $1.work }).prefix(worst) {
                        out(String(format: "SCROLLBENCH   slow step #%d at y=%.0f: work %.2f ms (scroll %.2f [styleVisible %.2f = viewport %.2f + lex %.2f + apply %.2f + endEditing %.2f; %d slices, %.0f chars] layout %.2f draw %.2f) late %.2f",
                                    s.index, s.y, s.work, s.scroll, Double(s.probe.visibleNs) / 1e6, Double(s.probe.viewportNs) / 1e6, Double(s.probe.lexNs) / 1e6, Double(s.probe.applyNs) / 1e6, Double(s.probe.endEditingNs) / 1e6,
                                    s.probe.slices, Double(s.probe.chars), s.layout, s.draw, s.late))
                    }
                }
                if SelfTest.flag("diagnose") && p == c.passes - 1 { await fixScrollDiagnose(t, host: host, pass: pass, c: c) }
                if p + 1 < c.passes {                                               // back to the top for the warm pass (not measured)
                    host.scrollView.contentView.scroll(to: .zero); host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
                    host.styler.styleVisible(); perfLayoutVisible(host)
                    await t.sleep(50)
                }
            }
            if SelfTest.flag("spell") { host.textView.isContinuousSpellCheckingEnabled = false }    // (AppKit remembers it in the defaults: put it back)
            t.close(r.doc)
        }
        return passes
    }

    /// For the slowest DRAW steps of a (warm) pass: go back to that place and draw the same strip again, 15 times. A strip that is slow every time is slow
    /// because of what is in it (content); one that is slow once was a hiccup of the machine.
    @MainActor static func fixScrollDiagnose(_ t: SelfTest.T, host: EditorViewController, pass: FixScrollPass, c: FixScrollCase) async {
        let sv = host.scrollView, tv = host.textView, clip = sv.contentView
        let text = tv.string as NSString
        for s in pass.steps.sorted(by: { $0.draw > $1.draw }).prefix(8) {
            clip.scroll(to: NSPoint(x: 0, y: s.y)); sv.reflectScrolledClipView(clip)
            host.styler.styleVisible(); perfLayoutVisible(host)
            let v = tv.visibleRect
            let strip = NSRect(x: v.minX, y: v.maxY - CGFloat(c.step), width: v.width, height: CGFloat(c.step))
            var times: [Double] = []
            var spaced: [Double] = []                                                // the same draw after 8 ms of idle (a frame's worth), 6 times: is it the strip or the idle CPU?
            for _ in 0..<6 { await t.sleep(8); let a = SelfTest.nowMs(); perfDrawRect(sv, sv.convert(strip, from: tv)); spaced.append(SelfTest.nowMs() - a) }
            for _ in 0..<15 { let a = SelfTest.nowMs(); perfDrawRect(sv, sv.convert(strip, from: tv)); times.append(SelfTest.nowMs() - a) }
            let lm = tv.layoutManager!, tc = tv.textContainer!
            let g = lm.glyphRange(forBoundingRect: strip.offsetBy(dx: 0, dy: -tv.textContainerOrigin.y), in: tc)
            let cr = lm.characterRange(forGlyphRange: g, actualGlyphRange: nil)
            let snippet = text.substring(with: NSRange(location: cr.location, length: min(90, cr.length))).replacingOccurrences(of: "\n", with: "⏎")
            let st = times.sorted()
            out(String(format: "SCROLLBENCH   DIAG y=%.0f pass draw %.2f ms; after 8 ms idle, 6x: %@; then back to back 15x: min %.2f median %.2f max %.2f ms; %d chars: \"%@\"", s.y, s.draw, spaced.map { String(format: "%.2f", $0) }.joined(separator: " "), st[0], st[st.count / 2], st[st.count - 1], cr.length, snippet))
        }
    }

    @MainActor static func fixScrollBench(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest fix-scroll-bench --input f.md [--size WxH] [--fonts default|fira|serif] [--step N] [--events N] [--display strip|full|none] [--pace ms] [--passes N]"); return }
        var c = FixScrollCase(url: URL(fileURLWithPath: input))
        c.label = SelfTest.argument("label") ?? URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
        if let s = SelfTest.argument("size") { let p = s.split(separator: "x").compactMap { Double($0) }; if p.count == 2 { c.size = NSSize(width: p[0], height: p[1]) } }
        if let f = SelfTest.argument("fonts") { c.fonts = f }
        if let v = SelfTest.argument("step").flatMap({ Double($0) }) { c.step = v }
        if let v = SelfTest.argument("events").flatMap({ Int($0) }) { c.events = v }
        if let v = SelfTest.argument("display") { c.display = v }
        if let v = SelfTest.argument("pace").flatMap({ Double($0) }) { c.pace = v }
        if let v = SelfTest.argument("passes").flatMap({ Int($0) }) { c.passes = v }
        let passes = try await fixScrollRun(t, c)
        t.check(!passes.isEmpty && passes.allSatisfy { !$0.steps.isEmpty }, "scrolled \(passes.count) passes of \(c.events) events")
    }

    // MARK: the regression guard

    /// Budgets of `fix-scroll` (ms per step: the scroll event, the styling and layout it causes, AppKit's display of what it exposed): 3x the worst p99 of three runs
    /// on the reference machine (Apple M5 Pro, release build, load ~1.5, a full-screen-sized window: 1512 x 982 pt at 2x; cold p99 6.9 / 7.2 / 6.2 ms for default /
    /// Fira Code / serif, warm p99 <= 2.0 ms), and never above a 60 Hz frame (16.6 ms) for p99.
    enum ScrollBudgets {
        static let coldP99Default = 16.6
        static let coldP99Fira = 16.6
        static let coldP99Serif = 16.6
        static let warmP99 = 6.5
        static let maxCompute = 16.6              // no step may COMPUTE for longer than a 60 Hz frame (thread CPU time >= 80 % of the wall time of the step)
    }

    @MainActor static func fixScroll(_ t: SelfTest.T) async throws {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let maxLoad = SelfTest.argument("max-load").flatMap { Double($0) } ?? cores / 2
        let scale = SelfTest.argument("budget-scale").flatMap { Double($0) } ?? 1
        guard PerfLab.isRelease else { t.note("SKIPPED: not a release build (the numbers would mean nothing)"); return }
        guard PerfLab.loadAverage() <= maxLoad else { t.note(String(format: "SKIPPED: load average %.1f is above %.1f (half the %d cores): timing assertions on a busy machine only measure the machine (--max-load N overrides)", PerfLab.loadAverage(), maxLoad, Int(cores))); return }

        // a document of a real size: ~1 MB of Markdown (headings, wrapped paragraphs, lists, quotes, code, tables; 2 % non-Latin words)
        let corpus = t.corpusFile(bytes: 1_000_000, seed: 5)
        for (fonts, budget) in [("default", ScrollBudgets.coldP99Default), ("fira", ScrollBudgets.coldP99Fira), ("serif", ScrollBudgets.coldP99Serif)] {
            var c = FixScrollCase(url: corpus)
            c.label = "guard-\(fonts)"; c.fonts = fonts; c.step = 60; c.events = 400
            let passes = try await fixScrollRun(t, c, quiet: true)
            guard passes.count == 2 else { t.check(false, "\(fonts): the passes did not run"); continue }
            for (i, p) in passes.enumerated() {
                let w = PerfLab.stat(p.work)
                func pct(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
                let p99 = pct(p.work, 0.99)
                let compute = p.steps.filter { $0.work > ScrollBudgets.maxCompute && $0.cpu >= 0.8 * $0.work }.count
                let limit = (i == 0 ? budget : ScrollBudgets.warmP99) * scale
                out(String(format: "FIXSCROLL %@ %@: p50 %.2f p95 %.2f p99 %.2f max %.2f ms (budget p99 %.1f), >8.3 ms: %d, >16.6 ms: %d (%d compute-bound)", fonts, i == 0 ? "cold" : "warm", w.p50, w.p95, p99, w.max, limit, p.work.filter { $0 > 8.3 }.count, p.work.filter { $0 > 16.6 }.count, compute))
                t.check(p99 <= min(limit, 16.6), String(format: "%@ %@ pass: p99 %.2f ms <= %.1f ms in a 1512 x 982 pt window (%d steps of 60 pt at 120 Hz over fresh text%@)", fonts, i == 0 ? "cold" : "warm", p99, min(limit, 16.6), p.steps.count, i == 0 ? "" : ", scrolled again"))
                t.equal(compute, 0, "\(fonts) \(i == 0 ? "cold" : "warm"): no step computed for more than \(ScrollBudgets.maxCompute) ms")
            }
        }
    }
}
#endif
