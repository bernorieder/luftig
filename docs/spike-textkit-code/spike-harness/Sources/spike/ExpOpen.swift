import AppKit

/// Pull the chars of `range` out of the text storage (what the real HighlightController would do) and lex them.
func lexFromStorage(_ storage: NSTextStorage, range: NSRange, inFence: Bool, lexer: MiniLexer, buf: inout [UInt16]) -> [Run] {
    let ns = storage.string as NSString
    if buf.count < range.length { buf = [UInt16](repeating: 0, count: range.length) }
    buf.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: range) }
    return buf.withUnsafeBufferPointer { b in
        lexer.lex(UnsafeBufferPointer(rebasing: b[0..<range.length]), offset: range.location, inFence: inFence)
    }
}

/// First-screen slice: roughly the first `lines` lines from the top of the storage.
func firstScreenRange(_ storage: NSTextStorage, lines: Int = 150) -> NSRange {
    let ns = storage.string as NSString
    let n = min(ns.length, lines * 90)
    var buf = [UInt16](repeating: 0, count: n)
    buf.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: n)) }
    var count = 0, end = 0
    for i in 0..<n where buf[i] == 10 {
        count += 1; end = i + 1
        if count == lines { break }
    }
    return NSRange(location: 0, length: end == 0 ? n : end)
}

struct OpenSample {
    var tSet = 0.0, tBase = 0.0, tStyle = 0.0, tLayout = 0.0, tDraw = 0.0
    var total: Double { tSet + tBase + tStyle + tLayout + tDraw }
    var unstyledTotal: Double { tSet + tBase + tLayout + tDraw }
    var rssDelta = 0.0
    var docHeight = 0.0
    var stallMs = 0.0
    var heightAfterIdle = 0.0
    var runs = 0
}

func measureOpen(engine: Engine, text: String, mode: SetTextMode, theme: Theme, styled: Bool, idle: Double, options: HarnessOptions = HarnessOptions(), png: String? = nil) -> OpenSample {
    var s = OpenSample()
    autoreleasepool {
        let rss0 = rssMB()
        let h = Harness(engine: engine, options: options)
        // base defaults the view needs just to display (font / colour / paragraph style) - constant cost, set while empty
        h.textView.font = theme.bodyFont
        h.textView.textColor = Palette.text
        h.textView.defaultParagraphStyle = theme.paragraphStyle(for: 0)
        _ = h.snapshotRep   // allocate the bitmap outside the timed region

        let base = theme.baseAttributes
        switch mode {
        case .stringProperty:
            s.tSet = ms { h.textView.string = text }
            s.tBase = 0   // typing attributes are applied by the setter itself
        case .replaceCharacters:
            s.tSet = ms { h.storage.replaceCharacters(in: NSRange(location: 0, length: h.storage.length), with: text) }
            s.tBase = ms { h.storage.setAttributes(base, range: NSRange(location: 0, length: h.storage.length)) }
        case .setAttributedString:
            var attr: NSAttributedString! = nil
            s.tSet = ms { attr = NSAttributedString(string: text, attributes: base) }   // building counts: it copies the string
            s.tBase = ms { h.storage.setAttributedString(attr) }
        }
        if styled {
            let lexer = MiniLexer()
            var buf = [UInt16]()
            s.tStyle = ms {
                let r = firstScreenRange(h.storage)
                let runs = lexFromStorage(h.storage, range: r, inFence: false, lexer: lexer, buf: &buf)
                s.runs = runs.count
                Styler.apply(runs, to: h.storage, theme: theme)
            }
        }
        s.tLayout = ms { h.layoutVisible() }
        s.tDraw = h.drawVisible()
        s.docHeight = h.docHeight
        if let png = png { h.savePNG(png) }
        s.rssDelta = rssMB() - rss0
        if idle > 0 {
            let (gap, _) = h.spin(idle, measureStalls: true)
            s.stallMs = gap
            s.heightAfterIdle = h.docHeight
        }
        // release before returning
        h.window.contentView = nil
    }
    return s
}

func runOpen(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let engines = Engine.parse(arg("engine", "all"))
    let corpora = arg("corpus", "100k,1m,5m,10m,20m").split(separator: ",").map(String.init)
    let runs = Int(arg("runs", "7"))!
    let modes: [SetTextMode] = arg("mode", "string").split(separator: ",").map {
        switch $0 { case "string": return .stringProperty; case "replace": return .replaceCharacters; default: return .setAttributedString }
    }
    let idle = Double(arg("idle", "1.0"))!
    let styled = arg("styled", "1") == "1"
    let png = rest.contains("--png")
    let theme = Theme()

    log("### open: runs=\(runs) styled=\(styled) idle=\(idle)s  (ms; breakdown = medians of runs 2..N; cold = run 1 total)")
    log("| corpus | engine | set mode | cold total | **total med** [min..max] | set | base attrs | style 1st screen | layout | draw | RSS Δ MB | docH after open -> after \(idle)s | max stall in idle ms |")
    log("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for corpus in corpora {
        let text = Corpus.load(corpus)
        for engine in engines {
            for mode in modes {
                var samples: [OpenSample] = []
                for i in 0..<runs { samples.append(measureOpen(engine: engine, text: text, mode: mode, theme: theme, styled: styled, idle: idle, png: (i == runs - 1 && png) ? "\(Corpus.dir)/../out/open-\(corpus)-\(engine.rawValue).png" : nil)) }
                let warm = Array(samples.dropFirst())
                func med(_ kp: (OpenSample) -> Double) -> Double { Stats(warm.map(kp)).median }
                let tot = Stats(warm.map { $0.total })
                log("| \(corpus) | \(engine.rawValue) | \(mode.rawValue) | \(f1(samples[0].total)) | **\(f1(tot.median))** [\(f1(tot.min))..\(f1(tot.max))] | \(f1(med { $0.tSet })) | \(f1(med { $0.tBase })) | \(f1(med { $0.tStyle })) | \(f1(med { $0.tLayout })) | \(f1(med { $0.tDraw })) | \(f1(med { $0.rssDelta })) | \(f1(med { $0.docHeight })) -> \(f1(med { $0.heightAfterIdle })) | \(f1(Stats(warm.map { $0.stallMs }).max)) |")
            }
        }
    }
}
