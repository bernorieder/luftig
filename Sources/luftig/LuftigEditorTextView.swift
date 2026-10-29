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
    /// ⌘-click: the character under the mouse (nil: not over text). Returns true when the click was taken (a link was followed); false lets NSTextView have it.
    var onCommandClick: ((Int) -> Bool)?
    /// A plain click: true when it was taken (a click into a table drawn as a grid puts the caret into the clicked cell: TableRender.swift).
    var onPlainClick: ((NSPoint) -> Bool)?
    /// Image files (or web images) dropped at a character index: true when they were taken (inserted as Markdown image links).
    var onDropImages: (([URL], Int) -> Bool)?

    /// Images dropped into the text become `![name](path)` lines (EditorViewController.insertImageLinks); anything else is NSTextView's.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let images = urls.filter { ImageDrop.isImage($0) }
        if !images.isEmpty, let handler = onDropImages, handler(images, characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))) { return true }
        return super.performDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), let handler = onCommandClick,
           let index = characterIndex(under: convert(event.locationInWindow, from: nil)), handler(index) { return }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, event.clickCount == 1, let handler = onPlainClick,
           handler(convert(event.locationInWindow, from: nil)) { return }
        super.mouseDown(with: event)
    }

    /// The character whose glyph lies under `point` (view coordinates); nil beyond the text (the end of a line, below the last line).
    func characterIndex(under point: NSPoint) -> Int? {
        guard textLayoutManager == nil, let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let o = textContainerOrigin
        let local = NSPoint(x: point.x - o.x, y: point.y - o.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: local, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.insetBy(dx: -1, dy: 0).contains(local) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

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
        super.drawInsertionPoint(in: caretRect(within: rect), color: color, turnedOn: flag)
    }

    /// The caret as tall as the font at the insertion point (ascent + descent), standing on the baseline, instead of the whole line box that NSTextView
    /// hands in (1.3 - 2 x the font size: uniform line heights, Theme.swift). The box's rect is what AppKit invalidates for the blink, so the caret stays inside it.
    func caretRect(within rect: NSRect) -> NSRect {
        guard let lm = layoutManager, let storage = textStorage else { return rect }
        let length = storage.length
        let loc = min(selectedRange().location, length)
        var font: NSFont?
        var baselineInFragment: CGFloat?                          // the baseline's y below the top of the line fragment
        if length > 0 {
            // the glyph at the caret: the character there, or the last one when the caret is at the end of the text (the extra line fragment after a final
            // line break has no glyph: it is set like the last line, which uses the same paragraph style)
            let charIndex = min(loc, length - 1)
            let glyph = lm.glyphIndexForCharacter(at: charIndex)
            if glyph < lm.numberOfGlyphs {
                baselineInFragment = lm.location(forGlyphAt: glyph).y
                font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont
            }
        }
        if font == nil { font = typingAttributes[.font] as? NSFont }
        guard let font, let baseline = baselineInFragment, baseline > 0 else { return rect }
        let height = font.ascender - font.descender
        guard height < rect.height else { return rect }
        // the typesetter rounds the baseline, so the descent can overshoot the box by a fraction of a point: moved up by that, never clipped
        var top = rect.minY + baseline - font.ascender
        if top + height > rect.maxY { top = rect.maxY - height }
        if top < rect.minY { top = rect.minY }
        return NSRect(x: rect.minX, y: top, width: rect.width, height: height)
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
        if frameChangeDepth > 0 { deferredScrollRange = range; return }
        lazyStyler?.prestyle(aroundCharacter: range.location)
        super.scrollRangeToVisible(range)
    }

    // MARK: the viewport across an edit (pitfall 38)

    /// Every user edit goes through `shouldChangeText` and `didChangeText`. Between the two, the storage edit makes the layout manager revise the text view's height
    /// (non-contiguous layout: the estimates for the text it has not laid out change with every edit, by a few points to 100 pt), and from inside that resize AppKit
    /// scrolls the view by the height change as if it had happened above the viewport (`-[NSLayoutManager _resizeTextViewForTextContainer:]` -> `scrollPoint:`), and
    /// asks to scroll the whole invalidated paragraph into view (-> `scrollRangeToVisible`). Measured in a document of long paragraphs (one physical line of 1,500
    /// characters wrapping to a dozen visual lines): every Backspace moved the view by 34 - 100 pt while the caret's line stayed where it was, and after a few keys
    /// the view snapped back by the sum. So: the line at the top of the viewport is captured before the edit and put back after it (the same `ViewportAnchor` the
    /// external reload uses: a position check, not a delta, so a correct compensation is left alone), and a `scrollRangeToVisible` that arrives while the frame
    /// changes is reduced to "is the caret's line in view once the frame change is over". The caret's own autoscroll after the edit runs after all this, as before.
    private var editAnchor: ViewportAnchor?
    private var editOldRange = NSRange(location: 0, length: 0)
    private var editNewLength = 0

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let ok = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if ok, let replacement = replacementString {                           // (nil: an attribute change, no layout to speak of)
            editAnchor = ViewportAnchor.capture(in: self)
            editOldRange = affectedCharRange
            editNewLength = (replacement as NSString).length
        }
        return ok
    }

    override func didChangeText() {
        if let anchor = editAnchor {
            editAnchor = nil
            // the anchor line replaced by the edit itself (a paste over everything): nothing to put back, AppKit shows the caret
            let replaced = editOldRange.length > 0 && anchor.characterIndex >= editOldRange.location && anchor.characterIndex < NSMaxRange(editOldRange)
            if !replaced {
                let edit = TextEdit(oldRange: editOldRange, newRange: NSRange(location: editOldRange.location, length: editNewLength))
                _ = anchor.restore(in: self, edits: [edit])
            }
        }
        super.didChangeText()
    }

    /// > 0 while `setFrameSize` runs: a `scrollRangeToVisible` from inside it (AppKit, see above) is never done as asked; at the end of the outermost frame change the
    /// caret's line is scrolled into view if it is out of view (a window resize that re-wrapped the text), which is what the call was for.
    private var frameChangeDepth = 0
    private var deferredScrollRange: NSRange?

    override func setFrameSize(_ newSize: NSSize) {
        frameChangeDepth += 1
        super.setFrameSize(newSize)
        frameChangeDepth -= 1
        guard frameChangeDepth == 0, deferredScrollRange != nil else { return }
        deferredScrollRange = nil
        let caret = selectedRange()
        guard caret.length == 0, !caretLineIsVisible(at: caret.location) else { return }
        scrollRangeToVisible(caret)
    }

    /// Whether the line that holds the caret at `location` lies fully inside the visible rect (laid out first; false when it cannot be told).
    private func caretLineIsVisible(at location: Int) -> Bool {
        guard let lm = layoutManager, let ts = textStorage, ts.length > 0, location <= ts.length else { return false }
        let line: NSRect
        if location >= ts.length, let last = ts.string.utf16.last, last == 0x0A || last == 0x0D {
            lm.ensureLayout(forCharacterRange: NSRange(location: ts.length - 1, length: 1))
            line = lm.extraLineFragmentRect
        } else {
            let loc = min(location, ts.length - 1)
            lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: 1))
            let glyph = lm.glyphIndexForCharacter(at: loc)
            guard glyph < lm.numberOfGlyphs else { return false }
            line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard line.height > 0 else { return false }
        let r = line.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return visibleRect.minY <= r.minY && r.maxY <= visibleRect.maxY
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
