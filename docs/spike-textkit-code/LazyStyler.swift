import AppKit

/// One style run: complete attribute dictionary for a UTF-16 range (font + colour + paragraph style + custom keys).
/// Use `setAttributes` semantics: the dictionary REPLACES whatever was there, so it must be complete.
struct StyledRun {
    var range: NSRange
    var attributes: [NSAttributedString.Key: Any]
}

/// Lazy, viewport-driven styling for a TextKit 1 text view (works unchanged with TK2 text views except `visibleCharacterRange`).
///
/// What it guarantees (each point was measured in the spike, see docs/spike-textkit.md):
///  * Styles ONLY what is visible plus a margin; never the whole document. 1 000 runs ~ 0.6 ms of setAttributes.
///  * Never re-applies attributes to text that is already styled (`styled` index set). Re-applying identical attributes still
///    invalidates layout and made TK2 jump by ~170 pt in 98 % of scroll steps; on TK1 it costs 4 ms per scroll step.
///  * Always batches in beginEditing/endEditing (un-batched: 83 ms instead of 0.6 ms per 1 000 runs on TK1).
///  * Restyles edited paragraphs from `textStorage(_:didProcessEditing:)` with plain setAttributes (attribute-only, no undo entries).
///  * Keeps the `styled` set in sync with edits (shifts indices after the edit).
///  * Does not touch the text while an IME composition is in progress (`hasMarkedText()`), restyles when it ends.
final class LazyStyler: NSObject, NSTextStorageDelegate {

    /// Provide runs for a line-aligned UTF-16 range. The provider is responsible for block state (fences...) at `range.location`.
    var runs: (NSRange) -> [StyledRun] = { _ in [] }
    /// After an edit: which range must be restyled? Default = the edited paragraph(s). A real incremental lexer returns more
    /// (e.g. everything until block state converges after an opening fence was typed).
    var restyleRange: ((_ edited: NSRange, _ delta: Int) -> NSRange)?

    var marginLines = 60
    /// Never extend a slice beyond this many UTF-16 units (protects against single-line megabyte documents).
    var maxSliceLength = 200_000

    private(set) var styled = IndexSet()
    private weak var textView: NSTextView?
    private var pendingWhileComposing: NSRange?
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        textView.textStorage?.delegate = self
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                self?.styleVisible()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [weak self] _ in
            self?.flushPendingAfterComposition()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - Public API

    /// Call after the document text was replaced (open / reload) or the theme changed: nothing is styled any more.
    func reset() {
        styled.removeAll()
        pendingWhileComposing = nil
    }

    /// Style what is visible (+ margin) and has not been styled yet. Cheap no-op when everything needed is already styled.
    @discardableResult
    func styleVisible() -> Int {
        guard let tv = textView, tv.textStorage != nil else { return 0 }
        if tv.hasMarkedText() { return 0 }
        let vis = visibleCharacterRange(tv)
        // fast path (runs on every scroll tick): a screenful above and below is already styled -> nothing to do, no line scanning
        let len = tv.textStorage?.length ?? 0
        let lo = max(0, vis.location - vis.length / 2), hi = min(len, NSMaxRange(vis) + vis.length / 2)
        if hi <= lo || styled.contains(integersIn: lo..<hi) { return 0 }
        return style(range: expanded(vis))
    }

    /// Jumps (Cmd-Down, find result, "go to heading"): style the target FIRST, then scroll. Layout then happens once, with final
    /// attributes, and the landing position does not shift (measured: 0 pt instead of -34 pt / -208 pt).
    func scroll(toCharacter location: Int) {
        guard let tv = textView, let ts = tv.textStorage, ts.length > 0 else { return }
        let loc = min(max(0, location), ts.length - 1)
        style(range: expanded(NSRange(location: loc, length: 0)))
        tv.scrollRangeToVisible(NSRange(location: min(location, ts.length), length: 0))
        styleVisible()   // the visible part after landing (no-op if the landing zone was already styled)
    }

    // MARK: - Viewport

    /// Characters currently on screen, via the layout manager (O(visible)). Do NOT use characterIndexForInsertion(at:) for this:
    /// above the first line it returns the END of the document in TK2.
    func visibleCharacterRange(_ tv: NSTextView) -> NSRange {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return NSRange(location: 0, length: 0) }
        let o = tv.textContainerOrigin
        let local = tv.visibleRect.offsetBy(dx: -o.x, dy: -o.y)
        let glyphs = lm.glyphRange(forBoundingRect: local, in: tc)
        return lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Line-aligned range around `r`: `marginLines` lines above and below (bounded by `maxSliceLength`).
    private func expanded(_ r: NSRange) -> NSRange {
        guard let ns = textView?.textStorage?.string as NSString?, ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let firstLoc = min(r.location, ns.length - 1)
        let lastLoc = min(max(r.location, NSMaxRange(r) - 1), ns.length - 1)
        var start = ns.lineRange(for: NSRange(location: firstLoc, length: 0)).location
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: lastLoc, length: 0)))
        var n = 0
        while n < marginLines && start > 0 && end - start < maxSliceLength {
            start = ns.lineRange(for: NSRange(location: start - 1, length: 0)).location
            n += 1
        }
        n = 0
        while n < marginLines && end < ns.length && end - start < maxSliceLength {
            end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
            n += 1
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Applying

    @discardableResult
    private func style(range: NSRange) -> Int {
        guard let ts = textView?.textStorage, range.length > 0 else { return 0 }
        var missing = IndexSet(integersIn: range.location..<NSMaxRange(range))
        missing.subtract(styled)
        guard !missing.isEmpty else { return 0 }
        var count = 0
        ts.beginEditing()                                  // ALWAYS batch
        for r in missing.rangeView {
            for run in runs(NSRange(location: r.lowerBound, length: r.count)) {
                ts.setAttributes(run.attributes, range: run.range)
                count += 1
            }
        }
        ts.endEditing()
        styled.formUnion(missing)
        return count
    }

    // MARK: - Edits (NSTextStorageDelegate)

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }   // our own attribute-only edits come through here too: ignore

        // textView.string = ..., a huge paste, a reload: do NOT restyle synchronously (would lex the whole document). Forget the
        // styled set and let styleVisible() do its lazy job.
        if editedRange.length > maxSliceLength {
            styled.removeAll()
            pendingWhileComposing = nil
            return
        }

        // keep the styled set aligned with the text: the replaced region is gone, everything behind it moves by `delta`
        let oldLength = editedRange.length - delta
        let loc = editedRange.location
        if oldLength > 0 { styled.remove(integersIn: loc..<(loc + oldLength)) }
        if delta != 0 { styled.shift(startingAt: loc + max(0, oldLength), by: delta) }

        // IME: leave the marked range alone while composing, remember what to restyle afterwards
        if let tv = textView, tv.hasMarkedText() {
            pendingWhileComposing = pendingWhileComposing.map { NSUnionRange($0, editedRange) } ?? editedRange
            return
        }
        restyle(textStorage, edited: editedRange, delta: delta)
    }

    private func restyle(_ ts: NSTextStorage, edited: NSRange, delta: Int) {
        let ns = ts.string as NSString
        guard ns.length > 0 else { return }
        var r: NSRange
        if let custom = restyleRange {
            r = custom(edited, delta)
        } else {
            let loc = min(edited.location, ns.length - 1)
            r = ns.paragraphRange(for: NSRange(location: loc, length: min(edited.length, ns.length - loc)))
            if NSMaxRange(r) < NSMaxRange(edited) {   // an edit that spans a newline
                r = NSUnionRange(r, ns.paragraphRange(for: NSRange(location: min(NSMaxRange(edited), ns.length) - 1, length: 0)))
            }
        }
        r = NSIntersectionRange(r, NSRange(location: 0, length: ns.length))
        guard r.length > 0 else { return }
        // We are INSIDE processEditing: plain setAttributes is allowed (attributes only) and is picked up by layout (verified:
        // typing "# " makes the line a heading, 18 -> 30 pt). Do not call beginEditing/endEditing here.
        for run in runs(r) { ts.setAttributes(run.attributes, range: run.range) }
        styled.formUnion(IndexSet(integersIn: r.location..<NSMaxRange(r)))
    }

    private func flushPendingAfterComposition() {
        guard let tv = textView, let ts = tv.textStorage, !tv.hasMarkedText(), let pending = pendingWhileComposing else { return }
        pendingWhileComposing = nil
        let r = NSIntersectionRange(pending, NSRange(location: 0, length: ts.length))
        guard r.length > 0 else { return }
        ts.beginEditing()
        restyle(ts, edited: r, delta: 0)
        ts.endEditing()
    }
}
