#if LUFTIG_SELFTEST
// Probe: where does the cost of NSTextStorage.fixFontAttribute(in:) go (the font fallback fix of LazyStyler)?
import AppKit

extension SelfTestScenarios {
    static let auditEditorFixProbeScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-fixcost", summary: "(probe) cost of fixFontAttribute: bare attributed string, bare storage, storage with a layout manager, the editor's storage", run: { t in try await probeFixCost(t) }, inAll: false),
    ]

    @MainActor static func probeFixCost(_ t: SelfTest.T) async throws {
        do {
            let m = NSMutableAttributedString(string: "ab 日本語 😀 é", attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
            m.fixFontAttribute(in: NSRange(location: 0, length: m.length))
            m.enumerateAttributes(in: NSRange(location: 0, length: m.length), options: []) { a, r, _ in
                t.note("scratch run \(NSStringFromRange(r)) keys \(a.keys.map { $0.rawValue }.sorted()) font \((a[.font] as? NSFont)?.fontName ?? "-")")
            }
        }
        let cjk = auditCJKText(bytes: 4000, seed: 5)
        let s = (cjk as NSString).substring(to: min(1000, (cjk as NSString).length))
        let font = NSFont.systemFont(ofSize: 16)
        func bench(_ label: String, _ body: () -> Void) {
            var times: [Double] = []
            for _ in 0..<15 { times.append(perfMs(body)) }
            times.sort()
            t.note("\(label): median \(String(format: "%.3f", times[7])) ms, min \(String(format: "%.3f", times[0])) (\((s as NSString).length) chars)")
        }
        bench("NSMutableAttributedString fixFontAttribute") {
            let m = NSMutableAttributedString(string: s, attributes: [.font: font])
            m.fixFontAttribute(in: NSRange(location: 0, length: m.length))
        }
        bench("NSTextStorage (no layout manager) fixFontAttribute") {
            let m = NSTextStorage(string: s, attributes: [.font: font])
            m.fixFontAttribute(in: NSRange(location: 0, length: m.length))
        }
        do {
            let ts = NSTextStorage(string: s, attributes: [.font: font])
            let lm = NSLayoutManager(); ts.addLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: 600, height: 1e7)); lm.addTextContainer(tc)
            lm.ensureLayout(for: tc)
            bench("NSTextStorage + laid-out layout manager, fix in place (already fixed text after the first run)") {
                ts.setAttributes([.font: font], range: NSRange(location: 0, length: ts.length))
                ts.fixFontAttribute(in: NSRange(location: 0, length: ts.length))
            }
            bench("same, but batched in begin/endEditing") {
                ts.beginEditing()
                ts.setAttributes([.font: font], range: NSRange(location: 0, length: ts.length))
                ts.fixFontAttribute(in: NSRange(location: 0, length: ts.length))
                ts.endEditing()
            }
            bench("setAttributes only (batched)") {
                ts.beginEditing()
                ts.setAttributes([.font: font], range: NSRange(location: 0, length: ts.length))
                ts.endEditing()
            }
        }
        // the same on a Latin string with a few accents
        let latin = String(repeating: "Größenänderung café naïve Zoë text with words ", count: 22)
        bench("Latin + accents, bare attributed string") {
            let m = NSMutableAttributedString(string: latin, attributes: [.font: font])
            m.fixFontAttribute(in: NSRange(location: 0, length: m.length))
        }
        // per character cost: one CJK character per call
        bench("1000 x one-character strings (bare)") {
            for ch in s.prefix(1000) {
                let m = NSMutableAttributedString(string: String(ch), attributes: [.font: font])
                m.fixFontAttribute(in: NSRange(location: 0, length: m.length))
            }
        }
        // the storage size matters: the same 1000 characters fixed inside storages of 1 / 100 / 1000 KB of text
        for kb in [1, 100, 1000, 4000] {
            let filler = String(repeating: "plain ascii text and some more words. ", count: kb * 1024 / 38)
            let ts = NSTextStorage(string: filler + s + filler, attributes: [.font: font])
            let lm = NSLayoutManager(); ts.addLayoutManager(lm)
            let range = NSRange(location: (filler as NSString).length, length: (s as NSString).length)
            bench("fix of 1000 CJK chars inside a storage of \(kb) KB (layout manager attached, nothing laid out)") {
                ts.beginEditing()
                ts.setAttributes([.font: font], range: range)
                ts.fixFontAttribute(in: range)
                ts.endEditing()
            }
            let bare = NSMutableAttributedString(string: filler + s + filler, attributes: [.font: font])
            bench("same in a bare NSMutableAttributedString of \(kb) KB") {
                bare.setAttributes([.font: font], range: range)
                bare.fixFontAttribute(in: range)
            }
        }
        // CoreText: the fallback font of a string, via CTFontCreateForString
        bench("CTFontCreateForString per 1000 characters") {
            let ns = s as NSString
            for i in 0..<min(1000, ns.length) { _ = CTFontCreateForString(font, s as CFString, CFRange(location: i, length: 1)) }
        }
    }
}
#endif

#if LUFTIG_SELFTEST
extension SelfTestScenarios {
    static let auditEditorFenceBigScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-fencebig", summary: "(probe) type a code fence at the top of a big document (real key events), undo, redo, delete it: time and styling", run: { t in try await probeFenceBig(t) }, inAll: false),
    ]

    @MainActor static func probeFenceBig(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 10_000_000
        let src = t.corpusFile(bytes: bytes)
        let copy = t.url("fencebig.md")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
        guard let host = doc.host as? EditorViewController else { return }
        let tv = host.textView
        let len = (tv.string as NSString).length
        t.note("opened \(len) units")
        func step(_ label: String, _ body: () -> Void) async {
            let ms = perfMs(body)
            let settle = perfMs { host.styler.styleVisible(); host.textView.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!) }
            await t.spin(5)
            let r = AuditEd.styledMismatches(host)
            let vis = host.styler.visibleCharacterRange(tv)
            let visStyled = vis.length == 0 || host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis))
            t.note("\(label): \(String(format: "%.1f", ms)) ms (+ \(String(format: "%.1f", settle)) ms to settle); styled runs compared \(r.compared), differ \(r.bad); visible styled \(visStyled); stale events \(host.styler.staleEvents); styled set \(host.styler.styled.rangeView.count) ranges")
            t.check(r.bad == 0 && visStyled, "\(label): styled == fresh lex, visible part styled")
        }
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        await step("type ``` at the top") { for ch in "```" { AuditEd.press(host, String(ch)) } }
        await step("Return") { AuditEd.pressKey(host, AuditEd.Key.returnKey) }
        await step("undo (Return)") { AuditEd.undo(host) }
        await step("undo (```)") { AuditEd.undo(host) }
        await step("redo") { AuditEd.redo(host) }
        await step("redo") { AuditEd.redo(host) }
        await step("backspace x4 (remove the fence again)") { for _ in 0..<4 { AuditEd.pressKey(host, AuditEd.Key.delete) } }
        // the same in the middle of the document, after a jump
        host.textView.scrollRangeToVisible(NSRange(location: len / 2, length: 0))
        let mid = (tv.string as NSString).lineRange(for: NSRange(location: len / 2, length: 0)).location
        tv.setSelectedRange(NSRange(location: mid, length: 0))
        await step("type ~~~ + Return in the middle") { for ch in "~~~" { AuditEd.press(host, String(ch)) }; AuditEd.pressKey(host, AuditEd.Key.returnKey) }
        await step("undo x2") { AuditEd.undo(host); AuditEd.undo(host) }
        t.close(doc)
    }
}
#endif

#if LUFTIG_SELFTEST
extension SelfTestScenarios {
    static let auditEditorBigLineScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-bigline", summary: "(probe) documents that are ONE line of N MB (<= 5 MB): open, scroll, type, undo", run: { t in try await probeBigLine(t) }, inAll: false),
    ]

    @MainActor static func probeBigLine(_ t: SelfTest.T) async throws {
        let sizes = (SelfTest.argument("sizes") ?? "200000,1000000,4000000").split(separator: ",").compactMap { Int($0) }
        for bytes in sizes where bytes <= 5_000_000 {
            var words = ""
            var r = TestRNG(11)
            let w = ["alpha", "bravo", "**bold**", "`code`", "charlie", "[l](u)", "delta", "echo", "*it*", "foxtrot"]
            while words.utf8.count < bytes { words += r.pick(w); words += " " }
            let url = t.write(words, to: "bigline-\(bytes).md")
            let t0 = SelfTest.nowMs()
            let doc = try await t.open(url, size: NSSize(width: 860, height: 700))
            let openMs = SelfTest.nowMs() - t0
            guard let host = doc.host as? EditorViewController else { continue }
            let tv = host.textView
            t.note("\(bytes) bytes in ONE line: open + window + first screen \(String(format: "%.0f", openMs)) ms; styled ranges \(host.styler.styled.rangeView.map { NSStringFromRange(NSRange(location: $0.lowerBound, length: $0.count)) })")
            let tl = perfMs { tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!) }
            t.note("   layout of the visible part: \(String(format: "%.0f", tl)) ms; document height \(Int(tv.frame.height))")
            // type at the start, the middle, the end
            for (label, frac) in [("start", 0.0), ("middle", 0.5), ("end", 1.0)] {
                let loc = Int(Double((tv.string as NSString).length) * frac)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                let g = perfMs { tv.scrollRangeToVisible(tv.selectedRange()) }
                var keys: [Double] = []
                for ch in "abcde" { keys.append(perfMs { AuditEd.press(host, String(ch)) }) }
                t.note("   typing at the \(label): jump \(String(format: "%.0f", g)) ms, 5 keystrokes \(keys.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms")
            }
            let u = perfMs { AuditEd.undo(host); AuditEd.undo(host) }
            let rr = AuditEd.styledMismatches(host)
            t.check(rr.bad == 0, "\(bytes): styled == fresh lex after typing/undo (\(rr.compared) runs, \(rr.bad) differ); undo x2 \(String(format: "%.1f", u)) ms")
            t.close(doc)
        }
    }
}
#endif

#if LUFTIG_SELFTEST
extension SelfTestScenarios {
    static let auditEditorLazyFixScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-lazyfix", summary: "(probe) AppKit's LAZY attribute fixing in a big CJK document: what does laying out / jumping to one place fix?", run: { t in try await probeLazyFix(t) }, inAll: false),
    ]

    @MainActor static func probeLazyFix(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 3_000_000
        let url = t.write(auditCJKText(bytes: bytes, seed: 7), to: "lazyfix.md")
        for action in ["none (just probe)", "ensureLayout 2000 chars at 50%", "scrollRangeToVisible at 50%", "clip view scroll to 50% + layout of the visible rect", "ensureLayout 2000 chars at 90%"] {
            let doc = try await t.open(url, size: NSSize(width: 860, height: 700))
            guard let host = doc.host as? EditorViewController else { continue }
            let tv = host.textView, ts = tv.textStorage!, lm = tv.layoutManager!
            let len = ts.length
            let mid = (tv.string as NSString).lineRange(for: NSRange(location: len / 2, length: 0)).location
            let late = (tv.string as NSString).lineRange(for: NSRange(location: len * 9 / 10, length: 0)).location
            let d: Double
            switch action {
            case "ensureLayout 2000 chars at 50%": d = perfMs { lm.ensureLayout(forCharacterRange: NSRange(location: mid, length: 2000)) }
            case "ensureLayout 2000 chars at 90%": d = perfMs { lm.ensureLayout(forCharacterRange: NSRange(location: late, length: 2000)) }
            case "scrollRangeToVisible at 50%": d = perfMs { tv.scrollRangeToVisible(NSRange(location: mid, length: 0)); host.styler.styleVisible() }
            case "clip view scroll to 50% + layout of the visible rect":
                d = perfMs {
                    host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: tv.frame.height / 2)); host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
                    lm.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                }
            default: d = 0
            }
            var parts: [String] = []
            for frac in [0.02, 0.2, 0.45, 0.49, 0.51, 0.55, 0.7, 0.88, 0.92, 0.98] {
                let p = Int(Double(len) * frac)
                var eff = NSRange(location: 0, length: 0)
                let m = perfMs { _ = ts.attributes(at: p, longestEffectiveRange: &eff, in: NSRange(location: p, length: 20_000)) }
                parts.append("\(Int(frac * 100))%: \(String(format: "%.1f", m))")
            }
            t.note("\(action): \(String(format: "%.0f", d)) ms; cost of reading the attributes of 20 000 characters at ... [\(parts.joined(separator: ", "))] ms (unfixed text is slow to read, fixed text is not)")
            t.close(doc)
        }
    }
}
#endif

#if LUFTIG_SELFTEST
extension SelfTestScenarios {
    static let auditEditorRunSizeScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-runsize", summary: "(probe) does the cost of AppKit's lazy font fixing depend on the size of the attribute RUN that is read?", run: { t in try await probeRunSize(t) }, inAll: false),
    ]

    @MainActor static func probeRunSize(_ t: SelfTest.T) async throws {
        let text = auditCJKText(bytes: Int(SelfTest.argument("bytes") ?? "") ?? 1_500_000, seed: 7)
        let font = NSFont.systemFont(ofSize: 16)
        let chunkKey = NSAttributedString.Key("luftig.probe.chunk")
        for (label, chunk) in [("one run for the whole text", 0), ("chunks of 100 000 chars", 100_000), ("chunks of 10 000 chars", 10_000), ("chunks of 2 000 chars", 2_000)] {
            let ts = NSTextStorage(string: text)
            let lm = NSLayoutManager(); ts.addLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: 700, height: 1e7)); lm.addTextContainer(tc)
            lm.allowsNonContiguousLayout = true
            ts.beginEditing()
            if chunk == 0 { ts.setAttributes([.font: font], range: NSRange(location: 0, length: ts.length)) }
            else {
                var i = 0, k = 0
                while i < ts.length { let n = min(chunk, ts.length - i); ts.setAttributes([.font: font, chunkKey: k], range: NSRange(location: i, length: n)); i += n; k += 1 }
            }
            ts.endEditing()
            var times: [String] = []
            var rng = TestRNG(5)
            for _ in 0..<6 {
                let p = rng.int(ts.length - 25_000)
                var eff = NSRange(location: 0, length: 0)
                let m = perfMs { _ = ts.attributes(at: p, longestEffectiveRange: &eff, in: NSRange(location: p, length: 20_000)) }
                times.append(String(format: "%.0f", m))
            }
            var lay: [String] = []
            for _ in 0..<4 {
                let p = rng.int(ts.length - 5_000)
                lay.append(String(format: "%.0f", perfMs { lm.ensureLayout(forCharacterRange: NSRange(location: p, length: 3000)) }))
            }
            t.note("\(label) (\(ts.length) chars): reading 20 000 characters at random places: \(times.joined(separator: ", ")) ms; ensureLayout of 3000 characters at random places: \(lay.joined(separator: ", ")) ms")
        }
    }
}
#endif
