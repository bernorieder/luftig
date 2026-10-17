import AppKit

/// Centered readable column without a custom container: the text container keeps tracking the text view width
/// (`widthTracksTextView = true`) and the horizontal `textContainerInset` is computed from the clip view width.
///
///   inset = max(minInset, (clipWidth - maxColumnWidth) / 2)
///
/// Measured (6e): a resize step incl. inset update, layout of the visible area and a full redraw costs 5-9 ms in a 20 MB document
/// (the inset update itself 0.2-1.4 ms). TK1 non-contiguous keeps the first visible character in place across a width change
/// (verified at 20 MB: 0.49997 -> 0.49997); TK2 does not (0.4999 -> 0.409).
final class ReadableColumnController {
    var maxColumnWidth: CGFloat
    var minInset: CGFloat
    var verticalInset: CGFloat
    private weak var scrollView: NSScrollView?
    private weak var textView: NSTextView?
    private var observer: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView, maxColumnWidth: CGFloat = 720, minInset: CGFloat = 28, verticalInset: CGFloat = 20) {
        self.scrollView = scrollView
        self.textView = textView
        self.maxColumnWidth = maxColumnWidth
        self.minInset = minInset
        self.verticalInset = verticalInset
        scrollView.contentView.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
            self?.update()
        }
        update()
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func update() {
        guard let sv = scrollView, let tv = textView else { return }
        let width = sv.contentView.bounds.width
        let inset = max(minInset, ((width - maxColumnWidth) / 2).rounded(.down))
        if abs(tv.textContainerInset.width - inset) > 0.5 || abs(tv.textContainerInset.height - verticalInset) > 0.5 {
            tv.textContainerInset = NSSize(width: inset, height: verticalInset)
        }
    }
}
