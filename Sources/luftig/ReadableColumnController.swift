import AppKit

/// Centered readable column without a custom container: the horizontal `textContainerInset` is computed from the clip view width, and the text
/// container's width is set by hand (`widthTracksTextView` is off; NSTextView draws the container at the inset's origin and never centres a narrower
/// one - measured, pitfall 34 - so the width is spelled out). The vertical inset is 0 (the editor's vertical padding is a margin of its viewport), except
/// in Typewriter Mode, where it is half the viewport so that the first and the last line can sit in the middle, and with `roomBelow` (the editor, outside
/// Typewriter Mode): 60 % of the viewport below the last line only, so that the end of the text can be scrolled up to the middle of the window to write
/// there (LuftigEditorTextView.insetOnlyBelow puts the whole inset below the text).
///
///   inset = max(minInset, (clipWidth - maxColumnWidth) / 2);  container width = clipWidth - 2 * inset
///
/// Measured (6e): a resize step incl. inset update, layout of the visible area and a full redraw costs 5-9 ms in a 20 MB document
/// (the inset update itself 0.2-1.4 ms). TK1 non-contiguous keeps the first visible character in place across a width change
/// (verified at 20 MB: 0.49997 -> 0.49997); TK2 does not (0.4999 -> 0.409).
final class ReadableColumnController {
    /// Width of the text column in points (Settings > Column width, `EditorPreferences.columnWidth`; 760 by default).
    var maxColumnWidth: CGFloat { didSet { if maxColumnWidth != oldValue { update() } } }
    /// When false the text fills the window (minimum inset on both sides).
    var isEnabled = true { didSet { if isEnabled != oldValue { update() } } }
    var minInset: CGFloat
    /// Typewriter Mode: the vertical inset is half the clip view's height (less half a line), so that the first and the last line can sit in the middle.
    var typewriter = false
    var typewriterLineHeight: CGFloat = 23
    /// Room below the last line outside Typewriter Mode (the editor; not the Settings preview).
    var roomBelow = false { didSet { if roomBelow != oldValue { update() } } }
    /// The share of the viewport's height that can be scrolled past the end of the text.
    static let roomBelowShare: CGFloat = 0.6
    /// Called with the text container's new width whenever it changes (tables are aligned only while they fit: TableAlignment.swift).
    var onContainerWidthChange: ((CGFloat) -> Void)?
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var observer: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView, maxColumnWidth: CGFloat = 760, minInset: CGFloat = 28) {
        self.scrollView = scrollView
        self.textView = textView
        self.maxColumnWidth = maxColumnWidth
        self.minInset = minInset
        scrollView.contentView.postsFrameChangedNotifications = true
        textView.textContainer?.widthTracksTextView = false                   // the width is ours (set in update), the height stays unlimited
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
            self?.update()
        }
        update()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func update() {
        guard let sv = scrollView, let tv = textView else { return }
        let width = sv.contentView.bounds.width
        let inset = isEnabled ? max(minInset, ((width - maxColumnWidth) / 2).rounded(.down)) : minInset
        let clipHeight = sv.contentView.bounds.height
        let below = roomBelow && !typewriter
        // (NSTextView puts the vertical inset above AND below the text; with the room below, the text view moves all of it below: twice half the room)
        let vertical: CGFloat = typewriter ? max(0, ((clipHeight - typewriterLineHeight) / 2).rounded(.down))
                                           : below ? max(0, (clipHeight * ReadableColumnController.roomBelowShare / 2).rounded(.down)) : 0
        (tv as? LuftigEditorTextView)?.insetOnlyBelow = below
        if abs(tv.textContainerInset.width - inset) > 0.5 || abs(tv.textContainerInset.height - vertical) > 0.5 {
            tv.textContainerInset = NSSize(width: inset, height: vertical)
        }
        // the container: the text view is as wide as the clip view (autoresizing); the container leaves the inset on both sides
        let containerWidth = max(50, tv.frame.width - 2 * inset)
        if let tc = tv.textContainer, abs(tc.size.width - containerWidth) > 0.5 {
            tc.size = NSSize(width: containerWidth, height: tc.size.height)
            onContainerWidthChange?(containerWidth - 2 * tc.lineFragmentPadding)
        }
    }
}
