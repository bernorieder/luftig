import Foundation

struct Delim {
    var pos: Int            // window index of the first remaining delimiter character
    var count: Int          // remaining characters
    var orig: Int           // original run length
    var ch: UInt16
    var canOpen: Bool
    var canClose: Bool
    var alive: Bool
    var prev: Int
    var next: Int
}

struct Bracket {
    var pos: Int            // index of '[' (or of '!' for images)
    var isImage: Bool
    var active: Bool
    var delimMark: Int      // delims.count when pushed
}

private let maxDelims = 1024
private let maxBrackets = 256

/// Inline lexer over the paragraph segments in `segS/segE[0..<segN]` (window-relative content ranges; the gaps
/// between segments are container prefixes and line breaks). Constructs never cross paragraph boundaries; an
/// unclosed delimiter degrades to plain text. Facets are OR-ed into `sty`.
extension Lexer {

    // MARK: painting across segments

    @inline(__always) func paintSpan(_ a: Int, _ b: Int, _ v: UInt32) {
        if a >= b { return }
        if segN == 1 { paint(a, b, v); return }
        var lo = 0, hi = segN
        while lo < hi { let mid = (lo + hi) >> 1; if segX[mid] > a { hi = mid } else { lo = mid + 1 } }
        var k = lo
        while k < segN && segS[k] < b {
            paint(max(a, segS[k]), min(b, segX[k]), v)
            k += 1
        }
    }

    /// Flanking class of the character that contains window unit `i`: 0 = other, 1 = whitespace, 2 = punctuation / symbol.
    @inline(__always) func clsAt(_ i: Int) -> Int {
        let c = w[i]
        if c < 128 { return Int(tables.uniClassASCII[Int(c)]) }
        return clsNonASCII(i, c)
    }

    func clsNonASCII(_ i: Int, _ c: UInt16) -> Int {
        if c >= 0xD800 && c <= 0xDBFF {                                // high surrogate: the pair starts here
            guard i + 1 < wLen, w[i + 1] >= 0xDC00 && w[i + 1] <= 0xDFFF else { return 0 }
            return Int(unicodeClass(0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(w[i + 1]) - 0xDC00)))
        }
        if c >= 0xDC00 && c <= 0xDFFF {                                // low surrogate: the pair started one unit earlier
            guard i > 0, w[i - 1] >= 0xD800 && w[i - 1] <= 0xDBFF else { return 0 }
            return Int(unicodeClass(0x10000 + ((UInt32(w[i - 1]) - 0xD800) << 10) + (UInt32(c) - 0xDC00)))
        }
        if uniCache.isEmpty { uniCache = [UInt8](repeating: 0xFF, count: 65536) }
        let v = uniCache[Int(c)]
        if v != 0xFF { return Int(v) }
        let k = unicodeClass(UInt32(c))
        uniCache[Int(c)] = k
        return Int(k)
    }

    // MARK: delimiter list

    @inline(__always) func unlinkDelim(_ k: Int) {
        let p = delims[k].prev, n = delims[k].next
        if p != -1 { delims[p].next = n } else { dHead = n }
        if n != -1 { delims[n].prev = p } else { dTail = p }
        delims[k].alive = false
    }

    /// Remove every delimiter with index >= lo from the live list.
    func removeDelims(from lo: Int) {
        if lo >= delims.count { return }
        var t = dTail
        while t != -1 && t >= lo { delims[t].alive = false; t = delims[t].prev }
        dTail = t
        if t != -1 { delims[t].next = -1 } else { dHead = -1 }
    }

    func processEmphasis(from lo: Int) {
        if lo >= delims.count { return }
        for k in 0..<18 { openersBottom[k] = -1 }
        var cur = lo
        while cur < delims.count && !delims[cur].alive { cur += 1 }
        if cur >= delims.count { return }
        while cur != -1 {
            let d = delims[cur]
            if d.canClose {
                let chIdx = d.ch == 42 ? 0 : (d.ch == 95 ? 1 : 2)
                let key = chIdx * 6 + (d.canOpen ? 3 : 0) + d.orig % 3
                let lower = max(openersBottom[key], lo - 1)
                var op = d.prev
                var found = -1
                while op != -1 && op > lower {
                    let o = delims[op]
                    if o.ch == d.ch && o.canOpen {
                        if d.ch == 126 { found = op; break }
                        let odd = (d.canOpen || o.canClose) && d.orig % 3 != 0 && (o.orig + d.orig) % 3 == 0
                        if !odd { found = op; break }
                    }
                    op = o.prev
                }
                if found != -1 {
                    let o = delims[found]
                    let use = (d.ch == 126) ? 2 : ((d.count >= 2 && o.count >= 2) ? 2 : 1)
                    let facet: UInt32 = d.ch == 126 ? MDStyle.strikethrough.rawValue
                        : (use == 2 ? MDStyle.bold.rawValue : MDStyle.italic.rawValue)
                    let opEnd = o.pos + o.count
                    paintSpan(opEnd - use, opEnd, facet | MDStyle.marker.rawValue)
                    paintSpan(d.pos, d.pos + use, facet | MDStyle.marker.rawValue)
                    paintSpan(opEnd, d.pos, facet)
                    delims[found].count -= use
                    delims[cur].count -= use
                    delims[cur].pos += use
                    var t = delims[found].next
                    while t != cur && t != -1 { delims[t].alive = false; t = delims[t].next }
                    delims[found].next = cur
                    delims[cur].prev = found
                    if delims[found].count == 0 { unlinkDelim(found) }
                    if delims[cur].count == 0 {
                        let nx = delims[cur].next
                        unlinkDelim(cur)
                        cur = nx
                    }
                } else {
                    openersBottom[key] = d.prev
                    let nx = d.next
                    if !d.canOpen { unlinkDelim(cur) }
                    cur = nx
                }
            } else {
                cur = d.next
            }
        }
    }

    // MARK: main scan

    func lexInline() {
        let w = self.w
        let cls = tables.inlineClass
        delims.removeAll(keepingCapacity: true)
        brackets.removeAll(keepingCapacity: true)
        dHead = -1; dTail = -1
        failedMask = 0
        var si = 0
        var s = 0, e = 0, i = 0
        var started = false
        while si < segN {
            if !started || i >= e {
                if started { si += 1; if si >= segN { break } }
                started = true
                s = segS[si]; e = segE[si]; i = s
            }
            // fast skip over plain text
            while i < e {
                let c = w[i]
                if c < 128 && cls[Int(c)] != 0 { break }
                i &+= 1
            }
            if i >= e { continue }
            let c = w[i]
            switch c {
            case 92:                                                    // backslash
                if i + 1 < e && isASCIIPunct(w[i + 1]) {
                    paintSpan(i, i + 2, MDStyle.escape.rawValue)
                    i += 2
                } else { i += 1 }

            case 96:                                                    // code span
                var j = i
                while j < e && w[j] == 96 { j += 1 }
                let n = j - i
                if n < 64 && (failedMask >> UInt64(n)) & 1 == 0 {
                    var p = j, k = si
                    var cs = -1, ce2 = -1, ck = si
                    search: while k < segN {
                        let ke = segE[k]
                        if k != si { p = segS[k] }
                        while p < ke {
                            if w[p] != 96 { p &+= 1; continue }
                            var q = p
                            while q < ke && w[q] == 96 { q += 1 }
                            if q - p == n { cs = p; ce2 = q; ck = k; break search }
                            p = q
                        }
                        k += 1
                    }
                    if cs >= 0 {
                        let cv = MDStyle.inlineCode.rawValue
                        paintSpan(i, j, cv | MDStyle.marker.rawValue)
                        paintSpan(j, cs, cv)
                        paintSpan(cs, ce2, cv | MDStyle.marker.rawValue)
                        si = ck; s = segS[si]; e = segE[si]; i = ce2
                        continue
                    }
                    failedMask |= UInt64(1) << UInt64(n)
                }
                i = j

            case 42, 95, 126:                                           // * _ ~
                var j = i
                while j < e && w[j] == c { j += 1 }
                let n = j - i
                if (c != 126 || n == 2) && delims.count < maxDelims {
                    let pc = i > s ? clsAt(i - 1) : 1
                    let nc = j < e ? clsAt(j) : 1
                    let left = nc != 1 && (nc != 2 || pc != 0)
                    let right = pc != 1 && (pc != 2 || nc != 0)
                    var canOpen = left, canClose = right
                    if c == 95 {
                        canOpen = left && (!right || pc == 2)
                        canClose = right && (!left || nc == 2)
                    }
                    if canOpen || canClose {
                        let idx = delims.count
                        delims.append(Delim(pos: i, count: n, orig: n, ch: c, canOpen: canOpen, canClose: canClose,
                                            alive: true, prev: dTail, next: -1))
                        if dTail != -1 { delims[dTail].next = idx } else { dHead = idx }
                        dTail = idx
                    }
                }
                i = j

            case 33:                                                    // '!'
                if i + 1 < e && w[i + 1] == 91 && brackets.count < maxBrackets {
                    brackets.append(Bracket(pos: i, isImage: true, active: true, delimMark: delims.count))
                    i += 2
                } else { i += 1 }

            case 91:                                                    // '['
                if brackets.count < maxBrackets {
                    brackets.append(Bracket(pos: i, isImage: false, active: true, delimMark: delims.count))
                }
                i += 1

            case 93:                                                    // ']'
                i = closeBracket(at: i, segStart: s, segEnd: e)

            case 60:                                                    // '<'
                let end = scanAngle(i, e)
                i = end > i ? end : i + 1

            case 38:                                                    // '&'
                var j = i + 1
                var ok = false
                if j < e {
                    if w[j] == 35 {
                        j += 1
                        if j < e && (w[j] == 120 || w[j] == 88) {
                            j += 1
                            let st0 = j
                            while j < e && j - st0 < 6 && (isDigit(w[j]) || (lower(w[j]) >= 97 && lower(w[j]) <= 102)) { j += 1 }
                            ok = j > st0
                        } else {
                            let st0 = j
                            while j < e && j - st0 < 7 && isDigit(w[j]) { j += 1 }
                            ok = j > st0
                        }
                    } else {
                        let st0 = j
                        while j < e && j - st0 < 32 && isAlnum(w[j]) { j += 1 }
                        ok = j > st0
                    }
                }
                if ok && j < e && w[j] == 59 {
                    paintSpan(i, j + 1, MDStyle.escape.rawValue)
                    i = j + 1
                } else { i += 1 }

            case 58:                                                    // ':' -> http(s)://
                var start = -1
                if i + 3 < e && w[i + 1] == 47 && w[i + 2] == 47 {
                    if i - 4 >= s && lower(w[i - 4]) == 104 && lower(w[i - 3]) == 116 && lower(w[i - 2]) == 116 && lower(w[i - 1]) == 112 { start = i - 4 }
                    else if i - 5 >= s && lower(w[i - 5]) == 104 && lower(w[i - 4]) == 116 && lower(w[i - 3]) == 116 && lower(w[i - 2]) == 112 && lower(w[i - 1]) == 115 { start = i - 5 }
                }
                if start >= 0 && !inOpenBracket() && schemeBoundary(start, s) {
                    let end = urlEnd(from: i + 3, e: e, start: start)
                    if end > i + 3 {
                        paintSpan(start, end, MDStyle.autolink.rawValue)
                        i = end
                        continue
                    }
                }
                i += 1

            case 46:                                                    // '.' -> www.
                if i - 3 >= s && i + 1 < e && lower(w[i - 1]) == 119 && lower(w[i - 2]) == 119 && lower(w[i - 3]) == 119 && !inOpenBracket() && urlBoundary(i - 3, s) {
                    let end = urlEnd(from: i + 1, e: e, start: i - 3)
                    if end > i + 1 {
                        paintSpan(i - 3, end, MDStyle.autolink.rawValue)
                        i = end
                        continue
                    }
                }
                i += 1

            default:
                i += 1
            }
        }
        processEmphasis(from: 0)
        removeDelims(from: 0)
    }

    // MARK: pieces

    func urlBoundary(_ start: Int, _ segStart: Int) -> Bool {
        if start <= segStart { return true }
        let p = w[start - 1]
        return isSpaceOrTab(p) || p == 42 || p == 95 || p == 126 || p == 40
    }

    /// Bare URLs are not recognised while any `[` / `![` opener is still waiting for its `]` (cmark-gfm: "in bracket", inactive
    /// openers count too): the text may turn out to be link text, which cannot contain a link.
    @inline(__always) func inOpenBracket() -> Bool { !brackets.isEmpty }

    /// `http://` / `https://` URLs: like cmark-gfm (which only looks back over letters for the scheme) any character that is not a
    /// letter may precede them - `"http://x.org"`, `url=http://x.org`, `,http://x.org`, `<b>http://x.org</b>`.
    /// `www.` keeps `urlBoundary` (GFM: start, blank, `*`, `_`, `~`, `(`).
    func schemeBoundary(_ start: Int, _ segStart: Int) -> Bool {
        if urlBoundary(start, segStart) { return true }
        return !isAlpha(w[start - 1])
    }

    /// End (exclusive) of a bare URL whose scheme/prefix started at `start`; body begins at `from`.
    func urlEnd(from: Int, e: Int, start: Int) -> Int {
        var j = from
        var paren = 0, bracket = 0
        while j < e {
            let c = w[j]
            if isSpaceOrTab(c) || c == 60 { break }
            if c == 40 { paren += 1 }
            else if c == 41 { if paren == 0 { break }; paren -= 1 }
            else if c == 91 { bracket += 1 }
            else if c == 93 { if bracket == 0 { break }; bracket -= 1 }
            j += 1
        }
        while j > from {
            let c = w[j - 1]
            if c == 63 || c == 33 || c == 46 || c == 44 || c == 58 || c == 42 || c == 95 || c == 126 || c == 39 || c == 34 { j -= 1 }
            else if c == 59 {
                // GFM: a trailing `;` that ends something resembling an entity reference (`&hl;`, `&amp;`) leaves out the whole
                // `&letters;`; any other trailing `;` is just dropped.
                var k = j - 2
                while k > start && isAlpha(w[k]) { k -= 1 }
                if k < j - 2 && k > start && w[k] == 38 { j = k } else { j -= 1 }
            } else { break }
        }
        return j
    }

    /// CommonMark e-mail address: `local@domain`, local part from [A-Za-z0-9.!#$%&'*+/=?^_`{|}~-], domain made of
    /// dot-separated labels of letters, digits and hyphens that start and end with a letter or digit (<= 63 units).
    func isEmailAddress(_ s: Int, _ at: Int, _ end: Int) -> Bool {
        let w = self.w
        var k = s
        while k < at {
            let c = w[k]
            if !(isAlnum(c) || (c >= 33 && c <= 47 && c != 34 && c != 40 && c != 41 && c != 44) || c == 61 || c == 63 || c == 94 || c == 95 || c == 96 || (c >= 123 && c <= 126)) { return false }
            k += 1
        }
        var labelStart = at + 1
        k = at + 1
        while k <= end {
            if k == end || w[k] == 46 {
                let len = k - labelStart
                if len < 1 || len > 63 || !isAlnum(w[labelStart]) || !isAlnum(w[k - 1]) { return false }
                labelStart = k + 1
            } else if !(isAlnum(w[k]) || w[k] == 45) { return false }
            k += 1
        }
        return true
    }

    /// Autolink / inline HTML at '<'. Returns the end index (exclusive) after painting, or i when not a construct.
    func scanAngle(_ i: Int, _ e: Int) -> Int {
        let w = self.w
        if i + 2 >= e { return i }
        let c1 = w[i + 1]
        // autolink <scheme:...> or <user@host>
        if isAlpha(c1) {
            let limit = min(e, i + 2048)
            var j = i + 1
            var at = -1, colon = -1
            while j < limit {
                let c = w[j]
                if c == 62 { break }
                if isSpaceOrTab(c) || c == 60 { j = limit; break }
                if c == 58 && colon < 0 { colon = j }
                if c == 64 && at < 0 { at = j }
                j += 1
            }
            if j < limit && w[j] == 62 {
                var isURI = false
                if colon > i + 2 && colon - (i + 1) <= 32 {
                    isURI = true
                    var k = i + 1
                    while k < colon { let c = w[k]; if !(isAlnum(c) || c == 43 || c == 46 || c == 45) { isURI = false; break }; k += 1 }
                }
                var isMail = false
                if !isURI && at > i + 1 && at < j - 1 && colon < 0 { isMail = isEmailAddress(i + 1, at, j) }
                if isURI || isMail {
                    let av = MDStyle.autolink.rawValue
                    paintSpan(i, i + 1, av | MDStyle.marker.rawValue)
                    paintSpan(i + 1, j, av)
                    paintSpan(j, j + 1, av | MDStyle.marker.rawValue)
                    return j + 1
                }
            }
        }
        // inline HTML
        let hv = MDStyle.html.rawValue
        if c1 == 33 {
            if i + 3 < e && w[i + 2] == 45 && w[i + 3] == 45 {            // comment
                // CommonMark 0.31: `<!-->` and `<!--->` are (empty) comments
                if i + 4 < e && w[i + 4] == 62 { paintSpan(i, i + 5, hv); return i + 5 }
                if i + 5 < e && w[i + 4] == 45 && w[i + 5] == 62 { paintSpan(i, i + 6, hv); return i + 6 }
                var j = i + 4
                let limit = min(e, i + 4096)
                while j + 2 < limit + 0 { if w[j] == 45 && w[j + 1] == 45 && w[j + 2] == 62 { paintSpan(i, j + 3, hv); return j + 3 }; j += 1 }
                return i
            }
            if isAlpha(w[i + 2]) {                                        // declaration
                var j = i + 3
                let limit = min(e, i + 2048)
                while j < limit { if w[j] == 62 { paintSpan(i, j + 1, hv); return j + 1 }; j += 1 }
            } else if i + 8 < e && w[i + 2] == 91 && w[i + 3] == 67 && w[i + 4] == 68 && w[i + 5] == 65 && w[i + 6] == 84 && w[i + 7] == 65 && w[i + 8] == 91 {
                var j = i + 9                                             // CDATA section
                let limit = min(e, i + 2048)
                while j + 2 < limit { if w[j] == 93 && w[j + 1] == 93 && w[j + 2] == 62 { paintSpan(i, j + 3, hv); return j + 3 }; j += 1 }
            }
            return i
        }
        if c1 == 63 {                                                     // processing instruction
            var j = i + 2
            let limit = min(e, i + 2048)
            while j + 1 < limit { if w[j] == 63 && w[j + 1] == 62 { paintSpan(i, j + 2, hv); return j + 2 }; j += 1 }
            return i
        }
        let end = parseHTMLTag(i, e)
        if end > 0 { paintSpan(i, end, hv); return end }
        return i
    }

    /// Handle ']' at index i. Returns the index to continue scanning from.
    func closeBracket(at i: Int, segStart s: Int, segEnd e: Int) -> Int {
        let w = self.w
        guard let b = brackets.last else { return i + 1 }
        if !b.active { brackets.removeLast(); return i + 1 }
        let textStart = b.pos + (b.isImage ? 2 : 1)
        let sameSeg = b.pos >= s
        let img = b.isImage
        let nextIsParen = i + 1 < e && w[i + 1] == 40

        // footnote reference [^id]
        if !img && sameSeg && !nextIsParen && i - textStart > 1 && w[textStart] == 94 {
            var ok = true
            var k = textStart + 1
            while k < i { if isSpaceOrTab(w[k]) || w[k] == 91 { ok = false; break }; k += 1 }
            if ok {
                let fv = MDStyle.footnote.rawValue
                paintSpan(b.pos, textStart + 1, fv | MDStyle.marker.rawValue)
                paintSpan(textStart + 1, i, fv)
                paintSpan(i, i + 1, fv | MDStyle.marker.rawValue)
                removeDelims(from: b.delimMark)
                brackets.removeLast()
                return i + 1
            }
        }

        let tv: UInt32 = img ? MDStyle.image.rawValue : MDStyle.linkText.rawValue
        let dv: UInt32 = img ? (MDStyle.image.rawValue | MDStyle.linkDestination.rawValue) : MDStyle.linkDestination.rawValue
        let mk = MDStyle.marker.rawValue

        // inline link / image: ](dest "title")
        if nextIsParen, let t = parseLinkTail(i + 1, e) {
            processEmphasis(from: b.delimMark)
            removeDelims(from: b.delimMark)
            paintSpan(b.pos, textStart, tv | mk)
            paintSpan(textStart, i, tv)
            paintSpan(i, i + 1, tv | mk)
            paintSpan(i + 1, i + 2, dv | mk)
            paintSpan(t.destStart, t.destEnd, dv)
            if t.titleStart >= 0 { paintSpan(t.titleStart, t.titleEnd, dv) }
            paintSpan(t.close, t.close + 1, dv | mk)
            finishLink(img)
            return t.close + 1
        }

        // reference link [text][ref] / [text][]
        if i + 1 < e && w[i + 1] == 91 && sameSeg {
            let prevIsWord = b.pos > s && isAlnum(w[b.pos - 1])
            var j = i + 2
            var nonWS = false
            while j < e && j - i < 1000 && w[j] != 93 && w[j] != 91 {
                if !isSpaceOrTab(w[j]) { nonWS = true }
                if w[j] == 92 { j += 1 }
                j += 1
            }
            if !prevIsWord && j < e && w[j] == 93 && (nonWS || (j == i + 2 && i > textStart)) {
                processEmphasis(from: b.delimMark)
                removeDelims(from: b.delimMark)
                let lv = MDStyle.referenceLabel.rawValue | (img ? MDStyle.image.rawValue : 0)
                paintSpan(b.pos, textStart, tv | mk)
                paintSpan(textStart, i, tv)
                paintSpan(i, i + 1, tv | mk)
                paintSpan(i + 1, i + 2, lv | mk)
                paintSpan(i + 2, j, lv)
                paintSpan(j, j + 1, lv | mk)
                finishLink(img)
                return j + 1
            }
        }

        brackets.removeLast()
        return i + 1
    }

    @inline(__always) func finishLink(_ isImage: Bool) {
        brackets.removeLast()
        if !isImage {
            var k = 0
            while k < brackets.count { if !brackets[k].isImage { brackets[k].active = false }; k += 1 }
        }
    }

    struct LinkTail { var destStart: Int; var destEnd: Int; var titleStart: Int; var titleEnd: Int; var close: Int }

    /// Parse "(dest "title")" starting at the '(' at p0, within one segment.
    func parseLinkTail(_ p0: Int, _ e: Int) -> LinkTail? {
        let w = self.w
        let limit = min(e, p0 + 1024)
        var j = p0 + 1
        while j < limit && isSpaceOrTab(w[j]) { j += 1 }
        let ds = j
        var de = j
        if j < limit && w[j] == 60 {
            j += 1
            while j < limit && w[j] != 62 && w[j] != 60 { if w[j] == 92 { j += 1 }; j += 1 }
            guard j < limit, w[j] == 62 else { return nil }
            j += 1
            de = j
        } else {
            var depth = 0
            while j < limit {
                let c = w[j]
                if isSpaceOrTab(c) || c < 32 { break }
                if c == 92 && j + 1 < limit && isASCIIPunct(w[j + 1]) { j += 2; continue }
                if c == 40 { depth += 1 }
                else if c == 41 { if depth == 0 { break }; depth -= 1 }
                j += 1
            }
            if depth != 0 { return nil }
            de = j
        }
        var k = j
        while k < limit && isSpaceOrTab(w[k]) { k += 1 }
        var ts = -1, te = -1
        if k < limit && w[k] != 41 {
            guard k > j else { return nil }
            let open = w[k]
            let close: UInt16 = open == 34 ? 34 : (open == 39 ? 39 : (open == 40 ? 41 : 0))
            guard close != 0 else { return nil }
            var t = k + 1
            while t < limit && w[t] != close { if w[t] == 92 { t += 1 }; t += 1 }
            guard t < limit else { return nil }
            ts = k; te = t + 1
            k = t + 1
            while k < limit && isSpaceOrTab(w[k]) { k += 1 }
        }
        guard k < limit, w[k] == 41 else { return nil }
        return LinkTail(destStart: ds, destEnd: de, titleStart: ts, titleEnd: te, close: k)
    }
}
