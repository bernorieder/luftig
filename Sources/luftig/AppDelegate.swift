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
//   * one instance: a luftig launched while another one runs hands it its files and quits (SingleInstance.swift)

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// True when another luftig was already running at launch: this process hands it the files and quits (SingleInstance).
    private(set) var yielding = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("applicationWillFinishLaunching begin")
        #endif
        yielding = SingleInstance.checkAtLaunch()
        if yielding { return }                                   // (no menu, no documents: the other instance has them)
        // Settings of the app's previous name (Scribe), once; before register(defaults:). Never in a self-test build, whose runs must
        // start from known preferences and must not read the user's real ones.
        if let id = Bundle.main.bundleIdentifier, !id.hasSuffix(".selftest") {
            EditorPreferences.migrateLegacySettings(newDomain: id)
            EditorPreferences.migratePlaceholderSettings(newDomain: id)            // (the placeholder bundle id before the first public release)
        }
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": true,                 // restore documents even if the system setting would close them
            EditorPreferences.readableWidthKey: true,
            EditorPreferences.colorSchemeKey: ColorSchemes.defaultID,
            EditorPreferences.columnWidthKey: Double(EditorPreferences.defaultColumnWidth),
        ])
        // The colour scheme is in force BEFORE any window exists (restored windows are created after this): the first frame has the right colours.
        Palette.apply(schemeID: EditorPreferences.colorSchemeID)
        MainMenu.install()
        NSWindow.allowsAutomaticWindowTabbing = true
        // Autosave in place: first autosave ~15 s after the first edit by default (measured). 3 s keeps the "dirty window"
        // short, which makes external changes meet a clean document almost always.
        NSDocumentController.shared.autosavingDelay = 3
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("applicationWillFinishLaunching end")
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if yielding { SingleInstance.finishYielding(); return }
        openUntitledIfNothingRestored()
        #if LUFTIG_SELFTEST
        SelfTestHooks.applicationDidFinishLaunching()
        #endif
    }

    /// AppKit opens the initial untitled document by itself - EXCEPT when the previous session has saved window state that yields no
    /// window: the user closed every window before quitting (the saved state is then "no windows"), or none of the saved windows
    /// could be restored (every file was deleted, moved or unreadable since). The app then starts with no window at all and looks
    /// dead (measured: 0 documents, 0 windows, until Cmd-N or a Dock click). A plain launch (Apple event 'oapp'; for 'odoc' a file
    /// is on its way and `currentAppleEvent` is nil) that has produced no document after half a second gets the untitled document
    /// the normal path would have opened. Restoring a few documents takes ~65 ms, and an extra empty window would be harmless.
    private func openUntitledIfNothingRestored() {
        guard NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(kAEOpenApplication) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let controller = NSDocumentController.shared
            if controller.documents.isEmpty { controller.newDocument(nil) }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !yielding }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag      // true -> AppKit creates an untitled document (via applicationShouldOpenUntitledFile)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: About

    /// The standard panel shows the name and "Version 1.0.0 (build)" from Info.plist; we only add a line of credits.
    static func aboutPanelOptions() -> [NSApplication.AboutPanelOptionKey: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: "A small, fast Markdown editor.\nThe Markdown source stays visible and editable.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        return [.credits: credits]
    }

    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: AppDelegate.aboutPanelOptions())
    }

    /// luftig > Settings… (⌘,): the one Settings window, opened or raised.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.present()
    }
}
