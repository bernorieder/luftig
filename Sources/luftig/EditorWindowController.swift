// EditorWindowController.swift - the window around an EditorViewController.
//
// Title bar: the document's name, the proxy icon (representedURL) and the "edited" dot come from NSDocument for free once the
// window controller belongs to the document (addWindowController). Tabbing follows the system "Prefer tabs" setting.

import AppKit

final class EditorWindowController: NSWindowController {

    var editorHost: EditorHost? { contentViewController as? EditorViewController }

    init() {
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("EditorWindowController.init begin")
        #endif
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: EditorWindowController.defaultContentSize()),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.minSize = NSSize(width: 360, height: 240)
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        // Tabbing: .automatic = follow the system setting ("Prefer tabs: in full screen only" by default).
        // All luftig windows share one tabbing identifier so "Merge All Windows" / drag-to-tab work.
        w.tabbingIdentifier = NSWindow.TabbingIdentifier("local.luftig.document")
        w.tabbingMode = .automatic
        super.init(window: w)
        shouldCascadeWindows = true
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("window created, creating EditorViewController")
        #endif
        let editor = EditorViewController()
        w.contentViewController = editor
        w.setContentSize(EditorWindowController.defaultContentSize())
        editor.applySchemeAppearance()          // a dark / light colour scheme forces the window's appearance (the system scheme leaves it alone)
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("EditorWindowController.init end")
        #endif
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// ~860 x 1000 pt, but never taller than the main screen's usable area.
    static func defaultContentSize() -> NSSize {
        let want = EditorViewController.initialSize
        guard let visible = NSScreen.main?.visibleFrame else { return want }
        return NSSize(width: min(want.width, visible.width - 40), height: min(want.height, visible.height - 80))
    }

    override var document: AnyObject? {
        didSet { (contentViewController as? EditorViewController)?.document = document as? MarkdownDocument }
    }
}
