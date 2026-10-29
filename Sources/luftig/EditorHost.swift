// EditorHost.swift
//
// The ONLY surface through which MarkdownDocument talks to the editor view. A text-view implementation conforms to
// `EditorHost` (or, for an NSTextView-based editor, to `TextViewEditorHost` and gets everything except the banner
// for free). Nothing in the document layer imports a concrete view class.

import AppKit

enum ExternalApplyMode {
    /// Clean document, silent reload: no undo registration, the undo history is CLEARED (stale entries could corrupt
    /// the new text), the document is not marked dirty.
    case silent
    /// Dirty document (merge result, or "Reload from Disk" after a conflict): applied as ONE undoable edit on top of
    /// the existing history, so Undo brings the previous text back; the caller decides about the change count.
    case undoable
}

struct ExternalApplyReport {
    var edits = 0                       // number of replaceCharacters calls
    var changedUnits = 0                // UTF-16 units replaced + inserted
    var seconds: Double = 0             // wall time of the whole apply (diff + replace + selection + scroll)
    var diffSeconds: Double = 0         // of which: computing the minimal edits
    var selectionBefore: [NSRange] = []
    var selectionAfter: [NSRange] = []
    var scrollAdjusted = false
}

struct EditorBanner {
    enum Style { case info, warning }
    var message: String
    var style: Style = .warning
    var buttons: [(title: String, action: () -> Void)] = []
}

protocol EditorHost: AnyObject {
    /// The live text, exactly as the user sees it (UTF-16 / NSString semantics). May be the text storage's own
    /// mutable string: use it synchronously, copy (`copy()`) if you need to keep it.
    var currentText: NSString { get }
    /// True while an input method has marked (uncommitted) text: external text must not be applied then.
    var isComposingText: Bool { get }
    /// First load of the document: replaces everything, selection at 0, scroll to top, no undo, not dirty.
    func loadInitialText(_ text: NSString)
    /// Replace the text with `text` by minimal edits; keeps selection and scroll position; must not mark the
    /// document dirty by itself (see ExternalApplyMode).
    @discardableResult func applyExternalText(_ text: NSString, mode: ExternalApplyMode) -> ExternalApplyReport
    /// Non-modal notification strip above the text (conflict / deleted / merged). Replaces a previous banner.
    func showBanner(_ banner: EditorBanner)
    func hideBanner()
    /// The document is about to write its file: what the user types next must be a change of its own (see MarkdownDocument.performSave).
    func documentWillSave()
    /// The document's file is `url` now (opened, saved under a new name, moved; nil: untitled): relative image paths start from its folder.
    func documentURLDidChange(_ url: URL?)
}

/// Convenience for NSTextView based editors: implement `textView`, `showBanner`, `hideBanner` and get the rest.
protocol TextViewEditorHost: EditorHost {
    var textView: NSTextView { get }
}

extension TextViewEditorHost {
    var currentText: NSString { (textView.textStorage?.string ?? "") as NSString }
    var isComposingText: Bool { textView.hasMarkedText() }

    // Default implementations. An editor that needs to do more (luftig's does: restyle, reset the lexer) implements the protocol
    // methods itself and calls the `default...` variants (Swift has no `super` for protocol extensions).
    func loadInitialText(_ text: NSString) { defaultLoadInitialText(text) }

    /// NSTextView coalesces typing into ONE undo action. Typing that goes on after a save would be added to the action from before the save:
    /// nothing new is registered, NSDocument's change count does not move, and the document says "not edited" while the editor holds text that
    /// is not on disk (TextEdit breaks the coalescing on every save for the same reason). Undo then takes back the typing since the last save.
    func documentWillSave() { textView.breakUndoCoalescing() }
    func documentURLDidChange(_ url: URL?) {}

    @discardableResult
    func applyExternalText(_ new: NSString, mode: ExternalApplyMode) -> ExternalApplyReport { defaultApplyExternalText(new, mode: mode) }

    func defaultLoadInitialText(_ text: NSString) {
        guard let storage = textView.textStorage else { return }
        let um = textView.undoManager
        um?.disableUndoRegistration()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text as String)
        um?.enableUndoRegistration()
        um?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    @discardableResult
    func defaultApplyExternalText(_ new: NSString, mode: ExternalApplyMode) -> ExternalApplyReport {
        var report = ExternalApplyReport()
        guard let storage = textView.textStorage else { return report }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let old = storage.string as NSString
        let edits = TextDiff.edits(old: old, new: new)
        report.diffSeconds = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
        guard !edits.isEmpty else { report.seconds = report.diffSeconds; return report }
        report.edits = edits.count
        report.changedUnits = edits.reduce(0) { $0 + $1.oldRange.length + $1.newRange.length }

        let selection = textView.selectedRanges.map { $0.rangeValue }
        report.selectionBefore = selection
        let anchor = ViewportAnchor.capture(in: textView)
        let um = textView.undoManager

        switch mode {
        case .silent:
            um?.disableUndoRegistration()
            TextDiff.apply(edits, newText: new, to: storage)
            um?.enableUndoRegistration()
            um?.removeAllActions()
        case .undoable:
            // Explicit group: an implicit (groupsByEvent) group opened outside an event would stay open until the end of
            // the NEXT event and swallow the user's next keystroke into the same undo step.
            textView.breakUndoCoalescing()
            um?.beginUndoGrouping()
            defer { um?.endUndoGrouping() }
            let ranges = edits.map { NSValue(range: $0.oldRange) }
            let strings = edits.map { new.substring(with: $0.newRange) }
            if textView.shouldChangeText(inRanges: ranges, replacementStrings: strings) {
                TextDiff.apply(edits, newText: new, to: storage)
                textView.didChangeText()
            } else {
                // the text view refused (not editable / delegate veto): the text MUST still end up equal to the file
                um?.disableUndoRegistration()
                TextDiff.apply(edits, newText: new, to: storage)
                um?.enableUndoRegistration()
            }
        }

        let mapped = selection.map { TextDiff.mapSnapped($0, through: edits, in: new) }
        report.selectionAfter = mapped
        textView.setSelectedRanges(mapped.map { NSValue(range: $0) }, affinity: textView.selectionAffinity, stillSelecting: false)
        if let anchor { report.scrollAdjusted = anchor.restore(in: textView, edits: edits) }
        report.seconds = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e9
        return report
    }
}

extension TextDiff {
    /// Applies the edits (descending, so earlier ranges stay valid) inside one beginEditing/endEditing.
    static func apply(_ edits: [TextEdit], newText: NSString, to storage: NSTextStorage) {
        guard !edits.isEmpty else { return }
        storage.beginEditing()
        for e in edits.reversed() {
            storage.replaceCharacters(in: e.oldRange, with: newText.substring(with: e.newRange))
        }
        storage.endEditing()
    }
}

/// Remembers which character sits at the top of the viewport (and how far it is scrolled out), so that after text
/// above the viewport changed size the same line is shown at the same place. Works with TextKit 1 and TextKit 2 text
/// views without ever forcing the TextKit 1 fallback (it does not touch `layoutManager` on a TextKit 2 view).
struct ViewportAnchor {
    #if LUFTIG_SELFTEST
    nonisolated(unsafe) static var lastDebug = ""        // diagnostics for the self-tests
    #endif
    static let tk2FullLayoutLimit = 1_000_000
    var characterIndex: Int
    var offsetIntoLine: CGFloat      // how many points of the anchor line are scrolled above the viewport top (>= 0)

    static func capture(in tv: NSTextView) -> ViewportAnchor? {
        guard tv.enclosingScrollView != nil else { return nil }
        let visible = tv.visibleRect
        let origin = tv.textContainerOrigin
        let point = NSPoint(x: 0, y: max(0, visible.minY - origin.y))
        if let tlm = tv.textLayoutManager {                                    // TextKit 2
            guard let frag = tlm.textLayoutFragment(for: point), let cm = tlm.textContentManager else { return nil }
            let idx = cm.offset(from: cm.documentRange.location, to: frag.rangeInElement.location)
            return ViewportAnchor(characterIndex: idx, offsetIntoLine: visible.minY - (frag.layoutFragmentFrame.minY + origin.y))
        }
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }   // TextKit 1
        guard lm.numberOfGlyphs > 0 else { return nil }
        let glyph = lm.glyphIndex(for: point, in: tc, fractionOfDistanceThroughGlyph: nil)
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return ViewportAnchor(characterIndex: lm.characterIndexForGlyph(at: glyph), offsetIntoLine: visible.minY - (line.minY + origin.y))
    }

    /// Returns true if the scroll position was changed.
    func restore(in tv: NSTextView, edits: [TextEdit]) -> Bool {
        // Also when all edits are AFTER the anchor: they cannot move the anchor character, but TextKit 1's non-contiguous layout
        // re-estimates the height of everything it has not laid out when the text changes, and the visible text then drifts
        // (measured: a one-line append at the end of a 400 KB document shifted the top line by several lines).
        return restore(in: tv, atCharacter: TextDiff.map(characterIndex, through: edits))
    }

    /// Put the anchor line back at the same place after something changed the layout (font size, column width) without moving text.
    @discardableResult
    func restoreSameCharacter(in tv: NSTextView) -> Bool { restore(in: tv, atCharacter: characterIndex) }

    private func restore(in tv: NSTextView, atCharacter newIndex: Int) -> Bool {
        guard let sv = tv.enclosingScrollView else { return false }
        var changed = false
        // TextKit 1 with non-contiguous layout ESTIMATES the height of text that was never laid out, and re-estimates when lines
        // near the viewport get laid out (measured: the same line's y moved by 14 pt after the first correction). So: correct,
        // lay out what is now visible, and look again - it settles in 2-3 passes.
        for pass in 0..<4 {
            guard let top = lineTop(in: tv, forCharacter: newIndex) else { return changed }
            let target = max(0, top + tv.textContainerOrigin.y + offsetIntoLine)
            let clip = sv.contentView
            #if LUFTIG_SELFTEST
            ViewportAnchor.lastDebug = "restore: pass \(pass) newIndex=\(newIndex) lineTop=\(top) clipY=\(clip.bounds.origin.y) target=\(target) tk2=\(tv.textLayoutManager != nil)"
            #endif
            if abs(clip.bounds.origin.y - target) < 0.5 { break }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            sv.reflectScrolledClipView(clip)
            changed = true
            if tv.textLayoutManager != nil { break }          // TextKit 2: laid out in full (<= 1 M units), exact
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(forBoundingRect: tv.visibleRect.offsetBy(dx: -tv.textContainerOrigin.x, dy: -tv.textContainerOrigin.y), in: tc)
            }
        }
        return changed
    }

    /// y of the top of the line fragment holding `newIndex` in the current layout (text view coordinates minus the container origin).
    private func lineTop(in tv: NSTextView, forCharacter newIndex: Int) -> CGFloat? {
        if let tlm = tv.textLayoutManager, let cm = tlm.textContentManager {
            let len = (tv.string as NSString).length
            let idx = min(newIndex, max(0, len))
            // MEASURED: after an edit, TextKit 2 only re-positions the fragments below the edit when the WHOLE document range
            // is laid out (a partial ensureLayout(start...anchor) leaves the stale y). That is O(document size), so the anchor
            // is only restored for documents up to `tk2FullLayoutLimit` UTF-16 units; larger TextKit 2 documents keep the old offset.
            if let loc = cm.location(cm.documentRange.location, offsetBy: idx), len <= ViewportAnchor.tk2FullLayoutLimit {
                tlm.ensureLayout(for: tlm.documentRange)
                return tlm.textLayoutFragment(for: loc)?.layoutFragmentFrame.minY
            }
            return nil
        }
        guard let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return nil }
        let len = (tv.string as NSString).length
        let idx = min(newIndex, max(0, len - 1))
        // lay out a neighbourhood, not just the one character: the estimated height of the lines just above the anchor is replaced
        // by their real height when they get laid out, which would move the anchor line a few points afterwards
        let from = max(0, idx - 3000)
        lm.ensureLayout(forCharacterRange: NSRange(location: from, length: min(len, idx + 3000) - from))
        let glyph = min(lm.glyphIndexForCharacter(at: idx), max(0, lm.numberOfGlyphs - 1))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }
}
