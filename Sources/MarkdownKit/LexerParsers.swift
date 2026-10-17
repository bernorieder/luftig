import Foundation

struct ListMarker {
    var width: Int
    var contentPos: Int
    var contentCol: Int
    var empty: Bool
    var ordered: Bool
    var number: Int
}

struct RefDef {
    var labelEnd: Int       // index of ']'
    var destStart: Int
    var destEnd: Int
    var titleStart: Int     // -1 if none
    var titleEnd: Int
}

/// Small syntactic recognisers used by the block pass. All indices are window-relative and bounded by `le`.
extension Lexer {

    func isThematicBreak(_ fp: Int, _ le: Int) -> Bool {
        let w = self.w
        let c = w[fp]
        guard c == 45 || c == 42 || c == 95 else { return false }
        var n = 0
        var i = fp
        while i < le {
            let x = w[i]
            if x == c { n += 1 } else if x != 32 && x != 9 { return false }
            i += 1
        }
        return n >= 3
    }

    /// ATX heading level at `fp` (1...6), or 0.
    func atxLevel(_ fp: Int, _ le: Int) -> Int {
        let w = self.w
        var n = 0
        while fp + n < le && w[fp + n] == 35 && n < 7 { n += 1 }
        if n < 1 || n > 6 { return 0 }
        if fp + n == le || isSpaceOrTab(w[fp + n]) { return n }
        return 0
    }

    /// Length of an opening code fence run at `fp`, or nil.
    func fenceLength(_ fp: Int, _ le: Int) -> Int? {
        let w = self.w
        let c = w[fp]
        var q = fp
        while q < le && w[q] == c { q += 1 }
        let n = q - fp
        if n < 3 { return nil }
        if c == 96 {
            var i = q
            while i < le { if w[i] == 96 { return nil }; i += 1 }
        }
        return n
    }

    /// Length of a setext underline made of `ch` (only trailing whitespace allowed), or nil.
    func underlineLength(_ fp: Int, _ le: Int, _ ch: UInt16) -> Int? {
        let w = self.w
        var q = fp
        while q < le && w[q] == ch { q += 1 }
        let n = q - fp
        while q < le && isSpaceOrTab(w[q]) { q += 1 }
        return q == le && n > 0 ? n : nil
    }

    func parseListMarker(_ fp: Int, _ fcol: Int, _ le: Int) -> ListMarker? {
        let w = self.w
        let c = w[fp]
        var p = fp
        var ordered = false
        var number = 0
        if c == 45 || c == 43 || c == 42 {
            p = fp + 1
        } else if isDigit(c) {
            var n = 0
            while p < le && isDigit(w[p]) && n < 10 { number = number * 10 + Int(w[p] - 48); p += 1; n += 1 }
            if n > 9 || p >= le { return nil }
            let d = w[p]
            if d != 46 && d != 41 { return nil }
            p += 1
            ordered = true
        } else { return nil }
        let width = p - fp
        let endCol = fcol + width
        if p < le && !isSpaceOrTab(w[p]) { return nil }
        if p >= le {
            return ListMarker(width: width, contentPos: le, contentCol: endCol + 1, empty: true, ordered: ordered, number: number)
        }
        var q = p, qc = endCol
        while q < le && isSpaceOrTab(w[q]) { qc += (w[q] == 9) ? 4 - (qc & 3) : 1; q += 1 }
        if q >= le {
            return ListMarker(width: width, contentPos: le, contentCol: endCol + 1, empty: true, ordered: ordered, number: number)
        }
        if qc - endCol >= 5 {
            let cc = (w[p] == 9) ? endCol + (4 - (endCol & 3)) : endCol + 1
            return ListMarker(width: width, contentPos: p + 1, contentCol: cc, empty: false, ordered: ordered, number: number)
        }
        return ListMarker(width: width, contentPos: q, contentCol: qc, empty: false, ordered: ordered, number: number)
    }

    /// `[^label]:` at fp -> index of the closing ']' ; nil otherwise.
    func footnoteDefEnd(_ fp: Int, _ le: Int) -> Int? {
        let w = self.w
        var j = fp + 2
        while j < le && w[j] != 93 && w[j] != 91 && !isSpaceOrTab(w[j]) { j += 1 }
        if j < le && w[j] == 93 && j > fp + 2 && j + 1 < le && w[j + 1] == 58 { return j }
        return nil
    }

    // MARK: HTML

    /// Index just after a complete single-line HTML open / closing tag starting at `i`, or -1.
    func parseHTMLTag(_ i: Int, _ e: Int) -> Int {
        let w = self.w
        let limit = min(e, i + 600)
        var j = i + 1
        if j >= limit { return -1 }
        if w[j] == 47 {
            j += 1
            guard j < limit, isAlpha(w[j]) else { return -1 }
            while j < limit && (isAlnum(w[j]) || w[j] == 45) { j += 1 }
            while j < limit && isSpaceOrTab(w[j]) { j += 1 }
            return (j < limit && w[j] == 62) ? j + 1 : -1
        }
        guard isAlpha(w[j]) else { return -1 }
        while j < limit && (isAlnum(w[j]) || w[j] == 45) { j += 1 }
        while true {
            var sp = 0
            while j < limit && isSpaceOrTab(w[j]) { j += 1; sp += 1 }
            if j >= limit { return -1 }
            let c = w[j]
            if c == 62 { return j + 1 }
            if c == 47 { return (j + 1 < limit && w[j + 1] == 62) ? j + 2 : -1 }
            if sp == 0 { return -1 }
            guard isAlpha(c) || c == 95 || c == 58 else { return -1 }
            j += 1
            while j < limit && (isAlnum(w[j]) || w[j] == 95 || w[j] == 46 || w[j] == 58 || w[j] == 45) { j += 1 }
            var k = j
            while k < limit && isSpaceOrTab(w[k]) { k += 1 }
            if k < limit && w[k] == 61 {
                k += 1
                while k < limit && isSpaceOrTab(w[k]) { k += 1 }
                if k >= limit { return -1 }
                let q = w[k]
                if q == 34 || q == 39 {
                    k += 1
                    while k < limit && w[k] != q { k += 1 }
                    if k >= limit { return -1 }
                    k += 1
                } else {
                    let s = k
                    while k < limit {
                        let x = w[k]
                        if isSpaceOrTab(x) || x == 34 || x == 39 || x == 61 || x == 60 || x == 62 || x == 96 { break }
                        k += 1
                    }
                    if k == s { return -1 }
                }
                j = k
            }
        }
    }

    private func nameMatches(_ s: Int, _ e: Int, _ name: [UInt8]) -> Bool {
        if e - s != name.count { return false }
        let w = self.w
        var i = 0
        while i < name.count { if lower(w[s + i]) != UInt16(name[i]) { return false }; i += 1 }
        return true
    }

    /// HTML block start condition 1...7 at `fp` (w[fp] == '<'), or 0.
    func htmlBlockStart(_ fp: Int, _ le: Int, allowType7: Bool) -> UInt8 {
        let w = self.w
        var p = fp + 1
        if p >= le { return 0 }
        let c = w[p]
        if c == 33 {                                              // <!
            if p + 2 < le && w[p + 1] == 45 && w[p + 2] == 45 { return 2 }
            if p + 7 < le + 0 && w[p + 1] == 91 && w[p + 2] == 67 && w[p + 3] == 68 && w[p + 4] == 65 && w[p + 5] == 84 && w[p + 6] == 65 && w[p + 7] == 91 { return 5 }
            if p + 1 < le && isAlpha(w[p + 1]) { return 4 }
            return 0
        }
        if c == 63 { return 3 }                                   // <?
        var closing = false
        if c == 47 { closing = true; p += 1 }
        let ns = p
        while p < le && (isAlnum(w[p]) || w[p] == 45) { p += 1 }
        if p == ns || !isAlpha(w[ns]) { return 0 }
        let term = p >= le || isSpaceOrTab(w[p]) || w[p] == 62
        if !closing && term {
            for rn in HTMLNames.rawNames where nameMatches(ns, p, rn) { return 1 }
        }
        if term || (w[p] == 47 && p + 1 < le && w[p + 1] == 62) {
            for bn in HTMLNames.blockNames where nameMatches(ns, p, bn) { return 6 }
        }
        if allowType7 {
            let end = parseHTMLTag(fp, le)
            if end > 0 {
                var q = end
                while q < le && isSpaceOrTab(w[q]) { q += 1 }
                if q == le { return 7 }
            }
        }
        return 0
    }

    /// Does the end condition of HTML block type `t` (1...5) occur in [from, le)?
    func htmlEnds(_ t: UInt8, _ from: Int, _ le: Int) -> Bool {
        let w = self.w
        var i = max(from, 0)
        switch t {
        case 1:
            while i + 2 < le {
                if w[i] == 60 && w[i + 1] == 47 {
                    for rn in HTMLNames.rawNames {
                        let e = i + 2 + rn.count
                        if e < le && w[e] == 62 && nameMatches(i + 2, e, rn) { return true }
                    }
                }
                i += 1
            }
            return false
        case 2:
            while i + 2 < le { if w[i] == 45 && w[i + 1] == 45 && w[i + 2] == 62 { return true }; i += 1 }
            return false
        case 3:
            while i + 1 < le { if w[i] == 63 && w[i + 1] == 62 { return true }; i += 1 }
            return false
        case 4:
            while i < le { if w[i] == 62 { return true }; i += 1 }
            return false
        case 5:
            while i + 2 < le { if w[i] == 93 && w[i + 1] == 93 && w[i + 2] == 62 { return true }; i += 1 }
            return false
        default:
            return false
        }
    }

    // MARK: Tables

    /// Number of cells if [fp, le) is a GFM table delimiter row (must contain a pipe), else nil.
    func tableDelimiterCells(_ fp: Int, _ le: Int) -> Int? {
        let w = self.w
        var i = fp
        var cells = 0
        var sawPipe = false
        if w[i] == 124 { sawPipe = true; i += 1 }
        while true {
            while i < le && isSpaceOrTab(w[i]) { i += 1 }
            if i >= le { break }
            if w[i] == 58 { i += 1 }
            var d = 0
            while i < le && w[i] == 45 { i += 1; d += 1 }
            if d == 0 { return nil }
            if i < le && w[i] == 58 { i += 1 }
            while i < le && isSpaceOrTab(w[i]) { i += 1 }
            cells += 1
            if i >= le { break }
            if w[i] != 124 { return nil }
            sawPipe = true
            i += 1
        }
        return (cells >= 1 && sawPipe) ? cells : nil
    }

    /// Number of cells of a table row (leading / trailing pipes optional, `\|` is not a separator).
    func tableCellCount(_ cs: Int, _ ce: Int) -> Int {
        let w = self.w
        var a = cs, b = ce
        while a < b && isSpaceOrTab(w[a]) { a += 1 }
        while b > a && isSpaceOrTab(w[b - 1]) { b -= 1 }
        if a >= b { return 0 }
        var pipes = 0
        var lastPipe = -1
        var i = a
        while i < b {
            if w[i] == 92 { i += 2; continue }
            if w[i] == 124 { pipes += 1; lastPipe = i }
            i += 1
        }
        let leading = w[a] == 124
        let trailing = lastPipe == b - 1
        return max(0, pipes + 1 - (leading ? 1 : 0) - (trailing ? 1 : 0))
    }

    // MARK: Link reference definitions

    func parseRefDef(_ fp: Int, _ le: Int) -> RefDef? {
        let w = self.w
        var j = fp + 1
        var nonWS = false
        while j < le {
            let c = w[j]
            if c == 93 { break }
            if c == 91 { return nil }
            if c == 92 { j += 1 }
            if !isSpaceOrTab(c) { nonWS = true }
            j += 1
        }
        guard j < le, w[j] == 93, nonWS, j - fp <= 1000, j + 1 < le, w[j + 1] == 58 else { return nil }
        var k = j + 2
        while k < le && isSpaceOrTab(w[k]) { k += 1 }
        guard k < le else { return nil }
        var ds = k, de = k
        if w[k] == 60 {
            var t = k + 1
            while t < le && w[t] != 62 && w[t] != 60 { t += 1 }
            guard t < le, w[t] == 62 else { return nil }
            de = t + 1
        } else {
            while k < le && !isSpaceOrTab(w[k]) { k += 1 }
            de = k
            if de == ds { return nil }
        }
        k = de
        var mm = k
        while mm < le && isSpaceOrTab(w[mm]) { mm += 1 }
        if mm >= le { return RefDef(labelEnd: j, destStart: ds, destEnd: de, titleStart: -1, titleEnd: -1) }
        guard mm > k else { return nil }
        let open = w[mm]
        let close: UInt16 = open == 34 ? 34 : (open == 39 ? 39 : (open == 40 ? 41 : 0))
        guard close != 0 else { return nil }
        var t = mm + 1
        while t < le && w[t] != close { if w[t] == 92 { t += 1 }; t += 1 }
        guard t < le else { return nil }
        var r = t + 1
        while r < le && isSpaceOrTab(w[r]) { r += 1 }
        guard r == le else { return nil }
        ds = min(ds, de)
        return RefDef(labelEnd: j, destStart: ds, destEnd: de, titleStart: mm, titleEnd: t + 1)
    }
}
