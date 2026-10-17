import AppKit

/// The editor's NSTextView (TextKit 1). Two jobs beyond NSTextView:
///  * draw the block / inline decorations from `drawBackground(in:)` (AppKit clips the layout manager's own background drawing to
///    the text container, so bands could not reach into the inset);
///  * make jumps land on already styled text (`scrollRangeToVisible`, Cmd-Up/Down): style the landing zone first.
///
/// Do NOT override `setNeedsDisplay(_:)` here: widening / clipping invalidation rects changed AppKit's background-layout behaviour
/// in the spike (docs/spike-textkit.md pitfall 14) and is not needed - AppKit already invalidates full-width rows.
final class LuftigEditorTextView: NSTextView {

    /// Set by the editor view controller; used to pre-style jump targets.
    weak var lazyStyler: LazyStyler?

    private var schemeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        // another colour scheme became current: page, insertion point and decorations read the new colours on the next draw
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            if let tv = self { LuftigEditorFactory.applySchemeColors(to: tv) }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }

    #if LUFTIG_SELFTEST
    /// Self-test only: told the rect of every `drawBackground(in:)` (AppKit's own display cycle asks for it once per drawn rect).
    nonisolated(unsafe) static var drawLog: ((NSRect) -> Void)?
    #endif

    /// No responsive (concurrent) scrolling for this view: trackpad scrolling takes the same synchronous path as the scroller knob and every other scroll.
    ///
    /// With responsive scrolling (the default for an NSTextView; it only ever applies to trackpad / mouse-wheel gestures, never to the scroller) AppKit
    /// asks the document view to `prepareContent(in:)` an OVERDRAW rect beyond the visible one, so that a scroll thread can move pre-rendered content
    /// while the main thread is busy. NSTextView's implementation lays out that rect in full (`_ensureLayoutCompleteForRect:withExtensionFactor:...`),
    /// which here means one to several screens of text that the lazy styler has not styled yet (it styles the visible rect plus a margin, when the
    /// clip view's bounds change). That text is laid out and drawn with the base attributes, and when it scrolls into view the styler gives it its real
    /// attributes: the layout is invalidated and redone, the text view's height is revised (non-contiguous layout, pitfall 27) and the whole layer
    /// - visible rect AND overdraw - is redrawn. In a full-screen window that is several screens of glyphs and decorations per revision, the next
    /// overdraw round starts the same again, and scrolling with two fingers was choppy while the knob of the scroller, which never prepares overdraw,
    /// was smooth (reported in daily use; `fix-probe-overdraw` measures the cost, `fix-scroll-path` guards this switch). The synchronous path styles
    /// first and lays out once, and is what `fix-scroll` measures: p99 under a 120 Hz frame in a full-screen-sized window.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }

    /// THE override that keeps full-screen scrolling smooth. It does nothing but call `super`: its EXISTENCE makes NSTextView draw the insertion point
    /// itself (the classic path) instead of through its `NSTextInsertionIndicator` subview (macOS 14+), which it uses only for subclasses that do not
    /// override this method. Measured on screen (`fix-scroll-screen`, a 1512 x 949 pt full-screen window on a 120 Hz display, one scroll step per frame,
    /// 480 frames): with the indicator view, an editable first-responder text view scrolling over text that was shown before stalled the main thread for
    /// 37 ms about ten times a second (55 - 60 stalls in 480 frames, in `CABackingStoreSynchronize` / `wait_for_synchronize`: Core Animation waiting for
    /// the render server on a commit); with this override, 0 dropped frames in every pass, run after run. Not editable, not first responder, or styling
    /// edits in flight (they pause the blink): no stalls either way - which is why the first pass over fresh text was always smooth and only the second
    /// one stuttered ("after a while it works fine"). Nothing else helped (full redraws, size changes, fresh layers, copy-on-scroll, asynchronous drawing,
    /// the redraw policy, the window's opacity, the input context, accessibility, hiding / removing the indicator: all measured). Pitfall 33.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func drawBackground(in rect: NSRect) {
        #if LUFTIG_SELFTEST
        LuftigEditorTextView.drawLog?(rect)
        #endif
        super.drawBackground(in: rect)
        if textLayoutManager == nil, let lm = layoutManager as? LuftigLayoutManager, let tc = textContainer {
            lm.drawDecorations(in: rect, origin: textContainerOrigin, container: tc)
        }
    }

    // MARK: jumps

    override func scrollRangeToVisible(_ range: NSRange) {
        lazyStyler?.prestyle(aroundCharacter: range.location)
        super.scrollRangeToVisible(range)
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        lazyStyler?.prestyle(aroundCharacter: textStorage?.length ?? 0)
        super.moveToEndOfDocument(sender)
    }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        lazyStyler?.prestyle(aroundCharacter: 0)
        super.moveToBeginningOfDocument(sender)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        lazyStyler?.prestyle(aroundCharacter: textStorage?.length ?? 0)
        super.scrollToEndOfDocument(sender)
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        lazyStyler?.prestyle(aroundCharacter: 0)
        super.scrollToBeginningOfDocument(sender)
    }
}
