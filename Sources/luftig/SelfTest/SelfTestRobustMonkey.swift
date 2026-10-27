#if LUFTIG_SELFTEST
// SelfTestRobustMonkey.swift - `monkey`: a seeded, reproducible random-action driver over several documents and windows.
//
//   --selftest monkey --seed 7 --steps 2000 --docs 3          one seed (default inside `all`: 3 seeds x 300 steps x 2 documents)
//                     --seeds 30                               seeds seed ... seed+29 in this process
//                     --log actions.jsonl                      every action is written (and flushed) BEFORE it runs: a crash leaves the reproduction
//                     --script actions.jsonl                   replay (or a hand-minimised) action list instead of generating one
//                     --autosave-delay 3                       NSDocumentController.autosavingDelay (the shipping value is 3 s)
//                     --no-exotic                              no U+2028 / lone CR / bidi controls among the typed characters
//                     --nul                                    also type U+0000 (FINDING "nul-save": the saved file is then one luftig refuses to reopen)
//                     --symlinks                               also swap an open document's file for a symlink (FINDING "symlink-save")
//
// Actions (all through the real paths: NSTextView.insertText, NSUndoManager, readSelection(from:) on a private pasteboard, window
// resizing, font size, appearance, find interface, NSDocument save / autosave / canClose / close, UITrap-answered sheets) plus REAL external
// writers (child processes: append, truncate+rewrite, atomic replace, delete, delete+recreate, rename away and back, `touch -r`,
// binary, chmod 000, symlink to a regular file, UTF-16, CRLF, empty, growing writer, touch storm). REGULAR FILES (and symlinks to regular files) ONLY:
// no named pipes, devices, sockets or mounts, ever (a FIFO swapped in for an open document's file wedged filecoordinationd machine-wide).
//
// Invariants (after every step unless noted):
//   * no crash / exception / hang (RobustCrash, RobustWatchdog); the step that was in flight is named
//   * the text storage equals the model the monkey keeps, unless an external apply explains the difference (document.generation)
//   * undo / redo give back exactly the recorded snapshots
//   * document / window counts, undo grouping level, selection bounds, styled-set bounds
//   * (periodically, when settled) every styled character equals a FRESH Theme + MarkdownStyler.lexAll (the differential oracle)
//   * (when settled) a clean in-sync document shows exactly the decoded file; a conflict keeps the typed text; an unreadable file keeps the text
//   * NO DATA LOSS: after every save the file decodes to the editor text; a save never replaces a disk version the document has not
//     loaded / merged unless the monkey told it to overwrite; closing a dirty document writes it (or asks); Discard leaves the disk alone
//   * main-thread time per step is recorded (steps over 100 ms are listed)

import AppKit
import Darwin
import MarkdownKit

extension Robust {

    // MARK: - actions

    struct MAction: Codable, CustomStringConvertible {
        var k: String
        var d = 0          // document slot
        var a = 0.0        // 0...1: position / fraction
        var b = 0.0
        var n = 0
        var s = ""
        var description: String {
            let sShort = s.count > 24 ? String(s.prefix(24)) + "…(\(s.count))" : s
            return "{\(k) d\(d) a=\(String(format: "%.3f", a)) b=\(String(format: "%.2f", b)) n=\(n) s=\(sShort.debugDescription)}"
        }
        func json() -> String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    static let monkeyChars = ["a", "b", "c", " ", " ", "e", "t", "é", "日", "😀", "x", "1", "\t"]
    static let monkeyMarkers = ["#", "# ", "## ", "> ", "> > ", "- ", "- [ ] ", "1. ", "* ", "**", "*", "_", "__", "`", "```\n", "~~~\n", "~~", "[", "](", ")", "---\n", "***\n",
                                "| a | b |\n|---|---|\n", "<!-- ", "-->", "\\", "!", "<", ">", "    ", "\n\n", "===\n", "---\nt: 1\n---\n", ":", "|"]
    static let monkeyExotic = ["\u{2028}", "\u{2029}", "\u{85}", "\r", "\r\n", SelfTest.flag("nul") ? "\u{0}" : "\u{FFFD}", "\u{200D}", "\u{301}", "\u{FEFF}", "👩‍💻", "\u{202E}", "\u{7F}", "\u{1B}", "\u{FFFC}", "\u{D7FF}"]
    static let externalKinds = ["append", "rewrite", "atomic", "delete", "recreate", "rename-away-back", "touch-r", "binary", "chmod000", "symlink", "utf16", "crlf", "empty", "grow", "touch-storm", "restore"]

    /// The generator: weights in per mille.
    static func generateAction(_ r: inout TestRNG, docs: Int, exotic: Bool) -> MAction {
        var a = MAction(k: "wait", d: r.int(docs))
        let x = r.int(1000)
        func frac() -> Double { Double(r.int(10_001)) / 10_000 }
        switch x {
        case 0..<170: a.k = "type"; a.a = frac(); a.s = r.pick(monkeyChars)
            if r.chance(20) { a.s = (0..<(2 + r.int(20))).map { _ in r.pick(monkeyChars) }.joined() }
        case 170..<260: a.k = "marker"; a.a = frac(); a.s = r.pick(monkeyMarkers)
            if r.chance(25) { a.a = 0 }
        case 260..<300: a.k = "newline"; a.a = frac()
        case 300..<370: a.k = "delete"; a.a = frac(); a.n = 1 + r.int(r.chance(15) ? 60 : 4)
        case 370..<390: a.k = "deleteLine"; a.a = frac()
        case 390..<395: a.k = "replaceAll"; a.s = SelfTestCorpus.markdown(bytes: 300 + r.int(3000), seed: r.next())
        case 395..<430: a.k = "undo"; a.n = 1 + r.int(3)
        case 430..<450: a.k = "redo"; a.n = 1 + r.int(2)
        case 450..<485: a.k = "paste"; a.a = frac()
            a.s = SelfTestCorpus.markdown(bytes: r.chance(8) ? 30_000 + r.int(30_000) : 100 + r.int(4000), seed: r.next())
        case 485..<560: a.k = "scroll"; a.a = frac()
        case 560..<575: a.k = r.pick(["jumpEnd", "jumpStart", "pageDown", "pageUp"])
        case 575..<595: a.k = "resize"; a.a = Double(r.int(1001)) / 1000; a.b = Double(r.int(1001)) / 1000; a.n = r.chance(12) ? 1 + r.int(3) : 0     // n: 1 = minimum size, 2 = huge, 3 = tall and thin
        case 595..<608: a.k = "font"; a.n = r.pick([-1, 1, 1, 0])
        case 608..<618: a.k = "appearance"; a.n = r.int(2)
        case 618..<624: a.k = "readable"
        case 624..<630: a.k = "spell"
        case 630..<655: a.k = "find"; a.n = r.int(5); a.a = frac()
        case 655..<715: a.k = "save"; a.n = r.int(4); a.b = r.chance(25) ? 1 : 0       // b == 1: do not settle first (race the watchers)
        case 715..<720: a.k = "saveAs"
        case 720..<740: a.k = "close"; a.n = r.int(3)
        case 740..<775: a.k = "reopen"
        case 775..<860: a.k = "ext"; a.n = r.int(externalKinds.count); a.s = "EXT\(r.int(100_000))"; a.b = Double(r.int(150))   // b: ms to spin afterwards
        case 860..<895: a.k = "choose"; a.n = r.int(2)
        case 895..<902: a.k = "openBig"; a.n = r.pick([1, 2, 3, 5, 5, 8, 20])
        case 902..<910: a.k = "newdoc"; a.s = r.pick(monkeyChars) + r.pick(monkeyMarkers)
        case 910..<925: a.k = "activate"
        case 925..<955: a.k = "wait"; a.n = 1 + r.int(80)
        case 955..<962: a.k = "revert"; a.n = r.int(2)
        case 962..<985: a.k = "draw"
        case 985..<1000: a.k = exotic ? "exotic" : "type"; a.a = frac(); a.s = exotic ? r.pick(monkeyExotic) : r.pick(monkeyChars)
        default: break
        }
        return a
    }

    // MARK: - per-document state

    /// A slot is a file name plus (maybe) an open document and what the monkey believes about it.
    @MainActor final class MSlot {
        let index: Int
        var file: URL
        var doc: MarkdownDocument?
        /// The text the editor should show (nil: unknown, resync from the editor).
        var model: NSString?
        var undoStack: [NSString] = []
        var redoStack: [NSString] = []
        var trackUndo = true
        /// The recorded history is shorter than the real one (older edits were dropped): undo / redo checks stop at its end.
        var undoTruncated = false
        var lastGeneration = -1
        var lastMerges = 0
        var lastSilent = 0
        /// The monkey told the document to overwrite / keep: a save may replace the disk version.
        var overwritePermitted = false
        var externalCount = 0
        /// An Undo ran on a document that had merged / reloaded an external version as an undoable edit: the undo can walk back past the external
        /// change and leave a clean document that shows other text than the file (FINDING "undo-merge"). Cleared by open / a write of the file.
        var undoPastExternal = false
        init(index: Int, file: URL) { self.index = index; self.file = file }
        var host: EditorViewController? { doc?.windowControllers.first?.contentViewController as? EditorViewController }
    }

    final class SaveWaiter: NSObject {
        var result: Bool?
        @objc func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) { result = didSave }
    }

    // MARK: - the driver

    @MainActor static func monkey(_ t: SelfTest.T) async throws {
        RobustWatchdog.shared.start(); RobustCrash.install()
        let docs = intArg("docs", smoke: 2, full: 3)
        let steps = intArg("steps", smoke: 300, full: 2000)
        let seed0 = UInt64(SelfTest.argument("seed").flatMap { Int($0) } ?? 1)
        let nSeeds = intArg("seeds", smoke: 3, full: 1)
        let exotic = !SelfTest.flag("no-exotic")
        let delay = Double(SelfTest.argument("autosave-delay") ?? "") ?? 3
        let script: [MAction]? = SelfTest.argument("script").flatMap { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(MAction.self, from: Data($0.utf8)) }
        }
        // The preferences the monkey changes (font size, readable width) live in the self-test bundle's UserDefaults domain, which every self-test run
        // shares. A run that is killed (hang report, timeout) cannot put them back, so the monkey does not "restore what it found": it starts from the
        // factory state (keys removed) and leaves the factory state behind - also from the hang report (RobustPrefs.reset).
        RobustPrefs.reset()
        let savedDelay = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = delay
        defer {
            RobustPrefs.reset()
            NSDocumentController.shared.autosavingDelay = savedDelay
        }
        let findChange0 = NSPasteboard(name: .find).changeCount
        var allSlow: [(String, Double)] = []
        for si in 0..<nSeeds {
            let seed = seed0 + UInt64(si)
            let m = Monkey(t, seed: seed, docs: docs, exotic: exotic, logPath: SelfTest.argument("log").map { nSeeds > 1 ? $0 + ".\(seed)" : $0 })
            try await m.run(steps: steps, script: script)
            allSlow += m.slowSteps
            t.check(m.violations == 0, "monkey seed \(seed): \(m.executed) steps over \(docs) documents, \(m.violations) invariant violations\(m.violations > 0 ? " (reproduce: --selftest monkey --seed \(seed) --steps \(steps) --docs \(docs); first: \(m.firstViolation))" : "")")
        }
        _ = findChange0      // (the find pasteboard is system-wide: other applications change it too, so its change count proves nothing; the monkey never writes it)
        if !allSlow.isEmpty { t.note("steps over 100 ms of main thread (all seeds), worst first: " + allSlow.sorted { $0.1 > $1.1 }.prefix(12).map { "\($0.0) \(Int($0.1)) ms" }.joined(separator: "; ")) }
    }

    @MainActor final class Monkey {
        let t: SelfTest.T
        let seed: UInt64
        let docsN: Int
        let exotic: Bool
        var rng: TestRNG
        var slots: [MSlot] = []
        var step = 0
        var executed = 0
        var violations = 0
        var firstViolation = ""
        var current = MAction(k: "-")
        var recent: [String] = []
        var logHandle: FileHandle?
        var slowSteps: [(String, Double)] = []
        var perKind: [String: [Double]] = [:]
        var alertAnswer = 0
        var panelAnswer: URL?
        var baselineFDs = 0
        var baselineFDList: [String] = []
        let pasteboard: NSPasteboard
        let dir: URL
        let closeProbe = CloseProbe()
        var copyCounter = 0
        let wd = RobustWatchdog.shared
        var settleFailures = 0
        var notes: Set<String> = []
        var lastEditNote = "-"
        struct Closed { weak var doc: MarkdownDocument?; var file: String; var step: Int }
        var closedDocs: [Closed] = []

        init(_ t: SelfTest.T, seed: UInt64, docs: Int, exotic: Bool, logPath: String?) {
            self.t = t; self.seed = seed; self.docsN = docs; self.exotic = exotic
            rng = TestRNG(seed &* 0x2545F491 &+ 17)
            dir = t.url("monkey-\(seed)")
            pasteboard = NSPasteboard(name: NSPasteboard.Name("local.luftig.robust.monkey.\(getpid()).\(seed)"))
            if let logPath {
                FileManager.default.createFile(atPath: logPath, contents: nil)
                logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            }
        }

        // MARK: reporting

        func violation(_ msg: String) {
            violations += 1
            if firstViolation.isEmpty { firstViolation = msg }
            t.check(false, "MONKEY VIOLATION seed \(seed) step \(step) after \(current): \(msg)")
            if violations <= 3 {
                t.info("last actions: " + recent.suffix(8).joined(separator: " | "))
                if !UITrap.alerts.isEmpty { t.info("alerts shown since the last reset: " + UITrap.alerts.suffix(4).map { "\($0)" }.joined(separator: " | ")) }
                t.info("documents: " + NSDocumentController.shared.documents.map { "\($0.displayName ?? "?") url=\($0.fileURL?.lastPathComponent ?? "nil") edited=\($0.isDocumentEdited)" }.joined(separator: ", "))
            }
        }
        func expect(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String) { if !cond() { violation(msg()) } }
        func noteOnce(_ s: String) { if notes.insert(s).inserted { t.note("monkey seed \(seed) step \(step): \(s)") } }

        // MARK: run

        func run(steps: Int, script: [MAction]?) async throws {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            UITrap.allowedRoot = dir
            UITrap.alertChooser = { [unowned self] rec in
                // NSDocument's "could not be saved / autosaved" alert: [Cancel, Duplicate, Discard]. "Duplicate" would create a document the
                // monkey does not track, so it is never chosen (the answer picks Cancel or Discard).
                // The "file is locked" sheet NSDocument shows at the first edit of a document whose file is not writable (chmod 000 by an external
                // writer): [Unlock, Cancel, Duplicate]. Unlock (the user is the owner) keeps the monkey's edits going.
                if rec.buttons == ["Unlock", "Cancel", "Duplicate"] { return 0 }
                if rec.buttons.contains("Duplicate") { return rec.buttons.firstIndex(of: self.alertAnswer == 1 ? "Discard" : "Cancel") ?? 0 }
                // otherwise by position: 0 = first button, 1 = second, 2 = the last (Cancel)
                switch self.alertAnswer { case 0: return 0; case 1: return min(1, rec.buttons.count - 1); default: return rec.buttons.count - 1 }
            }
            UITrap.panelChooser = { [unowned self] _ in self.panelAnswer }
            baselineFDs = RobustResources.fds().total
            baselineFDList = RobustResources.fdList()
            for i in 0..<docsN {
                // (one slot gets a name full of shell and Unicode traps: quotes, $, backtick, #, a space, accents, a snowman, a combining mark)
                let f = dir.appendingPathComponent(i == 1 ? "m1 \u{2018}q\u{2019} \"d\" $HOME `x` #1 e\u{301}\u{2603}.md" : "m\(i).md")
                let size = [3_000, 60_000, 300_000, 20_000, 120_000][i % 5]
                try Data(SelfTestCorpus.markdown(bytes: size, seed: seed &* 31 &+ UInt64(i), nonASCII: i % 2 == 0).utf8).write(to: f)
                slots.append(MSlot(index: i, file: f))
            }
            for s in slots { await open(s) }
            t.note("monkey seed \(seed): \(steps) steps, \(docsN) documents (\(slots.map { "\($0.host?.currentText.length ?? 0)" }.joined(separator: ", ")) units)")
            let tStart = SelfTest.nowMs()
            for i in 0..<steps {
                step = i
                let action: MAction
                if let script { guard i < script.count else { break }; action = script[i] }
                else { action = generateAction(&rng, docs: docsN, exotic: exotic) }
                current = action
                recent.append("\(i): \(action)"); if recent.count > 40 { recent.removeFirst() }
                if let h = logHandle { h.write(Data((action.json() + "\n").utf8)) }
                wd.label = "monkey seed \(seed) step \(i): \(action)"
                let t0 = SelfTest.nowMs()
                openMsInStep = 0
                await perform(action)
                let ms = SelfTest.nowMs() - t0 - openMsInStep
                executed += 1
                perKind[action.k, default: []].append(ms)
                if ms > 100 && !["wait", "ext", "save", "close", "reopen", "openBig", "newdoc", "saveAs", "activate", "choose", "revert"].contains(action.k) { slowSteps.append(("seed \(seed) step \(i) \(action.k)", ms)) }
                await invariants(after: action)
                if violations >= 6 { t.note("monkey seed \(seed): stopping after 6 violations"); break }
            }
            step = steps
            current = MAction(k: "final-settle")
            wd.label = "monkey seed \(seed): final settle"
            await periodicSettleCheck()
            for s in openSlots { await oracle(s) }
            await shutdown()
            let secs = (SelfTest.nowMs() - tStart) / 1000
            let kinds = perKind.map { ($0.key, $0.value.count, $0.value.sorted()[$0.value.count / 2], $0.value.max() ?? 0) }.sorted { $0.3 > $1.3 }.prefix(8)
            t.note(String(format: "monkey seed %llu: %d steps in %.1f s. slowest kinds (n, median, max ms): %@", seed, executed, secs,
                          kinds.map { "\($0.0) (\($0.1), \(Int($0.2)), \(Int($0.3)))" }.joined(separator: ", ")))
            try? logHandle?.close()
        }

        // MARK: slots

        var openSlots: [MSlot] { slots.filter { $0.doc != nil } }

        var openMsInStep = 0.0
        func open(_ s: MSlot) async {
            guard s.doc == nil, FileManager.default.fileExists(atPath: s.file.path) else { return }
            let t0 = SelfTest.nowMs()
            defer { let ms = SelfTest.nowMs() - t0; openMsInStep += ms; perKind["(open)", default: []].append(ms) }
            do {
                let d = try await t.open(s.file, size: NSSize(width: 700 + 40 * s.index, height: 500))
                s.doc = d
                s.undoStack = []; s.redoStack = []; s.undoTruncated = false
                s.lastGeneration = d.generation
                s.lastMerges = d.stats.merges; s.lastSilent = d.stats.silentReloads
                s.overwritePermitted = false
                s.undoPastExternal = false
                await t.spin(1)
                resync(s)
            } catch {
                s.doc = nil        // a file the monkey made unreadable (binary, chmod 000...): refusing it is right
            }
        }

        /// Takes the editor's text as the model (after an open or an external apply).
        func resync(_ s: MSlot) {
            guard let h = s.host else { return }
            s.model = h.currentText.copy() as? NSString
            s.trackUndo = (s.model?.length ?? 0) <= 1_500_000
        }

        func pickRange(_ s: MSlot, _ frac: Double, length: Int = 0) -> NSRange {
            guard let h = s.host else { return NSRange(location: 0, length: 0) }
            let len = h.currentText.length
            let loc = min(len, max(0, Int(Double(len) * frac)))
            return NSRange(location: loc, length: min(length, len - loc))
        }

        func spin(_ ms: Double) async { await t.spin(ms) }

        // MARK: perform

        func perform(_ a: MAction) async {
            let s = slots[a.d % slots.count]
            switch a.k {
            case "reopen": if s.doc == nil { await open(s) } else { await spin(1) }; return
            case "ext": await external(s, a); return
            case "wait": await spin(Double(a.n)); return
            case "openBig": await openBig(s, mb: a.n); return
            case "newdoc": await newDocument(s, text: a.s); return
            case "activate":
                NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                for o in openSlots { if let w = o.doc?.sheetWindow { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w) } }
                await spin(5); return
            case "font":
                let fs = EditorPreferences.fontSize
                EditorPreferences.fontSize = a.n == 0 ? EditorPreferences.defaultFontSize : fs + CGFloat(a.n)
                await spin(1); return
            case "readable": EditorPreferences.readableWidth.toggle(); await spin(1); return
            default: break
            }
            // everything below needs an open document in the slot: a closed slot is reopened (what a user would do first)
            if s.doc == nil { await open(s); if s.doc == nil { return } }
            guard let d = s.doc, let h = s.host else { return }
            let tv = h.textView
            switch a.k {
            case "type", "marker", "exotic": edit(s, range: pickRange(s, a.a), with: a.s)
            case "newline": edit(s, range: pickRange(s, a.a), with: "\n")
            case "delete":
                let r = pickRange(s, a.a)
                let n = min(a.n, r.location)
                if n > 0 { edit(s, range: NSRange(location: r.location - n, length: n), with: "") }
            case "deleteLine":
                let text = h.currentText
                if text.length > 0 { edit(s, range: text.lineRange(for: pickRange(s, a.a)), with: "") }
            case "replaceAll":
                if h.currentText.length < 600_000 { edit(s, range: NSRange(location: 0, length: h.currentText.length), with: a.s) }
            case "paste": pasteText(s, range: pickRange(s, a.a), text: a.s)
            case "undo": undo(s, times: a.n)
            case "redo": redo(s, times: a.n)
            case "scroll": t.scrollToTop(h, character: Int(Double(h.currentText.length) * a.a))
            case "jumpEnd": tv.moveToEndOfDocument(nil)
            case "jumpStart": tv.moveToBeginningOfDocument(nil)
            case "pageDown": tv.pageDown(nil); h.styler.styleVisible()
            case "pageUp": tv.pageUp(nil); h.styler.styleVisible()
            case "resize":
                if let w = d.windowControllers.first?.window {
                    switch a.n {
                    case 1: w.setContentSize(NSSize(width: 1, height: 1))                    // below minSize: AppKit clamps to 360 x 240
                    case 2: w.setContentSize(NSSize(width: 7000, height: 4000))              // larger than any screen
                    case 3: w.setContentSize(NSSize(width: 360, height: 6000))
                    default: w.setContentSize(NSSize(width: 320 + 1300 * a.a, height: 200 + 900 * a.b))
                    }
                    w.contentView?.layoutSubtreeIfNeeded()
                    h.styler.styleVisible()
                }
            case "appearance":
                d.windowControllers.first?.window?.appearance = NSAppearance(named: a.n == 0 ? .aqua : .darkAqua)
                if let w = d.windowControllers.first?.window { _ = t.renderPNG(w) }
            case "spell":
                // Continuous spell checking is switched on and straight off again. Left on, AppKit's autocorrection "guesses" timer runs a NESTED
                // event loop (NSCorrectionPanel._interceptEvents) on the main thread that only ends on a real mouse / key event - in this headless
                // process it never does, and every NSDocument save completion behind it never arrives (sampled: the stuck saves of seed 6).
                h.luftigToggleSpellChecking(nil); await spin(1); h.luftigToggleSpellChecking(nil)
                expect(!tv.isContinuousSpellCheckingEnabled, "spell checking is off again after the toggle pair")
            case "find": await find(s, a)
            case "save": await save(s, a)
            case "saveAs": await saveAs(s)
            case "close": await close(s, answer: a.n)
            case "choose": await choose(s, a.n)
            case "revert": await revertAction(s, answer: a.n)
            case "draw": if let w = d.windowControllers.first?.window { _ = t.renderPNG(w) }
            default: break
            }
            await spin(1)
        }

        // MARK: editing

        /// A range whose ends do not split a grapheme cluster (a surrogate pair, a base letter and its combining marks, an emoji ZWJ sequence): a person
        /// cannot put the caret there, and NSTextView moves a selection that starts inside one to the cluster's start.
        func safeRange(_ model: NSString, _ range: NSRange) -> NSRange {
            let rr = NSIntersectionRange(range, NSRange(location: 0, length: model.length))
            guard model.length > 0 else { return rr }
            if rr.length > 0 { return model.rangeOfComposedCharacterSequences(for: rr) }
            let loc = min(rr.location, model.length)
            if loc == 0 || loc >= model.length { return NSRange(location: loc, length: 0) }
            let cluster = model.rangeOfComposedCharacterSequence(at: loc)
            return NSRange(location: cluster.location, length: 0)       // an insertion point inside a cluster: before it
        }

        func pushUndo(_ s: MSlot, _ pre: NSString) {
            guard s.trackUndo else { return }
            s.undoStack.append(pre)
            if s.undoStack.count > 100 { s.undoStack.removeFirst(); s.undoTruncated = true }
            s.redoStack.removeAll()
        }

        func edit(_ s: MSlot, range: NSRange, with string: String) {
            guard let d = s.doc else { return }
            syncModel(s)
            guard let model = s.model else { return }
            let rr = safeRange(model, range)
            if rr.length == 0 && string.isEmpty { return }
            lastEditNote = "typeText \(string.debugDescription.prefix(40)) at \(NSStringFromRange(rr)) of \(model.length)"
            t.typeText(string, into: d, at: rr)
            let m = NSMutableString(string: model as String)
            m.replaceCharacters(in: rr, with: string)
            s.model = m.copy() as? NSString
            pushUndo(s, model)
        }

        func pasteText(_ s: MSlot, range: NSRange, text: String) {
            guard let h = s.host else { return }
            syncModel(s)
            guard let model = s.model else { return }
            let rr = safeRange(model, range)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let tv = h.textView
            tv.setSelectedRange(rr)
            let um = tv.undoManager
            um?.beginUndoGrouping()
            lastEditNote = "paste \(text.debugDescription.prefix(40)) at \(NSStringFromRange(rr)) of \(model.length)"
            let ok = tv.readSelection(from: pasteboard, type: .string)
            tv.breakUndoCoalescing()
            um?.endUndoGrouping()
            expect(ok, "readSelection(from: private pasteboard) refused plain text")
            if ok {
                let m = NSMutableString(string: model as String)
                m.replaceCharacters(in: rr, with: text)
                s.model = m.copy() as? NSString
                pushUndo(s, model)
            } else { resync(s) }
        }

        func undo(_ s: MSlot, times: Int) {
            guard let h = s.host, let um = h.textView.undoManager else { return }
            for _ in 0..<times {
                syncModel(s)
                let had = um.canUndo
                if had, let d = s.doc, d.stats.merges > 0 || d.stats.conflicts > 0 { s.undoPastExternal = true }
                if s.trackUndo && !s.undoTruncated { expect(had == !s.undoStack.isEmpty, "canUndo is \(had) but the monkey recorded \(s.undoStack.count) undoable edits") }
                guard had else { return }
                let pre = s.model
                um.undo()
                if s.trackUndo, !s.undoTruncated, let prev = s.undoStack.popLast() {
                    if let pre { s.redoStack.append(pre) }
                    s.model = prev
                } else { resync(s); s.undoStack.removeAll(); s.redoStack.removeAll() }
            }
        }

        func redo(_ s: MSlot, times: Int) {
            guard let h = s.host, let um = h.textView.undoManager else { return }
            for _ in 0..<times {
                syncModel(s)
                let had = um.canRedo
                if s.trackUndo && !s.undoTruncated { expect(had == !s.redoStack.isEmpty, "canRedo is \(had) but the monkey recorded \(s.redoStack.count) redoable edits") }
                guard had else { return }
                let pre = s.model
                um.redo()
                if s.trackUndo, !s.undoTruncated, let next = s.redoStack.popLast() {
                    if let pre { s.undoStack.append(pre) }
                    s.model = next
                } else { resync(s); s.undoStack.removeAll(); s.redoStack.removeAll() }
            }
        }

        /// Called before every local action and after every step: the model must equal the editor, unless an external apply explains the
        /// difference (document.generation / merge / silent reload counters moved); then the editor's text becomes the model.
        func syncModel(_ s: MSlot) {
            guard let d = s.doc, let h = s.host else { return }
            let actual = h.currentText
            guard let model = s.model else { resync(s); s.lastGeneration = d.generation; return }
            if !model.isEqual(to: actual as String) {
                if d.generation != s.lastGeneration || d.stats.merges != s.lastMerges || d.stats.silentReloads != s.lastSilent {
                    // silent reload: the undo history is cleared; merge / Reload from Disk: one undoable edit on top of it
                    let canUndo = h.textView.undoManager?.canUndo ?? false
                    if canUndo && s.trackUndo { pushUndo(s, model) } else { s.undoStack.removeAll(); s.redoStack.removeAll(); s.undoTruncated = false }
                    resync(s)
                    // the undo entry of an external apply on a document too big to track (or a tracked one that became small again) is a history
                    // the monkey has no snapshots for: the count check pauses until the next reset
                    if canUndo && s.undoStack.isEmpty { s.undoTruncated = true }
                    // two or more external applies since the last look are separate undo entries the monkey holds one snapshot for
                    if (d.stats.merges - s.lastMerges) + (d.stats.silentReloads - s.lastSilent) > 1 { s.undoTruncated = true }
                } else {
                    var i = 0
                    let n = min(actual.length, model.length)
                    while i < n, actual.character(at: i) == model.character(at: i) { i += 1 }
                    func ctx(_ t: NSString) -> String { t.substring(with: NSRange(location: max(0, i - 12), length: min(t.length - max(0, i - 12), 40))).debugDescription }
                    violation("the text storage (\(actual.length) units) differs from the model (\(model.length) units) and no external apply happened (generation \(d.generation)); first difference at \(i): editor \(ctx(actual)) model \(ctx(model)); last edit \(lastEditNote)")
                    resync(s); s.undoStack.removeAll(); s.redoStack.removeAll(); s.undoTruncated = false
                }
            } else if d.generation != s.lastGeneration && !(h.textView.undoManager?.canUndo ?? false) && !s.undoStack.isEmpty {
                // same text, but the history was cleared (a silent reload to identical text cannot happen; a revert can)
                s.undoStack.removeAll(); s.redoStack.removeAll(); s.undoTruncated = false
            }
            s.lastGeneration = d.generation
            s.lastMerges = d.stats.merges; s.lastSilent = d.stats.silentReloads
        }

        // MARK: find

        func find(_ s: MSlot, _ a: MAction) async {
            guard let h = s.host else { return }
            let tv = h.textView
            func item(_ act: NSTextFinder.Action) -> NSMenuItem { let i = NSMenuItem(); i.tag = act.rawValue; return i }
            switch a.n {
            case 0: tv.performTextFinderAction(item(.showFindInterface))
            case 1: tv.performTextFinderAction(item(.hideFindInterface))
            case 2: tv.performTextFinderAction(item(.showReplaceInterface))
            case 3: tv.performTextFinderAction(item(.nextMatch)); tv.performTextFinderAction(item(.previousMatch))
            default:
                // what the find bar does for a hit: select the range, scroll to it, flash the indicator
                let text = h.currentText
                guard text.length > 8 else { return }
                let start = min(text.length - 4, Int(Double(text.length) * a.a))
                let word = text.substring(with: NSRange(location: start, length: min(5, text.length - start)))
                let hit = text.range(of: word, options: [], range: NSRange(location: 0, length: text.length))
                if hit.location != NSNotFound {
                    h.styler.prestyle(aroundCharacter: hit.location)
                    tv.setSelectedRange(hit)
                    tv.scrollRangeToVisible(hit)
                    tv.showFindIndicator(for: hit)
                    h.styler.styleVisible()
                }
            }
            await spin(3)
        }

        // MARK: disk helpers

        func readDisk(_ s: MSlot) -> Data? {
            guard let sig = FileSignature.of(path: s.file.path), sig.size <= Int64(TextCodec.maxFileBytes) else { return nil }
            return try? Data(contentsOf: s.file)
        }
        /// Is the file's decoded text what the editor shows? A document whose line endings are normalised folds CR / CRLF the user typed or pasted
        /// into LF when it writes (TextCodec.encode: "stray CRs ... would double up"), so the comparison folds the editor text the same way.
        func same(_ disk: NSString, _ editor: NSString, _ d: MarkdownDocument) -> Bool {
            if disk.isEqual(to: editor as String) { return true }
            guard d.textFormat.lineEnding.isNormalised, editor.range(of: "\r").location != NSNotFound else { return false }
            let folded = (editor as String).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return disk.isEqual(to: folded)
        }
        func decodeFailure(_ s: MSlot) -> String {
            guard let data = readDisk(s) else { return "file unreadable / too large" }
            do { _ = try TextCodec.decode(data); return "decodes (?)" } catch {
                let nul = data.firstIndex(of: 0).map { "first NUL byte at offset \($0)" } ?? "no NUL byte"
                return "\(error) [\(data.count) bytes, \(nul)]"
            }
        }
        func hash(_ d: Data?) -> UInt64? { d.map { b in b.withUnsafeBytes { FastHash.hash64($0) } } }
        func decodedDisk(_ s: MSlot) -> (text: NSString, hash: UInt64)? {
            guard let data = readDisk(s), let dec = try? TextCodec.decode(data) else { return nil }
            return (dec.text, hash(data) ?? 0)
        }

        // MARK: save / close / choose / revert

        func save(_ s: MSlot, _ a: MAction) async {
            guard let d = s.doc, let h = s.host else { return }
            if a.b == 0 { await settle([s], maxMs: 900) }
            syncModel(s)
            let before = hash(readDisk(s))
            let known = d.lastDisk?.hash
            let stateBefore = d.syncState
            let merges0 = d.stats.merges
            alertAnswer = [0, 0, 1, 2][a.n % 4]
            UITrap.reset()
            var err: Error?
            var finished = true
            switch a.n {
            case 0: err = await t.autosave(d)
            case 1, 2:
                let w = SaveWaiter()
                d.save(withDelegate: w, didSave: #selector(SaveWaiter.document(_:didSave:contextInfo:)), contextInfo: nil)
                finished = await t.waitFor(6000) { w.result != nil }
                if w.result == false { err = CocoaError(.userCancelled) }
            default:
                let r = await withTimeout(6000) { await self.saveTo(d, s.file) }
                finished = r != nil
                if r == false { err = CocoaError(.userCancelled) }
            }
            await spin(2)
            expect(finished, "save (variant \(a.n)) did not complete within 6 s (state \(d.syncState), isSaving \(d.isSaving), edited \(d.isDocumentEdited), file exists \(FileManager.default.fileExists(atPath: s.file.path)))")
            if !finished {
                let presenters = NSFileCoordinator.filePresenters.map { p -> String in
                    if let md = p as? MarkdownDocument { return "MarkdownDocument(\(md.fileURL?.lastPathComponent ?? "nil"), closed=\(md.isClosed), saving=\(md.isSaving))" }
                    return String(describing: type(of: p))
                }
                t.note("file presenters registered: \(presenters)")
                t.note("windows: \(NSApp.windows.map { "\(type(of: $0)) '\($0.title)' sheet=\($0.isSheet) attachedSheet=\($0.attachedSheet.map { "\(type(of: $0))" } ?? "none")" }); modal window: \(NSApp.modalWindow.map { "\(type(of: $0))" } ?? "none"); alerts trapped so far: \(UITrap.alerts.count), panels: \(UITrap.panels.map { "\($0)" })")
                t.note("closed documents still alive: \(closedDocs.filter { $0.doc != nil }.map { "\($0.file)@step\($0.step)" })")
                await RobustSample.ofSelf("a save that never completes", t: t)
            }
            let after = hash(readDisk(s))
            let wrote = after != before
            let sheetChoice = UITrap.alerts.first?.chosen
            if wrote {
                // the app wrote the file: it must hold the editor text, and the document must have been entitled to replace what was there
                if let dec = decodedDisk(s) { expect(same(dec.text, h.currentText, d), "after a save the file (\(dec.text.length) units) is not the editor text (\(h.currentText.length) units): the data written is not what the user sees") }
                else { violation("the file written by a save does not decode: \(decodeFailure(s)) (editor text: first U+0000 at \(h.currentText.range(of: "\u{0}").location == NSNotFound ? "none" : String(h.currentText.range(of: "\u{0}").location)))") }
                let unseen = before != nil && before != known && stateBefore != .deletedOnDisk
                if unseen {
                    let entitled = d.stats.merges > merges0 || sheetChoice == 0 || s.overwritePermitted
                    expect(entitled, "UNAUTHORISED OVERWRITE: a save replaced a disk version (hash \(before.map { String($0, radix: 16) } ?? "-")) the document had not loaded (it knew \(known.map { String($0, radix: 16) } ?? "-"), state before: \(stateBefore)) - the other tool's text is gone")
                }
                if stateBefore == .conflict || stateBefore == .unreadable, a.n == 0 { violation("an autosave wrote the file while the document was in state \(stateBefore)") }
                s.overwritePermitted = false
                s.undoPastExternal = false
            } else if a.b == 0, err == nil, stateBefore == .inSync, d.syncState == .inSync, d.isDocumentEdited == false {
                // (only for a save that settled the watchers first: a clean document legitimately shows the old text until the next check)
                if let dec = decodedDisk(s) { expect(same(dec.text, h.currentText, d), "a successful save left the file (\(dec.text.length) units) different from the editor text (\(h.currentText.length) units)") }
            }
        }

        func saveTo(_ d: MarkdownDocument, _ url: URL) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                d.save(to: url, ofType: d.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { error in c.resume(returning: error == nil) }
            }
        }

        func saveAsOp(_ d: MarkdownDocument, _ url: URL) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                d.save(to: url, ofType: d.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation) { error in c.resume(returning: error == nil) }
            }
        }

        func withTimeout<R>(_ ms: Double, _ body: @escaping @MainActor () async -> R) async -> R? {
            var result: R?
            var done = false
            Task { @MainActor in result = await body(); done = true }
            _ = await t.waitFor(ms) { done }
            return done ? result : nil
        }

        func saveAs(_ s: MSlot) async {
            guard let d = s.doc, let h = s.host else { return }
            await settle([s], maxMs: 900)
            syncModel(s)
            copyCounter += 1
            let newURL = dir.appendingPathComponent("m\(s.index)-copy\(copyCounter).md")
            let ok = await withTimeout(6000) { await self.saveAsOp(d, newURL) } ?? false
            await spin(5)
            if ok {
                s.file = newURL
                if let dec = decodedDisk(s) { expect(same(dec.text, h.currentText, d), "Save As wrote a file that differs from the editor text") }
                else { violation("Save As produced no readable file") }
                expect(d.fileURL?.lastPathComponent == newURL.lastPathComponent, "after Save As the document still represents \(d.fileURL?.lastPathComponent ?? "nil")")
                s.lastGeneration = d.generation
            }
        }

        func close(_ s: MSlot, answer: Int) async {
            guard let d = s.doc, let h = s.host else { return }
            await spin(40)                       // a person closes a window well after the last key press (NSDocument registers a change one run-loop turn later)
            syncModel(s)
            alertAnswer = answer
            UITrap.reset()
            let before = hash(readDisk(s))
            let stateBefore = d.syncState
            let editedBefore = d.isDocumentEdited
            let known = d.lastDisk?.hash
            let startDesc = "at the start of the close: state \(d.syncState), lastDisk hash \(known.map { String($0, radix: 16) } ?? "nil") size \(d.lastDisk?.byteCount ?? -1), edited \(d.isDocumentEdited), text units \(h.currentText.length), file bytes \(readDisk(s)?.count ?? -1)"
            let merges0 = d.stats.merges
            closeProbe.result = nil
            d.canClose(withDelegate: closeProbe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            let answered = await t.waitFor(6000) { self.closeProbe.result != nil }
            expect(answered, "canClose never answered within 6 s (state \(stateBefore), sheets \(UITrap.alerts.map { $0.buttons }))")
            guard answered else { return }
            let shouldClose = closeProbe.result == true
            await spin(5)
            let textAtClose = h.currentText.copy() as! NSString
            let after = hash(readDisk(s))
            let sheet = UITrap.alerts.first?.chosen
            if shouldClose {
                closedDocs.append(Closed(doc: d, file: s.file.lastPathComponent, step: step))
                d.close()
                s.doc = nil
                if stateBefore == .inSync {
                    if after != before {
                        // the close wrote the file: it must be the user's text; and it must not have replaced a version the document did not know
                        if let dec = decodedDisk(s) { expect(same(dec.text, textAtClose, d), "closing wrote a file (\(dec.text.length) units) that is not the editor text (\(textAtClose.length) units)") }
                        if before != nil && before != known { expect(d.stats.merges > merges0 || sheet == 0 || s.overwritePermitted, "UNAUTHORISED OVERWRITE on close: the file held a version (hash \(before.map { String($0, radix: 16) } ?? "-")) the document did not know (\(known.map { String($0, radix: 16) } ?? "-")); now \(after.map { String($0, radix: 16) } ?? "-"); sheet \(sheet.map(String.init) ?? "none"); \(startDesc); \(describeWatcher(d, s))") }
                    } else if editedBefore {
                        // closed a dirty document and the file is unchanged: only fine when the file already has the text
                        if let dec = decodedDisk(s) { expect(same(dec.text, textAtClose, d), "DATA LOSS: closed a document with unsaved edits and the file does not contain them (file \(dec.text.length) units, editor \(textAtClose.length) units, sheets \(UITrap.alerts.count))") }
                    }
                } else {
                    // conflict / unreadable / deleted: Overwrite / Save Again write the user's text, Discard leaves the disk alone
                    if after != before {
                        expect(sheet == 0, "closing in state \(stateBefore): the file changed although the user did not choose Overwrite / Save Again (sheet answer \(sheet.map(String.init) ?? "none"))")
                        if let dec = decodedDisk(s) { expect(same(dec.text, textAtClose, d), "Overwrite on close wrote something other than the editor text") }
                    }
                }
                expect(!NSDocumentController.shared.documents.contains(where: { $0 === d }), "the closed document is still registered with NSDocumentController")
            } else {
                if stateBefore == .inSync && d.syncState != .inSync { noteOnce("close refused with no sheet while an external change was being noticed (state \(stateBefore) -> \(d.syncState)); the banner now explains it") }
                else if stateBefore == .inSync && UITrap.alerts.isEmpty && editedBefore && FileSignature.of(path: s.file.path) == nil {
                    noteOnce("FINDING: Close of a dirty document does nothing, silently, while the app has not yet noticed that its file is gone (grace period ~1.6 s): the held-back autosave cancels the close")
                }
                else if stateBefore == .inSync && UITrap.alerts.isEmpty && !editedBefore { violation("a clean in-sync document refused to close without asking anything") }
                else if stateBefore == .inSync && UITrap.alerts.isEmpty && d.syncState == .inSync { violation("a dirty in-sync document refused to close without a sheet (autosave failed?)") }
                expect(h.currentText.isEqual(to: textAtClose as String), "Cancel on close changed the text")
            }
        }

        func choose(_ s: MSlot, _ which: Int) async {
            guard let d = s.doc, let h = s.host else { return }
            await settle([s], maxMs: 900)
            syncModel(s)
            let textBefore = h.currentText.copy() as! NSString
            let applied0 = (d.generation, d.stats.merges, d.stats.silentReloads)
            func appliedMeanwhile() -> Bool { (d.generation, d.stats.merges, d.stats.silentReloads) != applied0 }
            switch d.syncState {
            case .conflict:
                let diskText = d.conflict?.diskText
                let before = hash(readDisk(s))
                if which == 0 {
                    h.pressBannerButton("Reload from Disk")
                    await spin(5)
                    syncModel(s)
                    if let diskText { expect(h.currentText.isEqual(to: diskText as String) || appliedMeanwhile(), "Reload from Disk did not show the disk version") }
                    expect(h.textView.undoManager?.canUndo == true, "Reload from Disk after a conflict is not undoable")
                    expect(d.syncState == .inSync, "state after Reload from Disk is \(d.syncState)")
                } else {
                    h.pressBannerButton("Keep My Version")
                    await spin(5)
                    s.overwritePermitted = true
                    // (a newer external version may be merged / reloaded right after the button: only a change without one is a violation)
                    expect(h.currentText.isEqual(to: textBefore as String) || appliedMeanwhile(), "Keep My Version changed the text (no external apply in between: generation \(applied0.0) -> \(d.generation))")
                    // (the button itself writes nothing; an autosave that was already due may fire right after it - the user just allowed that: the bytes are then
                    // exactly the ones the document encoded)
                    let nowHash = hash(readDisk(s))
                    expect(nowHash == before || (d.lastEncoded != nil && nowHash == d.lastEncoded?.hash), "Keep My Version wrote the file by itself")
                    expect(d.syncState == .inSync, "state after Keep My Version is \(d.syncState)")
                }
            case .unreadable:
                h.pressBannerButton("Keep My Version")
                s.overwritePermitted = true
                await spin(5)
            case .deletedOnDisk:
                alertAnswer = 0
                panelAnswer = s.file
                UITrap.reset()
                d.save(nil)
                _ = await t.waitFor(3000) { FileManager.default.fileExists(atPath: s.file.path) }
                await spin(20)
                panelAnswer = nil
                if let dec = decodedDisk(s) { expect(same(dec.text, textBefore, d), "Save Again wrote something other than the editor text") }
                else { violation("Save Again did not recreate the file") }
            case .inSync:
                break
            }
        }

        func revertAction(_ s: MSlot, answer: Int) async {
            guard let d = s.doc, let h = s.host else { return }
            await settle([s], maxMs: 900)
            syncModel(s)
            alertAnswer = answer
            UITrap.reset()
            d.luftigReloadFromDisk(nil)
            await spin(30)
            if answer == 0 || UITrap.alerts.isEmpty, d.syncState == .inSync, let dec = decodedDisk(s) {
                syncModel(s)
                expect(h.currentText.isEqual(to: dec.text as String), "File > Reload from Disk left text that is not the file (\(h.currentText.length) vs \(dec.text.length) units)")
            }
        }

        // MARK: new document / big file

        func newDocument(_ s: MSlot, text: String) async {
            guard s.doc == nil else { return }
            do {
                let d = try t.newUntitled()
                s.doc = d
                copyCounter += 1
                let url = dir.appendingPathComponent("m\(s.index)-new\(copyCounter).md")
                guard let h = s.host else { return }
                t.typeText(text, into: d)
                await spin(5)
                let ok = await withTimeout(6000) { await self.saveAsOp(d, url) } ?? false
                expect(ok, "the first save of a new document failed")
                if ok {
                    s.file = url
                    s.model = nil; resync(s)
                    s.undoStack = []; s.redoStack = []; s.undoTruncated = false
                    if h.textView.undoManager?.canUndo == true { s.undoStack = [""] }      // the typed text is one undoable edit of the empty document
                    s.lastGeneration = d.generation
                    if let dec = decodedDisk(s) { expect(same(dec.text, h.currentText, d), "the first save of a new document wrote something other than its text") }
                    else { violation("new document: no readable file after the first save") }
                } else { d.updateChangeCount(.changeCleared); d.close(); s.doc = nil }
            } catch { violation("could not create a new document: \(error)") }
        }

        func openBig(_ s: MSlot, mb: Int) async {
            if let d = s.doc {
                await settle([s], maxMs: 900)
                alertAnswer = 0
                closeProbe.result = nil
                d.canClose(withDelegate: closeProbe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
                _ = await t.waitFor(6000) { self.closeProbe.result != nil }
                if closeProbe.result == true { d.close(); s.doc = nil } else { return }
            }
            copyCounter += 1
            let url = dir.appendingPathComponent("m\(s.index)-big\(copyCounter).md")
            do { try RobustFiles.writeCorpus(url, bytes: mb << 20, seed: seed &+ UInt64(copyCounter), nonASCII: mb % 2 == 1) } catch { return }
            s.file = url
            await open(s)
            s.host?.styler.styleVisible()
        }

        // MARK: external writers

        func external(_ s: MSlot, _ a: MAction) async {
            let f = t.q(s.file)
            var kind = externalKinds[a.n % externalKinds.count]
            // FINDING (robust-regress "symlink-save"): once an open document's file has been replaced by a symlink to a regular file, NSDocument can no
            // longer save it ("The file doesn't exist"). The monkey would drown in that, so the swap is only done with --symlinks.
            if kind == "symlink" && !SelfTest.flag("symlinks") { kind = "atomic" }
            let tag = a.s
            var cmd: String
            switch kind {
            case "append": cmd = "[ -f \(f) ] && printf '\\n%s appended line\\n' \(tag) >> \(f)"
            case "rewrite": cmd = "printf '# %s\\n\\nrewritten body with *emphasis* and `code`\\n\\n> quote\\n' \(tag) > \(f)"
            case "atomic": cmd = "printf '# %s atomic\\n\\nreplaced atomically\\n\\n- a\\n- b\\n' \(tag) > \(f).tmp && mv \(f).tmp \(f)"
            case "delete": cmd = "rm -f \(f)"
            case "recreate": cmd = "rm -f \(f); sleep 0.03; printf '# %s recreated\\n\\ntext\\n' \(tag) > \(f)"
            case "rename-away-back": cmd = "[ -f \(f) ] && { mv \(f) \(f).away; sleep 0.1; printf '\\n%s renamed-back\\n' \(tag) >> \(f).away; mv \(f).away \(f); }"
            case "touch-r": cmd = "[ -s \(f) ] && { R=\(f).ref; touch -r \(f) \"$R\"; sz=$(wc -c < \(f)); { head -c $((sz-1)) \(f); printf 'Z'; } > \(f).new; cat \(f).new > \(f); touch -r \"$R\" \(f); rm -f \(f).new \"$R\"; }"
            case "binary": cmd = "printf '\\000\\001\\002\\377\\376\\000binary \\000 %s \\200\\201\\000' \(tag) > \(f)"
            case "chmod000": cmd = "[ -f \(f) ] && chmod 000 \(f)"
            case "symlink": cmd = "printf '# %s via symlink\\n\\ntarget text\\n' \(tag) > \(f).real && rm -f \(f) && ln -s \(f).real \(f)"
            case "utf16": cmd = "printf '\\377\\376#\\000 \\000U\\0001\\0006\\000\\n\\000t\\000x\\000\\n\\000' > \(f)"
            case "crlf": cmd = "printf '# %s crlf\\r\\n\\r\\nline\\r\\nline2\\r\\n' \(tag) > \(f)"
            case "empty": cmd = ": > \(f)"
            case "grow": cmd = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'grow %s\\n' $i >> \(f); sleep 0.01; done"
            case "touch-storm": cmd = "for i in $(seq 1 150); do touch \(f); done"
            default: cmd = "printf '# restored\\n\\nback again\\n' > \(f)"
            }
            // a file left chmod 000 by an earlier action is made readable again first by every kind that writes
            if !["chmod000", "symlink", "delete", "restore"].contains(kind) {
                cmd = "chmod 644 \(f) 2>&-; " + cmd
            } else if kind == "restore" {
                cmd = "rm -f \(f); " + cmd
            }
            if s.doc != nil { syncModel(s) }
            s.externalCount += 1
            s.overwritePermitted = false
            await t.sh(cmd)
            await spin(a.b)
        }

        // MARK: quiescence

        struct Probe: Equatable { var events: Int; var deliveries: Int; var checks: Int; var gen: Int }
        func probe(_ d: MarkdownDocument) -> Probe { Probe(events: d.monitor?.eventCount ?? 0, deliveries: d.monitor?.deliveryCount ?? 0, checks: d.stats.checks, gen: d.generation) }

        /// Waits until the watchers of the given slots have nothing in flight: no monitor event, check or reload for 150 ms, every in-sync
        /// document has caught up with the file's signature, and a vanished file has been recognised. False when that did not happen in `maxMs`.
        @discardableResult
        func settle(_ list: [MSlot], maxMs: Double) async -> Bool {
            let end = SelfTest.nowMs() + maxMs
            var last: [Probe] = []
            var stableSince = SelfTest.nowMs()
            while SelfTest.nowMs() < end {
                let docs = list.compactMap { $0.doc }
                let now = docs.map(probe)
                var busy = docs.contains { $0.checkInFlight || $0.recheckRequested || $0.isSaving || $0.isApplyingExternal }
                for s in list {
                    guard let d = s.doc, let url = d.fileURL, let lastDisk = d.lastDisk else { continue }
                    let sig = FileSignature.of(path: url.path)
                    switch d.syncState {
                    case .inSync:
                        if sig == nil || sig != lastDisk.signature { busy = true }      // missing: the grace period is running; different: a check is due
                    case .deletedOnDisk:
                        if sig != nil { busy = true }
                    default: break
                    }
                }
                if now != last || busy { last = now; stableSince = SelfTest.nowMs() }
                else if SelfTest.nowMs() - stableSince >= 150 { return true }
                await spin(20)
            }
            return false
        }

        // MARK: invariants

        func invariants(after a: MAction) async {
            if let w = SelfTest.argument("watch-slot").flatMap({ Int($0) }), step >= (SelfTest.argument("watch-from").flatMap { Int($0) } ?? 0), w < slots.count {
                let s = slots[w]
                let disk = readDisk(s)
                if let d = s.doc { t.info("watch step \(step) \(a.k): state \(d.syncState) edited \(d.isDocumentEdited) lastDisk hash \(d.lastDisk.map { String($0.hash, radix: 16) } ?? "nil")/\(d.lastDisk?.byteCount ?? -1) file bytes \(disk?.count ?? -1) hash \(hash(disk).map { String($0, radix: 16) } ?? "nil") units \(s.host?.currentText.length ?? -1) saving \(d.isSaving) unreadableSig \(d.lastUnreadableSignature != nil)") }
                else { t.info("watch step \(step) \(a.k): slot closed, file bytes \(disk?.count ?? -1)") }
            }
            let open = openSlots
            expect(NSDocumentController.shared.documents.count == open.count, "NSDocumentController has \(NSDocumentController.shared.documents.count) documents, the monkey has \(open.count) open")
            // (AppKit adds windows of its own - text input UI, spelling - lazily: count the editor windows)
            let editorWindows = NSApp.windows.filter { $0.windowController is EditorWindowController }
            expect(editorWindows.count == open.count, "\(editorWindows.count) editor windows for \(open.count) open documents")
            for s in open {
                guard s.doc != nil, let h = s.host else { continue }
                let tv = h.textView
                let len = tv.textStorage?.length ?? -1
                if let um = tv.undoManager { expect(um.groupingLevel == 0, "undo grouping level is \(um.groupingLevel) between steps") }
                let sel = tv.selectedRange()
                expect(sel.location != NSNotFound && NSMaxRange(sel) <= len, "selection \(NSStringFromRange(sel)) outside the text (\(len) units)")
                expect((tv.string as NSString).length == len, "text view string length differs from its storage")
                if let mx = h.styler.styled.max() { expect(mx < max(1, len), "styled set reaches \(mx) in a text of \(len) units") }
                if len <= 1_500_000 || step % 25 == 0 { syncModel(s) }
                // the app must never write the file while it sits on a disk version it has not loaded (conflict / unreadable): if the bytes on disk are
                // exactly the bytes the document last encoded, the document wrote them - and was not allowed to
                if let d = s.doc, d.syncState == .conflict || d.syncState == .unreadable, let enc = d.lastEncoded, let disk = readDisk(s), disk.count == enc.count, hash(disk) == enc.hash {
                    expect(s.overwritePermitted, "the document wrote the file while in state \(d.syncState): the disk version it had not loaded was replaced")
                }
            }
            if step % 20 == 19 { await oracle(slots[a.d % slots.count]) }
            if step % 60 == 59 { await periodicSettleCheck() }
        }

        /// Every styled character equals a FRESH Theme + MarkdownStyler.lexAll of the current text.
        func oracle(_ s: MSlot) async {
            guard let h = s.host, let ts = h.textView.textStorage, ts.length > 0, ts.length <= 600_000, !h.textView.hasMarkedText() else { return }
            await spin(2)
            h.styler.styleVisible()
            let text = ts.string as NSString
            let (expected, _) = StyleOracle.expectedRuns(text: text, baseSize: h.theme.baseSize, tableWidthLimit: h.provider.tables.widthLimit)
            guard !expected.isEmpty else { return }
            var bad = 0
            var first: String?
            for range in h.styler.styled.rangeView {
                var pos = range.lowerBound
                let hi = min(range.upperBound, ts.length)
                while pos < hi {
                    var lo = 0, up = expected.count - 1
                    while lo < up { let mid = (lo + up + 1) / 2; if expected[mid].range.location <= pos { lo = mid } else { up = mid - 1 } }
                    let run = expected[lo]
                    let runEnd = NSMaxRange(run.range)
                    if pos >= runEnd { pos = max(pos + 1, runEnd); continue }
                    var eff = NSRange(location: 0, length: 0)
                    let attrs = ts.attributes(at: pos, longestEffectiveRange: &eff, in: NSRange(location: pos, length: min(hi, runEnd) - pos))
                    var nonASCII = false
                    for i in eff.location..<min(NSMaxRange(eff), eff.location + 300) where text.character(at: i) > 0x7F { nonASCII = true; break }
                    if StyleOracle.attributesEqual(attrs, run.attributes, allowFontFallback: nonASCII) { pos = max(pos + 1, NSMaxRange(eff)) }
                    else {
                        bad += 1
                        if first == nil { first = "at \(NSStringFromRange(eff)) text \(text.substring(with: NSRange(location: eff.location, length: min(30, eff.length))).debugDescription): expected [\(StyleOracle.describe(run.attributes))] actual [\(StyleOracle.describe(attrs))]" }
                        pos = min(hi, runEnd)
                    }
                }
            }
            expect(bad == 0, "STALE ATTRIBUTES: \(bad) styled runs differ from a fresh lex; first \(first ?? "?")")
        }

        func periodicSettleCheck() async {
            let open = openSlots
            guard !open.isEmpty else { return }
            wd.label = "monkey seed \(seed) step \(step): settle"
            let quiet = await settle(open, maxMs: 5000)
            if !quiet { settleFailures += 1; if settleFailures <= 3 { t.note("monkey seed \(seed) step \(step): the watchers did not go quiet within 5 s") } }
            await settledChecks(open)
        }

        /// Invariants that only hold when nothing is in flight.
        func settledChecks(_ list: [MSlot]) async {
            for s in list {
                guard let d = s.doc, let h = s.host else { continue }
                syncModel(s)
                let exists = FileSignature.of(path: s.file.path) != nil
                if !exists {
                    if d.syncState != .deletedOnDisk {
                        let ok = await t.waitFor(2800) { d.syncState == .deletedOnDisk || FileSignature.of(path: s.file.path) != nil }
                        if !ok { violation("the file is gone but the document never reported it (state \(d.syncState))") }
                    }
                    continue
                }
                if d.syncState == .deletedOnDisk {
                    let ok = await t.waitFor(2500) { d.syncState != .deletedOnDisk }
                    if !ok { violation("the file came back but the document still says it was deleted") }
                    await settle([s], maxMs: 1500)
                    syncModel(s)
                }
                switch d.syncState {
                case .inSync:
                    guard let disk = decodedDisk(s) else {
                        // binary / too large / no permission: the document must have noticed - or the user chose "Keep My Version" for exactly this
                        // file version (then the document is in sync with an acknowledged, unreadable disk version by design)
                        let acknowledged = { FileSignature.of(path: s.file.path) == d.lastDisk?.signature }
                        let ok = await t.waitFor(2500) { d.syncState != .inSync || acknowledged() }
                        if !ok { violation("the file on disk is not readable text (binary / too large / no permission) but the document says it is in sync. \(describeWatcher(d, s))") }
                        continue
                    }
                    if !d.isDocumentEdited && !same(disk.text, h.currentText, d) {
                        // clean, in sync, watchers quiet: it must show the file. The presenter / activation safety nets get their chance first.
                        let ok = await t.waitFor(2600) { self.same(disk.text, h.currentText, d) || d.isDocumentEdited || d.syncState != .inSync }
                        syncModel(s)
                        if same(disk.text, h.currentText, d) {
                            if !ok || true { noteOnce("the editor caught up with the file only after the watchers had been quiet for 150 ms (last trigger '\(d.stats.lastReloadTrigger)')") }
                        } else if d.syncState == .inSync && !d.isDocumentEdited && s.undoPastExternal {
                            noteOnce("FINDING undo-merge: after Undo walked back past a merged / reloaded external change the document is clean and in sync but shows other text than the file")
                        } else if d.syncState == .inSync && !d.isDocumentEdited {
                            violation("STALE EDITOR: the document is clean and in sync but shows \(h.currentText.length) units while the file holds \(disk.text.length) units (last reload trigger '\(d.stats.lastReloadTrigger)') - the external change was never loaded")
                        }
                    }
                case .conflict:
                    expect(h.bannerVisible, "state conflict but no banner is visible")
                    if !d.isDocumentEdited { noteOnce("a conflicted document became clean again (Undo back to the saved state); the banner stays, nothing is lost") }
                case .unreadable:
                    expect(h.bannerVisible, "state unreadable but no banner is visible")
                case .deletedOnDisk:
                    break
                }
            }
        }

        func describeWatcher(_ d: MarkdownDocument, _ s: MSlot) -> String {
            let sig = FileSignature.of(path: s.file.path)
            let m = d.monitor
            return "watcher: events \(m?.eventCount ?? -1), deliveries \(m?.deliveryCount ?? -1), rebinds \(m?.rebindCount ?? -1), polling \(m?.isPolling ?? false); stats checks \(d.stats.checks) statUnchanged \(d.stats.statUnchanged) hashUnchanged \(d.stats.hashUnchanged) reloads \(d.stats.silentReloads); file \(s.file.lastPathComponent) sig [\(sig?.description ?? "none")]; lastDisk [\(d.lastDisk?.signature.description ?? "nil")]; unreadableSig \(d.lastUnreadableSignature != nil)"
        }

        // MARK: end

        func shutdown() async {
            for s in slots { await t.sh("chmod 644 \(t.q(s.file)) 2>&-; true") }
            for s in openSlots {
                guard let d = s.doc else { continue }
                alertAnswer = 1          // Discard / Reload: never write
                closeProbe.result = nil
                d.canClose(withDelegate: closeProbe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
                _ = await t.waitFor(6000) { self.closeProbe.result != nil }
                if closeProbe.result != true { d.updateChangeCount(.changeCleared) }
                d.close()
                s.doc = nil
            }
            for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared); d.close() }
            // (a connection AppKit is tearing down may still be on its way out: give the descriptors up to 3 s to go)
            func leftOver() -> [String] {
                RobustResources.fdList().filter { l in !baselineFDList.contains { $0.split(separator: ":").dropFirst().joined(separator: ":") == l.split(separator: ":").dropFirst().joined(separator: ":") } }
                    .filter { !$0.contains("com.apple.metal") && !$0.contains(".metallib") }
            }
            await spin(300)
            _ = await t.waitFor(3000) { leftOver().isEmpty }
            let fds = RobustResources.fds().total
            let fdNow = RobustResources.fdList()
            let extra = fdNow.filter { l in !baselineFDList.contains { $0.split(separator: ":").dropFirst().joined(separator: ":") == l.split(separator: ":").dropFirst().joined(separator: ":") } }
            // (the Metal shader caches AppKit opens lazily at the first draw are not ours: the monkey's own files, kqueues and pipes must be gone)
            let relevant = extra.filter { !$0.contains("com.apple.metal") && !$0.contains(".metallib") }
            expect(relevant.isEmpty, "file descriptors after closing everything: \(fds) (at the start: \(baselineFDs)); not there at the start: \(relevant)")
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
#endif
