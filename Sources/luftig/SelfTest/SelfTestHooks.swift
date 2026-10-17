#if LUFTIG_SELFTEST
// SelfTestHooks.swift - the only places where the self-test variant of the app hooks into the normal app.
// None of this exists in the shipping binary (the whole SelfTest/ directory and these two calls are compiled out).

import AppKit

enum SelfTestHooks {

    /// main.swift: `--selftest ...` runs the headless scenarios and never returns. Returns false for a normal launch.
    static func handleLaunchArguments(_ arguments: [String]) -> Bool {
        guard arguments.contains(where: { $0 == "--selftest" || $0.hasPrefix("--selftest=") }) else { return false }
        // Without this AppKit treats a loose argument ("all") as a file to open and blocks on an (invisible) error alert.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        SelfTest.run(arguments: arguments)          // never returns
    }

    /// AppDelegate.applicationDidFinishLaunching in the self-test variant: black-box introspection for launches through
    /// Launch Services (`open -g -j -a luftig-SelfTest.app --args -LuftigReport out.json`): about a second after launch the app
    /// writes a JSON description of its documents and windows to the given path and quits.
    /// `-LuftigCommands <file>` instead keeps the app running and executes the commands a test script appends to <file>
    /// (see `CommandPump`): the black-box lifecycle audits (Dock-click reopen, closing the last window, restoration) drive the
    /// REAL AppDelegate this way, which the in-process `--selftest` runner (it has its own delegate) cannot.
    static func applicationDidFinishLaunching() {
        if let path = UserDefaults.standard.string(forKey: "LuftigLaunchProbe") { LaunchProbe.start(reportTo: path) }
        if let path = UserDefaults.standard.string(forKey: "LuftigReport") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { writeReport(to: path); NSApp.terminate(nil) }
        }
        if let path = UserDefaults.standard.string(forKey: "LuftigCommands") { CommandPump.start(commandFile: path) }
    }

    static func reportDictionary() -> [String: Any] {
        var docs: [[String: Any]] = []
        for d in NSDocumentController.shared.documents {
            var e: [String: Any] = ["class": String(reflecting: type(of: d)), "displayName": d.displayName ?? "", "fileURL": d.fileURL?.path ?? "",
                                    "fileType": d.fileType ?? "", "edited": d.isDocumentEdited, "windows": d.windowControllers.count]
            if let m = d as? MarkdownDocument { e["textLength"] = (m.host?.currentText ?? m.pendingText).length; e["format"] = m.textFormat.description }
            docs.append(e)
        }
        /// Every text field / button title in a window that is not an editor window (what an alert or panel says).
        func texts(_ v: NSView?, _ out: inout [String]) {
            guard let v else { return }
            if let f = v as? NSTextField, !f.stringValue.isEmpty { out.append(f.stringValue) }
            if let b = v as? NSButton, !b.title.isEmpty { out.append("[\(b.title)]") }
            v.subviews.forEach { texts($0, &out) }
        }
        let windows: [[String: Any]] = NSApp.windows.map { w in
            var t: [String] = []
            if !(w.contentViewController is EditorViewController) && !(w is NSPanel && String(describing: type(of: w)).hasPrefix("TUI")) { texts(w.contentView, &t) }
            return ["class": String(describing: type(of: w)), "title": w.title, "visible": w.isVisible, "miniaturized": w.isMiniaturized,
                    "isSheet": w.isSheet, "isPanel": w is NSPanel, "hasSheet": w.attachedSheet != nil, "level": w.level.rawValue,
                    "tabs": w.tabbedWindows?.count ?? 1, "width": Int(w.frame.width), "height": Int(w.frame.height), "texts": t]
        }
        return ["pid": getpid(), "documents": docs, "windows": windows,
                "recentDocuments": NSDocumentController.shared.recentDocumentURLs.map { $0.path },
                "activationPolicy": NSApp.activationPolicy().rawValue, "isHidden": NSApp.isHidden, "isActive": NSApp.isActive,
                "modalWindow": NSApp.modalWindow.map { String(describing: type(of: $0)) } ?? "",
                "mainMenuTitles": NSApp.mainMenu?.items.map { $0.title } ?? [],
                "windowMenuTitles": NSApp.windowsMenu?.items.map { $0.title } ?? [],
                "documentTypes": NSDocumentController.shared.documentClassNames.sorted()]
    }

    private static func writeReport(to path: String) {
        if let data = try? JSONSerialization.data(withJSONObject: reportDictionary(), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Black-box command channel for Launch Services launches (self-test variant only): a script appends lines to the file named by
    /// `-LuftigCommands`; the app (polling every 30 ms, on the main queue, so also while a modal alert runs) executes and removes it.
    ///   report <out.json>   write `reportDictionary()` (atomically: the script polls for the file)
    ///   close-windows       close every document window (documents are cleared first: no dirty alerts)
    ///   minimize-windows    miniaturize every editor window
    ///   new-doc             File > New (NSDocumentController.newDocument)
    ///   type <text>         insert text (\n = newline) into the first document, like typing
    ///   press <title>       click the button with that title in the frontmost alert / sheet (what a user answering it does)
    ///   quit                NSApp.terminate(nil)
    enum CommandPump {
        nonisolated(unsafe) static var timer: DispatchSourceTimer?
        static func start(commandFile: String) {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30))
            t.setEventHandler {
                guard let text = try? String(contentsOfFile: commandFile, encoding: .utf8), !text.isEmpty else { return }
                try? FileManager.default.removeItem(atPath: commandFile)
                for line in text.split(separator: "\n") { run(String(line)) }
            }
            t.resume()
            timer = t
        }
        static func run(_ line: String) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts.first ?? "" {
            case "report":
                if parts.count > 1, let data = try? JSONSerialization.data(withJSONObject: reportDictionary(), options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                }
            case "close-windows":
                for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared); d.close() }
            case "minimize-windows":
                for w in NSApp.windows where w.contentViewController is EditorViewController { w.miniaturize(nil) }
            case "new-doc":
                NSDocumentController.shared.newDocument(nil)
            case "type":     // type <text> into the first document's editor (real insertText path, undo group closed explicitly)
                if parts.count > 1, let tv = (NSDocumentController.shared.documents.first as? MarkdownDocument)?.windowControllers.first.flatMap({ ($0.contentViewController as? EditorViewController)?.textView }) {
                    let um = tv.undoManager
                    um?.groupsByEvent = false; um?.beginUndoGrouping()
                    tv.insertText(parts[1].replacingOccurrences(of: "\\n", with: "\n"), replacementRange: tv.selectedRange())
                    tv.breakUndoCoalescing(); um?.endUndoGrouping()
                }
            case "press":    // press <button title>: the first button with that title in any alert panel or sheet
                if parts.count > 1 {
                    func buttons(_ v: NSView?) -> [NSButton] { guard let v else { return [] }; return ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
                    for w in NSApp.windows where w is NSPanel || w.isSheet {
                        if let b = buttons(w.contentView).first(where: { $0.title == parts[1] }) { b.performClick(nil); break }
                    }
                }
            case "quit":
                NSApp.terminate(nil)
            default: break
            }
        }
    }
}

/// Cold launch measurement for the black-box tests: `open -g -j -n -a luftig-SelfTest.app --args -LuftigLaunchProbe out.json`.
/// Writes the time from PROCESS START (kernel start time of this pid) to (a) the first document window existing and (b) its content
/// being drawn once, then quits. Windows of a hidden (`-j`) launch never reach the screen.
enum LaunchProbe {
    nonisolated(unsafe) static var mainEntered = 0.0
    nonisolated(unsafe) static var marks: [(String, Double)] = []
    /// Phase timestamps (self-test variant only): `LaunchProbe.mark("name")` calls are compiled out of the shipping binary.
    static func mark(_ name: String) { marks.append((name, Date().timeIntervalSince1970)) }
    /// Seconds since 1970 at which this process was started (sysctl KERN_PROC_PID, microsecond resolution).
    static func processStartTime() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    static func start(reportTo path: String) {
        let start = processStartTime()
        let launched = Date().timeIntervalSince1970
        func poll() {
            guard let window = NSApp.windows.first(where: { $0.contentViewController is EditorViewController }) else {
                DispatchQueue.main.async { poll() }
                return
            }
            let windowAt = Date().timeIntervalSince1970
            window.contentView?.layoutSubtreeIfNeeded()
            var drawnAt = windowAt
            if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                drawnAt = Date().timeIntervalSince1970
            }
            let report: [String: Any] = ["processStartToMainMs": (mainEntered - start) * 1000, "processStartToDidFinishLaunchingMs": (launched - start) * 1000,
                                         "processStartToWindowMs": (windowAt - start) * 1000,
                                         "processStartToFirstDrawMs": (drawnAt - start) * 1000,
                                         "phases": marks.map { ["name": $0.0, "msSinceMain": ($0.1 - mainEntered) * 1000] },
                                         "windowVisible": window.isVisible, "windows": NSApp.windows.count, "pid": getpid()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
            NSApp.terminate(nil)
        }
        poll()
    }
}
#endif
