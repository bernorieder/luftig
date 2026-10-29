#if LUFTIG_SELFTEST
// SelfTestAuditEditorRegress.swift - regression tests of the defects the editor audit found (each one FAILS on the baseline sources), plus
// the measurements that back the findings. Real key events through NSWindow.sendEvent, real scrolling, real preference changes.

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorRegressScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-nested-style", summary: "editor audit: a font size change with code blocks around the viewport leaves no line laid out with stale attributes (nested styling inside an edit cycle)", run: { t in try await auditNestedStyle(t) }),
        .init(name: "audit-perf-cjk", summary: "editor audit: what the font fallback fix costs - open, scroll, jump and typing in a 3 MB Chinese / Japanese / emoji document and in a 3 MB Latin document", run: { t in try await auditPerfCJK(t) }, inAll: false),
        .init(name: "audit-drop-kinds", summary: "editor audit: dropping a file, an image and a web link on the editor leaves plain text only (no attachment characters, no stray attributes)", run: { t in try await auditDropKinds(t) }),
        .init(name: "audit-undo-run", summary: "editor audit: typing through real key events with implicit (per event) undo groups: one undo takes back the whole typing run", run: { t in try await auditUndoRun(t) }),
    ]

    /// A document with a fenced code block, a quote and a heading every few lines, so that wherever the viewport sits the margin around it holds
    /// block boundaries.
    static func auditBlocksText(lines: Int) -> String {
        var out = "# Title\n\n"
        var i = 0
        while out.utf8.count < lines * 28 {
            i += 1
            out += "Paragraph \(i) with some words in it and more.\n\n```swift\nlet value\(i) = \(i)\nprint(value\(i))\n```\n\n> quote \(i)\n\n## Heading \(i)\n\n"
        }
        return out
    }

    /// Cmd-+ / Cmd-- at many scroll positions: every line fragment around the viewport must equal a fresh layout of a copy (same character range,
    /// width, used rect). The baseline styles from inside the layout manager's own callbacks during the font size change, and the layout manager
    /// keeps a layout computed from the OLD attributes for part of the lines it was styled for (code lines with the body font and no indent).
    @MainActor static func auditNestedStyle(_ t: SelfTest.T) async throws {
        let savedSize = EditorPreferences.fontSize, savedRW = EditorPreferences.readableWidth
        defer { EditorPreferences.fontSize = savedSize; EditorPreferences.readableWidth = savedRW }
        EditorPreferences.readableWidth = false
        var bad = 0, checked = 0
        var first: [String] = [], firstPixels: [String] = []
        var pixelBad = 0, rectBad = 0
        // small documents (a few KB: the whole text is inside the +- 60 lines margin of the styler, so the margin edge is exactly where the
        // blocks are), wide short windows
        let docs: [(String, String)] = (1...3).map { ("corpus \($0)", SelfTestCorpus.markdown(bytes: 3500 + $0 * 300, seed: UInt64($0) &+ 90)) } + [("blocks", auditBlocksText(lines: 160))]
        for (name, text) in docs {
            for (w, h) in [(1209.0, 307.0), (900.0, 420.0)] {
                EditorPreferences.fontSize = 9
                let (doc, host, _) = try await openEditor(t, text: text, name: "audit-nested.md", size: NSSize(width: w, height: h))
                let sv = host.scrollView
                let docHeight = host.textView.frame.height
                var y: CGFloat = 0
                while y < docHeight {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
                    host.styler.styleVisible()
                    host.luftigIncreaseFontSize(nil)
                    checked += 1
                    if let m = AuditEd.visibleLayoutMismatch(host) {
                        bad += 1
                        if first.count < 2 { first.append("\(name) \(Int(w))x\(Int(h)), scroll y=\(Int(y)), size \(host.fontSize): \(m)") }
                    }
                    // what the person sees: the window as it is vs the same window after EVERYTHING was laid out from scratch (same attributes)
                    if let win = doc.windowControllers.first?.window, let lm = host.textView.layoutManager, let len = host.textView.textStorage?.length {
                        host.styler.styleVisible()
                        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: len))
                        /// every line fragment of the whole text: character range -> rect
                        func lineRects() -> [NSRange: NSRect] {
                            var m: [NSRange: NSRect] = [:]
                            lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { r, _, _, gr, _ in
                                let chars = lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                                if let s = lm.textStorage, AuditEd.touchesDrawnTable(chars, s) { return }      // (drawn tables / images: see AuditEd.visibleLayoutMismatch)
                                m[chars] = r
                            }
                            return m
                        }
                        if let a = pixels(win) {
                            let originBefore = sv.contentView.bounds.origin, rectsBefore = lineRects()
                            lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: len), actualCharacterRange: nil)
                            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: len))
                            // Every line fragment must be exactly where the fresh layout puts it. (The scroll position is put back first: while TextKit
                            // re-lays out text above the viewport it may move the clip view by a point or two to keep its anchor - that is its own
                            // scroll anchoring, not a stale layout, and it only happens in this test's invalidate-everything step.)
                            if lineRects() != rectsBefore { rectBad += 1; if firstPixels.count < 2 { firstPixels.append("\(name) \(Int(w))x\(Int(h)) y=\(Int(y)): line fragments differ from a fresh layout") } }
                            if sv.contentView.bounds.origin != originBefore { sv.contentView.scroll(to: originBefore); sv.reflectScrolledClipView(sv.contentView) }
                            host.textView.needsDisplay = true
                            if var b = pixels(win) {
                                // (the overlay scroller at the right edge is not text: blank 40 device pixels there in both renderings)
                                var a = a
                                for y in 0..<a.h { for x in max(0, a.w - 40)..<a.w { for c in 0..<4 { a.data[(y * a.w + x) * 4 + c] = 0; b.data[(y * b.w + x) * 4 + c] = 0 } } }
                                let d = pixelDiff(a, b)
                                if d.count != 0 { pixelBad += 1; if firstPixels.count < 2 { firstPixels.append("\(name) \(Int(w))x\(Int(h)) y=\(Int(y)): \(d.count) px differ in \(d.box)") } }
                            }
                        }
                    }
                    host.luftigDecreaseFontSize(nil)
                    y += 61
                }
                t.close(doc)
            }
        }
        // the mechanism itself: a styling request that arrives from INSIDE an edit cycle (the layout manager's own callbacks do that:
        // scrollRangeToVisible, the clip view's bounds notification) must not edit the storage nested in it; it is postponed to the end of
        // the run loop turn and the visible text is styled then, without anyone asking again
        do {
            let (doc, host, _) = try await openEditor(t, text: SelfTestCorpus.markdown(bytes: 400_000, seed: 77), name: "audit-nested-mech.md", size: NSSize(width: 860, height: 500))
            let tv = host.textView, ts = tv.textStorage!
            nonisolated(unsafe) let tsU = ts           // (the observers below run on the main thread, in the same call as `AuditEd.type`)
            let far = ts.length * 3 / 4
            var nestedTouched = false, requests = 0
            // an observer of the storage's own notification runs INSIDE processEditing, exactly where AppKit calls scrollRangeToVisible
            let obs = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: ts, queue: nil) { _ in
                guard tsU.editedMask.contains(.editedCharacters) else { return }
                requests += 1
                let before = host.styler.styled
                host.styler.prestyle(aroundCharacter: far)
                host.styler.styleVisible()
                if host.styler.styled.intersection(IndexSet(integersIn: (far - 10)..<(far + 10))) != before.intersection(IndexSet(integersIn: (far - 10)..<(far + 10))) { nestedTouched = true }
            }
            tv.setSelectedRange(NSRange(location: 5, length: 0))
            AuditEd.type(host, "x")
            NotificationCenter.default.removeObserver(obs)
            t.check(requests > 0 && !nestedTouched, "a styling request from inside an edit cycle is not applied nested in it (requests \(requests), applied nested: \(nestedTouched))")
            host.styler.reset()                                      // (everything unstyled; the visible text must come back by itself)
            let obs2 = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: ts, queue: nil) { _ in
                if tsU.editedMask.contains(.editedCharacters) { host.styler.styleVisible() }
            }
            AuditEd.type(host, "y")
            NotificationCenter.default.removeObserver(obs2)
            await t.spin(20)
            let vis = host.styler.visibleCharacterRange(tv)
            t.check(vis.length > 0 && host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)), "... and the postponed request styles the visible text at the end of the turn, nobody asks again")
            t.close(doc)
        }
        t.check(bad == 0, "\(checked) font size changes over 4 small documents x 2 windows x every scroll position: the laid-out lines around the viewport equal a fresh layout (\(bad) differ) \(first)")
        t.check(rectBad == 0, "... and so does every line fragment of the whole text (\(rectBad) of \(checked) differ)")
        t.check(pixelBad == 0, "... and the window looks exactly like the same window laid out from scratch (\(pixelBad) of \(checked) renderings differ) \(firstPixels)")
    }

    /// A Markdown document of mostly CJK text (every line is 20-60 CJK characters), with headings, lists, quotes, code and emoji.
    static func auditCJKText(bytes: Int, seed: UInt64) -> String {
        var r = TestRNG(seed)
        let han = Array("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工体制机使业性应它合因由政四社义平形相表间关各重新线内数正反利比或质气第向命变条结解问建系军很情者最立代通并提直题党程展五果料象员革位入常总次品式活设及管特件求基资边流路级少图山统接知较组见计别角期根论运农指几九区强放决西被干做必战先则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酿历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严")
        let jp = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんアイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン日本語漢字文章編集保存開く")
        var out = "# 日本語と中文のメモ\n\n"
        while out.utf8.count < bytes {
            let n = 20 + r.int(40)
            var line = ""
            for _ in 0..<n { line.append(r.chance(70) ? r.pick(han) : r.pick(jp)); if r.chance(3) { line += r.pick(["😀", "🎉", "👩\u{200D}💻", "✅"]) } }
            switch r.int(12) {
            case 0: out += "## " + String(line.prefix(30)) + "\n\n"
            case 1: out += "- " + line + "\n- " + String(line.prefix(20)) + "\n\n"
            case 2: out += "> " + line + "\n\n"
            case 3: out += "```\n" + line + "\n```\n\n"
            case 4: out += "**" + String(line.prefix(10)) + "** `" + String(line.suffix(8)) + "` " + line + "\n\n"
            default: out += line + "\n\n"
            }
        }
        return out
    }

    @MainActor static func perfMs(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
    }

    @MainActor static func auditPerfCJK(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 3_000_000
        for (label, text) in [("CJK", auditCJKText(bytes: bytes, seed: 7)), ("Latin", SelfTestCorpus.markdown(bytes: bytes, seed: 7, nonASCII: false))] {
            let url = t.write(text, to: "perf-\(label).md")
            var opens: [Double] = []
            var doc: MarkdownDocument? = nil
            for _ in 0..<5 {
                if let d = doc { t.close(d) }
                let t0 = SelfTest.nowMs()
                let d = try await t.open(url, size: NSSize(width: 860, height: 700))
                opens.append(SelfTest.nowMs() - t0)
                doc = d
            }
            guard let doc, let host = doc.host as? EditorViewController else { t.check(false, "no editor"); return }
            let tv = host.textView, sv = host.scrollView
            let len = (tv.string as NSString).length
            t.note("\(label): \(bytes) bytes, \(len) units; open + window + first screen styled: median \(String(format: "%.1f", opens.sorted()[2])) ms (\(opens.map { String(format: "%.0f", $0) }.joined(separator: ", ")))")
            // scrolling: 60 steps of a third of a screen (what boundsDidChange does: style, then layout of the visible part)
            var steps: [Double] = []
            var y: CGFloat = 0
            for _ in 0..<60 {
                y += 230
                steps.append(perfMs { sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView); tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!) })
            }
            steps.sort()
            t.note("\(label): scrolling 60 x 230 pt (style + layout): median \(String(format: "%.2f", steps[30])) ms, p95 \(String(format: "%.2f", steps[56])) ms, max \(String(format: "%.2f", steps[59])) ms")
            // jumps to random places far away
            var rng = TestRNG(3)
            if SelfTest.flag("perf-jump-loop") && label == "CJK" {
                t.note("jump loop for sampling (pid \(getpid()))")
                let end = SelfTest.nowMs() + 20_000
                while SelfTest.nowMs() < end { let loc = rng.int(len); tv.scrollRangeToVisible(NSRange(location: loc, length: 0)); host.styler.styleVisible(); tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!) }
            }
            var jumps: [Double] = []
            func fontRuns() -> (count: Int, first: Int, last: Int) {
                var n = 0, first = Int.max, last = -1
                tv.textStorage!.enumerateAttribute(.font, in: NSRange(location: 0, length: len), options: []) { v, r, _ in
                    if let f = v as? NSFont, f.fontName != host.theme.bodyFont.fontName { n += 1; first = min(first, r.location); last = max(last, NSMaxRange(r)) }
                }
                return (n, first, last)
            }
            for _ in 0..<20 {
                let loc = rng.int(len)
                let before: (count: Int, first: Int, last: Int) = SelfTest.flag("perf-jumps") ? fontRuns() : (0, 0, 0)
                jumps.append(perfMs { tv.scrollRangeToVisible(NSRange(location: loc, length: 0)); host.styler.styleVisible(); tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!) })
                if SelfTest.flag("perf-jumps") && label == "CJK" { let after = fontRuns(); t.note("   jump to \(loc): \(String(format: "%.0f", jumps.last!)) ms; fallback-font runs \(before.count) -> \(after.count), span \(before.first)...\(before.last) -> \(after.first)...\(after.last); styled \(host.styler.styled.rangeView.count) ranges") }
            }
            if SelfTest.flag("perf-jumps") { t.note("\(label): jumps in order (ms): \(jumps.map { String(format: "%.0f", $0) }.joined(separator: ", "))") }
            jumps.sort()
            t.note("\(label): 20 random jumps: median \(String(format: "%.1f", jumps[10])) ms, max \(String(format: "%.1f", jumps[19])) ms")
            // typing 100 characters in the middle through real key events
            tv.setSelectedRange(NSRange(location: ((tv.string as NSString).lineRange(for: NSRange(location: len / 2, length: 0))).location, length: 0))
            tv.scrollRangeToVisible(tv.selectedRange())
            if SelfTest.flag("perf-loop") && label == "CJK" {
                t.note("typing loop for sampling (pid \(getpid()))")
                let end = SelfTest.nowMs() + 12_000
                while SelfTest.nowMs() < end { AuditEd.press(host, "a") }
            }
            var keys: [Double] = []
            for ch in "hello world, typing in the middle of the document with some words and more words to type until one hundred".prefix(100) {
                keys.append(perfMs { AuditEd.press(host, String(ch)) })
            }
            keys.sort()
            t.note("\(label): 100 keystrokes (real key events, restyle + layout of the edited line): median \(String(format: "%.2f", keys[50])) ms, p95 \(String(format: "%.2f", keys[95])) ms, max \(String(format: "%.2f", keys[99])) ms")
            // budgets: the Latin document keeps the DESIGN.md budget (8 ms); the CJK document pays for the font fallback of the edited paragraph
            // (measured 14 ms; 35 ms when every run of the paragraph is rewritten, 7.8 ms when the fallback is not restored at all and the
            // text is invisible). Timing assertions are load sensitive: this scenario is not part of `all`.
            t.check(keys[50] < (label == "CJK" ? 25 : 8), "\(label): median keystroke \(String(format: "%.1f", keys[50])) ms is within the budget (\(label == "CJK" ? 25 : 8) ms)")
            var cjk: [Double] = []
            AuditEd.pressKey(host, AuditEd.Key.returnKey)
            for ch in "这是一个关于编辑器的测试，日本語の文章も入力します。😀".prefix(40) { cjk.append(perfMs { AuditEd.press(host, String(ch)) }) }
            cjk.sort()
            t.note("\(label): typing \(cjk.count) CJK / emoji characters: median \(String(format: "%.2f", cjk[cjk.count / 2])) ms, max \(String(format: "%.2f", cjk[cjk.count - 1])) ms")
            let r = AuditEd.styledMismatches(host)
            t.check(r.bad == 0, "\(label): after all that, \(r.compared) styled runs equal a fresh lex (\(r.bad) differ)")
            t.close(doc)
        }
    }

    /// Things a person drags onto a text editor: a file from Finder, an image, a link from a browser. (Rich text / HTML / RTFD attachments are
    /// covered by the clipboard scenario; converting those makes AppKit's out-of-process nsattributedstringagent log a fault report for
    /// attachments, which is not something to leave in the user's DiagnosticReports once more.)
    /// The editor is plain text: whatever lands must be plain characters - never an attachment (U+FFFC), never an attribute that is not the
    /// Theme's. (Private pasteboards, the dragging-destination calls with a stub NSDraggingInfo.)
    @MainActor static func auditDropKinds(_ t: SelfTest.T) async throws {
        let (doc, host, _) = try await openEditor(t, text: "alpha beta\n\ndelta epsilon\n", name: "audit-drop.md")
        guard let window = host.view.window else { t.check(false, "no window"); return }
        let tv = host.textView, ts = tv.textStorage!
        let fileURL = t.write("dragged file content\n", to: "dragged file.txt")
        let tiff: Data = {
            let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
            return img.tiffRepresentation ?? Data()
        }()
        let kinds: [(String, (NSPasteboard) -> Void)] = [
            ("file URL", { pb in pb.writeObjects([fileURL as NSURL]) }),
            ("image (TIFF)", { pb in pb.declareTypes([.tiff], owner: nil); pb.setData(tiff, forType: .tiff) }),
            ("web link", { pb in pb.declareTypes([.URL, .string], owner: nil); pb.setString("https://example.com/page", forType: .URL); pb.setString("https://example.com/page", forType: .string) }),
            ("plain text", { pb in pb.declareTypes([.string], owner: nil); pb.setString("dropped text", forType: .string) }),
        ]
        let pb = AuditEd.privatePasteboard()
        defer { pb.releaseGlobally() }
        for (label, fill) in kinds {
            tv.undoManager?.disableUndoRegistration(); ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: "alpha beta\n\ndelta epsilon\n"); tv.undoManager?.enableUndoRegistration(); tv.undoManager?.removeAllActions()
            host.styler.reset(); host.styler.styleVisible()
            pb.clearContents()
            fill(pb)
            guard let lm = tv.layoutManager else { continue }
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: ts.length))
            let g = lm.glyphIndexForCharacter(at: ("alpha beta\n\ndelta " as NSString).length)
            let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let point = tv.convert(NSPoint(x: tv.textContainerOrigin.x + r.minX + lm.location(forGlyphAt: g).x + 1, y: tv.textContainerOrigin.y + r.midY), to: nil)
            let info = AuditDraggingInfo(window: window, pasteboard: pb, location: point, source: nil, mask: [.copy, .generic])
            // (the drag feedback caches the pixels under the drag caret with `lockFocus` - NSTextView's classic caret path, pitfall 33 - which needs a window
            // with a window number: ordered front, far outside every screen, for the drop)
            AuditEd.orderFrontOffscreen(window)
            let op = tv.draggingEntered(info)
            var ok = false
            tv.undoManager?.beginUndoGrouping()
            if op != [] { ok = tv.prepareForDragOperation(info) && tv.performDragOperation(info); tv.concludeDragOperation(info) }
            window.orderOut(nil)
            tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
            let after = tv.string
            var attachments = 0
            ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length), options: []) { v, _, _ in if v != nil { attachments += 1 } }
            let hasFFFC = after.contains("\u{FFFC}")
            t.note("\(label): draggingEntered \(op.rawValue), perform \(ok): \((after as NSString).substring(from: 18).debugDescription)")
            t.check(attachments == 0 && !hasFFFC, "\(label): no attachment character / attribute lands in the document (attachments \(attachments), U+FFFC \(hasFFFC))")
            await AuditEd.settle(t, host)
            let mm = AuditEd.styledMismatches(host)
            t.check(mm.bad == 0, "\(label): after the drop styled == fresh lex (\(mm.bad) differ) \(mm.first.map { "\(NSStringFromRange($0.range)) expected [\($0.expected)] actual [\($0.actual)]" })")
        }
        t.close(doc)
    }

    /// Undo granularity as a person experiences it: keys arrive one per event, the undo manager closes its implicit group at the end of each
    /// event, NSTextView coalesces the typing into one undo step.
    @MainActor static func auditUndoRun(_ t: SelfTest.T) async throws {
        let (doc, host, _) = try await openEditor(t, text: "start\n", name: "audit-undo-run.md")
        guard let um = doc.undoManager, let window = host.view.window else { t.check(false, "no undo manager / window"); return }
        let tv = host.textView
        um.groupsByEvent = true
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        for ch in "hello world" {
            window.sendEvent(AuditEd.keyEvent(window, characters: String(ch), code: 0))
            await t.spin(3)
        }
        t.check(tv.string == "start\nhello world", "typed: \(tv.string.debugDescription)")
        t.note("undo groups open: \(um.groupingLevel); canUndo \(um.canUndo)")
        um.undo()
        t.note("after ONE undo: \(tv.string.debugDescription)")
        t.check(tv.string == "start\n", "one undo takes back the whole typing run")
        um.redo()
        t.check(tv.string == "start\nhello world", "redo brings it back: \(tv.string.debugDescription)")
        um.groupsByEvent = false
        t.close(doc)
    }
}
#endif
