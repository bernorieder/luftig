// TextDiff.swift
//
// Foundation-only text diffing used by the external-change reload path:
//
//   TextDiff.edits(old:new:)      minimal list of replace-operations that turn `old` into `new`
//                                 (UTF-16 common prefix/suffix first, then - only if the changed middle is big and
//                                 the change is spread out - a line-based Myers diff, so two distant edits become two
//                                 small replacements instead of one huge one; falls back to ONE replacement when
//                                 the diff is too expensive or too fragmented)
//   TextDiff.map(position, edits) selection/caret mapping through those edits
//   TextDiff.apply(edits, ...)    apply to an NSTextStorage in one beginEditing/endEditing
//   Diff3.merge(base:mine:theirs:) line-based three-way merge; nil on any overlapping change
//
// Everything works on UTF-16 offsets (NSString / NSRange semantics), never splits a surrogate pair, never uses
// String.Index, and never allocates per character.

import Foundation

struct TextEdit: Equatable, CustomStringConvertible {
    /// Range in the OLD text that is replaced ...
    var oldRange: NSRange
    /// ... by this range of the NEW text.
    var newRange: NSRange
    var description: String { "old\(NSStringFromRange(oldRange)) -> new\(NSStringFromRange(newRange))" }
}

enum TextDiff {

    // MARK: prefix / suffix

    private static let chunk = 8192

    /// Number of leading UTF-16 units that are identical.
    static func commonPrefix(_ a: NSString, _ b: NSString) -> Int {
        let n = min(a.length, b.length)
        if n == 0 { return 0 }
        let ba = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        let bb = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { ba.deallocate(); bb.deallocate() }
        var i = 0
        while i < n {
            let c = min(chunk, n - i)
            a.getCharacters(ba, range: NSRange(location: i, length: c))
            b.getCharacters(bb, range: NSRange(location: i, length: c))
            if memcmp(ba, bb, c * 2) == 0 { i += c; continue }
            var j = 0
            while ba[j] == bb[j] { j += 1 }
            return i + j
        }
        return n
    }

    /// Number of trailing UTF-16 units that are identical, at most `maxLength` (so that it cannot overlap the prefix).
    static func commonSuffix(_ a: NSString, _ b: NSString, maxLength: Int) -> Int {
        let n = min(maxLength, min(a.length, b.length))
        if n <= 0 { return 0 }
        let ba = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        let bb = UnsafeMutablePointer<unichar>.allocate(capacity: chunk)
        defer { ba.deallocate(); bb.deallocate() }
        let la = a.length, lb = b.length
        var i = 0
        while i < n {
            let c = min(chunk, n - i)
            a.getCharacters(ba, range: NSRange(location: la - i - c, length: c))
            b.getCharacters(bb, range: NSRange(location: lb - i - c, length: c))
            if memcmp(ba, bb, c * 2) == 0 { i += c; continue }
            var j = c - 1
            while ba[j] == bb[j] { j -= 1 }
            return i + (c - 1 - j)
        }
        return n
    }

    @inline(__always) private static func isHigh(_ u: unichar) -> Bool { u >= 0xD800 && u <= 0xDBFF }
    @inline(__always) private static func isLow(_ u: unichar) -> Bool { u >= 0xDC00 && u <= 0xDFFF }

    // MARK: edits

    struct Options {
        /// Above this many hunks the line diff is abandoned and ONE replacement is used.
        var maxHunks = 128
        /// Myers edit-distance cap (inserted + deleted lines). Beyond it -> single replacement.
        var maxLineEditDistance = 1500
        /// If the changed middle (after prefix/suffix) is smaller than this, a single replacement is used outright.
        var lineDiffThresholdUnits = 4096
    }

    /// Minimal edit list (ascending, non-overlapping, OLD coordinates). Empty if the strings are equal.
    static func edits(old: NSString, new: NSString, options: Options = Options()) -> [TextEdit] {
        let oldLen = old.length, newLen = new.length
        var p = commonPrefix(old, new)
        if p == oldLen && p == newLen { return [] }
        if p > 0, p < oldLen || p < newLen, isHigh(old.character(at: p - 1)) { p -= 1 }          // do not split a pair
        var s = commonSuffix(old, new, maxLength: min(oldLen, newLen) - p)
        if s > 0, isLow(old.character(at: oldLen - s)) { s -= 1 }
        let oldMid = NSRange(location: p, length: oldLen - p - s)
        let newMid = NSRange(location: p, length: newLen - p - s)
        let single = [TextEdit(oldRange: oldMid, newRange: newMid)]
        if oldMid.length == 0 || newMid.length == 0 { return single }
        if oldMid.length + newMid.length < options.lineDiffThresholdUnits { return single }

        // Line-align the middle: start at the beginning of the line containing p, end after the next "\n".
        let ls = lineStart(old, before: p)
        var oldEnd = oldLen - s
        let q = old.range(of: "\n", options: .literal, range: NSRange(location: oldEnd, length: oldLen - oldEnd)).location
        oldEnd = (q == NSNotFound) ? oldLen : q + 1
        let suffixLen = oldLen - oldEnd
        let newEnd = newLen - suffixLen
        if newEnd < ls { return single }
        let oldBlock = NSRange(location: ls, length: oldEnd - ls)
        let newBlock = NSRange(location: ls, length: newEnd - ls)
        if oldBlock.length > 24_000_000 || newBlock.length > 24_000_000 { return single }

        let a = Lines(old, oldBlock), b = Lines(new, newBlock)
        guard let hunks = myers(a, b, maxD: options.maxLineEditDistance), !hunks.isEmpty, hunks.count <= options.maxHunks else {
            return single
        }
        var out: [TextEdit] = []
        out.reserveCapacity(hunks.count)
        for h in hunks {
            var o = NSRange(location: oldBlock.location + a.starts[h.aStart], length: a.starts[h.aEnd] - a.starts[h.aStart])
            var n = NSRange(location: newBlock.location + b.starts[h.bStart], length: b.starts[h.bEnd] - b.starts[h.bStart])
            // trim common characters inside the hunk (typing a word in one line -> a few-unit edit)
            let hp = commonPrefix(old.substring(with: o) as NSString, new.substring(with: n) as NSString)
            if hp > 0 { o.location += hp; o.length -= hp; n.location += hp; n.length -= hp }
            var hs = 0
            if o.length > 0 && n.length > 0 {
                hs = commonSuffix(old.substring(with: o) as NSString, new.substring(with: n) as NSString, maxLength: min(o.length, n.length))
                o.length -= hs; n.length -= hs
            }
            // keep surrogate pairs whole
            if o.location > 0, isHigh(old.character(at: o.location - 1)), (o.length > 0 && isLow(old.character(at: o.location)) || n.length > 0 && isLow(new.character(at: n.location))) {
                o.location -= 1; o.length += 1; n.location -= 1; n.length += 1
            }
            if o.length == 0 && n.length == 0 { continue }
            out.append(TextEdit(oldRange: o, newRange: n))
        }
        return out.isEmpty ? single : out
    }

    /// Index of the first unit of the line that contains `position` (searching only before it).
    private static func lineStart(_ s: NSString, before position: Int) -> Int {
        if position == 0 { return 0 }
        let r = s.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: position))
        return r.location == NSNotFound ? 0 : r.location + 1
    }

    // MARK: position mapping

    /// Maps an OLD offset to the NEW text. Offsets inside a replaced range keep their relative offset (clamped to the
    /// replacement), offsets exactly at the start of an edit stay in front of inserted text.
    static func map(_ position: Int, through edits: [TextEdit]) -> Int {
        var delta = 0
        for e in edits {
            let os = e.oldRange.location, oe = NSMaxRange(e.oldRange)
            if position <= os { return position + delta }
            if position < oe { return e.newRange.location + min(position - os, e.newRange.length) }
            if position == oe && e.oldRange.length > 0 { return NSMaxRange(e.newRange) }
            delta = NSMaxRange(e.newRange) - oe
        }
        return position + delta
    }

    static func map(_ range: NSRange, through edits: [TextEdit]) -> NSRange {
        let s = map(range.location, through: edits)
        let e = map(NSMaxRange(range), through: edits)
        return NSRange(location: s, length: max(0, e - s))
    }

    // MARK: line tables + Myers (shared with Diff3)

    struct Lines {
        var units: [UInt16]
        /// starts[i] = offset of line i inside `units`; starts[count] = units.count
        var starts: [Int] = []
        var hashes: [UInt64] = []
        var count: Int { hashes.count }

        init(_ s: NSString, _ range: NSRange) {
            units = [UInt16](repeating: 0, count: range.length)
            if range.length > 0 {
                units.withUnsafeMutableBufferPointer { s.getCharacters($0.baseAddress!, range: range) }
            }
            build()
        }
        init(units: [UInt16]) { self.units = units; build() }

        private mutating func build() {
            let n = units.count
            starts.reserveCapacity(n / 40 + 2)
            hashes.reserveCapacity(n / 40 + 2)
            units.withUnsafeBufferPointer { u in
                var lineStart = 0
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                var i = 0
                while i < n {
                    if i == lineStart { starts.append(i) }
                    h = (h ^ UInt64(u[i])) &* 0x0000_0100_0000_01b3
                    if u[i] == 10 {
                        hashes.append(h); h = 0xcbf2_9ce4_8422_2325; lineStart = i + 1
                    }
                    i += 1
                }
                if lineStart < n { hashes.append(h) }
            }
            starts.append(n)
        }

        @inline(__always) func equal(_ i: Int, _ other: Lines, _ j: Int) -> Bool {
            if hashes[i] != other.hashes[j] { return false }
            let la = starts[i + 1] - starts[i]
            if la != other.starts[j + 1] - other.starts[j] { return false }
            return units.withUnsafeBufferPointer { a in other.units.withUnsafeBufferPointer { b in
                memcmp(a.baseAddress! + starts[i], b.baseAddress! + other.starts[j], la * 2) == 0 } }
        }
    }

    struct Hunk: Equatable { var aStart: Int, aEnd: Int, bStart: Int, bEnd: Int }   // line indices, half-open

    /// Myers O(ND) greedy diff on line tables. nil if the edit distance exceeds `maxD`.
    static func myers(_ a: Lines, _ b: Lines, maxD: Int) -> [Hunk]? {
        let n = a.count, m = b.count
        var pre = 0
        while pre < n && pre < m && a.equal(pre, b, pre) { pre += 1 }
        var suf = 0
        while suf < n - pre && suf < m - pre && a.equal(n - 1 - suf, b, m - 1 - suf) { suf += 1 }
        let N = n - pre - suf, M = m - pre - suf
        if N == 0 && M == 0 { return [] }
        if N == 0 { return [Hunk(aStart: pre, aEnd: pre, bStart: pre, bEnd: pre + M)] }
        if M == 0 { return [Hunk(aStart: pre, aEnd: pre + N, bStart: pre, bEnd: pre)] }

        let cap = min(maxD, N + M)
        let off = cap + 1
        var v = [Int](repeating: 0, count: 2 * cap + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(min(cap + 1, 256))
        var found = -1
        search: for d in 0...cap {
            trace.append(Array(v[(off - d - 1)...(off + d + 1)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { x = v[off + k + 1] } else { x = v[off + k - 1] + 1 }
                var y = x - k
                while x < N && y < M && a.equal(pre + x, b, pre + y) { x += 1; y += 1 }
                v[off + k] = x
                if x >= N && y >= M { found = d; break search }
                k += 2
            }
        }
        if found < 0 { return nil }

        // Backtrack: collect single-line operations, then merge neighbours into hunks.
        var ops: [Hunk] = []
        var x = N, y = M
        var d = found
        while d > 0 {
            let vv = trace[d]                  // v after round d-1, window [-d-1 ... d+1] -> index k + d + 1
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vv[k - 1 + d + 1] < vv[k + 1 + d + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vv[prevK + d + 1]
            let prevY = prevX - prevK
            if prevK == k + 1 {   // insertion of b[prevY]
                ops.append(Hunk(aStart: pre + prevX, aEnd: pre + prevX, bStart: pre + prevY, bEnd: pre + prevY + 1))
            } else {              // deletion of a[prevX]
                ops.append(Hunk(aStart: pre + prevX, aEnd: pre + prevX + 1, bStart: pre + prevY, bEnd: pre + prevY))
            }
            x = prevX; y = prevY
            d -= 1
        }
        ops.reverse()
        var hunks: [Hunk] = []
        for op in ops {
            if var last = hunks.last, last.aEnd == op.aStart, last.bEnd == op.bStart {
                last.aEnd = op.aEnd; last.bEnd = op.bEnd
                hunks[hunks.count - 1] = last
            } else {
                hunks.append(op)
            }
        }
        return hunks
    }
}

// MARK: - three-way merge

enum Diff3 {
    /// Line-based three-way merge. `base` is the text both sides started from (the last text known to be on disk),
    /// `mine` the editor's text, `theirs` the new disk text. Returns the merged text, or nil when any change of the
    /// two sides touches/overlaps (conservative, like `git merge-file` without -zealous) or the diff is too big.
    static func merge(base: NSString, mine: NSString, theirs: NSString, maxLineEditDistance: Int = 1500) -> NSString? {
        if mine.isEqual(base) { return theirs }
        if theirs.isEqual(base) || mine.isEqual(theirs) { return mine }

        let bl = base.length, ml = mine.length, tl = theirs.length
        // common prefix/suffix of all three
        let p = min(TextDiff.commonPrefix(base, mine), TextDiff.commonPrefix(base, theirs))
        let sMax = min(bl, ml, tl) - p
        let s = min(TextDiff.commonSuffix(base, mine, maxLength: sMax), TextDiff.commonSuffix(base, theirs, maxLength: sMax))
        // line-align: start of the line containing p, end after the first "\n" at/after the suffix start
        var ls = 0
        if p > 0 {
            let r = base.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: p))
            ls = r.location == NSNotFound ? 0 : r.location + 1
        }
        var bEnd = bl - s
        let q = base.range(of: "\n", options: .literal, range: NSRange(location: bEnd, length: bl - bEnd)).location
        bEnd = (q == NSNotFound) ? bl : q + 1
        let suf = bl - bEnd
        let mEnd = ml - suf, tEnd = tl - suf
        if mEnd < ls || tEnd < ls || bEnd < ls { return nil }
        if (bEnd - ls) > 24_000_000 || (mEnd - ls) > 24_000_000 || (tEnd - ls) > 24_000_000 { return nil }

        let B = TextDiff.Lines(base, NSRange(location: ls, length: bEnd - ls))
        let M = TextDiff.Lines(mine, NSRange(location: ls, length: mEnd - ls))
        let T = TextDiff.Lines(theirs, NSRange(location: ls, length: tEnd - ls))
        guard let ha = TextDiff.myers(B, M, maxD: maxLineEditDistance),
              let hb = TextDiff.myers(B, T, maxD: maxLineEditDistance) else { return nil }

        struct Item { var side: Int; var h: TextDiff.Hunk }
        var items = ha.map { Item(side: 0, h: $0) } + hb.map { Item(side: 1, h: $0) }
        items.sort { ($0.h.aStart, $0.h.aEnd, $0.side) < ($1.h.aStart, $1.h.aEnd, $1.side) }

        var out: [UInt16] = []
        out.reserveCapacity(B.units.count + (M.units.count - B.units.count > 0 ? M.units.count - B.units.count : 0) + (T.units.count > B.units.count ? T.units.count - B.units.count : 0) + 16)
        func appendBase(_ from: Int, _ to: Int) { if to > from { out.append(contentsOf: B.units[B.starts[from]..<B.starts[to]]) } }
        func replacement(_ it: Item) -> ArraySlice<UInt16> {
            it.side == 0 ? M.units[M.starts[it.h.bStart]..<M.starts[it.h.bEnd]] : T.units[T.starts[it.h.bStart]..<T.starts[it.h.bEnd]]
        }
        var cursor = 0
        var i = 0
        while i < items.count {
            var clusterEnd = items[i].h.aEnd
            var j = i + 1
            var sides = 1 << items[i].side
            while j < items.count && items[j].h.aStart <= clusterEnd {
                clusterEnd = max(clusterEnd, items[j].h.aEnd); sides |= 1 << items[j].side; j += 1
            }
            let first = items[i]
            if sides == 3 {
                // both sides touched the same region: only OK if it is the very same change
                guard j - i == 2, items[i].h.aStart == items[i + 1].h.aStart, items[i].h.aEnd == items[i + 1].h.aEnd,
                      replacement(items[i]).elementsEqual(replacement(items[i + 1])) else { return nil }
                appendBase(cursor, first.h.aStart); out.append(contentsOf: replacement(first)); cursor = first.h.aEnd
            } else {
                for k in i..<j {
                    let it = items[k]
                    appendBase(cursor, it.h.aStart); out.append(contentsOf: replacement(it)); cursor = it.h.aEnd
                }
            }
            i = j
        }
        appendBase(cursor, B.count)

        // assemble prefix + merged middle + suffix
        let total = ls + out.count + suf
        var all = [UInt16](repeating: 0, count: total)
        all.withUnsafeMutableBufferPointer { buf in
            if ls > 0 { base.getCharacters(buf.baseAddress!, range: NSRange(location: 0, length: ls)) }
            out.withUnsafeBufferPointer { o in if o.count > 0 { memcpy(buf.baseAddress! + ls, o.baseAddress!, o.count * 2) } }
            if suf > 0 { base.getCharacters(buf.baseAddress! + ls + out.count, range: NSRange(location: bl - suf, length: suf)) }
        }
        return NSString(characters: all, length: total)
    }
}
