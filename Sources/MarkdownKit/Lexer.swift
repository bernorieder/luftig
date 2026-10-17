import Foundation

/// The lexing engine. One instance is owned by a `MarkdownStyler`. Not thread safe.
///
/// A *session* lexes a contiguous range of lines starting at a known block state. Text is pulled into a UTF-16
/// window (`w`), styles are painted into a parallel UInt32 buffer (`sty`, one entry per code unit, OR-combined),
/// and runs are extracted from `sty` at the end of the session (or whenever the window slides forward).
final class Lexer {
    let tables = CharTables.shared

    // MARK: Text + window
    var text: NSString = ""
    var textLen = 0
    var w: UnsafeMutablePointer<UInt16>
    var sty: UnsafeMutablePointer<UInt32>
    var wCap: Int
    var wLen = 0
    var wStart = 0
    var chunkSize = 32768
    static let baseCap = 1 << 15

    // MARK: Block state
    var st = BlockState()
    var emit = true

    // MARK: Pending paragraph
    struct PendLine { var cs: Int; var ce: Int; var eol: Int; var base: UInt32 }
    var pend: [PendLine] = []
    var pendUnits = 0
    var maxPendLines = 256
    var maxPendUnits = 65536      // paragraphs larger than this are not inline-lexed (degrade to plain)

    // MARK: Pending blank lines after indented code
    /// Blank lines that follow an indented code line. They are painted as ordinary blank lines when they are seen and
    /// re-painted as code if the next non-blank line is another code line of the same block (CommonMark: blank lines
    /// between the lines of an indented code block belong to it, trailing ones do not). Non-empty only while
    /// `st.leaf == Leaf.indentedCode`; like a pending paragraph it suppresses checkpoints, convergence and window slides.
    struct PendBlank { var s: Int; var e: Int }
    var pendBlanks: [PendBlank] = []
    var pendBlankStartAbs = 0

    // MARK: Output
    var out: [MDRun] = []
    var trimTarget = 0
    var trimStart = 0

    // MARK: Checkpoint recording / re-convergence
    var recordCPs = false
    /// Master checkpoint list (sorted by offset). Read-only during a session; the tail starting at `oldIdx`
    /// is compared (with offsets shifted by `oldShift`) against freshly computed states for re-convergence.
    var cps: [Checkpoint] = []
    var newCps: [Checkpoint] = []
    var oldIdx = 0
    var oldShift = 0
    var lastRecorded = -1
    var unitsSinceCP = 0
    var strideUnits = 2048
    var convergeFrom = 0
    var converged = false
    var stopAbs = Int.max
    var curLineAbs = 0
    var pendStartAbs = 0                // absolute start of the first line of the pending paragraph
    var stBefore = BlockState()         // block state before the line being processed
    var stopHere = false                // set by weakPoint(): end the session before the current line
    var stopPos = 0

    // MARK: Inline scratch
    var segS: UnsafeMutablePointer<Int>
    var segE: UnsafeMutablePointer<Int>
    var segX: UnsafeMutablePointer<Int>      // end including the line break (painting extent)
    var segCap = 64
    var segN = 0
    var uniCache: [UInt8] = []               // BMP scalar -> flanking class, filled on demand (0xFF: not yet known)
    var delims: [Delim] = []
    var brackets: [Bracket] = []
    var openersBottom = [Int](repeating: -1, count: 18)
    var failedMask: UInt64 = 0
    var dHead = -1
    var dTail = -1

    var frontMatterWindow = 16384
    /// Absolute offset just after the closing line of the front matter found while lexing with checkpoints
    /// (-1: none / unknown). Edits at or after it cannot change whether line 0 is a front matter opener.
    var fmEnd = -1
    var slideMin = 131072               // slide the text window forward once this far in ...
    var slideLow = 16384                // ... and fewer than this many units remain loaded
    var chunkOverride = 0               // test hook: force a small window chunk size
    var poison = false                  // test hook: fill the unloaded part of the window with junk

    init() {
        wCap = Lexer.baseCap
        w = .allocate(capacity: wCap + 8)
        sty = .allocate(capacity: wCap + 8)
        sty.initialize(repeating: 0, count: wCap + 8)
        segS = .allocate(capacity: segCap)
        segE = .allocate(capacity: segCap)
        segX = .allocate(capacity: segCap)
        pend.reserveCapacity(257)
        delims.reserveCapacity(64)
        brackets.reserveCapacity(32)
    }

    deinit {
        w.deallocate(); sty.deallocate(); segS.deallocate(); segE.deallocate(); segX.deallocate()
    }

    // MARK: - Window management

    func ensureCap(_ c: Int) {
        guard c > wCap else { return }
        let newCap = max(c, wCap * 2)
        let nw = UnsafeMutablePointer<UInt16>.allocate(capacity: newCap + 8)
        nw.update(from: w, count: wLen)
        let ns = UnsafeMutablePointer<UInt32>.allocate(capacity: newCap + 8)
        ns.update(from: sty, count: wLen)
        (ns + wLen).initialize(repeating: 0, count: newCap + 8 - wLen)
        w.deallocate(); sty.deallocate()
        w = nw; sty = ns; wCap = newCap
    }

    /// Release oversized buffers after a big session.
    func trimBuffers() {
        if wCap > (1 << 21) {
            w.deallocate(); sty.deallocate()
            wCap = Lexer.baseCap
            w = .allocate(capacity: wCap + 8)
            sty = .allocate(capacity: wCap + 8)
            sty.initialize(repeating: 0, count: wCap + 8)
        }
        if segCap > 4096 {
            segS.deallocate(); segE.deallocate(); segX.deallocate()
            segCap = 64
            segS = .allocate(capacity: segCap); segE = .allocate(capacity: segCap); segX = .allocate(capacity: segCap)
        }
    }

    func loadMore(_ want: Int) {
        let at = wStart + wLen
        let n = min(textLen - at, max(want, chunkSize))
        if n <= 0 { return }
        ensureCap(wLen + n)
        text.getCharacters(w + wLen, range: NSRange(location: at, length: n))
        wLen += n
        if poison { poisonTail() }
    }

    func poisonTail() {
        let k = min(wCap + 8 - wLen, 96)
        if k > 0 { (w + wLen).update(repeating: 0x60, count: k) }       // backticks: maximally confusing
    }

    func startWindow(at abs: Int, minUnits: Int) {
        wStart = abs
        wLen = 0
        loadMore(minUnits)
    }

    @inline(__always) var atEOF: Bool { wStart + wLen >= textLen }

    /// Index of the first '\n' or '\r' at or after `start`, extending the window as needed; `wLen` if none (EOF).
    func findBreak(_ start: Int) -> Int {
        var i = start
        while true {
            let end = wLen
            let raw = UnsafeRawPointer(w)
            while i + 4 <= end {
                let v = raw.loadUnaligned(fromByteOffset: i &* 2, as: UInt64.self)
                let a = v ^ 0x000A_000A_000A_000A
                let b = v ^ 0x000D_000D_000D_000D
                let ha = (a &- 0x0001_0001_0001_0001) & ~a & 0x8000_8000_8000_8000
                let hb = (b &- 0x0001_0001_0001_0001) & ~b & 0x8000_8000_8000_8000
                let h = ha | hb
                if h != 0 { return i &+ (h.trailingZeroBitCount >> 4) }
                i &+= 4
            }
            while i < end {
                let c = w[i]
                if c == 10 || c == 13 { return i }
                i &+= 1
            }
            if atEOF { return end }
            loadMore(wLen)
        }
    }

    /// End of line content `le` and start of next line `eol` for the line starting at `pos`.
    @inline(__always) func lineBounds(_ pos: Int) -> (le: Int, eol: Int) {
        let le = findBreak(pos)
        if le >= wLen { return (le, le) }
        if w[le] == 10 { return (le, le + 1) }
        // '\r'
        if le + 1 >= wLen && !atEOF { loadMore(16) }
        if le + 1 < wLen && w[le + 1] == 10 { return (le, le + 2) }
        return (le, le + 1)
    }

    // MARK: - Painting + extraction

    @inline(__always) func paint(_ a: Int, _ b: Int, _ v: UInt32) {
        if !emit || v == 0 || a >= b { return }
        var i = a
        while i < b { sty[i] |= v; i &+= 1 }
    }

    @inline(__always) func appendRun(_ s: Int, _ e: Int, _ v: UInt32) {
        let n = out.count
        if n > 0 {
            let last = out[n - 1]
            if last.style.rawValue == v && last.range.location + last.range.length == s {
                out[n - 1].range.length += e - s
                return
            }
        }
        out.append(MDRun(s, e, MDStyle(rawValue: v)))
    }

    /// Convert painted styles in window [0, upTo) into runs (clipped at the trim start), then clear them.
    func extractRuns(upTo: Int) {
        guard emit else { return }
        let clip = (trimTarget >= wStart + upTo) ? (wStart + upTo) : trimStart
        var i = max(0, clip - wStart)
        let s = sty
        while i < upTo {
            let v = s[i]
            var j = i &+ 1
            while j < upTo && s[j] == v { j &+= 1 }
            appendRun(wStart + i, wStart + j, v)
            i = j
        }
        sty.update(repeating: 0, count: upTo)
    }

    // MARK: - Weak checkpoints

    /// Called when line `ls` (window-relative, ending at `eol`) starts a paragraph and nothing is pending.
    /// Records a checkpoint / detects re-convergence / ends the session, exactly like the loop-top logic does
    /// for line starts that follow a finished block.
    func weakPoint(ls: Int, eol: Int) {
        guard recordCPs else { return }
        let x = wStart + ls
        while oldIdx < cps.count && cps[oldIdx].offset + oldShift < x { oldIdx += 1 }
        var hasOld = false
        if oldIdx < cps.count && cps[oldIdx].offset + oldShift == x {
            hasOld = true
            if x > 0 && x >= convergeFrom && cps[oldIdx].state == stBefore {
                // Reached as a paragraph start that closed the previous paragraph: the retained checkpoint is
                // only valid for edits after this line (offsets in the master list are still pre-edit).
                cps[oldIdx].validAfter = wStart + eol - oldShift
                converged = true; stopHere = true; stopPos = ls
                return
            }
        }
        if x > lastRecorded && (hasOld || unitsSinceCP >= strideUnits || x >= stopAbs) {
            newCps.append(Checkpoint(offset: x, state: stBefore, validAfter: wStart + eol))
            lastRecorded = x
            unitsSinceCP = 0
        }
        if x >= stopAbs { stopHere = true; stopPos = ls }
    }

    // MARK: - Session loop

    /// Prepare a session that starts at checkpoint `cp` (window starts there). `cps`/`oldIdx` handling is the
    /// caller's job (default: no old tail to compare against).
    func begin(from cp: Checkpoint, emit: Bool, record: Bool, chunk: Int) {
        self.emit = emit
        recordCPs = record
        st = cp.state
        chunkSize = chunkOverride > 0 ? chunkOverride : chunk
        startWindow(at: cp.offset, minUnits: chunkSize)
        out = []
        trimTarget = cp.offset
        trimStart = cp.offset
        newCps.removeAll(keepingCapacity: true)
        oldIdx = cps.count
        oldShift = 0
        lastRecorded = cp.offset
        unitsSinceCP = 0
        convergeFrom = 0
        converged = false
    }

    /// Lex whole lines from window position 0 until a line start (with no pending paragraph) at or after
    /// absolute offset `stopAbs`, or EOF, or (when re-converging) a line start whose state equals the old one.
    /// Returns the absolute offset where lexing stopped. `st` must hold the state at the window start.
    func run(stopAbs stop: Int) -> Int {
        var pos = 0
        pend.removeAll(keepingCapacity: true)
        pendUnits = 0
        pendBlanks.removeAll(keepingCapacity: true)
        converged = false
        stopHere = false
        stopAbs = stop
        while true {
            let x = wStart + pos
            if x >= textLen && !pend.isEmpty {
                flushPara(level: 0)
                st.inPara = false
            }
            if x >= textLen && !pendBlanks.isEmpty { pendBlanks.removeAll(keepingCapacity: true) }
            // Paragraph cap: end an over-long paragraph here so that a checkpoint can be taken. The state keeps
            // `inPara`, so the next line still counts as paragraph continuation.
            if !pend.isEmpty && (pend.count >= maxPendLines || pendUnits >= maxPendUnits) { flushPara(level: 0) }
            if pend.isEmpty && pendBlanks.isEmpty {
                if recordCPs {
                    while oldIdx < cps.count && cps[oldIdx].offset + oldShift < x { oldIdx += 1 }
                    var hasOld = false
                    if oldIdx < cps.count && cps[oldIdx].offset + oldShift == x {
                        hasOld = true
                        if x > 0 && x >= convergeFrom && cps[oldIdx].state == st {      // x == 0 is position-dependent (front matter)
                            // Reached at a line start with nothing pending: an ordinary (strong) checkpoint.
                            cps[oldIdx].validAfter = cps[oldIdx].offset
                            converged = true
                            extractRuns(upTo: pos)
                            return x
                        }
                    }
                    if x > lastRecorded && (hasOld || unitsSinceCP >= strideUnits || x >= stopAbs || x >= textLen) {
                        newCps.append(Checkpoint(offset: x, state: st))
                        lastRecorded = x
                        unitsSinceCP = 0
                    }
                }
                if x >= textLen || x >= stopAbs {
                    extractRuns(upTo: pos)
                    return x
                }
                // slide the window forward if we are running low (only between blocks)
                if pos >= slideMin && wLen - pos < slideLow && !atEOF {
                    extractRuns(upTo: pos)
                    (w).update(from: w + pos, count: wLen - pos)
                    wLen -= pos
                    wStart += pos
                    pos = 0
                    if poison { poisonTail() }
                    loadMore(0)
                }
            }
            let ls = pos
            curLineAbs = wStart + ls
            if curLineAbs <= trimTarget {
                trimStart = !pend.isEmpty ? min(curLineAbs, pendStartAbs) : (!pendBlanks.isEmpty ? min(curLineAbs, pendBlankStartAbs) : curLineAbs)
            }
            let (le, eol) = lineBounds(ls)
            stBefore = st
            processLine(ls: ls, le: le, eol: eol)
            if stopHere {
                // A paragraph-start checkpoint decided to end the session before this line: undo its painting.
                stopHere = false
                var i = ls
                while i < eol { sty[i] = 0; i += 1 }
                extractRuns(upTo: ls)
                return wStart + ls
            }
            unitsSinceCP += eol - ls
            pos = eol
        }
    }
}
