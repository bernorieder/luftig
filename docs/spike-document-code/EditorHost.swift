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
}

/// Convenience for NSTextView based editors: implement `textView`, `showBanner`, `hideBanner` and get the rest.
protocol TextViewEditorHost: EditorHost {
    var textView: NSTextView { get }
}

extension TextViewEditorHost {
    var currentText: NSString { (textView.textStorage?.string ?? "") as NSString }
    var isComposingText: Bool { textView.hasMarkedText() }

    func loadInitialText(_ text: NSString) {
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
    func applyExternalText(_ new: NSString, mode: ExternalApplyMode) -> ExternalApplyReport {
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

        let mapped = selection.map { TextDiff.map($0, through: edits) }
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
    nonisolated(unsafe) static var lastDebug = ""        // diagnostics for the self-tests
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
        // Edits entirely after the anchor cannot move it.
        if edits.allSatisfy({ $0.oldRange.location >= characterIndex }) { return false }
        guard let sv = tv.enclosingScrollView else { return false }
        let newIndex = TextDiff.map(characterIndex, through: edits)
        let origin = tv.textContainerOrigin
        var lineTop: CGFloat? = nil
        if let tlm = tv.textLayoutManager, let cm = tlm.textContentManager {
            let len = (tv.string as NSString).length
            let idx = min(newIndex, max(0, len))
            // MEASURED: after an edit, TextKit 2 only re-positions the fragments below the edit when the WHOLE document range
            // is laid out (a partial ensureLayout(start...anchor) leaves the stale y). That is O(document size), so the anchor
            // is only restored for documents up to `tk2FullLayoutLimit` UTF-16 units; larger TextKit 2 documents keep the old offset.
            if let loc = cm.location(cm.documentRange.location, offsetBy: idx), len <= ViewportAnchor.tk2FullLayoutLimit {
                tlm.ensureLayout(for: tlm.documentRange)
                lineTop = tlm.textLayoutFragment(for: loc)?.layoutFragmentFrame.minY
            }
        } else if let lm = tv.layoutManager {
            let len = lm.numberOfGlyphs
            if len > 0 {
                let idx = min(newIndex, max(0, (tv.string as NSString).length - 1))
                lm.ensureLayout(forCharacterRange: NSRange(location: idx, length: min(1, (tv.string as NSString).length - idx)))
                let glyph = min(lm.glyphIndexForCharacter(at: idx), max(0, lm.numberOfGlyphs - 1))
                lineTop = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
        }
        ViewportAnchor.lastDebug = "restore: newIndex=\(newIndex) lineTop=\(String(describing: lineTop)) clipY=\(sv.contentView.bounds.origin.y) tk2=\(tv.textLayoutManager != nil)"
        guard let top = lineTop else { return false }
        let target = max(0, top + origin.y + offsetIntoLine)
        let clip = sv.contentView
        if abs(clip.bounds.origin.y - target) < 0.5 { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        sv.reflectScrolledClipView(clip)
        return true
    }
}
