import Foundation

/// Lazy, incremental Markdown lexer producing style runs for a syntax-highlighting text view.
///
/// Not thread safe: use from one thread / queue at a time (it may move between threads between calls).
/// See README.md for semantics.
public final class MarkdownStyler {
    private let lx = Lexer()
    /// Length of the text the checkpoints were computed for (-1: nothing known).
    private var knownLength = -1

    public init() {
        lx.cps = [Checkpoint(offset: 0, state: BlockState())]
    }

    /// Text was replaced wholesale: drop all cached state.
    public func reset() {
        lx.cps.removeAll(keepingCapacity: true)
        lx.cps.append(Checkpoint(offset: 0, state: BlockState()))
        lx.newCps.removeAll(keepingCapacity: true)
        lx.fmEnd = -1
        knownLength = -1
    }

    // MARK: - Public API

    /// Style runs for a line-aligned superset of `range` (it also starts at the beginning of the block - e.g.
    /// paragraph - that contains `range.location`). Cheap for nearby / overlapping / out-of-order calls: it resumes
    /// from the nearest cached block-state checkpoint and extends the known frontier lazily. If `text.length`
    /// differs from the length last seen (an edit was not reported through `update`), the cache is reset first.
    public func styleRuns(in range: NSRange, of text: NSString) -> MDResult {
        attach(text)
        let len = lx.textLen
        if len == 0 { return MDResult(range: NSRange(location: 0, length: 0), runs: []) }
        let (a, b) = clamp(range, len)
        return emitRegion(from: a, to: b)
    }

    /// Call after every edit. `text` is the POST-edit text; `editedRange` / `changeInLength` have the meaning
    /// of `NSTextStorage.editedRange` / `changeInLength`. Returns exactly the re-lexed line-aligned region.
    public func update(afterEdit editedRange: NSRange, changeInLength delta: Int, of text: NSString) -> MDResult {
        return update(afterEdit: editedRange, changeInLength: delta, of: text, maxRegion: nil)
    }

    /// Like `update(afterEdit:changeInLength:of:)`, but stops re-lexing after about `maxRegion` UTF-16 units
    /// (it always covers the edited lines) even if the block state has not re-converged yet. In that case
    /// `result.staleFrom` tells the caller where previously applied styling can no longer be trusted. Use it to
    /// keep the typing path bounded when an edit changes the block structure of a huge document (e.g. typing
    /// an opening code fence near the top): style the returned region now and restyle the rest lazily.
    public func update(afterEdit editedRange: NSRange, changeInLength delta: Int, of text: NSString, maxRegion: Int?) -> MDResult {
        let newLen = text.length
        let oldLen = newLen - delta
        if knownLength < 0 || oldLen != knownLength {
            // Nothing cached, or the caller's edit description does not match what we last saw (missed edit,
            // wrong delta): forget everything and restyle around the edit; the rest is reported as stale.
            let hadState = knownLength >= 0
            reset()
            attach(text)
            if newLen == 0 { return MDResult(range: NSRange(location: 0, length: 0), runs: []) }
            let (a, b) = clamp(editedRange, newLen)
            var r = emitRegion(from: a, to: b)
            let end = r.range.location + r.range.length
            if hadState && end < newLen { r.staleFrom = end }
            return r
        }
        lx.text = text
        lx.textLen = newLen
        knownLength = newLen
        if newLen == 0 {
            reset(); knownLength = 0
            return MDResult(range: NSRange(location: 0, length: 0), runs: [])
        }
        let e = max(0, min(editedRange.location, newLen))
        let editLen = max(0, min(editedRange.length, newLen - e))
        let newEnd = e + editLen
        let oldEnd = max(e, newEnd - delta)

        // Checkpoints beyond the old frontier cannot be compared against; skim up to the edit first.
        if let last = lx.cps.last, last.offset < e {
            extendFrontier(upTo: e)
            // Drop checkpoints at/after the edit: they were computed on the new text and are not "old".
            while lx.cps.count > 1, let l = lx.cps.last, l.offset >= e { lx.cps.removeLast() }
        }

        // Prefix: checkpoints strictly before the edit (front matter is a lookahead construct: restart at 0).
        var prefixCount: Int
        var fmRestart = false
        if e < lx.frontMatterWindow + 16 && !(lx.fmEnd >= 0 && e >= lx.fmEnd) && startsWithFrontMatterCandidate(text) {
            prefixCount = 1
            fmRestart = true
        } else {
            prefixCount = lowerBound(e)               // first index with offset >= e
            if prefixCount < 1 { prefixCount = 1 }
        }
        // A weak checkpoint is only valid for edits after the line that decided it.
        while prefixCount > 1 && lx.cps[prefixCount - 1].validAfter > e { prefixCount -= 1 }
        let tailStart = max(prefixCount, lowerBound(oldEnd))
        let restart = lx.cps[prefixCount - 1]

        lx.begin(from: restart, emit: true, record: true, chunk: 16384)
        lx.oldIdx = tailStart
        lx.oldShift = delta
        lx.lastRecorded = restart.offset
        lx.convergeFrom = newEnd
        var stop = newEnd
        if tailStart < lx.cps.count { stop = max(stop, lx.cps[lx.cps.count - 1].offset + delta) }
        lx.trimTarget = fmRestart ? restart.offset : max(restart.offset, e - 1)
        let tailLast = tailStart < lx.cps.count ? lx.cps[lx.cps.count - 1].offset + delta : -1
        if let mr = maxRegion { stop = min(stop, max(newEnd, restart.offset + max(0, mr))) }
        let x = lx.run(stopAbs: stop)

        // Splice the new checkpoints in.
        if lx.converged {
            let from = lx.oldIdx
            lx.cps.replaceSubrange(prefixCount..<from, with: lx.newCps)
            if delta != 0 {
                var i = prefixCount + lx.newCps.count
                let n = lx.cps.count
                while i < n { lx.cps[i].offset += delta; lx.cps[i].validAfter += delta; i += 1 }
            }
        } else {
            lx.cps.replaceSubrange(prefixCount..<lx.cps.count, with: lx.newCps)
        }
        let stale: Int? = (!lx.converged && tailLast > x) ? x : nil
        return finish(start: lx.trimStart, end: x, staleFrom: stale)
    }

    /// Non-incremental reference implementation: lexes the whole text from scratch (does not touch cached state).
    public func lexAll(_ text: NSString) -> [MDRun] {
        lx.text = text
        lx.textLen = text.length
        if lx.textLen == 0 { return [] }
        lx.begin(from: Checkpoint(offset: 0, state: BlockState()), emit: true, record: false, chunk: 1 << 18)
        _ = lx.run(stopAbs: Int.max)
        let r = lx.out
        lx.out = []
        lx.trimBuffers()
        return r
    }

    // MARK: - Internals

    private func attach(_ text: NSString) {
        lx.text = text
        lx.textLen = text.length
        if knownLength != lx.textLen {
            if knownLength >= 0 { reset() }
            knownLength = lx.textLen
        }
    }

    /// Does line 0 look like a front matter opener ("---" plus optional trailing blanks)? Whether it really is
    /// one depends on text up to `frontMatterWindow` units later, so edits there must restart from 0.
    private func startsWithFrontMatterCandidate(_ text: NSString) -> Bool {
        let n = min(80, text.length)
        if n < 3 { return false }
        var buf = [unichar](repeating: 0, count: n)
        text.getCharacters(&buf, range: NSRange(location: 0, length: n))
        if buf[0] != 45 || buf[1] != 45 || buf[2] != 45 { return false }
        var i = 3
        while i < n {
            let c = buf[i]
            if c == 10 || c == 13 { return true }
            if c != 32 && c != 9 { return false }
            i += 1
        }
        return true
    }

    private func clamp(_ r: NSRange, _ len: Int) -> (Int, Int) {
        var a = max(0, min(r.location, len))
        var b = r.length > 0 ? (r.length >= len - a ? len : a + r.length) : a
        if b < a { b = a }
        if a >= len { a = len - 1; b = len }
        return (a, b)
    }

    /// First index whose offset is >= v.
    private func lowerBound(_ v: Int) -> Int {
        var lo = 0, hi = lx.cps.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if lx.cps[mid].offset >= v { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Make sure the checkpoint frontier reaches `target` (cheap block-state-only pass, no runs).
    private func extendFrontier(upTo target: Int) {
        while let last = lx.cps.last, last.offset < target, last.offset < lx.textLen {
            lx.begin(from: last, emit: false, record: true, chunk: 1 << 18)
            lx.lastRecorded = last.offset
            _ = lx.run(stopAbs: target)
            lx.cps.append(contentsOf: lx.newCps)
            lx.newCps.removeAll(keepingCapacity: true)
            if lx.cps.last!.offset <= last.offset { break }
        }
        lx.trimBuffers()
    }

    private func emitRegion(from a: Int, to b: Int) -> MDResult {
        if let last = lx.cps.last, last.offset < a { extendFrontier(upTo: a) }
        var idx = lowerBound(a + 1) - 1          // last checkpoint with offset <= a
        if idx < 0 { idx = 0 }
        let cp = lx.cps[idx]
        lx.begin(from: cp, emit: true, record: true, chunk: 32768)
        lx.lastRecorded = lx.cps[lx.cps.count - 1].offset
        lx.trimTarget = a
        let x = lx.run(stopAbs: max(b, a + 1))
        lx.cps.append(contentsOf: lx.newCps)
        lx.newCps.removeAll(keepingCapacity: true)
        return finish(start: lx.trimStart, end: x)
    }

    private func finish(start: Int, end: Int, staleFrom: Int? = nil) -> MDResult {
        let runs = lx.out
        lx.out = []
        lx.trimBuffers()
        return MDResult(range: NSRange(location: start, length: end - start), runs: runs, staleFrom: staleFrom)
    }

    // MARK: - Diagnostics / test hooks (used by the checks)

    /// Test hook: shrink internal limits to stress the checkpoint / cap code paths. Resets cached state.
    public func debugConfigure(strideUnits: Int, maxParagraphLines: Int, maxParagraphUnits: Int, frontMatterWindow: Int,
                               chunk: Int = 0, slideMin: Int = 131072, slideLow: Int = 16384, poison: Bool = false) {
        lx.poison = poison
        lx.chunkOverride = chunk
        lx.slideMin = slideMin
        lx.slideLow = slideLow
        lx.strideUnits = strideUnits
        lx.maxPendLines = maxParagraphLines
        lx.maxPendUnits = maxParagraphUnits
        lx.frontMatterWindow = frontMatterWindow
        reset()
    }

    /// One line per checkpoint: offset, validAfter, state summary.
    public func debugDumpCheckpoints() -> [String] {
        lx.cps.map { "\($0.offset) validAfter=\($0.validAfter) leaf=\($0.state.leaf) cont=\($0.state.ccount) inPara=\($0.state.inPara) emptyItem=\($0.state.emptyItem)" }
    }

    /// Number of stored block-state checkpoints and the offset of the frontier.
    public var debugCheckpointCount: Int { lx.cps.count }
    public var debugFrontier: Int { lx.cps.last?.offset ?? 0 }
}
