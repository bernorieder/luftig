import AppKit

/// Lazy, viewport-driven styling for the TextKit 1 text view (docs/spike-textkit.md, section 3.3).
///
/// What it guarantees (each point was measured in the spike):
///  * Styles ONLY what is visible plus a margin; never the whole document. 1 000 runs ~ 0.6 ms of setAttributes.
///  * Never re-applies attributes to text that is already styled (`styled` index set). Re-applying identical attributes still
///    invalidates layout and made TK2 jump by ~170 pt in 98 % of scroll steps; on TK1 it costs 4 ms per scroll step.
///  * Always batches in beginEditing/endEditing (un-batched: 83 ms instead of 0.6 ms per 1 000 runs on TK1).
///  * Restyles edited text from `textStorage(_:didProcessEditing:)` with plain setAttributes (attribute-only, no undo entries),
///    using exactly the `editedRange` / `changeInLength` AppKit passes (they are only valid in that callback).
///  * Keeps the `styled` set in sync with edits (shifts indices after the edit).
///  * Does not touch the text while an IME composition is in progress (`hasMarkedText()`), restyles when it ends.
///  * Main thread only.
final class LazyStyler: NSObject, NSTextStorageDelegate {

    /// Result of an incremental re-lex after an edit (see MarkdownKit `update(afterEdit:...)`).
    struct EditResult {
        /// The line-aligned region that was re-lexed: `runs` cover exactly this range; nothing outside it changed.
        var region: NSRange
        var runs: [StyledRun]
        /// Attributes at/after this offset (post-edit coordinates) can no longer be trusted (bounded re-lex gave up early).
        var staleFrom: Int?
    }

    /// Runs for a line-aligned UTF-16 range. The provider knows the block state (fences, quotes) at `range.location` (MarkdownKit
    /// checkpoints). The result may cover MORE than asked (the lexer starts at the beginning of the block - paragraph, table - that
    /// contains the range and ends at a block boundary): ALL of it is applied and marked styled. Clipping it to the request would
    /// leave the first lines of a paragraph with attributes from an older lex (found by the differential self-test: a paragraph that
    /// became a setext heading through a change below its first line).
    struct RunResult {
        var region: NSRange
        var runs: [StyledRun]
    }
    var runs: (NSRange) -> RunResult = { _ in RunResult(region: NSRange(location: 0, length: 0), runs: []) }
    /// After an edit: re-lex and return what to re-apply. Must be called for EVERY character edit so that the lexer's cached state
    /// stays in step with the text. nil = restyle the edited paragraph(s) through `runs`.
    var restyleAfterEdit: ((_ edited: NSRange, _ delta: Int) -> EditResult)?
    /// The text was replaced wholesale (open, reload by full replace, revert, huge paste): the lexer must forget everything.
    var onTextReplaced: (() -> Void)?

    var marginLines = 60
    /// Never extend a slice beyond this many UTF-16 units (protects against single-line megabyte documents).
    var maxSliceLength = 200_000
    /// An edit larger than this is treated as "text replaced": forget what was styled, lex lazily. (Never lex it synchronously.)
    var maxSynchronousEdit = 200_000

    private(set) var styled = IndexSet()
    /// True while the owner replaces the whole text (open, revert): edits are not restyled, `reset()` follows.
    private var isReplacingText = false
    private weak var textView: NSTextView?
    private var compositionPending = false
    private var visibleRestyleScheduled = false
    private var observers: [NSObjectProtocol] = []

    #if LUFTIG_SELFTEST
    /// Self-test only: where the time of the styling goes (the scroll benchmark reads and resets it). Nanoseconds.
    struct Probe {
        var visibleNs: UInt64 = 0        // styleVisible() in total (viewport query + fast path + style)
        var viewportNs: UInt64 = 0       // visibleCharacterRange (the layout manager query: lays out what is on screen)
        var lexNs: UInt64 = 0            // the provider: MarkdownKit + Theme.styledRuns
        var applyNs: UInt64 = 0          // setAttributes of the runs, inside begin/endEditing
        var endEditingNs: UInt64 = 0     // endEditing (invalidation of layout / glyphs)
        var calls = 0, slices = 0, runs = 0, chars = 0
        mutating func reset() { self = Probe() }
    }
    nonisolated(unsafe) static var probe = Probe()
    @inline(__always) static func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    #endif

    /// Counters for tests / diagnostics.
    private(set) var appliedRunCount = 0
    private(set) var editRestyles = 0
    private(set) var staleEvents = 0

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
            self?.flushAfterComposition()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - Public API

    /// Wrap the replacement of the WHOLE text (`textView.string = ...`, base attributes): the edit notifications inside are ignored
    /// (nothing would be left of the work they could do) and the styler is reset afterwards. Without it a document below
    /// `maxSynchronousEdit` units would be lexed and styled completely once, only to be thrown away by the reset.
    func replacingWholeText(_ body: () -> Void) {
        isReplacingText = true
        body()
        isReplacingText = false
        reset()
    }

    /// Call after the document text was replaced (open / reload) or the theme changed: nothing is styled any more.
    func reset() {
        styled.removeAll()
        compositionPending = false
        onTextReplaced?()
    }

    /// Style what is visible (+ margin) and has not been styled yet. Cheap no-op when everything needed is already styled.
    @discardableResult
    func styleVisible() -> Int {
        #if LUFTIG_SELFTEST
        let probeStart = LazyStyler.tick()
        defer { LazyStyler.probe.visibleNs &+= LazyStyler.tick() &- probeStart; LazyStyler.probe.calls += 1 }
        #endif
        guard let tv = textView, let ts = tv.textStorage else { return 0 }
        if tv.hasMarkedText() { return 0 }
        let len = ts.length
        if len == 0 { return 0 }
        #if LUFTIG_SELFTEST
        let vpStart = LazyStyler.tick()
        #endif
        let vis = visibleCharacterRange(tv)
        #if LUFTIG_SELFTEST
        LazyStyler.probe.viewportNs &+= LazyStyler.tick() &- vpStart
        #endif
        if vis.length == 0 {
            // No viewport yet (window not laid out / zero-sized): style the top of the document so that the first draw is styled.
            return style(range: expanded(NSRange(location: 0, length: 0)))
        }
        // fast path (runs on every scroll tick): a screenful above and below is already styled -> nothing to do, no line scanning
        let lo = max(0, vis.location - vis.length / 2), hi = min(len, NSMaxRange(vis) + vis.length / 2)
        if hi <= lo || styled.contains(integersIn: lo..<hi) { return 0 }
        return style(range: expanded(vis))
    }

    /// Style the whole document in slices (tests, and "select all + export"-like needs). Not used on the open path.
    func styleEverything() { styleAll(upTo: textView?.textStorage?.length ?? 0) }

    /// Style everything from the start of the document up to `end` (a jump that must land exactly lays out everything above its target, and
    /// layout of styled text is what the final layout will be: headings are taller than unstyled lines).
    func styleAll(upTo end: Int) {
        guard let ts = textView?.textStorage else { return }
        var loc = 0
        let limit = min(end, ts.length)
        let ns = ts.string as NSString
        while loc < limit {
            var e = min(limit, loc + 100_000)
            if e < ts.length { e = NSMaxRange(ns.lineRange(for: NSRange(location: e, length: 0))) }
            style(range: NSRange(location: loc, length: e - loc))
            loc = e
        }
    }

    /// Style the zone around `location` without scrolling (a jump is about to happen: Cmd-Down, find, go to line).
    func prestyle(aroundCharacter location: Int) {
        guard let ts = textView?.textStorage, ts.length > 0 else { return }
        let loc = min(max(0, location), ts.length - 1)
        style(range: expanded(NSRange(location: loc, length: 0)))
    }

    /// Jumps (Cmd-Down, find result, "go to heading"): style the target FIRST, then scroll. Layout then happens once, with final
    /// attributes, and the landing position does not shift (measured: 0 pt instead of -34 pt / -208 pt).
    func scroll(toCharacter location: Int) {
        guard let tv = textView, let ts = tv.textStorage, ts.length > 0 else { return }
        prestyle(aroundCharacter: location)
        tv.scrollRangeToVisible(NSRange(location: min(location, ts.length), length: 0))
        styleVisible()   // the visible part after landing (no-op if the landing zone was already styled)
    }

    // MARK: - Viewport

    /// Characters currently on screen, via the layout manager (O(visible)). Do NOT use characterIndexForInsertion(at:) for this.
    func visibleCharacterRange(_ tv: NSTextView) -> NSRange {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return NSRange(location: 0, length: 0) }
        let o = tv.textContainerOrigin
        let local = tv.visibleRect.offsetBy(dx: -o.x, dy: -o.y)
        if local.isEmpty { return NSRange(location: 0, length: 0) }
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

    // MARK: - Font fallback

    private var scanBuffer = [unichar](repeating: 0, count: 2048)

    /// True when `range` of `text` holds a character >= U+0080 (Latin-1 and beyond: the system font cannot render all of them).
    private func containsNonASCII(_ text: NSString, _ range: NSRange) -> Bool {
        var loc = range.location
        let end = NSMaxRange(range)
        while loc < end {
            let n = min(scanBuffer.count, end - loc)
            scanBuffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: loc, length: n)) }
            for i in 0..<n where scanBuffer[i] > 0x7F { return true }
            loc += n
        }
        return false
    }

    /// `setAttributes` for one run, plus the font fallback AppKit's attribute FIXING would give it.
    ///
    /// Fixing gives text the run's font cannot render (CJK, emoji, Hebrew, Arabic, ...) a fallback font. A wholesale `setAttributes` with the
    /// Theme's font throws that fallback away; the fixing pass AppKit ran for an edit has already happened when we restyle inside
    /// `didProcessEditing` (nothing runs it again), and its lazy pass after a `beginEditing` / `endEditing` batch is not reliable either.
    /// The text is then present but has no glyph (measured: glyph id 0, drawn as nothing; typed or pasted CJK / emoji / Arabic, and every
    /// restyle after a font size change, a scroll or an external reload). So the fallback is restored right here. Pure ASCII: plain
    /// `setAttributes`, exactly as before.
    ///
    /// Text that needs a fallback is applied differently, for speed (measured in a 3 MB Chinese / Japanese document, 100 keystrokes):
    ///  * the fixing pass runs on a scratch copy of the run, not on the live storage: `NSTextStorage.fixFontAttribute(in:)` costs time
    ///    proportional to the SIZE OF THE WHOLE STORAGE (1000 CJK characters: 0.6 ms in 1 KB of text, 2.5 ms in 1 MB, 6.5 ms in 4 MB)
    ///    while the same call on a bare attributed string is 0.4 ms at any size;
    ///  * every font switch is a separate attribute run (Han / kana / emoji: one run per few characters) and every change of a run is a
    ///    memmove of the storage's whole run table (2.4 ms / 1000 runs ... 25 ms per keystroke), so only the pieces whose attributes
    ///    actually differ from what the storage holds are written. Typing in a paragraph then rewrites the runs around the caret, not the
    ///    hundreds of runs of the paragraph (and does not invalidate the layout of the unchanged text).
    private func apply(_ attributes: TextAttributes, to range: NSRange, in ts: NSTextStorage, text: NSString) {
        guard containsNonASCII(text, range), let font = attributes[.font] as? NSFont else {
            ts.setAttributes(attributes, range: range)
            return
        }
        autoreleasepool {                                  // (thousands of runs in one batch: do not let the temporaries pile up)
            let scratch = NSMutableAttributedString(string: text.substring(with: range), attributes: [.font: font])
            let all = NSRange(location: 0, length: scratch.length)
            scratch.fixFontAttribute(in: all)
            var wanted = attributes
            scratch.enumerateAttribute(.font, in: all, options: []) { value, r, _ in
                wanted[.font] = (value as? NSFont) ?? font
                let piece = NSRange(location: range.location + r.location, length: r.length)
                var effective = NSRange(location: 0, length: 0)
                let current = ts.attributes(at: piece.location, longestEffectiveRange: &effective, in: piece)
                if effective.length < piece.length || !(current as NSDictionary).isEqual(to: wanted) { ts.setAttributes(wanted, range: piece) }
            }
        }
    }

    // MARK: - Applying

    /// True while the text storage is inside an edit cycle: between `beginEditing` and the end of `endEditing`, which includes
    /// `processEditing`, its delegate / notification callbacks and everything the layout manager and the text view call from there
    /// (`scrollRangeToVisible`, the clip view's bounds notification). `editedMask` is empty outside of one.
    ///
    /// Styling from inside such a callback is NESTED editing of a storage whose layout manager is in the middle of processing the outer
    /// edit: measured (font size change with a code block just above the viewport) the nested `setAttributes` batch was applied, but the
    /// layout manager kept the layout it had computed from the OLD attributes (line fragments with the body font and without the code
    /// indent, for lines whose attributes were right), until something invalidated them again. So a request that arrives from inside an
    /// edit cycle is postponed to the end of the run loop turn (before the next display pass); the explicit `styleVisible()` calls of
    /// the owner come after the edit cycle and cover the visible text anyway.
    private func insideEditCycle(_ ts: NSTextStorage) -> Bool { !ts.editedMask.isEmpty }

    @discardableResult
    private func style(range: NSRange) -> Int {
        guard let ts = textView?.textStorage, range.length > 0 else { return 0 }
        if insideEditCycle(ts) { scheduleVisibleRestyle(); return 0 }
        let whole = NSRange(location: 0, length: ts.length)
        let range = NSIntersectionRange(range, whole)
        guard range.length > 0 else { return 0 }
        var missing = IndexSet(integersIn: range.location..<NSMaxRange(range))
        missing.subtract(styled)
        guard !missing.isEmpty else { return 0 }
        var count = 0
        var covered = missing
        let text = ts.string as NSString
        #if LUFTIG_SELFTEST
        LazyStyler.probe.slices += 1
        var lexTicks: UInt64 = 0
        let applyStart = LazyStyler.tick()
        #endif
        ts.beginEditing()                                  // ALWAYS batch
        for r in missing.rangeView {
            #if LUFTIG_SELFTEST
            let lexStart = LazyStyler.tick()
            #endif
            let result = runs(NSRange(location: r.lowerBound, length: r.count))
            #if LUFTIG_SELFTEST
            lexTicks &+= LazyStyler.tick() &- lexStart
            LazyStyler.probe.chars += r.count
            #endif
            for run in result.runs {
                let rr = NSIntersectionRange(run.range, whole)
                if rr.length > 0 { apply(run.attributes, to: rr, in: ts, text: text); count += 1 }
            }
            let region = NSIntersectionRange(result.region, whole)
            if region.length > 0 { covered.insert(integersIn: region.location..<NSMaxRange(region)) }
        }
        #if LUFTIG_SELFTEST
        let endStart = LazyStyler.tick()
        #endif
        ts.endEditing()
        #if LUFTIG_SELFTEST
        let endTick = LazyStyler.tick()
        LazyStyler.probe.endEditingNs &+= endTick &- endStart
        LazyStyler.probe.lexNs &+= lexTicks
        LazyStyler.probe.applyNs &+= (endStart &- applyStart) &- lexTicks
        LazyStyler.probe.runs += count
        #endif
        styled.formUnion(covered)
        appliedRunCount += count
        return count
    }

    // MARK: - Edits (NSTextStorageDelegate)

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }   // our own attribute-only edits come through here too: ignore
        if isReplacingText { return }

        // textView.string = ..., a huge paste, a reload: do NOT restyle synchronously (would lex the whole document). Forget the
        // styled set and let styleVisible() do its lazy job.
        if editedRange.length > maxSynchronousEdit {
            styled.removeAll()
            compositionPending = false
            onTextReplaced?()
            return
        }

        // keep the styled set aligned with the text: the replaced region is gone, everything behind it moves by `delta`
        let oldLength = editedRange.length - delta
        let loc = editedRange.location
        if oldLength > 0 { styled.remove(integersIn: loc..<(loc + oldLength)) }
        if delta != 0 { styled.shift(startingAt: loc + max(0, oldLength), by: delta) }

        let length = textStorage.length
        let composing = textView?.hasMarkedText() ?? false
        var region: NSRange
        var newRuns: [StyledRun]
        var stale: Int? = nil
        if let relex = restyleAfterEdit {
            // ALWAYS tell the lexer (even while composing): its cached state must follow the text.
            let r = relex(editedRange, delta)
            region = r.region; newRuns = r.runs; stale = r.staleFrom
        } else {
            let ns = textStorage.string as NSString
            guard ns.length > 0 else { return }
            let l = min(editedRange.location, ns.length - 1)
            region = ns.paragraphRange(for: NSRange(location: l, length: min(editedRange.length, ns.length - l)))
            if NSMaxRange(region) < NSMaxRange(editedRange) {   // an edit that spans a newline
                region = NSUnionRange(region, ns.paragraphRange(for: NSRange(location: min(NSMaxRange(editedRange), ns.length) - 1, length: 0)))
            }
            newRuns = runs(region).runs
        }
        region = NSIntersectionRange(region, NSRange(location: 0, length: length))
        if let s = stale {
            // The bounded re-lex gave up before the block state converged: everything from `s` on is unstyled again (the lexer
            // forgot it too) and is filled lazily when it scrolls into view.
            staleEvents += 1
            if s < length { styled.remove(integersIn: s..<length) }
            region = NSIntersectionRange(region, NSRange(location: 0, length: min(length, s)))
            scheduleVisibleRestyle()
        }
        guard region.length > 0 else { return }

        if composing {
            // IME: leave the marked range (and its underline attributes) alone; the hole in `styled` is filled afterwards.
            styled.remove(integersIn: region.location..<NSMaxRange(region))
            compositionPending = true
            return
        }
        // We are INSIDE processEditing: plain setAttributes is allowed (attributes only) and is picked up by layout (verified:
        // typing "# " makes the line a heading, 18 -> 30 pt). Do not call beginEditing/endEditing here.
        let text = textStorage.string as NSString
        for run in newRuns {
            let rr = NSIntersectionRange(run.range, NSRange(location: 0, length: length))
            if rr.length > 0 { apply(run.attributes, to: rr, in: textStorage, text: text) }
        }
        styled.formUnion(IndexSet(integersIn: region.location..<NSMaxRange(region)))
        appliedRunCount += newRuns.count
        editRestyles += 1
    }

    /// Visible text that became unstyled during an edit (bounded re-lex) is restyled right after the edit cycle, before the
    /// run loop goes to sleep (so before the next display pass).
    private func scheduleVisibleRestyle() {
        guard !visibleRestyleScheduled else { return }
        visibleRestyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibleRestyleScheduled = false
            self.styleVisible()
        }
    }

    private func flushAfterComposition() {
        guard compositionPending, let tv = textView, !tv.hasMarkedText() else { return }
        compositionPending = false
        styleVisible()
    }
}
