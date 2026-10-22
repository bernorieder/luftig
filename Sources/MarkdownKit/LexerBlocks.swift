import Foundation

/// Block-level line processing.
extension Lexer {

    @inline(__always) func skipWS(_ p: inout Int, _ c: inout Int, _ le: Int) {
        let w = self.w
        while p < le {
            let ch = w[p]
            if ch == 32 { c &+= 1 } else if ch == 9 { c &+= 4 - (c & 3) } else { return }
            p &+= 1
        }
    }

    /// Close unmatched containers (keep the first `m`), end any paragraph / leaf block.
    @inline(__always) func closeBlocks(_ m: Int) {
        st.truncate(to: m)
        if !pend.isEmpty { flushPara(level: 0) }
        st.inPara = false
        if st.leaf != Leaf.none { st.clearLeaf() }
    }

    func addSeg(_ s: Int, _ e: Int, _ x: Int) {
        if segN == segCap {
            let nc = segCap * 2
            let ns = UnsafeMutablePointer<Int>.allocate(capacity: nc)
            let ne = UnsafeMutablePointer<Int>.allocate(capacity: nc)
            let nx = UnsafeMutablePointer<Int>.allocate(capacity: nc)
            ns.update(from: segS, count: segN); ne.update(from: segE, count: segN); nx.update(from: segX, count: segN)
            segS.deallocate(); segE.deallocate(); segX.deallocate()
            segS = ns; segE = ne; segX = nx; segCap = nc
        }
        segS[segN] = s; segE[segN] = e; segX[segN] = x; segN += 1
    }

    /// Append a paragraph text line (content [cs, ce), line ends at eol). Prefix painting is the caller's job.
    func addPara(cs: Int, ce: Int, eol: Int, base: UInt32) {
        if pend.isEmpty { pendStartAbs = curLineAbs }
        pend.append(PendLine(cs: cs, ce: ce, eol: eol, base: base))
        pendUnits += ce - cs
    }

    /// End the pending paragraph: paint base style (+ heading level) and run the inline lexer over it.
    func flushPara(level: Int) {
        if pend.isEmpty { return }
        if emit {
            let hb = MDStyle.headingBits(level)
            for pl in pend { paint(pl.cs, pl.eol, pl.base | hb) }
            if pendUnits <= maxPendUnits {
                segN = 0
                for pl in pend where pl.ce > pl.cs { addSeg(pl.cs, pl.ce, pl.eol) }
                if segN > 0 { lexInline() }
            }
        }
        pend.removeAll(keepingCapacity: true)
        pendUnits = 0
    }

    // MARK: - The line

    func processLine(ls: Int, le: Int, eol: Int) {
        let w = self.w
        let absLS = wStart + ls
        // The previous line opened an empty list item (nothing after its marker) and nothing has followed yet: a blank line now
        // ends that item (CommonMark 5.2: a list item can begin with at most one blank line).
        let afterEmptyItem = st.emptyItem
        st.emptyItem = false

        // Front matter: only at the very start of the document, closed within the window, and YAML-like (the first line with content is `key:` or a
        // `#` comment): a document that opens with a thematic break and prose (`---`, a paragraph, `---`) gets two rules, as CommonMark reads it.
        if absLS == 0 && recordCPs { fmEnd = -1 }
        if absLS == 0 && st.ccount == 0 && st.leaf == Leaf.none && le - ls >= 3 && w[ls] == 45 && w[ls + 1] == 45 && w[ls + 2] == 45 {
            var q = ls + 3
            while q < le && isSpaceOrTab(w[q]) { q += 1 }
            if q == le, let close = frontMatterClose(after: eol), frontMatterLooksLikeYAML(after: eol, closeEnd: close.end) {
                // A closing line without a line break (end of file) can still grow: never skip the restart then.
                if recordCPs { fmEnd = close.hasEOL ? wStart + close.end : Int.max }
                st.leaf = Leaf.frontMatter
                st.inPara = false
                paint(ls, eol, MDStyle.frontMatter.rawValue | MDStyle.marker.rawValue)
                return
            }
        }

        let cc = Int(st.ccount)
        var pos = ls, col = 0, base = 0
        var m = 0, qd = 0
        var pp = ls                 // prefix painted up to here

        // 1. Match open containers.
        while m < cc {
            let c = st.container(m)
            var p = pos, cl = col
            while p < le {
                let ch = w[p]
                if ch == 32 { cl &+= 1 } else if ch == 9 { cl &+= 4 - (cl & 3) } else { break }
                p &+= 1
            }
            if c & 0x80 != 0 {
                if p < le && w[p] == 62 && cl - base <= 3 {
                    let mp = p
                    p += 1; cl += 1
                    if p < le {
                        if w[p] == 32 { p += 1; cl += 1 } else if w[p] == 9 { cl += 4 - (cl & 3); p += 1 }
                    }
                    paint(pp, mp, MDStyle.quoteBits(qd))
                    paint(mp, p, MDStyle.marker.rawValue | MDStyle.quoteBits(qd + 1))
                    pp = p
                    pos = p; col = cl; base = cl
                    m += 1; qd += 1
                } else { break }
            } else {
                let ind = Int(c)
                if p >= le {
                    if afterEmptyItem && m == cc - 1 { break }      // blank line directly after an empty list item: it ends there
                    m += 1                      // other blank lines keep list items open
                } else if cl >= ind {
                    var q = pos, qc = col
                    while qc < ind && q < le {
                        if w[q] == 9 { qc += 4 - (qc & 3) } else { qc += 1 }
                        q += 1
                    }
                    pos = q; col = qc; base = ind
                    m += 1
                } else { break }
            }
        }
        let allMatched = (m == cc)

        var fp = pos, fcol = col
        skipWS(&fp, &fcol, le)

        // 2. Continue a multi-line leaf block.
        if st.leaf != Leaf.none && st.leaf != Leaf.table {
            if allMatched {
                if continueLeaf(ls: pp, pos: pos, fp: fp, fcol: fcol, base: base, le: le, eol: eol, qd: qd) { return }
            } else {
                st.clearLeaf()
                pendBlanks.removeAll(keepingCapacity: true)
            }
        }

        // 3. Open new containers (quotes, list items, footnote definitions).
        var blank = fp >= le
        var opened = false
        var emptyItemOpened = false         // the innermost container opened on this line is a list item with nothing after its marker
        while !blank {
            let ind = fcol - base
            if ind >= 4 { break }
            let ch = w[fp]
            let curCC = Int(st.ccount)
            if ch == 62 {                                           // '>'
                if m >= BlockState.maxContainers { break }
                if !opened { closeBlocks(m); opened = true }
                emptyItemOpened = false
                st.push(0x80)
                var p = fp + 1, cl = fcol + 1
                if p < le {
                    if w[p] == 32 { p += 1; cl += 1 } else if w[p] == 9 { cl += 4 - (cl & 3); p += 1 }
                }
                paint(pp, fp, MDStyle.quoteBits(qd))
                paint(fp, p, MDStyle.marker.rawValue | MDStyle.quoteBits(qd + 1))
                pp = p
                pos = p; col = cl; base = cl
                m += 1; qd += 1
                fp = pos; fcol = col
                skipWS(&fp, &fcol, le)
                blank = fp >= le
                continue
            }
            // A paragraph restricts what may interrupt it (empty / non-1 list items, ...). A table does not: in GFM it is not a
            // paragraph, so any block start - also indented code, type 7 HTML, `2.` or an empty `-` - ends it.
            let restrict = (curCC == m) && st.inPara && !opened
            if ch == 91 && fp + 1 < le && w[fp + 1] == 94 {         // "[^": footnote definition
                if restrict || m >= BlockState.maxContainers || fcol + 4 > 127 { break }
                if let labelEnd = footnoteDefEnd(fp, le) {
                    closeBlocks(m); opened = true
                    emptyItemOpened = false
                    st.push(UInt8(fcol + 4))
                    let qv = MDStyle.quoteBits(qd)
                    let mk = MDStyle.marker.rawValue | MDStyle.footnote.rawValue | qv
                    paint(pp, fp, qv)
                    paint(fp, fp + 2, mk)
                    paint(fp + 2, labelEnd, MDStyle.footnote.rawValue | qv)
                    paint(labelEnd, labelEnd + 2, mk)
                    pp = labelEnd + 2
                    var p = labelEnd + 2, cl = fcol + (labelEnd + 2 - fp)
                    while p < le && isSpaceOrTab(w[p]) { cl += (w[p] == 9) ? 4 - (cl & 3) : 1; p += 1 }
                    pos = p; col = cl
                    base = col                  // the label's text is an ordinary paragraph line (continuation lines use column fcol + 4)
                    m += 1
                    fp = pos; fcol = col
                    blank = fp >= le
                    continue
                }
                break
            }
            if ch == 45 || ch == 43 || ch == 42 || isDigit(ch) {
                if (ch == 45 || ch == 42) && isThematicBreak(fp, le) { break }
                if m >= BlockState.maxContainers { break }
                guard let lm = parseListMarker(fp, fcol, le) else { break }
                if lm.contentCol > 127 { break }
                if restrict && (lm.empty || (lm.ordered && lm.number != 1)) { break }
                if !opened { closeBlocks(m) }
                opened = true
                emptyItemOpened = lm.empty
                st.push(UInt8(lm.contentCol))
                let lmEnd = lm.empty ? fp + lm.width : lm.contentPos
                paint(pp, fp, MDStyle.quoteBits(qd))
                paint(fp, lmEnd, MDStyle.listMarker.rawValue | MDStyle.quoteBits(qd))
                pp = lmEnd
                pos = lm.contentPos; col = lm.contentCol; base = lm.contentCol
                m += 1
                // task list marker
                if !lm.empty && lm.contentPos + 2 < le && w[lm.contentPos] == 91 && w[lm.contentPos + 2] == 93 {
                    let x = w[lm.contentPos + 1]
                    let after = lm.contentPos + 3
                    if (x == 32 || x == 120 || x == 88) && (after >= le || isSpaceOrTab(w[after])) {
                        var tv = MDStyle.taskMarker.rawValue
                        if x != 32 { tv |= MDStyle.taskChecked.rawValue }
                        paint(lm.contentPos, after, tv | MDStyle.quoteBits(qd))
                        pp = after
                        var p = after, cl = col + 3
                        while p < le && isSpaceOrTab(w[p]) { cl += (w[p] == 9) ? 4 - (cl & 3) : 1; p += 1 }
                        pos = p; col = cl
                        base = col                  // the text after the checkbox is an ordinary paragraph line, never indented code
                    }
                }
                fp = pos; fcol = col
                skipWS(&fp, &fcol, le)
                blank = fp >= le
                continue
            }
            break
        }

        // 4. Leaf level.
        let hasUnmatched = Int(st.ccount) > m
        if blank {
            closeBlocks(m)
            paint(pp, eol, MDStyle.quoteBits(qd))
            st.emptyItem = emptyItemOpened
            return
        }
        let qb = MDStyle.quoteBits(qd)
        let ind = fcol - base
        let paraLike = st.inPara
        let ch = w[fp]

        if ind >= 4 {
            if paraLike { textLine(ls: pp, lineStart: ls, fp: fp, le: le, eol: eol, m: m, qd: qd, hasUnmatched: hasUnmatched); return }
            // Indented code (also inside list items and quotes: `ind` is relative to the innermost container's content column).
            closeBlocks(m)
            paint(pp, pos, qb)
            paint(pos, eol, qb | MDStyle.codeBlock.rawValue)
            st.leaf = Leaf.indentedCode
            return
        }

        // Quick reject: most lines start with a letter.
        let maybeBlock = ch == 35 || ch == 96 || ch == 126 || ch == 60 || ch == 61 || ch == 45 || ch == 124 || ch == 58 || ch == 91 || ch == 95 || ch == 42
        if !maybeBlock {
            textLine(ls: pp, lineStart: ls, fp: fp, le: le, eol: eol, m: m, qd: qd, hasUnmatched: hasUnmatched)
            return
        }

        switch ch {
        case 35:                                                     // '#'
            let lvl = atxLevel(fp, le)
            if lvl > 0 {
                closeBlocks(m)
                atxHeading(level: lvl, ls: pp, pos: pos, fp: fp, le: le, eol: eol, qb: qb)
                return
            }
        case 96, 126:                                                // '`' '~'
            if let n = fenceLength(fp, le) {
                closeBlocks(m)
                st.leaf = Leaf.fenced
                st.leafKind = UInt8(ch)
                st.fenceLen = UInt16(min(n, 65535))
                paint(pp, pos, qb)
                paint(pos, eol, qb | MDStyle.codeFence.rawValue)
                var a = fp + n
                while a < le && isSpaceOrTab(w[a]) { a += 1 }
                var b = a
                while b < le && !isSpaceOrTab(w[b]) { b += 1 }
                paint(a, b, MDStyle.codeLanguage.rawValue)
                return
            }
        case 60:                                                     // '<'
            // Type 7 cannot interrupt a paragraph - and a lazy continuation line (unmatched containers, paragraph open) is paragraph
            // continuation text. (cmark lets it start a block there, commonmark.js / markdown-it do not; the spec text means the latter.)
            let canInterrupt = !paraLike
            let t = htmlBlockStart(fp, le, allowType7: canInterrupt)
            if t != 0 {
                closeBlocks(m)
                paint(pp, pos, qb)
                paint(pos, eol, qb | MDStyle.html.rawValue)
                let from = (t == 2 || t == 3 || t == 4) ? fp + 2 : (t == 5 ? fp + 9 : fp)
                if t <= 5 && !htmlEnds(t, from, le) {
                    st.leaf = Leaf.html
                    st.leafKind = t
                } else if t >= 6 {
                    st.leaf = Leaf.html
                    st.leafKind = t
                }
                return
            }
        default:
            break
        }

        if !hasUnmatched && !pend.isEmpty {
            // setext underline
            if ch == 61 || ch == 45 {
                if let n = underlineLength(fp, le, ch), n >= 2 {
                    let lvl = ch == 61 ? 1 : 2
                    paint(pp, pos, qb)
                    paint(pos, eol, qb | MDStyle.headingBits(lvl))
                    paint(fp, fp + n, MDStyle.marker.rawValue)
                    flushPara(level: lvl)
                    st.inPara = false
                    return
                }
            }
            // table delimiter row
            if (ch == 124 || ch == 45 || ch == 58), let n = tableDelimiterCells(fp, le), n == tableCellCount(pend[pend.count - 1].cs, pend[pend.count - 1].ce) {
                startTable(ls: pp, pos: pos, le: le, eol: eol, qb: qb)
                return
            }
        }

        if (ch == 45 || ch == 42 || ch == 95) && isThematicBreak(fp, le) {
            closeBlocks(m)
            paint(pp, pos, qb)
            paint(pos, eol, qb | MDStyle.horizontalRule.rawValue)
            return
        }

        // (a definition is resolved from paragraph text, so unlike the block starts above it cannot interrupt a table row either)
        if ch == 91 && !paraLike && st.leaf != Leaf.table, let rd = parseRefDef(fp, le) {
            closeBlocks(m)
            paint(pp, pos, qb)
            paint(pos, eol, qb)
            let mk = MDStyle.marker.rawValue | MDStyle.referenceLabel.rawValue
            paint(fp, fp + 1, mk)
            paint(fp + 1, rd.labelEnd, MDStyle.referenceLabel.rawValue)
            paint(rd.labelEnd, rd.labelEnd + 2, mk)
            paint(rd.destStart, rd.destEnd, MDStyle.linkDestination.rawValue)
            if rd.titleStart >= 0 { paint(rd.titleStart, rd.titleEnd, MDStyle.linkDestination.rawValue) }
            return
        }

        textLine(ls: pp, lineStart: ls, fp: fp, le: le, eol: eol, m: m, qd: qd, hasUnmatched: hasUnmatched)
    }

    // MARK: - Leaf continuation

    /// Returns true if the line was consumed by the leaf block.
    func continueLeaf(ls: Int, pos: Int, fp: Int, fcol: Int, base: Int, le: Int, eol: Int, qd: Int) -> Bool {
        let w = self.w
        let qb = MDStyle.quoteBits(qd)
        switch st.leaf {
        case Leaf.fenced:
            var closing = false
            if fp < le && fcol - base < 4 && UInt16(st.leafKind) == w[fp] {
                var q = fp
                let fc = w[fp]
                while q < le && w[q] == fc { q += 1 }
                if q - fp >= Int(st.fenceLen) {
                    var r = q
                    while r < le && isSpaceOrTab(w[r]) { r += 1 }
                    closing = (r == le)
                }
            }
            paint(ls, pos, qb)
            if closing {
                paint(pos, eol, qb | MDStyle.codeFence.rawValue)
                st.clearLeaf()
            } else {
                paint(pos, eol, qb | MDStyle.codeBlock.rawValue)
            }
            return true
        case Leaf.html:
            let t = st.leafKind
            if t >= 6 && fp >= le { st.clearLeaf(); return false }
            paint(ls, pos, qb)
            paint(pos, eol, qb | MDStyle.html.rawValue)
            if t <= 5 && htmlEnds(t, pos, le) { st.clearLeaf() }
            return true
        case Leaf.indentedCode:
            if fp >= le {
                // A blank line: part of the block only if another code line follows (decided then).
                paint(ls, eol, qb)
                if pendBlanks.isEmpty { pendBlankStartAbs = curLineAbs }
                pendBlanks.append(PendBlank(s: ls, e: eol))
                // Work cap (the same limit as a pending paragraph): while blank lines are pending no checkpoint can be taken, so an
                // endless run of them would make every keystroke inside it re-lex the whole run and keep one entry per line. A run
                // this long ends the block; the blank lines stay plain and a later indented line starts a new block.
                if pendBlanks.count >= maxPendLines {
                    st.clearLeaf()
                    pendBlanks.removeAll(keepingCapacity: true)
                }
                return true
            }
            if fcol - base >= 4 {
                if !pendBlanks.isEmpty {
                    for b in pendBlanks { paint(b.s, b.e, qb | MDStyle.codeBlock.rawValue) }
                    pendBlanks.removeAll(keepingCapacity: true)
                }
                paint(ls, pos, qb)
                paint(pos, eol, qb | MDStyle.codeBlock.rawValue)
                return true
            }
            st.clearLeaf()
            pendBlanks.removeAll(keepingCapacity: true)
            return false
        case Leaf.frontMatter:
            var closing = false
            let n = le - ls
            if n >= 3 && n <= 6 && ls == pos {
                let c = w[ls]
                if (c == 45 || c == 46) && w[ls + 1] == c && w[ls + 2] == c {
                    var q = ls + 3
                    while q < le && isSpaceOrTab(w[q]) { q += 1 }
                    closing = (q == le)
                }
            }
            if closing {
                paint(ls, eol, MDStyle.frontMatter.rawValue | MDStyle.marker.rawValue)
                st.clearLeaf()
            } else {
                paint(ls, eol, MDStyle.frontMatter.rawValue)
            }
            return true
        default:
            return false
        }
    }

    /// End (window-relative, after its line break) of the closing front matter line if one starts within the
    /// lookahead window.
    func frontMatterClose(after eol: Int) -> (end: Int, hasEOL: Bool)? {
        var p = eol
        while wStart + p < min(textLen, frontMatterWindow) {
            let (le, e2) = lineBounds(p)
            let ww = self.w
            let n = le - p
            if n >= 3 && n <= 6 {
                let c = ww[p]
                if (c == 45 || c == 46) && ww[p + 1] == c && ww[p + 2] == c {
                    var q = p + 3
                    while q < le && isSpaceOrTab(ww[q]) { q += 1 }
                    if q == le { return (e2, e2 > le) }
                }
            }
            if e2 <= p { return nil }
            p = e2
        }
        return nil
    }

    /// Whether the lines between the opening `---` (after `eol`) and the closing line look like YAML: the first line with content (within the window) is a
    /// `key:` line (a YAML key: a letter or `_`, then letters, digits, `_`, `-`, `.`, blanks, then `:` followed by a blank or the end of the line) or a `#` comment.
    /// Empty front matter (nothing before the closing line) does not count.
    func frontMatterLooksLikeYAML(after eol: Int, closeEnd: Int) -> Bool {
        let ww = self.w
        var p = eol
        while p < closeEnd {
            let (le, e2) = lineBounds(p)
            var q = p
            while q < le && isSpaceOrTab(ww[q]) { q += 1 }
            if q < le {
                if e2 >= closeEnd { return false }                     // the closing line is the first one with content: empty front matter
                let c = ww[q]
                if c == 35 { return true }                                // #
                let isLetter = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
                if !isLetter { return false }
                var r = q + 1
                while r < le {
                    let d = ww[r]
                    if d == 58 { let after = r + 1; return after >= le || isSpaceOrTab(ww[after]) }      // :
                    let ok = (d >= 65 && d <= 90) || (d >= 97 && d <= 122) || (d >= 48 && d <= 57) || d == 95 || d == 45 || d == 46 || isSpaceOrTab(d)
                    if !ok { return false }
                    r += 1
                }
                return false
            }
            if e2 <= p { return false }
            p = e2
        }
        return false
    }

    // MARK: - Text lines, headings, tables

    func textLine(ls: Int, lineStart: Int, fp: Int, le: Int, eol: Int, m: Int, qd: Int, hasUnmatched: Bool) {
        var qdLine = qd
        if hasUnmatched {
            if st.inPara && st.leaf == Leaf.none {
                qdLine = st.quoteCount            // lazy continuation keeps its containers
            } else {
                closeBlocks(m)
            }
        }
        let qb = MDStyle.quoteBits(qdLine)
        paint(ls, fp, qb)
        if st.leaf == Leaf.table {
            paintRow(cs: fp, ce: le, eol: eol, base: qb, header: false)
            return
        }
        if pend.isEmpty { weakPoint(ls: lineStart, eol: eol) }
        addPara(cs: fp, ce: le, eol: eol, base: qb)
        st.inPara = true
    }

    func atxHeading(level: Int, ls: Int, pos: Int, fp: Int, le: Int, eol: Int, qb: UInt32) {
        let w = self.w
        paint(ls, pos, qb)
        paint(pos, eol, qb | MDStyle.headingBits(level))
        var cs = fp + level
        while cs < le && isSpaceOrTab(w[cs]) { cs += 1 }
        paint(fp, cs, MDStyle.marker.rawValue)
        var ce = le
        while ce > cs && isSpaceOrTab(w[ce - 1]) { ce -= 1 }
        var q = ce
        while q > cs && w[q - 1] == 35 { q -= 1 }
        if q < ce && (q == cs || isSpaceOrTab(w[q - 1])) {
            paint(q, ce, MDStyle.marker.rawValue)
            ce = q
            while ce > cs && isSpaceOrTab(w[ce - 1]) { ce -= 1 }
        }
        if emit && ce > cs && ce - cs <= maxPendUnits {
            segN = 0
            addSeg(cs, ce, ce)
            lexInline()
        }
        st.inPara = false
    }

    func startTable(ls: Int, pos: Int, le: Int, eol: Int, qb: UInt32) {
        let header = pend.removeLast()
        pendUnits -= header.ce - header.cs
        if !pend.isEmpty { flushPara(level: 0) }
        pend.removeAll(keepingCapacity: true)
        pendUnits = 0
        paintRow(cs: header.cs, ce: header.ce, eol: header.eol, base: header.base, header: true)
        paint(ls, pos, qb)
        paint(pos, eol, qb | MDStyle.table.rawValue | MDStyle.tableDelimiter.rawValue)
        st.inPara = false
        st.leaf = Leaf.table
    }

    /// Paint one table row: base style for [cs, eol), pipes as delimiters, cell contents inline-lexed.
    func paintRow(cs: Int, ce: Int, eol: Int, base: UInt32, header: Bool) {
        guard emit else { return }
        let w = self.w
        var rowStyle = base | MDStyle.table.rawValue
        if header { rowStyle |= MDStyle.tableHeader.rawValue }
        paint(cs, eol, rowStyle)
        if ce - cs > maxPendUnits { return }
        var cellStart = cs
        var i = cs
        while i <= ce {
            let atEnd = i == ce
            if atEnd || w[i] == 124 {
                if !atEnd { paint(i, i + 1, MDStyle.tableDelimiter.rawValue) }
                var a = cellStart, b = i
                while a < b && isSpaceOrTab(w[a]) { a += 1 }
                while b > a && isSpaceOrTab(w[b - 1]) { b -= 1 }
                if b > a {
                    segN = 0
                    addSeg(a, b, b)
                    lexInline()
                }
                cellStart = i + 1
            } else if w[i] == 92 && i + 1 < ce {
                i += 1                                   // escaped character (incl. \|)
            }
            i += 1
        }
    }
}
