#if LUFTIG_SELFTEST
// SelfTest.swift
//
// Headless scenario runner (no XCTest/swift-testing on this machine). Usage, from the assembled bundle:
//
//     build/luftig.app/Contents/MacOS/luftig --selftest all
//     build/luftig.app/Contents/MacOS/luftig --selftest reload-clean,dirty-merge --workdir=/some/scratch/dir
//     build/luftig.app/Contents/MacOS/luftig --selftest list
//
//   * activation policy .prohibited: no Dock icon, no focus change, no menu bar takeover
//   * windows are created but NEVER ordered front (a window ordered front IS reported on-screen by CGWindowList
//     even for a .prohibited app); sheets/alerts/save panels are intercepted by UITrap (nothing can appear on screen
//     or block the run loop)
//   * the real NSDocumentController / MarkdownDocument / EditorViewController / file system are used; external
//     writers are real child processes (/bin/sh), so atomic replace, truncate, touch -r, ... are the real thing
//   * exit status: 0 all checks passed, 1 at least one check failed, 2 runner problem/timeout
//
// It must run from the .app bundle (document types come from Info.plist): `swift run` would have none.

import AppKit

enum SelfTest {

    struct Scenario {
        let name: String
        let summary: String
        let run: @MainActor (T) async throws -> Void
        /// false for scenarios that need command line arguments (render): not part of `--selftest all`.
        var inAll = true
    }

    // MARK: context

    @MainActor
    final class T {
        let scenario: String
        let work: URL
        private(set) var passed = 0
        private(set) var failed = 0
        private(set) var failures: [String] = []
        var traces: [(t: Double, doc: String, msg: String)] = []

        init(scenario: String, work: URL) {
            self.scenario = scenario
            self.work = work
        }

        // -- assertions
        func check(_ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, line: Int = #line) {
            if cond() { passed += 1; out("  ok    \(msg())") }
            else { failed += 1; let m = "\(scenario): \(msg()) (line \(line))"; failures.append(m); out("  FAIL  \(msg())  [SelfTest line \(line)]") }
        }
        func equal<X: Equatable>(_ a: @autoclosure () -> X, _ b: @autoclosure () -> X, _ msg: String, line: Int = #line) {
            let x = a(), y = b()
            if x == y { passed += 1; out("  ok    \(msg)") }
            else { failed += 1; let m = "\(scenario): \(msg): got \(x) expected \(y) (line \(line))"; failures.append(m); out("  FAIL  \(msg): got \(String(describing: x)) expected \(String(describing: y))  [SelfTest line \(line)]") }
        }
        func note(_ s: String) { out("  note  \(s)") }
        func info(_ s: String) { out("  ...   \(s)") }

        // -- time
        func sleep(_ ms: Double) async {
            let end = SelfTest.nowMs() + ms
            while SelfTest.nowMs() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        func waitFor(_ timeoutMs: Double, _ cond: () -> Bool) async -> Bool {
            let end = SelfTest.nowMs() + timeoutMs
            while SelfTest.nowMs() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 1_000_000) }
            return cond()
        }

        // -- files / processes
        func url(_ name: String) -> URL { work.appendingPathComponent(name) }
        @discardableResult func write(_ text: String, to name: String) -> URL {
            let u = url(name)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: u, atomically: false, encoding: .utf8)
            return u
        }
        @discardableResult func write(data: Data, to name: String) -> URL {
            let u = url(name)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! data.write(to: u)
            return u
        }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<unreadable>" }
        func readData(_ u: URL) -> Data { (try? Data(contentsOf: u)) ?? Data() }

        /// Runs `/bin/sh -c cmd` without blocking the main run loop. Returns the time (ms, SelfTest.nowMs) at which it finished.
        @discardableResult func sh(_ cmd: String) async -> Double {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd]
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch { c.resume() }
            }
            return SelfTest.nowMs()
        }
        func q(_ u: URL) -> String { "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

        // -- documents
        /// Opens a file through NSDocumentController (Info.plist wiring!) and builds the window controller, never ordering it front.
        func open(_ u: URL, window: Bool = true, size: NSSize = NSSize(width: 800, height: 600)) async throws -> MarkdownDocument {
            let (doc, _) = try await NSDocumentController.shared.openDocument(withContentsOf: u, display: false)
            guard let md = doc as? MarkdownDocument else {
                throw NSError(domain: "selftest", code: 1, userInfo: [NSLocalizedDescriptionKey: "document class is \(Swift.type(of: doc)), expected MarkdownDocument"])
            }
            if window { attachWindow(md, size: size) }
            return md
        }
        func attachWindow(_ md: MarkdownDocument, size: NSSize = NSSize(width: 800, height: 600)) {
            md.makeWindowControllers()
            // Headless: no events -> implicit (groupsByEvent) undo groups would never close. Tests close groups explicitly.
            md.undoManager?.groupsByEvent = false
            if let w = md.windowControllers.first?.window {
                w.setContentSize(size)
                w.contentView?.layoutSubtreeIfNeeded()
            }
        }
        func newUntitled(window: Bool = true) throws -> MarkdownDocument {
            let doc = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            guard let md = doc as? MarkdownDocument else { throw NSError(domain: "selftest", code: 2, userInfo: [NSLocalizedDescriptionKey: "untitled document is \(Swift.type(of: doc))"]) }
            if window { attachWindow(md) }
            return md
        }
        func editor(_ d: MarkdownDocument) -> EditorViewController? { d.windowControllers.first?.contentViewController as? EditorViewController }
        func close(_ d: MarkdownDocument) { d.updateChangeCount(.changeCleared); d.close() }

        /// Simulates the user typing `s` at the caret (goes through NSTextView's real edit path: delegate, undo, change count).
        func typeText(_ s: String, into d: MarkdownDocument, at range: NSRange? = nil) {
            guard let tv = editor(d)?.textView else { return }
            let r = range ?? tv.selectedRange()
            tv.setSelectedRange(r)
            // Headless: there are no events, so groupsByEvent groups would never close. Close the group explicitly,
            // exactly what the end of a real key event does (NSDocument counts the change when the group closes).
            let um = tv.undoManager
            um?.beginUndoGrouping()
            tv.insertText(s, replacementRange: r)
            tv.breakUndoCoalescing()        // NSTextView registers typing undo lazily (coalescing) - flush it into the group
            um?.endUndoGrouping()
        }

        func autosave(_ d: MarkdownDocument) async -> Error? {
            await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
                d.autosave(withImplicitCancellability: false) { c.resume(returning: $0) }
            }
        }
    }

    // MARK: runner

    /// Dropped into a work directory the runner created: only a directory with this file (or an empty one) may be reused and deleted.
    static let workdirMarker = ".luftig-selftest-workdir"

    nonisolated(unsafe) static var startNs = DispatchTime.now().uptimeNanoseconds
    static func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1e6 }

    static func run(arguments: [String]) -> Never {
        startNs = DispatchTime.now().uptimeNanoseconds
        func opt(_ name: String) -> String? {
            if let a = arguments.first(where: { $0.hasPrefix("--\(name)=") }) { return String(a.dropFirst(name.count + 3)) }
            return nil
        }
        // --selftest all   |   --selftest a,b   |   --selftest=a,b
        var selection = opt("selftest")
        if selection == nil, let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count { selection = arguments[i + 1] }
        // the whole suite takes about ten minutes: a single scenario or a short list keeps the 240 s default
        let timeout = Double(opt("timeout") ?? "") ?? (selection == "all" ? 1800 : 240)
        let workRoot = URL(fileURLWithPath: opt("workdir") ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("luftig-selftest-\(getpid())"))
        // The runner DELETES its work directory (at the start and at the end). A --workdir that is somebody's real folder must never
        // be treated like that: it has to be new, empty, or one this runner created before (it leaves a marker file).
        if opt("workdir") != nil, selection != "list" {
            let fm = FileManager.default
            let marker = workRoot.appendingPathComponent(SelfTest.workdirMarker)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: workRoot.path, isDirectory: &isDir) {
                let entries = (try? fm.contentsOfDirectory(atPath: workRoot.path)) ?? []
                if !isDir.boolValue || (!entries.isEmpty && !fm.fileExists(atPath: marker.path)) {
                    out("refusing --workdir=\(workRoot.path): it exists and is not an empty directory or a previous self-test work directory. The runner deletes its work directory; pass a new or empty one.")
                    exit(2)
                }
            }
        }
        // A previous run that was killed (timeout, Ctrl-C) leaves its last preference behind (font size 20, readable width off).
        // Every run starts from the defaults, as the scenarios assume.
        for key in EditorPreferences.allKeys { UserDefaults.standard.removeObject(forKey: key) }       // font size, readable width, and the Settings window's fonts / spacing / column / scheme

        let all = SelfTestScenarios.all
        if selection == "list" || selection == nil {
            out("scenarios:"); all.forEach { out("  \($0.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \($0.summary)") }
            exit(selection == nil ? 2 : 0)
        }
        let wanted: [Scenario]
        if selection == "all" { wanted = all.filter { $0.inAll } }
        else {
            let names = selection!.split(separator: ",").map(String.init)
            var picked: [Scenario] = []
            for n in names {
                guard let s = all.first(where: { $0.name == n }) else { out("unknown scenario '\(n)'. Try --selftest list"); exit(2) }
                picked.append(s)
            }
            wanted = picked
        }
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") != nil else {
            out("selftest must run from the .app bundle (document types come from Info.plist): build/luftig.app/Contents/MacOS/luftig --selftest ...")
            exit(2)
        }

        // AppKit swallows an Objective-C exception raised inside a main-queue block (it logs nothing visible) and the scenario Task
        // is simply abandoned, i.e. the run "hangs" until the timeout. With NSApplicationCrashOnExceptions the handler below runs.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        NSSetUncaughtExceptionHandler { e in
            print("UNCAUGHT EXCEPTION \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(25).joined(separator: "\n"))")
            fflush(stdout)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = SelfTestDelegate(scenarios: wanted, workRoot: workRoot)
        app.delegate = delegate
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            out("SELFTEST TIMEOUT after \(Int(timeout)) s (scenario '\(delegate.currentScenario)')")
            exit(2)
        }
        UITrap.install()
        app.run()
        exit(2)
    }

    static func out(_ s: String) { print(s); fflush(stdout) }
}

func out(_ s: String) { SelfTest.out(s) }

final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    let scenarios: [SelfTest.Scenario]
    let workRoot: URL
    var currentScenario = "-"

    init(scenarios: [SelfTest.Scenario], workRoot: URL) {
        self.scenarios = scenarios
        self.workRoot = workRoot
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    /// The real AppDelegate's About action (the runner has its own delegate, so the menu's action must resolve here too).
    @objc func showAboutPanel(_ sender: Any?) { AppDelegate().showAboutPanel(sender) }
    /// Likewise luftig > Settings… (the runner never puts a window on the screen: SettingsWindowController.headless).
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.present() }
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The real menu, so menu scenarios test the real thing (NSApp.mainMenu is not displayed for .prohibited apps).
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? FileManager.default.removeItem(at: workRoot)
            try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: workRoot.appendingPathComponent(SelfTest.workdirMarker).path, contents: nil)
            out("luftig selftest on macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(getpid()), work dir \(workRoot.path)")
            var totalPassed = 0, totalFailed = 0
            var failures: [String] = []
            for s in scenarios {
                currentScenario = s.name
                out("\n== \(s.name): \(s.summary)")
                let dir = workRoot.appendingPathComponent(s.name)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let t = SelfTest.T(scenario: s.name, work: dir)
                UITrap.reset()
                UITrap.allowedRoot = dir
                UITrap.alertChooser = { _ in 0 }
                UITrap.panelChooser = { _ in nil }
                let verbose = CommandLine.arguments.contains("--trace")
                MarkdownDocument.trace = { doc, msg in
                    t.traces.append((SelfTest.nowMs(), doc.displayName ?? "?", msg))
                    if verbose { out(String(format: "  trace %8.1f  [%@] %@", SelfTest.nowMs(), doc.displayName ?? "?", msg)) }
                }
                let t0 = SelfTest.nowMs()
                do { try await s.run(t) } catch {
                    t.check(false, "scenario threw: \(error)")
                }
                for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared); d.close() }
                MarkdownDocument.trace = nil
                out(String(format: "-- %@: %d passed, %d failed (%.0f ms)", s.name, t.passed, t.failed, SelfTest.nowMs() - t0))
                totalPassed += t.passed; totalFailed += t.failed; failures += t.failures
            }
            try? FileManager.default.removeItem(at: workRoot)
            out("\nSELFTEST RESULT: \(totalFailed == 0 ? "PASS" : "FAIL")  \(totalPassed) checks passed, \(totalFailed) failed, \(scenarios.count) scenarios")
            failures.forEach { out("  failed: \($0)") }
            exit(totalFailed == 0 ? 0 : 1)
        }
    }
}
#endif
