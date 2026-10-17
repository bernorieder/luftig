import AppKit

/// Holds the UTF-16 copy of a document + fence index (what MarkdownKit would own) and the mini lexer.
final class Doc {
    let text: String
    let u16: [UInt16]
    let fences: FenceIndex
    let lexer = MiniLexer()
    var buildU16Ms = 0.0
    var buildFenceMs = 0.0

    init(_ text: String) {
        self.text = text
        var t = nowMs()
        let a = Array(text.utf16)
        buildU16Ms = nowMs() - t
        u16 = a
        t = nowMs()
        fences = a.withUnsafeBufferPointer { FenceIndex.build($0) }
        buildFenceMs = nowMs() - t
    }

    var length: Int { u16.count }

    /// Start of the line containing `i`.
    func lineStart(_ i: Int) -> Int {
        var j = min(i, u16.count)
        while j > 0 && u16[j - 1] != 10 { j -= 1 }
        return j
    }

    /// End of the line (exclusive, after the "\n") containing `i`.
    func lineEnd(_ i: Int) -> Int {
        var j = i
        let n = u16.count
        while j < n && u16[j] != 10 { j += 1 }
        return min(j + 1, n)
    }

    /// Line-aligned range starting at the line containing `loc`, covering `lines` lines.
    func range(fromLineAt loc: Int, lines: Int) -> NSRange {
        let s = lineStart(loc)
        var e = s
        for _ in 0..<lines {
            if e >= u16.count { break }
            e = lineEnd(e)
        }
        return NSRange(location: s, length: e - s)
    }

    /// Line-aligned range centred around `loc`: `before` lines above, `after` lines below.
    func range(around loc: Int, before: Int, after: Int) -> NSRange {
        var s = lineStart(loc)
        for _ in 0..<before { if s > 0 { s = lineStart(s - 1) } }
        var e = lineEnd(loc)
        for _ in 0..<after { if e < u16.count { e = lineEnd(e) } }
        return NSRange(location: s, length: e - s)
    }

    func lex(_ r: NSRange, coalesce: Bool = true) -> [Run] {
        lexer.coalesce = coalesce
        let fence = fences.inFence(atLineStart: r.location)
        return u16.withUnsafeBufferPointer { buf in
            lexer.lex(UnsafeBufferPointer(rebasing: buf[r.location..<(r.location + r.length)]), offset: r.location, inFence: fence)
        }
    }
}

enum Styler {
    enum Mode { case setAttributes, addAttributes }

    /// Apply runs to a storage. `batch` wraps in beginEditing/endEditing.
    @discardableResult
    static func apply(_ runs: [Run], to storage: NSTextStorage, theme: Theme, batch: Bool = true, mode: Mode = .setAttributes) -> Double {
        let t0 = nowMs()
        if batch { storage.beginEditing() }
        switch mode {
        case .setAttributes:
            for r in runs { storage.setAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
        case .addAttributes:
            for r in runs { storage.addAttributes(theme.attrs(r.style), range: NSRange(location: r.loc, length: r.len)) }
        }
        if batch { storage.endEditing() }
        return nowMs() - t0
    }

    /// Style a line-aligned range of the (unedited) document: lex + apply. Returns (lexMs, applyMs, runCount).
    @discardableResult
    static func style(doc: Doc, range: NSRange, storage: NSTextStorage, theme: Theme, batch: Bool = true, coalesce: Bool = true) -> (Double, Double, Int) {
        let t0 = nowMs()
        let runs = doc.lex(range, coalesce: coalesce)
        let t1 = nowMs()
        apply(runs, to: storage, theme: theme, batch: batch)
        let t2 = nowMs()
        return (t1 - t0, t2 - t1, runs.count)
    }
}
