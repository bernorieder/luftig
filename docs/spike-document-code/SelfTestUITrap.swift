// SelfTestUITrap.swift
//
// TEST SUPPORT (not used by the shipping app paths): lets headless self-tests run flows that would normally
// put an NSAlert / sheet / NSSavePanel on screen. The trap swizzles the presentation entry points, records
// what NSDocument (or our code) wanted to show, and answers immediately - nothing is ever displayed, nothing
// blocks the run loop, no window can flash on the user's screen.
//
// Why this exists: with NSApp.setActivationPolicy(.prohibited) a window that is ordered front *is* reported
// on-screen by CGWindowList, and a modal NSAlert would block the test forever (invisible, unanswerable).
//
// Usage:
//     UITrap.install()
//     UITrap.alertChooser = { a in a.buttons.firstIndex { $0.contains("Revert") } ?? 0 }
//     ... run scenario ...
//     UITrap.alerts            // what was shown
//     UITrap.panels            // save/open panels that would have been shown

import AppKit
import ObjectiveC

enum UITrap {
    struct AlertRecord: CustomStringConvertible {
        var message: String
        var info: String
        var buttons: [String]
        var chosen: Int
        var flavour: String
        var description: String {
            "alert[\(flavour)] \"\(message)\" / \"\(info)\" buttons=\(buttons) -> #\(chosen)"
        }
    }
    struct PanelRecord: CustomStringConvertible {
        var kind: String                 // "save" / "open"
        var allowedTypes: [String]       // UTType identifiers
        var nameField: String
        var directory: String?
        var allowsOtherTypes: Bool
        var hasAccessory: Bool
        var message: String
        var description: String {
            "\(kind)panel name=\"\(nameField)\" types=\(allowedTypes) otherTypesAllowed=\(allowsOtherTypes) accessory=\(hasAccessory) dir=\(directory ?? "nil")"
        }
    }

    static private(set) var alerts: [AlertRecord] = []
    static private(set) var panels: [PanelRecord] = []
    static private(set) var installed = false
    fileprivate static var confirmed: [ObjectIdentifier: URL] = [:]

    /// Decides which button of a trapped alert is "clicked" (index into `buttons`). Default: the first button.
    static var alertChooser: (AlertRecord) -> Int = { _ in 0 }
    /// Decides the result of a trapped save/open panel. Return a URL to confirm with, nil to cancel.
    /// SAFETY: a URL outside `allowedRoot` is refused (cancel) and recorded in `violations` - a test must never be able to
    /// write into the user's folders. NOTE: confirming panels that NSDocument itself owns (first Save of an untitled
    /// document) proved unreliable (once in four runs NSDocument ignored the faked URL and used ~/Documents/Untitled),
    /// so tests only confirm panels created by Scribe's own code and drive NSDocument's save through save(to:...).
    static var panelChooser: (PanelRecord) -> URL? = { _ in nil }
    static var allowedRoot: URL?
    static private(set) var violations: [String] = []

    static func reset() { alerts.removeAll(); panels.removeAll() }

    static func install() {
        guard !installed else { return }
        installed = true
        swap(NSAlert.self, #selector(NSAlert.runModal), #selector(NSAlert.uitrap_runModal))
        swap(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:)),
             #selector(NSAlert.uitrap_beginSheetModal(for:completionHandler:)))
        swap(NSAlert.self, NSSelectorFromString("beginSheetModalForWindow:modalDelegate:didEndSelector:contextInfo:"),
             #selector(NSAlert.uitrap_beginSheetLegacy(_:modalDelegate:didEndSelector:contextInfo:)))
        swap(NSSavePanel.self, #selector(NSSavePanel.runModal), #selector(NSSavePanel.uitrap_runModal))
        swap(NSSavePanel.self, #selector(NSSavePanel.beginSheetModal(for:completionHandler:)),
             #selector(NSSavePanel.uitrap_beginSheetModal(for:completionHandler:)))
        swap(NSSavePanel.self, #selector(NSSavePanel.begin(completionHandler:)),
             #selector(NSSavePanel.uitrap_begin(completionHandler:)))
        // a panel that was never shown has no `url`: report the one the chooser confirmed
        swap(NSSavePanel.self, #selector(getter: NSSavePanel.url), #selector(NSSavePanel.uitrap_url))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let m1 = class_getInstanceMethod(cls, original), let m2 = class_getInstanceMethod(cls, replacement) else {
            FileHandle.standardError.write(Data("UITrap: cannot swizzle \(original) on \(cls)\n".utf8)); return
        }
        method_exchangeImplementations(m1, m2)
    }

    fileprivate static func answer(_ a: NSAlert, flavour: String) -> NSApplication.ModalResponse {
        var rec = AlertRecord(message: a.messageText, info: a.informativeText,
                              buttons: a.buttons.map { $0.title }, chosen: 0, flavour: flavour)
        rec.chosen = max(0, min(alertChooser(rec), max(0, rec.buttons.count - 1)))
        alerts.append(rec)
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + rec.chosen)
    }

    fileprivate static func answer(_ p: NSSavePanel, kind: String) -> NSApplication.ModalResponse {
        let rec = PanelRecord(kind: kind, allowedTypes: p.allowedContentTypes.map { $0.identifier },
                              nameField: p.nameFieldStringValue, directory: p.directoryURL?.path,
                              allowsOtherTypes: p.allowsOtherFileTypes, hasAccessory: p.accessoryView != nil,
                              message: p.message ?? "")
        panels.append(rec)
        if let url = panelChooser(rec) {
            // canonical comparison: /private/tmp vs /tmp, symlinked folders (the file itself may not exist yet)
            func canon(_ u: URL) -> String { u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent).path }
            guard let root = allowedRoot, canon(url).hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                violations.append("refused panel URL outside the test work dir: \(url.path)")
                return .cancel
            }
            p.directoryURL = url.deletingLastPathComponent()
            p.nameFieldStringValue = url.lastPathComponent
            confirmed[ObjectIdentifier(p)] = url
            return .OK
        }
        return .cancel
    }
}

extension NSAlert {
    @objc fileprivate func uitrap_runModal() -> NSApplication.ModalResponse {
        UITrap.answer(self, flavour: "runModal")
    }
    @objc fileprivate func uitrap_beginSheetModal(for window: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?) {
        let r = UITrap.answer(self, flavour: "sheet")
        DispatchQueue.main.async { handler?(r) }
    }
    @objc fileprivate func uitrap_beginSheetLegacy(_ window: NSWindow, modalDelegate: AnyObject?, didEndSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let r = UITrap.answer(self, flavour: "sheet-legacy")
        guard let d = modalDelegate, let sel = didEndSelector else { return }
        DispatchQueue.main.async {
            // -(void)alertDidEnd:(NSAlert *)alert returnCode:(NSInteger)rc contextInfo:(void *)ctx
            typealias Fn = @convention(c) (AnyObject, Selector, NSAlert, Int, UnsafeMutableRawPointer?) -> Void
            let imp = d.method(for: sel)
            unsafeBitCast(imp, to: Fn.self)(d, sel, self, r.rawValue, contextInfo)
        }
    }
}

extension NSSavePanel {
    @objc fileprivate func uitrap_url() -> URL? {
        UITrap.confirmed[ObjectIdentifier(self)] ?? uitrap_url()      // (swapped: the second call is the original getter)
    }
    @objc fileprivate func uitrap_runModal() -> NSApplication.ModalResponse {
        UITrap.answer(self, kind: self is NSOpenPanel ? "open" : "save")
    }
    @objc fileprivate func uitrap_beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        let r = UITrap.answer(self, kind: self is NSOpenPanel ? "open" : "save")
        DispatchQueue.main.async { handler(r) }
    }
    @objc fileprivate func uitrap_begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        let r = UITrap.answer(self, kind: self is NSOpenPanel ? "open" : "save")
        DispatchQueue.main.async { handler(r) }
    }
}
