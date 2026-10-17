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
