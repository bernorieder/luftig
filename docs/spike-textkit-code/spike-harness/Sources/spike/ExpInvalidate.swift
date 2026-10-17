import AppKit

/// Does an edit that changes a block's extent invalidate everything that has to be redrawn?
/// (neighbour lines change their rounded corners; the band reaches into the inset margins)
/// Uses the first fenced code block of the 100 KB corpus (visible in the first screen).
func runInvalidate(_ rest: [String]) {
    let uniform = rest.contains("--uniform")
    let theme = uniform ? Theme(uniformLineHeight: 21, uniformHeadings: true) : Theme()
    log("theme: \(uniform ? "uniform line heights (M1)" : "natural line heights (M0)")")
    let text = Corpus.load("100k")
    let doc = Doc(text)
    let open = Int(doc.fences.starts[0]), close = Int(doc.fences.starts[1])
    let closingFence = NSRange(location: close, length: doc.lineEnd(close) - close)
    let below = NSRange(location: NSMaxRange(closingFence), length: doc.lineEnd(NSMaxRange(closingFence)) - NSMaxRange(closingFence))
    let lastBody = NSRange(location: doc.lineStart(close - 1), length: close - doc.lineStart(close - 1))
    let beforeLast = NSRange(location: doc.lineStart(lastBody.location - 1), length: lastBody.location - doc.lineStart(lastBody.location - 1))
    _ = open

    log("| engine | case | widen invalidation | neighbour touch | invalidated rects after the change (rows) | required region covered | TK2: paragraph offsets with re-created fragments |")
    log("|---|---|---|---|---|---|---|")
    for engine in Engine.parse((rest.firstIndex(of: "--engine").map { rest[$0 + 1] }) ?? "tk1n,tk2") {
        for scenario in ["grow: line below the block becomes code", "shrink: last body line + closing fence become prose"] {
            for widen in [false, true] {
                for touch in [false, true] {
                    if engine.isTK2 && widen { continue }   // widening is a TK1 text-view concern (TK2 draws per fragment)
                    var o = HarnessOptions(); o.width = 720; o.height = 640; o.appearance = .aqua; o.inset = NSSize(width: 28, height: 16)
                    let h = Harness(engine: engine, options: o)
                    h.textView.font = theme.bodyFont
                    h.textView.string = text
                    if uniform { h.storage.beginEditing(); h.storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: h.storage.length)); h.storage.endEditing() }
                    Styler.style(doc: doc, range: doc.range(fromLineAt: 0, lines: 300), storage: h.storage, theme: theme)
                    h.textView.widenInvalidationForDecorations = widen
                    for _ in 0..<3 { h.layoutVisible(); _ = h.spin(0.01); h.textView.displayIfNeeded() }
                    let co = h.textView.textContainerOrigin
                    let outset = DecorationMetrics.bandOutset
                    let cw = h.container.size.width

                    // geometry (view coordinates) BEFORE the change
                    func rect(_ r: NSRange) -> (CGFloat, CGFloat) { (h.yOfChar(r.location), h.heightOfChar(r.location)) }
                    let (yL, hL) = rect(closingFence)
                    let (yB, hB) = rect(below)
                    let (yLB, hLB) = rect(lastBody)
                    let (yBL, hBL) = rect(beforeLast)

                    h.textView.invalidRects.removeAll()
                    h.textView.recordInvalidations = true
                    h.createdFragments.removeAll()

                    var changedTop = 0.0, changedBottom = 0.0
                    h.storage.beginEditing()
                    if scenario.hasPrefix("grow") {
                        h.storage.setAttributes(theme.attrs(S.codeBlock), range: below)
                        if touch { if rest.contains("--edited") { h.storage.edited(.editedAttributes, range: closingFence, changeInLength: 0) } else { h.storage.setAttributes(theme.attrs(S.codeBlock | S.fence), range: closingFence) } }
                        changedTop = Double(yL + hL - DecorationMetrics.bandCornerRadius); changedBottom = Double(yB + hB)
                    } else {
                        h.storage.setAttributes(theme.attrs(0), range: lastBody)
                        h.storage.setAttributes(theme.attrs(0), range: closingFence)
                        if touch { if rest.contains("--edited") { h.storage.edited(.editedAttributes, range: beforeLast, changeInLength: 0) } else { h.storage.setAttributes(theme.attrs(S.codeBlock), range: beforeLast) } }
                        changedTop = Double(yBL + hBL - DecorationMetrics.bandCornerRadius); changedBottom = Double(yL + hL)
                        _ = (yLB, hLB)
                    }
                    h.storage.endEditing()
                    h.layoutVisible()
                    h.textView.displayIfNeeded()
                    h.textView.recordInvalidations = false

                    // required: full band width incl. outset, from the neighbour's corner zone to the bottom of the changed line(s)
                    let req = NSRect(x: co.x - outset - 1, y: changedTop, width: cw + 2 * outset + 2, height: changedBottom - changedTop)
                    var covered = true
                    if !engine.isTK2 {
                        var y = req.minY
                        while y < req.maxY {
                            for x in [req.minX + 1, req.midX, req.maxX - 1] {
                                if !h.textView.invalidRects.contains(where: { $0.contains(NSPoint(x: x, y: y)) }) { covered = false }
                            }
                            y += 1
                        }
                    }
                    let rows = h.textView.invalidRects.map { $0.width > 100_000 ? "FULL(infinite)" : "[\(f1($0.minY))..\(f1($0.maxY)) x\(f1($0.minX))..\(f1($0.maxX))]" }.joined(separator: " ")
                    let frags = h.createdFragments.map(String.init).joined(separator: ",")
                    let coverText = engine.isTK2 ? "n/a (per-fragment layers)" : (covered ? "YES" : "**NO**")
                    log("| \(engine.rawValue) | \(scenario) | \(engine.isTK2 ? "-" : (widen ? "yes" : "no")) | \(touch ? "yes" : "no") | \(rows.isEmpty ? "none" : rows) (required y \(f1(req.minY))..\(f1(req.maxY)), x \(f1(req.minX))..\(f1(req.maxX))) | \(coverText) | \(engine.isTK2 ? frags : "-") |")
                    h.window.contentView = nil
                }
            }
        }
    }
    log("(offsets: block closing fence = \(closingFence.location), last body line = \(lastBody.location), line before that = \(beforeLast.location), line below the block = \(below.location))")
}
