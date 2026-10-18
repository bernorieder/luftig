import AppKit

/// Centered readable column without a custom container: the horizontal `textContainerInset` is computed from the clip view width, and the text
/// container's width is set by hand (`widthTracksTextView` is off), so that the RIGHT side can have more air than the left (`trailingExtra`: the
/// text's right edge keeps its distance from the scroller, Settings > Layout > Padding). NSTextView draws the container at the inset's origin and
/// never centres a narrower one (measured), so left = inset, right = inset + trailingExtra.
///
///   inset = max(minInset, (clipWidth - trailingExtra - maxColumnWidth) / 2);  container width = clipWidth - 2 * inset - trailingExtra
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
    var verticalInset: CGFloat
    /// Extra air on the right of the text, on top of the inset (0: symmetric, as it always was).
    var trailingExtra: CGFloat = 0 { didSet { if trailingExtra != oldValue { update() } } }
    /// Typewriter Mode: the vertical inset grows to half the clip view's height (less half a line), so that the first and the last line can sit in the middle.
    var typewriter = false
    var typewriterLineHeight: CGFloat = 23
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var observer: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView, maxColumnWidth: CGFloat = 760, minInset: CGFloat = 28, verticalInset: CGFloat = 20) {
        self.scrollView = scrollView
        self.textView = textView
        self.maxColumnWidth = maxColumnWidth
        self.minInset = minInset
        self.verticalInset = verticalInset
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
        let inset = isEnabled ? max(minInset, ((width - trailingExtra - maxColumnWidth) / 2).rounded(.down)) : minInset
        let vertical = typewriter ? max(verticalInset, ((sv.contentView.bounds.height - typewriterLineHeight) / 2).rounded(.down)) : verticalInset
        if abs(tv.textContainerInset.width - inset) > 0.5 || abs(tv.textContainerInset.height - vertical) > 0.5 {
            tv.textContainerInset = NSSize(width: inset, height: vertical)
        }
        // the container: the text view is as wide as the clip view (autoresizing); the container leaves the inset on the left and inset + extra on the right
        let containerWidth = max(50, tv.frame.width - 2 * inset - trailingExtra)
        if let tc = tv.textContainer, abs(tc.size.width - containerWidth) > 0.5 {
            tc.size = NSSize(width: containerWidth, height: tc.size.height)
        }
    }
}
