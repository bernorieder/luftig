import Foundation

/// Style bit set used by the spike lexer (stand-in for MarkdownKit's MDStyle).
enum S {
    static let headingMask: UInt32 = 7           // low 3 bits: heading level 1..6
    static let bold: UInt32 = 1 << 3
    static let italic: UInt32 = 1 << 4
    static let strike: UInt32 = 1 << 5
    static let inlineCode: UInt32 = 1 << 6
    static let codeBlock: UInt32 = 1 << 7
    static let fence: UInt32 = 1 << 8
    static let quote: UInt32 = 1 << 9
    static let marker: UInt32 = 1 << 10          // dim syntax punctuation
    static let listMarker: UInt32 = 1 << 11
    static let linkText: UInt32 = 1 << 12
    static let linkDest: UInt32 = 1 << 13
    static let rule: UInt32 = 1 << 14
    static let table: UInt32 = 1 << 15
    static let comment: UInt32 = 1 << 16
    static let listItem: UInt32 = 1 << 17         // line-level: paragraph is a list item

    /// Bits that decide the paragraph style (must be identical for every run of a paragraph).
    static let lineLevelMask: UInt32 = headingMask | codeBlock | fence | quote | rule | table | comment | listItem
}

struct Run {
    var loc: Int
    var len: Int
    var style: UInt32
}

/// Line-oriented markdown lexer over UTF-16 code units. Emits coalesced, ordered, non-overlapping runs.
/// Not a CommonMark implementation: only enough fidelity for realistic run counts and styles.
final class MiniLexer {
    private var runs: [Run] = []
    private var base = 0
    private var p: UnsafePointer<UInt16>! = nil
    private var inFence = false
    private var lineBase: UInt32 = 0
    /// If true, adjacent runs with equal style are merged (coalesced). If false every token boundary is kept.
    var coalesce = true

    /// `buf` is the text of the slice only; `offset` is the slice's absolute UTF-16 location.
    /// The slice must start at a line start. `inFence` is the fence state at the slice start.
    func lex(_ buf: UnsafeBufferPointer<UInt16>, offset: Int, inFence startFence: Bool) -> [Run] {
        runs.removeAll(keepingCapacity: true)
        runs.reserveCapacity(buf.count / 6)
        base = offset
        guard let baseAddress = buf.baseAddress else { return [] }
        p = baseAddress
        inFence = startFence
        let n = buf.count
        var i = 0
        while i < n {
            var e = i
            while e < n && p[e] != 10 { e += 1 }
            lexLine(i, e)
            if e < n { emit(e, e + 1, lineBase) }
            i = e < n ? e + 1 : e
        }
        return runs
    }

    @inline(__always) private func emit(_ s: Int, _ e: Int, _ style: UInt32) {
        if e <= s { return }
        if coalesce, var last = runs.last, last.style == style, last.loc + last.len == base + s {
            last.len += e - s
            runs[runs.count - 1] = last
        } else {
            runs.append(Run(loc: base + s, len: e - s, style: style))
        }
    }

    private func lexLine(_ s: Int, _ e: Int) {
        let len = e - s
        if len == 0 { lineBase = inFence ? S.codeBlock : 0; return }
        // fenced code
        if inFence {
            lineBase = S.codeBlock
            if len >= 3 && p[s] == 96 && p[s + 1] == 96 && p[s + 2] == 96 {
                emit(s, e, S.codeBlock | S.fence); inFence = false
            } else {
                emit(s, e, S.codeBlock)
            }
            return
        }
        if len >= 3 && p[s] == 96 && p[s + 1] == 96 && p[s + 2] == 96 {
            lineBase = S.codeBlock
            emit(s, e, S.codeBlock | S.fence); inFence = true; return
        }
        let c0 = p[s]
        // ATX heading
        if c0 == 35 {
            var h = 0
            while s + h < e && p[s + h] == 35 && h < 7 { h += 1 }
            if h <= 6 && s + h < e && p[s + h] == 32 {
                lineBase = UInt32(h)
                emit(s, s + h + 1, lineBase | S.marker)
                lexInline(s + h + 1, e, base: lineBase)
                return
            }
        }
        // block quote
        if c0 == 62 {
            lineBase = S.quote
            var m = s + 1
            if m < e && p[m] == 32 { m += 1 }
            emit(s, m, S.quote | S.marker)
            lexInline(m, e, base: S.quote)
            return
        }
        // horizontal rule
        if (c0 == 45 || c0 == 42 || c0 == 95) && len >= 3 {
            var all = true
            var j = s
            while j < e { if p[j] != c0 && p[j] != 32 { all = false; break }; j += 1 }
            if all {
                lineBase = S.rule
                emit(s, e, S.rule | S.marker); return
            }
        }
        // table row
        if c0 == 124 {
            lineBase = S.table
            lexInline(s, e, base: S.table)
            return
        }
        // html comment
        if c0 == 60 && len >= 4 && p[s + 1] == 33 && p[s + 2] == 45 && p[s + 3] == 45 {
            lineBase = S.comment
            emit(s, e, S.comment); return
        }
        // list item
        var k = s
        while k < e && p[k] == 32 && k - s < 12 { k += 1 }
        if k < e {
            let c = p[k]
            var markerEnd = -1
            if (c == 45 || c == 42 || c == 43) && k + 1 < e && p[k + 1] == 32 {
                markerEnd = k + 2
            } else if c >= 48 && c <= 57 {
                var d = k
                while d < e && p[d] >= 48 && p[d] <= 57 && d - k < 9 { d += 1 }
                if d < e && d > k && (p[d] == 46 || p[d] == 41) && d + 1 < e && p[d + 1] == 32 { markerEnd = d + 2 }
            }
            if markerEnd > 0 {
                lineBase = S.listItem
                if k > s { emit(s, k, S.listItem) }
                emit(k, markerEnd, S.listItem | S.listMarker)
                lexInline(markerEnd, e, base: S.listItem)
                return
            }
        }
        lineBase = 0
        lexInline(s, e, base: 0)
    }

    @inline(__always) private func isAlnum(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127
    }

    private func lexInline(_ s: Int, _ e: Int, base b: UInt32) {
        var i = s
        var seg = s
        var bold = false, italic = false, strike = false
        @inline(__always) func cur() -> UInt32 {
            b | (bold ? S.bold : 0) | (italic ? S.italic : 0) | (strike ? S.strike : 0)
        }
        @inline(__always) func flush(_ upTo: Int) {
            if upTo > seg { emit(seg, upTo, cur()) }
            seg = upTo
        }
        while i < e {
            let c = p[i]
            switch c {
            case 92: // backslash escape
                i += 2
            case 96: // inline code
                var n = 0
                while i + n < e && p[i + n] == 96 { n += 1 }
                var j = i + n
                var close = -1
                while j < e {
                    if p[j] == 96 {
                        var m = 0
                        while j + m < e && p[j + m] == 96 { m += 1 }
                        if m == n { close = j; break }
                        j += m
                    } else { j += 1 }
                }
                if close >= 0 {
                    flush(i)
                    emit(i, i + n, cur() | S.inlineCode | S.marker)
                    emit(i + n, close, cur() | S.inlineCode)
                    emit(close, close + n, cur() | S.inlineCode | S.marker)
                    i = close + n; seg = i
                } else { i += n }
            case 42, 95: // * _
                var n = 0
                while i + n < e && p[i + n] == c { n += 1 }
                let prev: UInt16 = i > s ? p[i - 1] : 32
                let next: UInt16 = i + n < e ? p[i + n] : 32
                let opening = next != 32 && !(c == 95 && isAlnum(prev))
                let closing = prev != 32 && !(c == 95 && isAlnum(next))
                let active = (n == 1 && italic) || (n == 2 && bold) || (n == 3 && bold && italic)
                if n <= 3 && ((active && closing) || (!active && opening)) {
                    flush(i)
                    // marker run carries the style *before* toggling for closers and *after* for openers
                    if n == 1 { italic.toggle() } else if n == 2 { bold.toggle() } else { bold.toggle(); italic.toggle() }
                    emit(i, i + n, cur() | S.marker)
                    i += n; seg = i
                } else { i += n }
            case 126: // ~~
                if i + 1 < e && p[i + 1] == 126 {
                    flush(i)
                    strike.toggle()
                    emit(i, i + 2, cur() | S.marker)
                    i += 2; seg = i
                } else { i += 1 }
            case 91: // [text](dest)
                var j = i + 1
                while j < e && p[j] != 93 { j += 1 }
                if j + 1 < e && p[j] == 93 && p[j + 1] == 40 {
                    var k = j + 2
                    while k < e && p[k] != 41 { k += 1 }
                    if k < e {
                        flush(i)
                        emit(i, i + 1, cur() | S.marker)
                        emit(i + 1, j, cur() | S.linkText)
                        emit(j, j + 2, cur() | S.marker)
                        emit(j + 2, k, cur() | S.linkDest)
                        emit(k, k + 1, cur() | S.marker)
                        i = k + 1; seg = i
                        continue
                    }
                }
                i += 1
            default:
                i += 1
            }
        }
        flush(min(i, e))
    }
}

/// Fast pre-scan for fence lines (lines starting with ```). Gives the block state at any offset by binary search.
/// Cost is reported in the spike: this is what a "jump to the middle of a 20 MB file" needs for block state.
struct FenceIndex {
    var starts: [Int32] = []   // UTF-16 offsets of fence lines in order; odd count before offset => inside fence
    static func build(_ u: UnsafeBufferPointer<UInt16>) -> FenceIndex {
        var idx = FenceIndex()
        let n = u.count
        var i = 0
        idx.starts.reserveCapacity(n / 2000)
        // line starts: i == 0 or u[i-1] == '\n'
        while i < n {
            if i + 2 < n && u[i] == 96 && u[i + 1] == 96 && u[i + 2] == 96 { idx.starts.append(Int32(i)) }
            // advance to next line start
            var j = i
            while j < n && u[j] != 10 { j += 1 }
            i = j + 1
        }
        return idx
    }
    /// Is a line starting at `offset` (a line start) inside a fenced block (i.e. after an opening fence, before its closing)?
    func inFence(atLineStart offset: Int) -> Bool {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(starts[mid]) < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo % 2 == 1
    }
}
