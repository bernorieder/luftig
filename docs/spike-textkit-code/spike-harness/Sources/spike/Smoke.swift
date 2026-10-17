import AppKit

func runSmoke(_ rest: [String]) {
    let scratch = ProcessInfo.processInfo.environment["SPIKE_SCRATCH"] ?? "/tmp"
    let theme = Theme()
    let text = Corpus.load("100k")
    let doc = Doc(text)
    log("corpus 100k: \(text.utf8.count) bytes, \(doc.length) utf16, lines \(doc.u16.filter { $0 == 10 }.count)")
    for engine in Engine.allCases {
        let h = Harness(engine: engine)
        log("== \(engine.rawValue): window visible=\(h.window.isVisible) scale=\(h.window.backingScaleFactor) contentSize=\(h.scroll.contentSize)")
        h.installBaseDefaults(theme)
        let tSet = h.setText(text, mode: .stringProperty, baseAttrs: nil)
        let r = doc.range(fromLineAt: 0, lines: 120)
        let (lexMs, applyMs, runs) = Styler.style(doc: doc, range: r, storage: h.storage, theme: theme)
        let tLayout = ms { h.layoutVisible() }
        let tDraw = h.drawVisible()
        log("  set=\(f2(tSet)) lex=\(f2(lexMs)) apply=\(f2(applyMs)) runs=\(runs) layout=\(f2(tLayout)) draw=\(f2(tDraw)) docHeight=\(f1(h.docHeight))")
        log("  storage.delegate = \(String(describing: h.storage.delegate)) ; textView is TK2 = \(h.textView.textLayoutManager != nil)")
        log("  occlusion=\(h.window.occlusionState.rawValue) onActiveSpace=\(h.window.isOnActiveSpace) isVisible=\(h.window.isVisible) tv.window=\(h.textView.window != nil) visibleRect=\(h.textView.visibleRect)")
        for (name, fn) in [("window.displayIfNeeded", { h.window.displayIfNeeded() }), ("tv.displayIfNeeded", { h.textView.displayIfNeeded() }),
                           ("tv.display", { h.textView.display() }), ("tv.displayIgnoringOpacity", { h.textView.displayIgnoringOpacity(h.textView.visibleRect) }),
                           ("scroll.display", { h.scroll.display() })] as [(String, () -> Void)] {
            h.textView.drawCount = 0
            h.textView.setNeedsDisplay(h.textView.visibleRect)
            let t = ms { fn() }
            log("  \(name): drawCount=\(h.textView.drawCount) \(f2(t)) ms")
        }
        h.savePNG("\(scratch)/out/smoke-\(engine.rawValue).png")
    }
}
