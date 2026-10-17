import AppKit
import Foundation

// MARK: - Watchdog (a stuck TK1-contiguous 20 MB layout must not hang the whole spike)

enum Watchdog {
    nonisolated(unsafe) static var generation = 0
    static func arm(seconds: Double, label: String) {
        generation += 1
        let g = generation
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if generation == g {
                FileHandle.standardOutput.write("TIMEOUT after \(seconds)s: \(label)\n".data(using: .utf8)!)
                exit(124)
            }
        }
    }
    static func disarm() { generation += 1 }
}

// MARK: - Paragraph restyle on edits (the HighlightController prototype)

/// NSTextStorageDelegate that restyles the edited paragraph(s) with setAttributes from inside `didProcessEditing`.
final class HighlightController: NSObject, NSTextStorageDelegate {
    let theme: Theme
    let lexer = MiniLexer()
    var buf = [UInt16]()
    var restyleMs = 0.0
    var restyleCalls = 0
    var enabled = true
    var lastRuns = 0
    /// Return true to skip restyling (e.g. during IME composition).
    var shouldSkip: (() -> Bool)?
    var pendingSkipped: NSRange? = nil

    init(theme: Theme) { self.theme = theme }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard enabled, editedMask.contains(.editedCharacters) else { return }
        if let skip = shouldSkip, skip() {
            pendingSkipped = pendingSkipped.map { NSUnionRange($0, editedRange) } ?? editedRange
            return
        }
        let t0 = nowMs()
        restyle(textStorage, around: editedRange)
        restyleMs += nowMs() - t0
        restyleCalls += 1
    }

    func restyle(_ storage: NSTextStorage, around editedRange: NSRange) {
        let ns = storage.string as NSString
        let len = ns.length
        guard len > 0 else { return }
        let loc = min(editedRange.location, len - 1)
        var para = ns.paragraphRange(for: NSRange(location: loc, length: min(editedRange.length, len - loc)))
        // extend to the following paragraph if the edit touched a newline at the end
        if NSMaxRange(para) < NSMaxRange(editedRange) { para = NSUnionRange(para, ns.paragraphRange(for: NSRange(location: NSMaxRange(editedRange) - 1, length: 0))) }
        var inFence = false
        if para.location > 0, let v = storage.attribute(.scribeBlock, at: para.location - 1, effectiveRange: nil) as? NSNumber, v.intValue == BlockKind.code.rawValue {
            inFence = true
        }
        let runs = lexFromStorage(storage, range: para, inFence: inFence, lexer: lexer, buf: &buf)
        lastRuns = runs.count
        for r in runs { storage.setAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
    }
}

// MARK: - Viewport helpers

extension Harness {
    /// UTF-16 range of the characters currently in (or near) the visible rect, engine independent.
    func visibleCharRange() -> NSRange {
        let r = visibleRect
        let o = textView.textContainerOrigin
        // NOTE: a hit test ABOVE the first line (inside the top inset) returns the END of the document in TK2 (observed);
        // keep the probe points inside the text area.
        let lo = textView.characterIndexForInsertion(at: NSPoint(x: o.x + 40, y: max(r.minY, o.y) + 2))
        let hi = textView.characterIndexForInsertion(at: NSPoint(x: o.x + 40, y: r.maxY - 2))
        return NSRange(location: min(lo, hi), length: abs(hi - lo))
    }

    /// Style [visible ± margin lines] lazily. Returns (range, runs, lexMs, applyMs).
    /// With `onlyNew` the already-styled sub-ranges (tracked in `styledSet`) are not touched again, so no layout invalidation
    /// happens for text that is already styled.
    @discardableResult
    func styleViewport(doc: Doc, theme: Theme, marginLines: Int = 60, onlyNew: Bool = false, skipNothing: Bool = false) -> (NSRange, Int, Double, Double) {
        let vis = visibleCharRange()
        let loc = min(vis.location, max(0, doc.length - 1))
        let endLoc = min(NSMaxRange(vis), max(0, doc.length - 1))
        var r = doc.range(around: loc, before: marginLines, after: 0)
        let tail = doc.range(around: endLoc, before: 0, after: marginLines)
        r = NSUnionRange(r, tail)
        if !onlyNew {
            let (lexMs, applyMs, n) = Styler.style(doc: doc, range: r, storage: storage, theme: theme)
            styledSet.insert(integersIn: r.location..<NSMaxRange(r))
            return (r, n, lexMs, applyMs)
        }
        var missing = IndexSet(integersIn: r.location..<NSMaxRange(r))
        missing.subtract(styledSet)
        var lexT = 0.0, applyT = 0.0, count = 0
        for rng in missing.rangeView {
            let (a, b, n) = Styler.style(doc: doc, range: NSRange(location: rng.lowerBound, length: rng.count), storage: storage, theme: theme)
            lexT += a; applyT += b; count += n
        }
        styledSet.formUnion(missing)
        return (r, count, lexT, applyT)
    }
}
