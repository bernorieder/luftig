import AppKit

/// Which first-use API calls are O(document) in each engine at 20 MB?
func runProbe(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let corpus = arg("corpus", "20m")
    let text = Corpus.load(corpus)
    let theme = Theme()
    for engine in Engine.parse(arg("engine", "tk1n,tk2")) {
        let h = Harness(engine: engine)
        h.textView.font = theme.bodyFont
        let o = h.textView.textContainerOrigin
        log("== \(engine.rawValue) \(corpus)")
        log("  string=                         \(f1(ms { h.textView.string = text }))")
        log("  layoutVisible                   \(f1(ms { h.layoutVisible() }))")
        log("  layoutVisible (again)           \(f1(ms { h.layoutVisible() }))")
        var lo = 0, hi = 0
        log("  characterIndexForInsertion(top) \(f1(ms { lo = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 2, y: 1)) }))  -> \(lo)")
        log("  characterIndexForInsertion(bot) \(f1(ms { hi = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 2, y: 690)) }))  -> \(hi)")
        log("  characterIndexForInsertion(bot) \(f1(ms { hi = h.textView.characterIndexForInsertion(at: NSPoint(x: o.x + 2, y: 690)) }))  (again)")
        if let tlm = h.textLayoutManager2 {
            var vr: NSTextRange?
            log("  viewportRange                   \(f1(ms { vr = tlm.textViewportLayoutController.viewportRange }))")
            if let vr = vr {
                let cm = tlm.textContentManager!
                var a = 0, b = 0
                log("  viewport offsets via content mgr \(f1(ms { a = cm.offset(from: cm.documentRange.location, to: vr.location); b = cm.offset(from: cm.documentRange.location, to: vr.endLocation) })) -> \(a)..<\(b)")
            }
            log("  documentRange                   \(f1(ms { _ = tlm.documentRange }))")
            log("  usageBoundsForTextContainer     \(f1(ms { _ = tlm.usageBoundsForTextContainer }))")
        }
        var r = NSRect.zero
        log("  firstRect(char 400)             \(f1(ms { r = h.textView.firstRect(forCharacterRange: NSRange(location: 400, length: 1), actualRange: nil) }))")
        log("  setSelectedRange(400)           \(f1(ms { h.textView.setSelectedRange(NSRange(location: 400, length: 0)) }))")
        log("  scrollRangeToVisible(400)       \(f1(ms { h.textView.scrollRangeToVisible(NSRange(location: 400, length: 0)) }))")
        log("  storage.string as NSString len  \(f1(ms { _ = (h.storage.string as NSString).length }))")
        log("  storage.length                  \(f1(ms { _ = h.storage.length }))")
        log("  paragraphRange(mid)             \(f1(ms { _ = (h.storage.string as NSString).paragraphRange(for: NSRange(location: h.storage.length / 2, length: 0)) }))")
        log("  attribute(at: mid)              \(f1(ms { _ = h.storage.attribute(.font, at: h.storage.length / 2, effectiveRange: nil) }))")
        log("  (string as NSString).getCharacters(mid, 20k) \(f1(ms { var b = [UInt16](repeating: 0, count: 20000); let ns = h.storage.string as NSString; b.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: h.storage.length / 2, length: 20000)) } }))")
        if engine == .tk1n {
            let n = h.storage.length
            for f in [0.25, 0.5, 0.75, 0.99, 0.5, 0.1] {
                log("  attribute(at: \(f) * n)           \(f1(ms { _ = h.storage.attribute(.font, at: Int(Double(n) * f), effectiveRange: nil) }))")
            }
        }
        h.window.contentView = nil
    }
}

/// TK2 landing stability: how many layout passes does it take until the anchor stops moving after a jump?
func runProbeSettle(_ rest: [String]) {
    func arg(_ n: String, _ d: String) -> String { if let i = rest.firstIndex(of: "--" + n), i + 1 < rest.count { return rest[i + 1] }; return d }
    let corpus = arg("corpus", "20m")
    let text = Corpus.load(corpus)
    let doc = Doc(text)
    for engine in Engine.parse(arg("engine", "tk1n,tk2")) {
        for mit in [Mitigation.m0, Mitigation.m1, Mitigation.m0n, Mitigation.m1n] {
            let rig = ScrollRig(engine: engine, text: text, doc: doc, mitigation: mit)
            let h = rig.h
            let target = doc.lineStart(doc.length / 2)
            if mit.onlyNew {
                // styled-range cache + pre-style: style the target region first, remember it
                let rg = doc.range(around: target, before: 80, after: 80)
                Styler.style(doc: doc, range: rg, storage: h.storage, theme: rig.theme)
                h.styledSet.formUnion(IndexSet(integersIn: rg.location..<NSMaxRange(rg)))
            }
            h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            let o = h.textView.textContainerOrigin
            var line = "\(engine.rawValue) \(mit.name): "
            h.layoutVisible()
            let anchor = rig.anchorChar(at: h.visibleRect.midY, origin: o)
            var y0 = rig.yOfChar(anchor) - h.visibleRect.minY
            line += "after jump+1 layout: anchor@\(f1(y0)) "
            for i in 2...4 {
                h.layoutVisible()
                _ = h.spin(0.02)
                let y = rig.yOfChar(anchor) - h.visibleRect.minY
                line += "| pass \(i): \(f1(y - y0)) "
                y0 = y
            }
            rig.styleVis()
            h.layoutVisible()
            let ys = rig.yOfChar(anchor) - h.visibleRect.minY
            line += "| after styling: \(f1(ys - y0))"
            log(line)
        }
    }
}

/// Where does marked-text decoration live (storage attributes vs temporary / rendering attributes), and does restyling touch it?
func runProbeMarked(_ rest: [String]) {
    let theme = Theme()
    let base = "Hello world\n"
    for engine in Engine.parse("tk1n,tk2") {
        let h = Harness(engine: engine)
        h.textView.font = theme.bodyFont
        h.textView.string = base
        h.layoutVisible()
        let tv = h.textView
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        let ime = NSAttributedString(string: "ni", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
        tv.setMarkedText(ime, selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let mr = tv.markedRange()
        func report(_ when: String) {
            var line = "\(engine.rawValue) \(when): marked=\(tv.markedRange()) storage keys=\(attrKeys(h.storage.attributes(at: mr.location, effectiveRange: nil)))"
            if let lm = h.layoutManager1 {
                let t = lm.temporaryAttributes(atCharacterIndex: mr.location, effectiveRange: nil)
                line += " | TK1 temporaryAttributes keys=\(attrKeys(t))"
            }
            if let tlm = h.textLayoutManager2, let cm = tlm.textContentManager {
                var keys = Set<String>()
                if let s = cm.location(cm.documentRange.location, offsetBy: mr.location), let e = cm.location(cm.documentRange.location, offsetBy: NSMaxRange(mr)) {
                    tlm.enumerateRenderingAttributes(from: s, reverse: false) { _, attrs, range in
                        for k in attrs.keys { keys.insert(k.rawValue) }
                        return cm.offset(from: range.endLocation, to: e) > 0
                    }
                }
                line += " | TK2 renderingAttributes keys=\(keys.sorted().joined(separator: ","))"
            }
            log(line)
        }
        report("after setMarkedText")
        let doc = Doc(h.storage.string)
        Styler.style(doc: doc, range: NSRange(location: 0, length: doc.length), storage: h.storage, theme: theme)
        h.layoutVisible()
        report("after restyle (setAttributes whole doc)")
        tv.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        report("after commit")
        h.window.contentView = nil
    }
}

// MARK: - where does AppKit clip TK1 background drawing?

final class ClipProbeLM: NSLayoutManager {
    var lmClip: [CGRect] = []
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let ctx = NSGraphicsContext.current?.cgContext { lmClip.append(ctx.boundingBoxOfClipPath) }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
final class ClipProbeTV: NSTextView {
    var tvClip: [CGRect] = []
    override func drawBackground(in rect: NSRect) {
        if let ctx = NSGraphicsContext.current?.cgContext { tvClip.append(ctx.boundingBoxOfClipPath) }
        super.drawBackground(in: rect)
    }
}

func runProbeClip(_ rest: [String]) {
    let storage = NSTextStorage()
    let lm = ClipProbeLM()
    storage.addLayoutManager(lm)
    let tc = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    lm.addTextContainer(tc)
    let tv = ClipProbeTV(frame: NSRect(x: 0, y: 0, width: 720, height: 400), textContainer: tc)
    tv.textContainerInset = NSSize(width: 60, height: 20)
    tv.string = "Hello clip probe\nsecond line\nthird line\n"
    let scroll = NSScrollView(frame: tv.frame)
    scroll.documentView = tv
    let w = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = scroll
    w.orderBack(nil)
    let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
    scroll.cacheDisplay(in: scroll.bounds, to: rep)
    log("text view 720 pt wide, container 600 pt wide, inset 60 pt each side")
    log("clip bounding box inside NSTextView.drawBackground(in:)                : \(tv.tvClip.last.map { "x \($0.minX)..\($0.maxX), y \($0.minY)..\($0.maxY)" } ?? "none")")
    log("clip bounding box inside NSLayoutManager.drawBackground(forGlyphRange:): \(lm.lmClip.last.map { "x \($0.minX)..\($0.maxX), y \($0.minY)..\($0.maxY)" } ?? "none")")
}

/// Supplement: file -> String cost (outside the text engine, but part of "open").
func runProbeFileLoad(_ rest: [String]) {
    log("| file | String(contentsOfFile:encoding:.utf8) | Data + String(decoding:as:UTF8) | NSString(contentsOfFile:encoding:) | Data(.alwaysMapped) only |")
    log("|---|---|---|---|---|")
    for name in ["1m", "5m", "20m"] {
        let path = "\(Corpus.dir)/\(name).md"
        _ = Corpus.load(name)
        func med(_ f: () -> Void) -> Double { var t: [Double] = []; for _ in 0..<7 { t.append(ms { f() }) }; return Stats(Array(t.dropFirst())).median }
        let a = med { _ = try? String(contentsOfFile: path, encoding: .utf8) }
        let b = med { if let d = try? Data(contentsOf: URL(fileURLWithPath: path)) { _ = String(decoding: d, as: UTF8.self) } }
        let c = med { _ = try? NSString(contentsOfFile: path, encoding: String.Encoding.utf8.rawValue) }
        let d = med { _ = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) }
        log("| \(name) | \(f1(a)) | \(f1(b)) | \(f1(c)) | \(f1(d)) |")
    }
}

/// Which engine / layout mode do the stock constructors give?
func runProbeDefaults(_ rest: [String]) {
    let sv = NSTextView.scrollableTextView()
    let a = sv.documentView as? NSTextView
    log("NSTextView.scrollableTextView(): TextKit 2 = \(a?.textLayoutManager != nil)")
    let b = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    log("NSTextView(frame:): TextKit 2 = \(b.textLayoutManager != nil)")
    let c = NSTextView(usingTextLayoutManager: false)
    log("NSTextView(usingTextLayoutManager: false): TextKit 2 = \(c.textLayoutManager != nil), layoutManager.allowsNonContiguousLayout = \(c.layoutManager?.allowsNonContiguousLayout ?? false), backgroundLayoutEnabled = \(c.layoutManager?.backgroundLayoutEnabled ?? false)")
    let lm = NSLayoutManager()
    log("NSLayoutManager().allowsNonContiguousLayout = \(lm.allowsNonContiguousLayout), backgroundLayoutEnabled = \(lm.backgroundLayoutEnabled)")
}
