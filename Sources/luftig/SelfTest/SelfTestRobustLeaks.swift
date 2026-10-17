#if LUFTIG_SELFTEST
// SelfTestRobustLeaks.swift - `leaks`: open / use / close documents in bulk and check that EVERYTHING comes back.
//
//   * live instances (weak references to the document, window controller, window, view controller, text view, text storage, layout
//     manager, scroll view, styler, run provider, lexer, theme, external-change monitor) must all be gone after the close
//   * file descriptors (total, kqueue, vnode), threads, mach ports, registered NSFilePresenters, NSDocumentController / NSApp window
//     counts must return to the baseline taken after a warm-up
//   * memory (phys_footprint) must not grow with the number of cycles (slope between the middle and the end of the run)
//
//   --selftest leaks --docs 300 --big 30        (smoke inside `all`: 12 x 1 MB, 2 x 20 MB)

import AppKit
import Darwin
import MarkdownKit

extension Robust {

    /// Weak references to everything one open document creates.
    struct LiveSet {
        weak var doc: MarkdownDocument?
        weak var wc: NSWindowController?
        weak var window: NSWindow?
        weak var vc: EditorViewController?
        weak var tv: NSTextView?
        weak var storage: NSTextStorage?
        weak var layout: NSLayoutManager?
        weak var scroll: NSScrollView?
        weak var styler: LazyStyler?
        weak var provider: MarkdownRunProvider?
        weak var lexer: MarkdownStyler?
        weak var theme: Theme?
        weak var monitor: ExternalChangeMonitor?
        var tag = ""

        @MainActor init(_ d: MarkdownDocument) {
            doc = d
            wc = d.windowControllers.first
            window = d.windowControllers.first?.window
            monitor = d.monitor
            if let vc = d.windowControllers.first?.contentViewController as? EditorViewController {
                self.vc = vc; tv = vc.textView; storage = vc.textView.textStorage; layout = vc.textView.layoutManager
                scroll = vc.scrollView; styler = vc.styler; provider = vc.provider; lexer = vc.provider.styler; theme = vc.theme
            }
        }

        /// Names of the objects that are still alive.
        var alive: [String] {
            var a: [String] = []
            if doc != nil { a.append("MarkdownDocument") }
            if wc != nil { a.append("NSWindowController") }
            if window != nil { a.append("NSWindow") }
            if vc != nil { a.append("EditorViewController") }
            if tv != nil { a.append("NSTextView") }
            if storage != nil { a.append("NSTextStorage") }
            if layout != nil { a.append("NSLayoutManager") }
            if scroll != nil { a.append("NSScrollView") }
            if styler != nil { a.append("LazyStyler") }
            if provider != nil { a.append("MarkdownRunProvider") }
            if lexer != nil { a.append("MarkdownStyler") }
            if theme != nil { a.append("Theme") }
            if monitor != nil { a.append("ExternalChangeMonitor") }
            return a
        }
    }

    @MainActor static func leaks(_ t: SelfTest.T) async throws {
        let wd = RobustWatchdog.shared
        wd.start(); RobustCrash.install()
        let savedDelay = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = 3        // the shipping value (AppDelegate): a closed NSDocument lives until its autosave timer has fired
        RobustPrefs.reset()
        defer { NSDocumentController.shared.autosavingDelay = savedDelay; RobustPrefs.reset() }
        let nSmall = intArg("docs", smoke: 12, full: 300)
        let nBig = intArg("big", smoke: 2, full: 30)
        let small = t.url("leak-1m.md"), big = t.url("leak-20m.md")
        try RobustFiles.writeCorpus(small, bytes: 1 << 20, seed: 11)
        try RobustFiles.writeCorpus(big, bytes: 20 << 20, seed: 12)
        var lives: [LiveSet] = []
        var activityCounter = 0
        let userClose = CloseProbe()
        let modes: [Int] = (SelfTest.argument("close-modes") ?? "1,2").split(separator: ",").compactMap { Int($0) }

        /// One cycle: open, use the document the way a user (or a monkey) does, close it.
        func cycle(_ file: URL, closeVia: Int) async throws {
            activityCounter += 1
            let n = activityCounter
            let d = try await t.open(file, size: NSSize(width: 800 + (n % 5) * 40, height: 600))
            lives.append(LiveSet(d))
            let idx = lives.count - 1
            guard let host = t.editor(d) else { return }
            let units = host.textView.string.utf16.count
            await t.spin(3)
            lives[idx].monitor = d.monitor
            lives[idx].tag = "cycle \(n) via=\(closeVia) ext=\(n % 6 == 0) find=\(n % 9 == 0) spell=\(n % 7 == 0) appearance=\(n % 5 == 0) font=\(n % 11 == 0)"
            // activity
            t.typeText("x", into: d, at: NSRange(location: 0, length: 0))
            t.typeText("# heading\n", into: d, at: NSRange(location: units / 2, length: 0))
            t.scrollToTop(host, character: units / 3)
            _ = t.renderPNG(d.windowControllers.first!.window!)
            if n % 7 == 0 { host.luftigToggleSpellChecking(nil); host.luftigToggleSpellChecking(nil) }
            if n % 5 == 0 { d.windowControllers.first?.window?.appearance = NSAppearance(named: n % 2 == 0 ? .darkAqua : .aqua) }
            if n % 11 == 0 { EditorPreferences.fontSize += 1; EditorPreferences.fontSize -= 1 }
            if n % 9 == 0 { host.textView.performTextFinderAction(NSTextFinder.Action.showFindInterface.asSender); host.textView.performTextFinderAction(NSTextFinder.Action.hideFindInterface.asSender) }
            if n % 6 == 0 {      // an external change in flight while the window closes
                await t.sh("printf '\\nexternal %d\\n' \(n) >> \(t.q(file))")
                await t.spin(Double(10 + (n % 4) * 25))
            }
            if n % 10 == 3 { await t.spin(3) }
            // close. 0: the test helper's quick path (updateChangeCount(.changeCleared) + close() in the same run-loop turn as the last edit);
            // 1: what a window's close button does: NSDocument.canClose (autosave in place writes the edit) + close(), a person's time after the last edit;
            // 2: NSWindowController.close() (the window goes away, the last window controller takes the document with it), same timing as 1.
            switch closeVia {
            case 0:
                d.updateChangeCount(.changeCleared)
                d.close()
            case 1:
                await t.spin(60)      // NSDocument registers a change one run-loop turn after the edit; a person needs far longer than that to reach the close button
                d.canClose(withDelegate: userClose, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
                _ = await t.waitFor(5000) { userClose.result != nil }
                if userClose.result == true { d.close() } else { d.updateChangeCount(.changeCleared); d.close() }
                userClose.result = nil
            default:
                await t.spin(60)
                d.windowControllers.first?.close()
                if NSDocumentController.shared.documents.contains(where: { $0 === d }) { d.updateChangeCount(.changeCleared); d.close() }
            }
            // restore the files the external writer appended to (keep them 1 MB / 20 MB)
            if n % 6 == 0 || closeVia != 0 { try? RobustFiles.writeCorpus(file, bytes: file == big ? 20 << 20 : 1 << 20, seed: file == big ? 12 : 11) }
        }

        // the harness' own floor: idle CPU of the bare process (heartbeat paused) before any document exists
        do {
            wd.pause()
            let c0 = ProcessMetrics.cpuSeconds(), w0 = now()
            try? await Task.sleep(nanoseconds: 2_000_000_000)       // (one sleep: t.spin polls every 2 ms and would measure itself)
            let floor = (ProcessMetrics.cpuSeconds() - c0) / ((now() - w0) / 1000) * 100
            wd.resume()
            t.note(String(format: "idle floor before any document: %.2f %% of a core", floor))
        }
        // ---- warm-up (lazy initialisation of AppKit, fonts, caches is not a leak)
        t.note("---- warm-up ----")
        for i in 0..<6 { try await cycle(small, closeVia: modes[i % modes.count]); await t.spin(10) }
        try await cycle(big, closeVia: modes[0])
        lives.removeAll()
        await t.spin(300)
        let base = RobustResources.snapshot()
        t.note("baseline: \(base.description)")

        // ---- many 1 MB documents
        t.note("---- \(nSmall) x 1 MB open / use / close ----")
        var mid: RobustResources.Snapshot?
        wd.label = "leaks: small documents"
        wd.reset()
        let t0 = now()
        for i in 0..<nSmall {
            try await cycle(small, closeVia: modes[i % modes.count])
            if i % 8 == 0 { await t.spin(5) }
            if i == nSmall / 2 { await t.spin(100); mid = RobustResources.snapshot() }
        }
        let smallMs = now() - t0
        let smallStall = wd.maxStallMs()
        await t.spin(400)
        let afterSmall = RobustResources.snapshot()
        t.note(String(format: "%d cycles in %.0f s (%.0f ms each), longest main-thread stall %.0f ms", nSmall, smallMs / 1000, smallMs / Double(nSmall), smallStall))
        t.note("after:    \(afterSmall.description)")
        if let mid {
            let slope = RobustResources.mb(afterSmall.footprint - mid.footprint) / Double(max(1, nSmall - nSmall / 2))
            t.note(String(format: "footprint slope over the second half: %.3f MB per cycle (a 1 MB document)", slope))
            if nSmall >= 100 { t.check(slope < 0.15, String(format: "no memory growth per open/close cycle (%.3f MB per 1 MB document < 0.15)", slope)) }
        }
        await report(t, "1 MB documents", lives, base: base, after: afterSmall)
        lives.removeAll()

        // ---- 20 MB documents
        t.note("---- \(nBig) x 20 MB open / use / close ----")
        wd.label = "leaks: big documents"
        wd.reset()
        let b0 = now()
        let bigBase = RobustResources.snapshot()
        var bigMid: RobustResources.Snapshot?
        for i in 0..<nBig {
            try await cycle(big, closeVia: modes[i % modes.count])
            if i == nBig / 2 { await t.spin(150); bigMid = RobustResources.snapshot() }
        }
        let bigMs = now() - b0
        await t.spin(500)
        let afterBig = RobustResources.snapshot()
        t.note(String(format: "%d cycles in %.0f s (%.0f ms each), longest main-thread stall %.0f ms", nBig, bigMs / 1000, bigMs / Double(nBig), wd.maxStallMs()))
        t.note("before:   \(bigBase.description)")
        t.note("after:    \(afterBig.description)")
        if let bigMid, nBig >= 10 {
            let slope = RobustResources.mb(afterBig.footprint - bigMid.footprint) / Double(max(1, nBig - nBig / 2))
            t.note(String(format: "footprint slope over the second half: %.2f MB per cycle (a 20 MB document)", slope))
            t.check(slope < 2.0, String(format: "no memory growth per 20 MB open/close cycle (%.2f MB per cycle < 2)", slope))
        }
        do {
            let released = RobustResources.pressureRelief()
            await t.spin(200)
            let afterRelief = RobustResources.snapshot()
            t.note("after malloc_zone_pressure_relief (released \(RobustResources.mbs(released))): \(afterRelief.description)")
        }
        await report(t, "20 MB documents", lives, base: bigBase, after: afterBig)
        lives.removeAll()

        // ---- many documents open at once, then all closed
        let nAtOnce = isSmoke ? 8 : 40
        t.note("---- \(nAtOnce) documents open at once ----")
        var files: [URL] = []
        for i in 0..<nAtOnce { let f = t.url("once-\(i).md"); try RobustFiles.writeCorpus(f, bytes: 300_000, seed: UInt64(20 + i)); files.append(f) }
        let onceBase = RobustResources.snapshot()
        var open: [MarkdownDocument] = []
        for f in files { let d = try await t.open(f); lives.append(LiveSet(d)); open.append(d) }
        let peak = RobustResources.snapshot()
        t.note("peak:     \(peak.description)")
        t.check(peak.documents - onceBase.documents == nAtOnce, "\(nAtOnce) documents registered with NSDocumentController (\(peak.documents - onceBase.documents))")
        for (i, d) in open.enumerated() { if i % 3 == 0 { t.typeText("edit", into: d) } }
        await t.spin(40)
        // a burst of external changes to every one of them, then close them all at once, in the middle of the checks
        for f in files { await t.sh("printf 'ext\\n' >> \(t.q(f))") }
        await t.spin(30)
        for d in open { d.updateChangeCount(.changeCleared); d.close() }
        open.removeAll()
        await t.spin(500)
        let afterOnce = RobustResources.snapshot()
        t.note("after:    \(afterOnce.description)")
        await report(t, "documents open at once", lives, base: onceBase, after: afterOnce)
        lives.removeAll()
        for f in files { try? FileManager.default.removeItem(at: f) }

        // ---- the same file opened twice returns the same document; close while a background read is in flight
        do {
            let f = t.url("twice.md")
            try RobustFiles.writeCorpus(f, bytes: 2 << 20, seed: 40)
            // (the document references live in this function's frame only: a local `let a` in the enclosing scope would keep the document alive by itself)
            @MainActor func openTwiceAndClose() async throws -> LiveSet {
                let a = try await t.open(f), b = try await NSDocumentController.shared.openDocument(withContentsOf: f, display: false).0
                t.check(a === b, "opening the same file twice returns the same document")
                let live = LiveSet(a)
                await t.sh("printf 'x\\n' >> \(t.q(f))")
                await t.spin(60)      // the monitor fired, the background read is running or just finished
                a.windowControllers.first?.close()      // the window's close box: the last window controller takes the document with it
                if NSDocumentController.shared.documents.contains(where: { $0 === a }) { a.updateChangeCount(.changeCleared); a.close() }
                return live
            }
            let live = try await openTwiceAndClose()
            let ok = await t.waitFor(9000) { live.alive.isEmpty }
            t.check(ok, "close while an external-change check is in flight releases everything (alive after 9 s: \(live.alive))")
            try? FileManager.default.removeItem(at: f)
        }
        // close a moment after open (before the monitor is armed)
        do {
            let f = t.url("quick.md")
            try RobustFiles.writeCorpus(f, bytes: 100_000, seed: 41)
            var quick: [LiveSet] = []
            for _ in 0..<20 {
                let d = try await t.open(f)
                quick.append(LiveSet(d))
                await t.spin(5)
                d.windowControllers.first?.close()
                if NSDocumentController.shared.documents.contains(where: { $0 === d }) { d.updateChangeCount(.changeCleared); d.close() }
            }
            let ok = await t.waitFor(9000) { quick.allSatisfy { $0.alive.isEmpty } }
            checkKnown(t, ok, "20 x open + close a moment later: nothing alive afterwards (after 9 s: \(quick.first(where: { !$0.alive.isEmpty })?.alive ?? []))", defect: "textkit-leak")
            try? FileManager.default.removeItem(at: f)
        }
        await t.spin(300)
        if SelfTest.flag("leaks-tool") { runLeaksTool(t) }
        let end = RobustResources.snapshot()
        t.note("end:      \(end.description)")
        // nothing of the closed documents may keep the process busy: timers, idle-work chains, retry loops, kqueue sources of dead documents
        wd.pause()
        try? await Task.sleep(nanoseconds: 4_000_000_000)       // (closing a document leaves a little work behind: the 3 s autosave timer, releases of big buffers; a leak would not stop)
        let cpu0 = ProcessMetrics.cpuSeconds(), w0 = now()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let busy = (ProcessMetrics.cpuSeconds() - cpu0) / ((now() - w0) / 1000) * 100
        if busy >= 2 || SelfTest.flag("idle-sample") {
            // who is busy?  a 3 s sample of this process while it idles (the heartbeat is still off)
            let file = NSTemporaryDirectory() + "luftig-idle-\(getpid()).txt"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sample"); p.arguments = ["\(getpid())", "3", "-file", file]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in p.terminationHandler = { _ in c.resume() }; do { try p.run() } catch { c.resume() } }
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                t.note("idle sample (\(file)): the busiest frames of every thread")
                let lines = text.components(separatedBy: "\n")
                if let i = lines.firstIndex(where: { $0.contains("Call graph:") }) {
                    var shown = 0
                    for l in lines[(i + 1)...] {
                        if l.hasPrefix("Total number in stack") { break }
                        // top-level thread lines and everything deeper that is not the plain run-loop wait
                        if l.contains("Thread_") || (l.contains("luftig") || l.contains("NSLayoutManager") || l.contains("NSTextView") || l.contains("NSDocument") || l.contains("Timer") || l.contains("kevent")) {
                            out("    | " + l.prefix(200)); shown += 1; if shown > 70 { break }
                        }
                    }
                }
            }
        }
        wd.resume()
        t.check(busy < 2, String(format: "idle after all those documents: %.2f %% of a core over 3 s (< 2 %%)", busy))
        t.check(end.fds.total <= base.fds.total + 4, "file descriptors back to the baseline: \(end.fds.total) vs \(base.fds.total)")
        t.check(end.threads <= base.threads + 20, "threads back to about the baseline: \(end.threads) vs \(base.threads)")
        t.check(end.presenters <= base.presenters, "no file presenter left registered: \(end.presenters) vs \(base.presenters)")
    }

    /// One round per action: open a 300 KB document, do ONLY that action, close, spin, and look at the weak references.
    @MainActor static func leaksBisect(_ t: SelfTest.T) async throws {
        RobustWatchdog.shared.start(); RobustCrash.install()
        let file = t.url("bisect.md")
        try RobustFiles.writeCorpus(file, bytes: 300_000, seed: 31)
        typealias Action = (String, @MainActor (MarkdownDocument, EditorViewController) async -> Void)
        let actions: [Action] = [
            ("nothing (open + close)", { _, _ in }),
            ("renderPNG (draw)", { d, _ in _ = t.renderPNG(d.windowControllers.first!.window!) }),
            ("scroll to the middle", { _, h in t.scrollToTop(h, character: 100_000) }),
            ("type one character", { d, _ in t.typeText("x", into: d, at: NSRange(location: 5, length: 0)) }),
            ("type + wait 50 ms (change registered)", { d, _ in t.typeText("x", into: d, at: NSRange(location: 5, length: 0)); await t.spin(50) }),
            ("type + undo", { d, h in t.typeText("x", into: d, at: NSRange(location: 5, length: 0)); h.textView.undoManager?.undo() }),
            ("type, save (autosave)", { d, _ in t.typeText("x", into: d, at: NSRange(location: 5, length: 0)); await t.spin(30); _ = await t.autosave(d) }),
            ("select all", { _, h in h.textView.selectAll(nil) }),
            ("find interface show + hide", { _, h in h.textView.performTextFinderAction(NSTextFinder.Action.showFindInterface.asSender); await t.spin(20); h.textView.performTextFinderAction(NSTextFinder.Action.hideFindInterface.asSender) }),
            ("find interface show only", { _, h in h.textView.performTextFinderAction(NSTextFinder.Action.showFindInterface.asSender); await t.spin(20) }),
            ("spell checking toggle x2", { _, h in h.luftigToggleSpellChecking(nil); h.luftigToggleSpellChecking(nil) }),
            ("window appearance dark", { d, _ in d.windowControllers.first?.window?.appearance = NSAppearance(named: .darkAqua) }),
            ("font size +1 -1", { _, _ in EditorPreferences.fontSize += 1; EditorPreferences.fontSize -= 1 }),
            ("resize window", { d, _ in d.windowControllers.first?.window?.setContentSize(NSSize(width: 500, height: 400)); d.windowControllers.first?.window?.contentView?.layoutSubtreeIfNeeded() }),
            ("external append + wait for reload", { d, _ in let r = d.stats.silentReloads; await t.sh("printf 'x\\n' >> \(t.q(file))"); _ = await t.waitFor(2000) { d.stats.silentReloads > r } }),
            ("first responder / makeKey", { d, h in d.windowControllers.first?.window?.makeFirstResponder(h.textView) }),
            ("accessibility value", { _, h in _ = h.textView.accessibilityValue(); _ = h.textView.accessibilityVisibleCharacterRange() }),
        ]
        for (name, act) in actions {
            var live: LiveSet?
            do {
                let d = try await t.open(file, size: NSSize(width: 800, height: 600))
                live = LiveSet(d)
                if let h = t.editor(d) { await act(d, h) }
                d.updateChangeCount(.changeCleared)
                d.close()
            }
            let tClose = now()
            // AppKit releases a text view a few hundred ms after its last reference is gone: give it time before calling it a leak
            let freed = await t.waitFor(4000) { live?.alive.isEmpty ?? true }
            let alive = live?.alive ?? []
            t.check(freed, "after [\(name)] + close, everything is deallocated\(freed ? String(format: " (after %.0f ms)", now() - tClose) : " - STILL ALIVE after 4 s: \(alive)")")
        }
        await leaksBisectStacks(t)
    }

    /// Part 2 of the bisect: AppKit pieces without any NSDocument, to see which one keeps the text view alive.
    @MainActor static func leaksBisectStacks(_ t: SelfTest.T) async {
        struct W { weak var tv: NSTextView?; weak var storage: NSTextStorage?; weak var lm: NSLayoutManager?; weak var win: NSWindow?; weak var vc: NSViewController?; weak var styler: LazyStyler?
            var alive: [String] { var a: [String] = []; if tv != nil { a.append("tv") }; if storage != nil { a.append("storage") }; if lm != nil { a.append("layout") }; if win != nil { a.append("window") }; if vc != nil { a.append("vc") }; if styler != nil { a.append("styler") }; return a } }
        func make() -> (EditorViewController, W) {
            let vc = EditorViewController()
            _ = vc.view
            return (vc, W(tv: vc.textView, storage: vc.textView.textStorage, lm: vc.textView.layoutManager, win: nil, vc: vc, styler: vc.styler))
        }
        func report(_ name: String, _ w: W) async {
            await t.spin(300)
            t.check(w.alive.isEmpty, "stack [\(name)]: nothing alive after release (alive: \(w.alive))")
        }
        // A: a view controller, nothing else
        do { var w: W; do { let (vc, ww) = make(); w = ww; _ = vc }; await report("EditorViewController alone", w) }
        // B: + text
        do { var w: W; do { let (vc, ww) = make(); w = ww; vc.loadInitialText("# hello\n\nworld *x*\n"); }; await report("EditorViewController + loadInitialText", w) }
        // C: + in a window (never ordered front), window released
        do { var w: W; do { let (vc, ww) = make(); w = ww; let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true); win.isReleasedWhenClosed = false; win.contentViewController = vc; vc.loadInitialText("# hello\n"); win.close() }; await report("EditorViewController in an NSWindow, closed", w) }
        // D: + a keystroke through the real input path
        do { var w: W; do { let (vc, ww) = make(); w = ww; let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true); win.isReleasedWhenClosed = false; win.contentViewController = vc; vc.loadInitialText("# hello\n"); vc.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0)); win.close() }; await report("... + one keystroke", w) }
        // E0: sanity of the method itself - plain AppKit objects
        func probe(_ name: String, _ body: () -> [AnyObject]) async {
            weak var w0: AnyObject?; weak var w1: AnyObject?; weak var w2: AnyObject?
            do { let objs = body(); w0 = objs.first; if objs.count > 1 { w1 = objs[1] }; if objs.count > 2 { w2 = objs[2] } }
            await t.spin(300)
            t.check(w0 == nil && w1 == nil && w2 == nil, "plain AppKit [\(name)]: released (alive: \([w0, w1, w2].compactMap { $0 }.map { String(describing: type(of: $0)) }))")
        }
        await probe("NSView") { [NSView(frame: .zero)] }
        await probe("NSTextField") { [NSTextField(labelWithString: "x")] }
        await probe("NSTextStorage + NSLayoutManager + NSTextContainer (no view)") {
            let s = NSTextStorage(string: "hello"); let l = NSLayoutManager(); s.addLayoutManager(l); let c = NSTextContainer(); l.addTextContainer(c); return [s, l, c] }
        await probe("NSTextView()") { [NSTextView()] }
        await probe("NSTextView(frame:)") { [NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))] }
        await probe("NSTextView(frame:) + string") { let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tv.string = "hello"; return [tv] }
        await probe("NSTextView(frame:) + layout forced") { let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tv.string = "hello"; tv.layoutManager?.ensureLayout(for: tv.textContainer!); return [tv] }
        await probe("NSTextView(usingTextLayoutManager: false)") { [NSTextView(usingTextLayoutManager: false)] }
        await probe("NSTextView(usingTextLayoutManager: true)") { [NSTextView(usingTextLayoutManager: true)] }
        await probe("NSScrollView + NSTextView (scrollableTextView)") { [NSTextView.scrollableTextView()] }
        await probe("NSTextView in NSWindow, closed") {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false; w.contentView = tv; w.close(); return [tv, w] }
        // E: bare NSTextView stack of AppKit (no luftig code)
        do {
            weak var tvw: NSTextView?; weak var sw: NSTextStorage?
            do { let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)); tv.string = "hello"; tvw = tv; sw = tv.textStorage }
            await t.spin(300)
            t.check(tvw == nil && sw == nil, "plain AppKit NSTextView: released (tv alive: \(tvw != nil), storage alive: \(sw != nil))")
        }
    }

    /// `--leaks-tool`: run /usr/bin/leaks on this very process (MallocStackLogging=1 in the environment gives allocation backtraces) and print its report.
    @MainActor static func runLeaksTool(_ t: SelfTest.T) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        p.arguments = ["\(getpid())", "--nocontext"] + (SelfTest.argument("leaks-args").map { $0.split(separator: " ").map(String.init) } ?? [])
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { t.note("leaks tool failed to start: \(error)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let path = NSTemporaryDirectory() + "luftig-leaks-\(getpid()).txt"
        try? text.write(toFile: path, atomically: false, encoding: .utf8)
        t.note("leaks tool: exit \(p.terminationStatus), \(text.count) characters, full output: \(path)")
        for l in text.split(separator: "\n").prefix(60) { out("    | " + l) }
    }

    @MainActor static func report(_ t: SelfTest.T, _ what: String, _ lives: [LiveSet], base: RobustResources.Snapshot, after afterIn: RobustResources.Snapshot) async {
        // NSDocument keeps a closed document for up to `autosavingDelay` (3 s: its autosave timer), AppKit releases a text view a
        // few hundred ms after its last reference is gone: wait for that before calling anything a leak.
        let tWait = now()
        let settled = await t.waitFor(9000) { lives.allSatisfy { $0.alive.isEmpty } }
        t.note(String(format: "%@: everything %@ %.0f ms after the last close", what, settled ? "deallocated" : "NOT deallocated, still alive after", now() - tWait + 0))
        let after = settled ? RobustResources.snapshot() : afterIn
        let stillAlive = lives.filter { !$0.alive.isEmpty }
        if SelfTest.flag("leaks-tool"), let first = stillAlive.first {
            func addr(_ o: AnyObject?) -> String { o.map { String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque())) } ?? "nil" }
            t.note("alive: doc \(addr(first.doc)) textStorage \(addr(first.storage)) textView \(addr(first.tv)) layout \(addr(first.layout)) (\(first.alive))")
            for (nm, o) in [("doc", first.doc as AnyObject?), ("storage", first.storage as AnyObject?), ("tv", first.tv as AnyObject?), ("layout", first.layout as AnyObject?)] where o != nil {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
                p.arguments = ["\(getpid())", "--traceTree=\(addr(o))"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                if (try? p.run()) != nil {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    try? text.write(toFile: NSTemporaryDirectory() + "luftig-trace-\(nm)-\(getpid()).txt", atomically: false, encoding: .utf8)
                    t.note("traceTree \(nm): \(NSTemporaryDirectory())luftig-trace-\(nm)-\(getpid()).txt (\(text.count) chars)")
                }
            }
        }
        var kinds: [String: Int] = [:]
        for l in stillAlive { for k in l.alive { kinds[k, default: 0] += 1 } }
        for l in stillAlive.prefix(12) { t.note("  still alive: \(l.alive.joined(separator: ", ")) <- \(l.tag)") }
        checkKnown(t, stillAlive.isEmpty, "\(what): all \(lives.count) documents and everything they created are deallocated after close (\(stillAlive.count) alive: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")))", defect: "textkit-leak")
        t.check(after.documents == base.documents, "\(what): NSDocumentController has \(after.documents) documents (baseline \(base.documents))")
        t.check(after.windows <= base.windows + 1, "\(what): NSApp.windows \(after.windows) (baseline \(base.windows))")
        t.check(after.fds.total <= base.fds.total + 3, "\(what): file descriptors \(after.fds.total) (baseline \(base.fds.total); kqueue \(after.fds.kqueue)/\(base.fds.kqueue), vnode \(after.fds.vnode)/\(base.fds.vnode))")
        t.check(after.threads <= base.threads + 20, "\(what): threads \(after.threads) (baseline \(base.threads); GCD's pool breathes, a leak would be one per document)")
        t.check(after.presenters <= base.presenters, "\(what): registered file presenters \(after.presenters) (baseline \(base.presenters))")
        t.check(after.ports <= base.ports + 40, "\(what): mach ports \(after.ports) (baseline \(base.ports); a leak would be one or more per document)")
    }
}

private extension NSTextFinder.Action {
    /// performTextFinderAction(_:) reads `tag` from its sender.
    var asSender: NSMenuItem { let i = NSMenuItem(); i.tag = rawValue; return i }
}
#endif
