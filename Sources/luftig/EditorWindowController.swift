// EditorWindowController.swift - the window around an EditorViewController.
//
// Title bar: the document's name, the proxy icon (representedURL) and the "edited" dot come from NSDocument for free once the
// window controller belongs to the document (addWindowController). Tabbing follows the system "Prefer tabs" setting.

import AppKit

final class EditorWindowController: NSWindowController {

    var editorHost: EditorHost? { contentViewController as? EditorViewController }
    private var preferenceObserver: NSObjectProtocol?
    deinit { if let o = preferenceObserver { NotificationCenter.default.removeObserver(o) } }

    /// Every editor window that is in full screen leaves it (except the windows of `document`, which is about to be shown): a file opened while another
    /// one filled the screen used to land in that full-screen Space, sometimes as a full-screen window of its own. Returns how many windows were told.
    @discardableResult
    static func leaveFullScreenEverywhere(except document: NSDocument? = nil) -> Int {
        var n = 0
        for w in NSApp.windows where w.styleMask.contains(.fullScreen) {
            guard let wc = w.windowController as? EditorWindowController else { continue }
            if let document, wc.document === document { continue }
            w.toggleFullScreen(nil)
            n += 1
        }
        return n
    }

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
        // Tabbing: Settings > General > Open files in tabs (.preferred) or windows of their own (.disallowed); never the system's "Prefer tabs: in full
        // screen only", which put a file opened from the Finder into the full-screen window as a tab. All luftig windows share one tabbing identifier
        // so "Merge All Windows" / drag-to-tab work whatever the setting.
        w.tabbingIdentifier = NSWindow.TabbingIdentifier("local.luftig.document")
        w.tabbingMode = EditorPreferences.tabbingMode
        super.init(window: w)
        preferenceObserver = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { [weak w] _ in
            w?.tabbingMode = EditorPreferences.tabbingMode
        }
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
