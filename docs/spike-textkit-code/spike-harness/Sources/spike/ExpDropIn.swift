import AppKit

/// Provider for LazyStyler built on the spike's MiniLexer (stand-in for MarkdownKit).
final class SpikeProvider {
    let theme: Theme
    let lexer = MiniLexer()
    var buf = [UInt16]()
    weak var storage: NSTextStorage?
    var fences: FenceIndex?
    var fenceBuildMs = 0.0

    init(theme: Theme) { self.theme = theme }

    func runs(_ range: NSRange) -> [StyledRun] {
        guard let storage = storage else { return [] }
        let inFence = range.location == 0 ? false : fenceState(at: range.location)
        return lexFromStorage(storage, range: range, inFence: inFence, lexer: lexer, buf: &buf).map {
            StyledRun(range: NSRange(location: $0.loc, length: $0.len), attributes: theme.attrs($0.style))
        }
    }

    /// Block state at a line start: pre-scan for fence lines in 1 MB chunks (what MarkdownKit's checkpoints replace).
    func fenceState(at loc: Int) -> Bool {
        if fences == nil, let storage = storage {
            let t0 = nowMs()
            let ns = storage.string as NSString
            var idx = FenceIndex()
            let chunk = 1 << 20
            var chunkBuf = [UInt16](repeating: 0, count: chunk + 4)
            var pos = 0
            var atLineStart = true
            while pos < ns.length {
                let n = min(chunk, ns.length - pos)
                chunkBuf.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: pos, length: n)) }
                var i = 0
                while i < n {
                    if atLineStart, i + 2 < n || pos + i + 2 < ns.length {
                        let c0 = chunkBuf[i]
                        if c0 == 96 {
                            // look-ahead may cross the chunk end: fetch directly in that rare case
                            let c1: UInt16 = i + 1 < n ? chunkBuf[i + 1] : ns.character(at: pos + i + 1)
                            let c2: UInt16 = i + 2 < n ? chunkBuf[i + 2] : ns.character(at: pos + i + 2)
                            if c1 == 96 && c2 == 96 { idx.starts.append(Int32(pos + i)) }
                        }
                    }
                    atLineStart = chunkBuf[i] == 10
                    // skip to the end of this line quickly
                    if !atLineStart {
                        var j = i + 1
                        while j < n && chunkBuf[j] != 10 { j += 1 }
                        i = j
                        if i < n { atLineStart = true; i += 1 }
                        continue
                    }
                    i += 1
                }
                pos += n
            }
            fences = idx
            fenceBuildMs = nowMs() - t0
        }
        return fences?.inFence(atLineStart: loc) ?? false
    }

    /// Keep fence offsets aligned with edits (typing does not create fences in the spike).
    func noteEdit(location: Int, delta: Int) {
        guard delta != 0, var f = fences else { return }
        for i in 0..<f.starts.count where Int(f.starts[i]) >= location { f.starts[i] += Int32(delta) }
        fences = f
    }
}

final class DropInRig {
    let window: NSWindow
    let stack: ScribeEditorFactory.Stack
    let styler: LazyStyler
    let provider: SpikeProvider
    let theme: Theme
    let column: ReadableColumnController
    var tv: ScribeEditorTextView { stack.textView }
    var scroll: NSScrollView { stack.scrollView }
    var clip: NSClipView { scroll.contentView }

    init(theme: Theme, appearance: NSAppearance.Name? = nil, width: CGFloat = 900, height: CGFloat = 700) {
        self.theme = theme
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        stack = ScribeEditorFactory.make(frame: frame, bodyFont: theme.bodyFont, defaultParagraphStyle: theme.paragraphStyle(for: 0))
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let a = appearance { window.appearance = NSAppearance(named: a) }
        window.contentView = stack.scrollView
        window.orderBack(nil)
        provider = SpikeProvider(theme: theme)
        provider.storage = stack.storage
        column = ReadableColumnController(scrollView: stack.scrollView, textView: stack.textView, maxColumnWidth: 760, minInset: 28)
        styler = LazyStyler(textView: stack.textView)
        styler.runs = { [provider] r in provider.runs(r) }
        let provider = provider
        styler.restyleRange = { [weak self] edited, delta in
            provider.noteEdit(location: edited.location, delta: delta)
            let ns = (self?.stack.storage.string ?? "") as NSString
            guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
            let loc = min(edited.location, ns.length - 1)
            var r = ns.paragraphRange(for: NSRange(location: loc, length: min(edited.length, ns.length - loc)))
            if NSMaxRange(r) < NSMaxRange(edited) { r = NSUnionRange(r, ns.paragraphRange(for: NSRange(location: min(NSMaxRange(edited), ns.length) - 1, length: 0))) }
            return r
        }
    }

    deinit { window.contentView = nil; window.close() }

    func load(_ text: String) {
        tv.string = text                       // delegate sees a huge edit -> resets the styled set, no synchronous lexing
        // uniform base attributes in ONE run (fixed line heights everywhere before anything is styled)
        stack.storage.beginEditing()
        stack.storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: stack.storage.length))
        stack.storage.endEditing()
        styler.reset()
        provider.fences = nil
    }

    func layoutVisible() {
        let o = tv.textContainerOrigin
        _ = o
        stack.layoutManager.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
        tv.layoutSubtreeIfNeeded()
    }

    lazy var rep: NSBitmapImageRep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
    func draw() { scroll.cacheDisplay(in: scroll.bounds, to: rep) }

    func yOfChar(_ idx: Int) -> CGFloat {
        let len = max(0, min(1, stack.storage.length - idx))
        let sr = tv.firstRect(forCharacterRange: NSRange(location: idx, length: len), actualRange: nil)
        let wr = window.convertFromScreen(sr)
        return tv.convert(wr, from: nil).minY
    }
    func scrollTo(_ y: CGFloat) { clip.scroll(to: NSPoint(x: 0, y: max(0, y))); scroll.reflectScrolledClipView(clip) }
    var topFraction: Double { Double(styler.visibleCharacterRange(tv).location) / Double(max(1, stack.storage.length)) }
    var thumb: Double { scroll.verticalScroller?.doubleValue ?? -1 }
}

func runDropIn(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let corpus = arg("corpus", "20m")
    let text = Corpus.load(corpus)
    let theme = Theme(uniformLineHeight: 21, uniformHeadings: true)
    let n16 = (text as NSString).length

    log("### drop-in stack (ScribeEditorFactory + LazyStyler + ReadableColumnController + ScribeLayoutManager), corpus \(corpus), uniform line heights")

    // A. open
    var opens: [[Double]] = []
    for i in 0..<7 {
        autoreleasepool {
            let r = DropInRig(theme: theme)
            _ = r.rep
            let t0 = nowMs()
            r.load(text)
            let t1 = nowMs()
            let nRuns = r.styler.styleVisible()
            let t2 = nowMs()
            r.layoutVisible()
            let t3 = nowMs()
            r.draw()
            let t4 = nowMs()
            opens.append([t1 - t0, t2 - t1, t3 - t2, t4 - t3, t4 - t0, Double(nRuns)])
            if i == 6 { _ = r.rep }
        }
    }
    func med(_ k: Int) -> Double { Stats(opens.dropFirst().map { $0[k] }).median }
    log("\nA. open (median of runs 2..7; cold = run 1 total \(f1(opens[0][4])) ms): string= + base attrs \(f1(med(0))) | style first screen (\(Int(med(5))) runs) \(f1(med(1))) | layout \(f1(med(2))) | draw \(f1(med(3))) | **total \(f1(med(4))) ms** [min \(f1(opens.dropFirst().map { $0[4] }.min()!)) max \(f1(opens.dropFirst().map { $0[4] }.max()!))]")

    // B. scroll steps with the automatic bounds-change hook
    for scenario in ["down from top", "up from end"] {
        let r = DropInRig(theme: theme)
        r.load(text)
        r.styler.styleVisible(); r.layoutVisible(); r.draw()
        if scenario == "up from end" {
            r.styler.scroll(toCharacter: n16)
            r.layoutVisible(); r.styler.scroll(toCharacter: n16); r.layoutVisible(); r.draw()
        }
        var ms_: [Double] = [], jumps: [Double] = [], thumbs: [Double] = []
        let dy: CGFloat = scenario == "up from end" ? -350 : 350
        var noop: [Double] = []
        for _ in 0..<100 {
            let vis0 = r.clip.documentVisibleRect
            let o = r.tv.textContainerOrigin
            let anchor = min(max(0, r.tv.characterIndexForInsertion(at: NSPoint(x: o.x + 40, y: vis0.midY + dy / 2))), n16 - 1)
            let y0 = r.yOfChar(anchor) - vis0.minY
            let th0 = r.thumb
            let t0 = nowMs()
            r.scrollTo(vis0.minY + dy)          // clip bounds notification -> LazyStyler.styleVisible()
            r.layoutVisible()
            r.draw()
            ms_.append(nowMs() - t0)
            let y1 = r.yOfChar(anchor) - r.clip.documentVisibleRect.minY
            jumps.append(abs((y1) - (y0 - dy)))
            thumbs.append(r.thumb - th0)
            noop.append(ms { _ = r.styler.styleVisible() })
        }
        let s = Stats(ms_)
        log("B. \(scenario): step ms med \(f2(s.median)) / p95 \(f2(s.sorted[94])) / max \(f2(s.max)); steps with visual jump > 0.5 pt: \(jumps.filter { $0 > 0.5 }.count)/100 (max \(f1(jumps.max() ?? 0)) pt); thumb Δ per step min/max \(String(format: "%.5f / %.5f", thumbs.min() ?? 0, thumbs.max() ?? 0)); styleVisible() fast path when nothing to do: \(String(format: "%.4f", Stats(noop).median)) ms")
    }

    // C. jumps
    for (name, frac) in [("Cmd-Down (styler.scroll(toCharacter: end))", 1.0), ("jump to middle", 0.5), ("jump to 25 %", 0.25), ("jump to 75 %", 0.75)] {
        let r = DropInRig(theme: theme)
        r.load(text)
        r.styler.styleVisible(); r.layoutVisible(); r.draw()
        let target = frac >= 1 ? n16 : (text as NSString).lineRange(for: NSRange(location: Int(Double(n16) * frac), length: 0)).location
        let t0 = nowMs()
        r.styler.scroll(toCharacter: target)
        r.layoutVisible()
        let callMs = nowMs() - t0
        let o = r.tv.textContainerOrigin
        let anchor = min(max(0, r.tv.characterIndexForInsertion(at: NSPoint(x: o.x + 40, y: r.clip.documentVisibleRect.midY))), n16 - 1)
        let yA = r.yOfChar(anchor) - r.clip.documentVisibleRect.minY
        for _ in 0..<3 { r.layoutVisible(); r.styler.styleVisible(); r.layoutVisible() }
        let yB = r.yOfChar(anchor) - r.clip.documentVisibleRect.minY
        r.draw()
        let atBottom = r.clip.documentVisibleRect.maxY >= r.tv.frame.height - 1
        log("C. \(name): \(f1(callMs)) ms; landing shift after further layout/styling passes \(f1(yB - yA)) pt; top char fraction \(String(format: "%.4f", r.topFraction)); thumb \(String(format: "%.4f", r.thumb)); at bottom \(atBottom); fence pre-scan (first jump only) \(f1(r.provider.fenceBuildMs)) ms")
        if abs(frac - 0.5) < 0.01 {
            for (an, app) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let rr = DropInRig(theme: theme, appearance: app)
                rr.load(text)
                rr.styler.styleVisible(); rr.layoutVisible()
                rr.styler.scroll(toCharacter: target); rr.layoutVisible()
                // put a code block into view if there is one close by: scroll to the next fence line
                if let f = rr.provider.fences, let next = f.starts.first(where: { Int($0) > target }) {
                    rr.styler.scroll(toCharacter: Int(next) - 200)
                    rr.layoutVisible()
                }
                rr.draw()
                writePNG(rr.rep, "DROPIN-TK1n-\(an)-20MB-middle")
            }
        }
    }

    // D. typing at the middle of the document with the real restyle path
    do {
        let r = DropInRig(theme: theme)
        r.load(text)
        let target = (text as NSString).lineRange(for: NSRange(location: n16 / 2, length: 0)).location
        r.styler.scroll(toCharacter: target); r.layoutVisible(); r.draw()
        let o = r.tv.textContainerOrigin
        let idx = r.tv.characterIndexForInsertion(at: NSPoint(x: o.x + 60, y: r.clip.documentVisibleRect.midY))
        r.tv.setSelectedRange(NSRange(location: idx, length: 0))
        r.window.makeFirstResponder(r.tv)
        var tot: [Double] = [], ins: [Double] = []
        let chars = Array("the quick brown fox `code` **bold** jumps ")
        for k in 0..<70 {
            let t0 = nowMs()
            r.tv.insertText(String(chars[k % chars.count]), replacementRange: NSRange(location: NSNotFound, length: 0))
            let t1 = nowMs()
            r.layoutVisible(); r.draw()
            if k >= 10 { tot.append(nowMs() - t0); ins.append(t1 - t0) }
        }
        log("D. typing at the middle of \(corpus) through LazyStyler.didProcessEditing: total \(f2(Stats(tot).median)) ms (p95 \(f2(Stats(tot).sorted[56]))), insertText incl. restyle \(f2(Stats(ins).median)) ms")
        // undo sanity
        let um = r.tv.undoManager
        var levels = 0
        while let u = um, u.canUndo, levels < 10 { u.undo(); levels += 1 }
        log("   undo: \(levels) level(s) to revert 60 typed characters; styled-set ranges after edits: \(r.styler.styled.rangeView.count)")
    }

    // E. IME guard with the real class
    do {
        let r = DropInRig(theme: theme)
        let base = "Hello world\n\n# Heading\n\nText `code`\n"
        r.load(base)
        r.styler.styleVisible(); r.layoutVisible()
        r.window.makeFirstResponder(r.tv)
        r.tv.setSelectedRange(NSRange(location: 5, length: 0))
        let ime = NSAttributedString(string: "ni", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
        r.tv.setMarkedText(ime, selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let during = r.styler.styleVisible()   // must be a no-op while composing
        let hadMarked = r.tv.hasMarkedText()
        r.tv.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = r.window.contentView?.needsLayout
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        log("E. IME: styleVisible() during composition applied \(during) runs (expected 0), hasMarkedText \(hadMarked) -> \(r.tv.hasMarkedText()), final text starts with \"\(r.stack.storage.string.prefix(8))\"")
    }

    // F. resize with the readable column (top character must stay put)
    do {
        let r = DropInRig(theme: theme)
        r.load(text)
        let target = (text as NSString).lineRange(for: NSRange(location: n16 / 2, length: 0)).location
        r.styler.scroll(toCharacter: target); r.layoutVisible()
        let before = r.topFraction
        var stepMs: [Double] = []
        var w: CGFloat = 900
        for i in 0..<60 { w += i < 30 ? -5 : 5; stepMs.append(ms { r.window.setContentSize(NSSize(width: w, height: 700)); r.layoutVisible(); r.draw() }) }
        r.window.setContentSize(NSSize(width: 600, height: 700)); r.layoutVisible()
        log("F. resize 900 -> 600 in the middle of \(corpus) with ReadableColumnController: step med \(f2(Stats(stepMs).median)) ms, p95 \(f2(Stats(stepMs).sorted[56])) ms; top char fraction \(String(format: "%.5f", before)) -> \(String(format: "%.5f", r.topFraction)); inset now \(f1(Double(r.tv.textContainerInset.width)))")
    }
}
