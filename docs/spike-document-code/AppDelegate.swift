// AppDelegate.swift
//
// Application lifecycle for a document-based app without nib:
//   * main menu is installed in applicationWillFinishLaunching (before AppKit builds the Window/Help menus)
//   * launch without documents -> ONE untitled Markdown document, no Open panel (applicationShouldOpenUntitledFile)
//   * Dock-icon click with no windows -> new untitled document (applicationShouldHandleReopen)
//   * files dropped on the Dock icon / opened from Finder -> NSDocumentController (Apple Event odoc) - do NOT implement
//     application(_:openFile:) / application(_:open:), that would bypass the document class and Open Recent
//   * window restoration: NSDocument restores last windows by itself; secure restorable state must be declared
//   * quitting with dirty documents: autosave in place means nothing is dirty for more than a few seconds; untitled
//     documents are drafts that survive the quit; conflicts are asked about by MarkdownDocument.canClose

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// If set (`-ScribeReport <path>`), the app writes a JSON description of its open documents to <path> about a
    /// second after launch and quits. Used by the black-box launch tests (open -a ... file.md).
    private var reportPath: String? { UserDefaults.standard.string(forKey: "ScribeReport") }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": true,                 // restore documents even if the system setting would close them
            "ScribeFontSize": 14,
        ])
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = true
        // Autosave in place: first autosave ~15 s after the first edit by default (measured). 3 s keeps the "dirty window"
        // short, which makes external changes meet a clean document almost always.
        NSDocumentController.shared.autosavingDelay = 3
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = reportPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.writeReport(to: path); NSApp.terminate(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag      // true -> AppKit creates an untitled document (via applicationShouldOpenUntitledFile)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: black-box introspection

    private func writeReport(to path: String) {
        var docs: [[String: Any]] = []
        for d in NSDocumentController.shared.documents {
            var e: [String: Any] = ["class": String(reflecting: type(of: d)), "displayName": d.displayName ?? "", "fileURL": d.fileURL?.path ?? "",
                                    "fileType": d.fileType ?? "", "edited": d.isDocumentEdited, "windows": d.windowControllers.count]
            if let m = d as? MarkdownDocument { e["textLength"] = (m.host?.currentText ?? m.pendingText).length; e["format"] = m.textFormat.description }
            docs.append(e)
        }
        let windows: [[String: Any]] = NSApp.windows.map { ["class": String(describing: type(of: $0)), "title": $0.title, "visible": $0.isVisible] }
        let report: [String: Any] = ["pid": getpid(), "documents": docs, "windows": windows,
                                     "recentDocuments": NSDocumentController.shared.recentDocumentURLs.map { $0.path },
                                     "activationPolicy": NSApp.activationPolicy().rawValue,
                                     "mainMenuTitles": NSApp.mainMenu?.items.map { $0.title } ?? []]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
