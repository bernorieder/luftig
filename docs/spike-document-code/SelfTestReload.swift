// SelfTestReload.swift - external change of a CLEAN document: the writer matrix, UX (selection/scroll/undo), presenter path.

import AppKit

extension SelfTestScenarios {
    static let reloadScenarios: [SelfTest.Scenario] = [
        .init(name: "reload-clean", summary: "clean doc + real external writers (append, truncate, atomic, rm+create, rename, touch -r, burst, 10 MB)", run: { t in try await reloadClean(t) }),
        .init(name: "reload-ux", summary: "selection, scroll anchor, undo stack and dirty flag across a reload; 1 MB / 10 MB apply cost", run: { t in try await reloadUX(t) }),
        .init(name: "reload-tk2", summary: "the same selection/scroll-anchor checks on a TextKit 2 text view (best effort, never-shown window)", run: { t in try await reloadTK2(t) }),
        .init(name: "reload-triggers", summary: "presenter-only, activation-only, coordinated (NSFileCoordinator) writer, symlinked folder, re-arm after atomic replace", run: { t in try await reloadTriggers(t) }),
    ]

    private struct Writer {
        let name: String
        let command: (_ f: String, _ t: SelfTest.T) -> String
        var expectedReloads: ClosedRange<Int> = 1...1
        var settleMs: Double = 1500
        var maxLatencyMs: Double = 400
    }

    /// Latency of the first reload trace after `since`, measured from `done` (writer finished).
    @MainActor private static func firstReloadTrace(_ t: SelfTest.T, since: Double) -> (t: Double, msg: String)? {
        t.traces.first { $0.t >= since && ($0.msg.hasPrefix("silent reload") || $0.msg.hasPrefix("revert(")) }.map { ($0.t, $0.msg) }
    }

    @MainActor static func reloadClean(_ t: SelfTest.T) async throws {
        let base = "# Title\n\nline one\nline two\nline three\n"
        let writers: [Writer] = [
            .init(name: "a append in place", command: { f, _ in "printf 'appended %s\\n' $RANDOM >> \(f)" }),
            .init(name: "b truncate + rewrite", command: { f, _ in "printf 'rewritten %s\\n' $RANDOM > \(f)" }),
            .init(name: "c atomic replace (tmp + mv)", command: { f, _ in "printf 'atomic %s\\n' $RANDOM > \(f).tmp && mv \(f).tmp \(f)" }),
            .init(name: "d1 delete, 50 ms, recreate", command: { f, _ in "rm \(f); sleep 0.05; printf 'recreated %s\\n' $RANDOM > \(f)" }),
            .init(name: "d2 delete + recreate immediately", command: { f, _ in "rm \(f); printf 'recreated %s\\n' $RANDOM > \(f)" }),
            .init(name: "e rename away, edit, rename back", command: { f, _ in "mv \(f) \(f).away; sleep 0.2; printf 'renamed-back %s\\n' $RANDOM > \(f).away; mv \(f).away \(f)" }),
            .init(name: "f same size + same mtime (touch -r)", command: { f, _ in
                "cp -p \(f) \(f).ref; n=$(wc -c < \(f)); printf '%0*d' $((n-1)) $((RANDOM%9+1)) > \(f); echo >> \(f); touch -r \(f).ref \(f); rm \(f).ref" }),
            .init(name: "g burst: 20 writes in 1 s", command: { f, _ in "for i in $(seq 1 20); do printf 'burst %s\\n' $i >> \(f); sleep 0.05; done" },
                  expectedReloads: 1...7, settleMs: 1200, maxLatencyMs: 400),
        ]
        for w in writers {
            let file = t.write(base, to: "doc-\(w.name.prefix(2).trimmingCharacters(in: .whitespaces)).md")
            let f = t.q(file)
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no editor host"); continue }
            t.check(doc.monitor != nil, "\(w.name): monitor armed after open")
            await t.sleep(150)
            t.info("--- \(w.name)")
            for round in 1...2 {
                host.textView.setSelectedRange(NSRange(location: 3, length: 0))
                let reloads0 = doc.stats.silentReloads
                let start = SelfTest.nowMs()
                let done = await t.sh(w.command(f, t))
                _ = await t.waitFor(w.name.hasPrefix("g") ? 3000 : 3000) { doc.stats.silentReloads > reloads0 && host.currentText.isEqual(to: t.read(file)) }
                await t.sleep(w.settleMs)       // long enough for the NSFilePresenter echo (~1.1 s): must NOT cause a second reload
                let reloads = doc.stats.silentReloads - reloads0
                let tr = firstReloadTrace(t, since: start)
                let latency = tr.map { $0.t - done }
                t.check(w.expectedReloads.contains(reloads), "\(w.name) round \(round): reloads=\(reloads) (expected \(w.expectedReloads)), first reload \(latency.map { String(format: "%.0f ms", $0) } ?? "NEVER") after the writer finished, via \(doc.stats.lastReloadTrigger)")
                t.check(host.currentText.isEqual(to: t.read(file)), "\(w.name) round \(round): editor text equals the file")
                t.check(!doc.isDocumentEdited, "\(w.name) round \(round): document is not dirty")
                if let latency, !w.name.hasPrefix("g") { t.check(latency < w.maxLatencyMs, "\(w.name) round \(round): latency \(Int(latency)) ms < \(Int(w.maxLatencyMs)) ms") }
                t.check(UITrap.alerts.isEmpty && UITrap.panels.isEmpty, "\(w.name) round \(round): no alert/sheet/panel was shown")
            }
            t.note("\(w.name): monitor events=\(doc.monitor?.eventCount ?? 0) deliveries=\(doc.monitor?.deliveryCount ?? 0) rebinds=\(doc.monitor?.rebindCount ?? 0); stat-only=\(doc.stats.statUnchanged) hash-equal(no reload)=\(doc.stats.hashUnchanged)")
            t.close(doc)
        }

        // h: big files (10 MB). h1: tool regenerates the file with a small change; h2: completely different content (worst case)
        func bigFile(_ seed: Int, changeAt: Int?) -> Data {
            var lines: [String] = []
            lines.reserveCapacity(150_000)
            for i in 0..<150_000 { lines.append("Line \(i) - the quick brown fox jumps over the lazy dog \(i * 7919 % 10007) and more words to fill it up") }
            if let c = changeAt { lines[c] = "Line \(c) - CHANGED BY AN EXTERNAL TOOL" }
            if seed != 0 { for i in 0..<lines.count { lines[i] = "S\(seed) " + lines[i] } }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }
        let a = bigFile(0, changeAt: nil)
        t.info("--- h 10 MB (\(a.count / 1_000_000) MB, 150k lines)")
        let bigURL = t.write(data: a, to: "big.md")
        t.write(data: bigFile(0, changeAt: 75_000), to: "big-h1.tmp")
        t.write(data: bigFile(1, changeAt: nil), to: "big-h2.tmp")
        let tOpen = SelfTest.nowMs()
        let doc = try await t.open(bigURL)
        t.note("open 10 MB incl. window + text view: \(Int(SelfTest.nowMs() - tOpen)) ms")
        guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
        await t.sleep(200)
        for (label, tmp) in [("h1 small change in the middle", "big-h1.tmp"), ("h2 everything different", "big-h2.tmp")] {
            let reloads0 = doc.stats.silentReloads
            let startH = SelfTest.nowMs()
            let done = await t.sh("cp \(t.q(t.url(tmp))) \(t.q(t.url("big.md.tmp"))) && mv \(t.q(t.url("big.md.tmp"))) \(t.q(bigURL))")
            let ok = await t.waitFor(8000) { doc.stats.silentReloads > reloads0 }
            let latency = firstReloadTrace(t, since: startH).map { $0.t - done }
            let apply = doc.stats.lastApply
            t.check(ok, "\(label): reloaded, latency \(latency.map { String(format: "%.0f ms", $0) } ?? "?") after the writer finished (apply: \(apply.map { String(format: "diff %.1f ms, total %.1f ms, %d edit(s), %d units", $0.diffSeconds * 1000, $0.seconds * 1000, $0.edits, $0.changedUnits) } ?? "?"))")
            t.check(host.currentText.isEqual(to: t.read(bigURL)), "\(label): editor text equals the file")
            t.check(!doc.isDocumentEdited, "\(label): not dirty")
            await t.sleep(1300)
            t.equal(doc.stats.silentReloads - reloads0, 1, "\(label): exactly one reload (presenter echo is a no-op)")
        }
        t.close(doc)
    }

    // MARK: UX

    @MainActor static func reloadUX(_ t: SelfTest.T) async throws {
        func lineText(_ i: Int) -> String { "Line \(i): " + String(repeating: "lorem ipsum dolor sit amet ", count: 2 + i % 3) }
        func makeText(_ n: Int, insertAbove: Int = 0, changeLine: (Int, String)? = nil) -> String {
            var ls = (0..<n).map(lineText)
            if let (i, s) = changeLine { ls[i] = s }
            if insertAbove > 0 { ls.insert(contentsOf: (0..<insertAbove).map { "INSERTED \($0)" }, at: 100) }
            return ls.joined(separator: "\n") + "\n"
        }
        let n = 6000
        let file = t.write(makeText(n), to: "ux.md")
        let doc = try await t.open(file, size: NSSize(width: 800, height: 600))
        guard let host = doc.host as? EditorViewController, let sv = Optional(host.scrollView) else { t.check(false, "no host"); return }
        let tv = host.textView
        func lineStart(_ i: Int) -> Int { (tv.string as NSString).range(of: "Line \(i): ").location }
        func scrollToLine(_ i: Int) {
            let r = NSRange(location: lineStart(i), length: 0)
            tv.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(tv.string.utf16.count, NSMaxRange(r) + 3000)))
            let glyph = tv.layoutManager!.glyphIndexForCharacter(at: r.location)
            let rect = tv.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            sv.contentView.scroll(to: NSPoint(x: 0, y: rect.minY + tv.textContainerOrigin.y + 7))   // 7 pt of the anchor line scrolled away
            sv.reflectScrolledClipView(sv.contentView)
        }
        func topLineText() -> String {
            guard let a = ViewportAnchor.capture(in: tv) else { return "<no anchor>" }
            let s = tv.string as NSString
            let r = s.lineRange(for: NSRange(location: a.characterIndex, length: 0))
            return s.substring(with: r).trimmingCharacters(in: .newlines)
        }
        t.info("text: \(n) lines, \((tv.string as NSString).length / 1000) K units; window 800x600")

        // 1. change ABOVE the viewport, caret + scroll in the middle
        scrollToLine(3000)
        let caretLine = 3003
        tv.setSelectedRange(NSRange(location: lineStart(caretLine) + 5, length: 4))
        let selText = (tv.string as NSString).substring(with: tv.selectedRange())
        let topBefore = topLineText()
        let yBefore = sv.contentView.bounds.origin.y
        t.check(topBefore.hasPrefix("Line 3000"), "setup: top visible line is '\(topBefore.prefix(12))'")
        let oldSel = tv.selectedRange()
        try await externalWrite(t, file, makeText(n, insertAbove: 50), doc)
        t.check(tv.string == makeText(n, insertAbove: 50), "above: editor text equals the new file")
        let shifted = oldSel.location + ("INSERTED 0\n".utf16.count * 0) + (0..<50).reduce(0) { $0 + "INSERTED \($1)\n".utf16.count }
        t.equal(tv.selectedRange(), NSRange(location: shifted, length: oldSel.length), "above: selection moved by the inserted text")
        t.equal((tv.string as NSString).substring(with: tv.selectedRange()), selText, "above: selection still covers the same characters ('\(selText)')")
        t.equal(topLineText(), topBefore, "above: the same line is still at the top of the viewport (scroll anchor)")
        let yAfter = sv.contentView.bounds.origin.y
        t.check(abs(yAfter - yBefore) > 100, "above: scroll offset really changed to compensate (\(Int(yBefore)) -> \(Int(yAfter)) pt)")
        t.check(doc.stats.lastApply?.scrollAdjusted == true, "above: report.scrollAdjusted")
        t.check(!doc.isDocumentEdited, "above: not dirty")
        t.check(doc.undoManager?.canUndo != true, "above: undo history is cleared")

        // 2. change BELOW the viewport: nothing may move
        let y2 = sv.contentView.bounds.origin.y
        let sel2 = tv.selectedRange()
        try await externalWrite(t, file, makeText(n, insertAbove: 50, changeLine: (5000, "Line 5000: CHANGED BELOW")), doc)
        t.equal(sv.contentView.bounds.origin.y, y2, "below: scroll offset untouched")
        t.equal(tv.selectedRange(), sel2, "below: selection untouched")
        t.equal(doc.stats.lastApply?.edits, 1, "below: one small edit")
        t.check(doc.stats.lastApply?.scrollAdjusted == false, "below: report.scrollAdjusted == false")

        // 3. the changed region contains the caret
        let caretLoc = lineStart(3010) + 8
        tv.setSelectedRange(NSRange(location: caretLoc, length: 0))
        try await externalWrite(t, file, makeText(n, insertAbove: 50, changeLine: (5000, "Line 5000: CHANGED BELOW")).replacingOccurrences(of: lineText(3010), with: "Line 3010: short"), doc)
        let ns = tv.string as NSString
        let l3010 = ns.range(of: "Line 3010: short")
        t.check(NSLocationInRange(tv.selectedRange().location, NSRange(location: l3010.location, length: l3010.length + 1)), "overlap: caret clamped into the rewritten line (\(tv.selectedRange().location) in \(NSStringFromRange(l3010)))")

        // 4. undo stack: the user typed, autosave made the doc clean again, THEN the file changes
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        t.typeText("TYPED ", into: doc)
        await t.sleep(30)          // the undo group (and with it NSDocument's change count) closes at the end of the run loop turn
        t.note("after typing: text starts \(tv.string.prefix(12).debugDescription), edited=\(doc.isDocumentEdited) canUndo=\(doc.undoManager?.canUndo ?? false) tvUndoManager===docUndoManager: \(tv.undoManager === doc.undoManager) hasUndoManager=\(doc.hasUndoManager) allowsUndo=\(tv.allowsUndo) groupsByEvent=\(doc.undoManager?.groupsByEvent ?? false) levels=\(doc.undoManager?.groupingLevel ?? -1)")
        t.check(doc.isDocumentEdited && doc.undoManager?.canUndo == true, "typing: dirty, undo available")
        let err = await t.autosave(doc)
        t.check(err == nil, "autosave of the typed text succeeded: \(String(describing: err))")
        await t.sleep(200)
        t.check(!doc.isDocumentEdited, "after autosave: clean")
        let diskNow = t.read(file)
        t.check(diskNow.hasPrefix("TYPED Line 0"), "autosave wrote the typed text to the file")
        try await externalWrite(t, file, diskNow.replacingOccurrences(of: "Line 1:", with: "Line ONE:"), doc)
        t.check(doc.undoManager?.canUndo != true && doc.undoManager?.canRedo != true, "reload cleared the undo history (no stale entries)")
        let afterReload = tv.string
        tv.undoManager?.undo()
        t.check(tv.string == afterReload, "Undo after reload is a no-op (nothing to corrupt)")
        t.typeText("Z", into: doc, at: NSRange(location: 10, length: 0))
        await t.sleep(30)
        let withZ = tv.string
        tv.undoManager?.undo()
        t.check(tv.string == afterReload, "type after reload, then Undo: back to the reloaded text exactly (\(withZ.utf16.count - afterReload.utf16.count) unit typed, undone)")
        t.close(doc)

        // 5. cost of the minimal-diff apply at 1 MB / 10 MB, in place (no disk): middle edit, top edit, 3 distant edits
        func big(_ units: Int) -> String {
            var s = ""; s.reserveCapacity(units + 100)
            var i = 0
            while s.utf16.count < units { s += lineText(i) + "\n"; i += 1 }
            return s
        }
        for (label, size) in [("1 MB", 1_000_000), ("10 MB", 10_000_000)] {
            let bigText = big(size)
            let f2 = t.write(bigText, to: "apply-\(size).md")
            let d2 = try await t.open(f2, size: NSSize(width: 800, height: 600))
            guard let h2 = d2.host as? EditorViewController else { continue }
            let units = (h2.textView.string as NSString).length
            func measure(_ what: String, _ new: String) {
                let report = h2.applyExternalText(new as NSString, mode: .silent)
                t.note(String(format: "%@ (%d K units) %@: diff %.2f ms, apply total %.2f ms (%d edit(s), %d units replaced)", label, units / 1000, what, report.diffSeconds * 1000, report.seconds * 1000, report.edits, report.changedUnits))
                t.check(h2.textView.string == new, "\(label) \(what): text equals target")
            }
            let ns = bigText as NSString
            let mid = ns.length / 2
            let line = ns.lineRange(for: NSRange(location: mid, length: 0))
            measure("one line changed in the middle", ns.replacingCharacters(in: line, with: "A CHANGED LINE IN THE MIDDLE\n"))
            measure("one line changed at the top", (h2.textView.string as NSString).replacingCharacters(in: NSRange(location: 0, length: 20), with: "TOP"))
            let cur = h2.textView.string as NSString
            let l1 = cur.lineRange(for: NSRange(location: cur.length / 5, length: 0)), l2 = cur.lineRange(for: NSRange(location: cur.length / 2, length: 0)), l3 = cur.lineRange(for: NSRange(location: cur.length * 4 / 5, length: 0))
            var three = cur.replacingCharacters(in: l3, with: "THIRD\n") as NSString
            three = three.replacingCharacters(in: l2, with: "SECOND\n") as NSString
            three = three.replacingCharacters(in: l1, with: "FIRST\n") as NSString
            measure("3 distant lines changed", three as String)
            measure("append 1 line", (three as String) + "appended\n")
            // viewport in the MIDDLE of the document, change ABOVE it (scroll anchor must be restored)
            let tv2 = h2.textView, sv2 = h2.scrollView, lm2 = tv2.layoutManager!
            let midChar = (tv2.string as NSString).length / 2
            let tJump = SelfTest.nowMs()
            lm2.ensureLayout(forCharacterRange: NSRange(location: 0, length: midChar + 2000))      // what a "jump to middle" costs once
            let g = lm2.glyphIndexForCharacter(at: midChar)
            let r = lm2.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            sv2.contentView.scroll(to: NSPoint(x: 0, y: r.minY + tv2.textContainerOrigin.y)); sv2.reflectScrolledClipView(sv2.contentView)
            t.note(String(format: "%@: scrolling a never-visited middle of the document into view (layout of everything above it): %.0f ms - TextKit 1 cost, not ours", label, SelfTest.nowMs() - tJump))
            let topBefore = ViewportAnchor.capture(in: tv2)?.characterIndex ?? -1
            var above = h2.textView.string as NSString
            above = above.replacingCharacters(in: NSRange(location: 20, length: 0), with: "INSERTED ABOVE THE VIEWPORT\n" + String(repeating: "more inserted\n", count: 50)) as NSString
            let rep = h2.applyExternalText(above, mode: .silent)
            let topAfter = ViewportAnchor.capture(in: tv2)?.characterIndex ?? -1
            t.note(String(format: "%@ viewport in the middle, 51 lines inserted above: diff %.2f ms, apply+selection+scroll-anchor restore %.2f ms, scrollAdjusted=%@", label, rep.diffSeconds * 1000, rep.seconds * 1000, rep.scrollAdjusted ? "yes" : "no"))
            t.check(topAfter == topBefore + (above.length - (tv2.string as NSString).length) + ((tv2.string as NSString).length - (above.length - 0)) || topAfter > topBefore, "\(label): anchor line stays at the top of the viewport after the insert above (char \(topBefore) -> \(topAfter))")
            t.close(d2)
        }
    }

    /// Minimal TextKit 2 host (NSTextView(usingTextLayoutManager: true)) conforming to the same protocol.
    final class TK2Host: TextViewEditorHost {
        let textView: NSTextView
        let scrollView = NSScrollView()
        let window: NSWindow
        init() {
            textView = NSTextView(usingTextLayoutManager: true)
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = NSSize(width: 0, height: 0); textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = true
            textView.allowsUndo = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = scrollView
            scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func showBanner(_ banner: EditorBanner) {}
        func hideBanner() {}
    }

    @MainActor static func reloadTK2(_ t: SelfTest.T) async throws {
        func lineText(_ i: Int) -> String { "Line \(i): " + String(repeating: "lorem ipsum dolor sit amet ", count: 2 + i % 3) }
        let n = 3000
        let base = (0..<n).map(lineText).joined(separator: "\n") + "\n"
        let host = TK2Host()
        let tv = host.textView
        t.check(tv.textLayoutManager != nil, "text view is TextKit 2 (textLayoutManager present)")
        host.loadInitialText(base as NSString)
        guard let tlm = tv.textLayoutManager, let cm = tlm.textContentManager else { t.check(false, "no TK2 managers"); return }
        tlm.ensureLayout(for: tlm.documentRange)
        t.note("TK2: laid out \(n) lines, usedRect height \(Int(tlm.usageBoundsForTextContainer.height)) pt, tv frame \(tv.frame.size)")
        // scroll line 1500 to the top
        let idx = (tv.string as NSString).range(of: "Line 1500: ").location
        guard let loc = cm.location(cm.documentRange.location, offsetBy: idx), let frag = tlm.textLayoutFragment(for: loc) else { t.check(false, "no fragment"); return }
        host.scrollView.contentView.scroll(to: NSPoint(x: 0, y: frag.layoutFragmentFrame.minY + tv.textContainerOrigin.y + 5))
        host.scrollView.reflectScrolledClipView(host.scrollView.contentView)
        func topLine() -> String {
            guard let a = ViewportAnchor.capture(in: tv) else { return "<no anchor>" }
            let s = tv.string as NSString
            return s.substring(with: s.lineRange(for: NSRange(location: a.characterIndex, length: 0))).trimmingCharacters(in: .newlines)
        }
        let before = topLine()
        t.note("TK2: visible rect \(tv.visibleRect), top line before: '\(before.prefix(14))'")
        t.check(before.hasPrefix("Line 1500"), "TK2: scroll anchor capture finds the top visible line")
        tv.setSelectedRange(NSRange(location: idx + 7, length: 3))
        let sel = (tv.string as NSString).substring(with: tv.selectedRange())
        var new = base
        new = (new as NSString).replacingCharacters(in: NSRange(location: 10, length: 0), with: (0..<40).map { "INSERTED \($0)\n" }.joined()) as String
        let oldTop = tlm.textLayoutFragment(for: cm.location(cm.documentRange.location, offsetBy: idx)!)?.layoutFragmentFrame.minY ?? -1
        let rep = host.applyExternalText(new as NSString, mode: .silent)
        let newIdx = idx + (0..<40).reduce(0) { $0 + "INSERTED \($1)\n".utf16.count }
        let locN = cm.location(cm.documentRange.location, offsetBy: newIdx)!
        let a1 = tlm.textLayoutFragment(for: locN)?.layoutFragmentFrame.minY ?? -1
        tlm.ensureLayout(for: NSTextRange(location: cm.documentRange.location, end: cm.location(locN, offsetBy: 1)!)!)
        let a2 = tlm.textLayoutFragment(for: locN)?.layoutFragmentFrame.minY ?? -1
        tlm.ensureLayout(for: tlm.documentRange)
        let a3 = tlm.textLayoutFragment(for: locN)?.layoutFragmentFrame.minY ?? -1
        t.note("TK2 fragment y of the anchor line: before edit \(oldTop); after edit (no ensure) \(a1); after partial ensureLayout \(a2); after full ensureLayout \(a3)")
        t.check(tv.string == new, "TK2: text equals target")
        t.equal((tv.string as NSString).substring(with: tv.selectedRange()), sel, "TK2: selection still covers '\(sel)'")
        t.note("TK2 \(ViewportAnchor.lastDebug); report: \(rep.edits) edit(s), scrollAdjusted=\(rep.scrollAdjusted); clip y now \(host.scrollView.contentView.bounds.origin.y), tv frame \(tv.frame.size)")
        t.equal(topLine(), before, "TK2: same line at the top of the viewport after an insert above (scrollAdjusted=\(rep.scrollAdjusted))")
    }

    /// Write `text` to `file` atomically (what editors do), wait for the document to show it.
    @MainActor private static func externalWrite(_ t: SelfTest.T, _ file: URL, _ text: String, _ doc: MarkdownDocument) async throws {
        let reloads0 = doc.stats.silentReloads
        let tmp = file.appendingPathExtension("tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = await t.sh("mv \(t.q(tmp)) \(t.q(file))")
        let ok = await t.waitFor(4000) { doc.stats.silentReloads > reloads0 }
        t.check(ok, "external write was picked up")
        await t.sleep(80)
    }

    // MARK: triggers

    @MainActor static func reloadTriggers(_ t: SelfTest.T) async throws {
        let base = "# Title\n\nline one\nline two\n"
        // 1. NSFilePresenter only (monitor stopped): what NSDocument alone gives us, through our check
        do {
            let file = t.write(base, to: "presenter.md")
            let doc = try await t.open(file)
            await t.sleep(150)
            doc.monitor?.stop()
            let reloads0 = doc.stats.silentReloads
            let done = await t.sh("printf 'x\\n' >> \(t.q(file))")
            let ok = await t.waitFor(4000) { doc.stats.silentReloads > reloads0 }
            let lat = firstReloadTrace(t, since: done - 100).map { $0.t - done }
            t.check(ok, "presenter-only (kqueue monitor stopped): reload happens, \(lat.map { String(format: "%.0f ms", $0) } ?? "?") after the write (trigger \(doc.stats.lastReloadTrigger))")
            t.check(doc.stats.lastReloadTrigger.hasPrefix("presenter"), "... and it was the NSFilePresenter callback that triggered it")
            t.close(doc)
        }
        // 2. activation only: monitor stopped, write, post didBecomeActive right away (presenter would take ~1 s)
        do {
            let file = t.write(base, to: "activation.md")
            let doc = try await t.open(file)
            await t.sleep(150)
            doc.monitor?.stop()
            let reloads0 = doc.stats.silentReloads
            await t.sh("printf 'x\\n' >> \(t.q(file))")
            let s = SelfTest.nowMs()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            let ok = await t.waitFor(1000) { doc.stats.silentReloads > reloads0 }
            t.check(ok && doc.stats.lastReloadTrigger == "activation", "app activation re-checks immediately: reload \(Int(SelfTest.nowMs() - s)) ms after activation (trigger \(doc.stats.lastReloadTrigger))")
            await t.sleep(1300)
            t.equal(doc.stats.silentReloads - reloads0, 1, "presenter echo afterwards is a no-op")
            t.close(doc)
        }
        // 3. coordinated writer (what iCloud/File Provider/Finder-style clients do): NSDocument itself reverts -> our revert override
        do {
            let file = t.write(base, to: "coordinated.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(150)
            host.textView.setSelectedRange(NSRange(location: 3, length: 0))
            let before = doc.stats.silentReloads
            let tStart = SelfTest.nowMs()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    let co = NSFileCoordinator(filePresenter: nil)
                    var err: NSError?
                    co.coordinate(writingItemAt: file, options: .forReplacing, error: &err) { u in
                        try? Data("# Title\n\ncoordinated write\nline two\n".utf8).write(to: u)
                    }
                    c.resume()
                }
            }
            let ok = await t.waitFor(4000) { host.currentText.isEqual(to: "# Title\n\ncoordinated write\nline two\n") }
            await t.sleep(1500)
            let sawRevert = t.traces.contains { $0.t >= tStart && $0.msg.hasPrefix("revert(") }
            t.check(ok, "coordinated write is shown (reloads by our check: \(doc.stats.silentReloads - before), via NSDocument revert: \(sawRevert))")
            t.check(!doc.isDocumentEdited, "coordinated: not dirty afterwards")
            t.equal(host.textView.selectedRange(), NSRange(location: 3, length: 0), "coordinated: selection kept")
            t.check(UITrap.alerts.isEmpty, "coordinated: no alert")
            t.close(doc)
        }
        // 4. symlinked folder (write through the real path and through the link)
        do {
            try FileManager.default.createDirectory(at: t.url("real"), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: t.url("link"))
            try FileManager.default.createSymbolicLink(at: t.url("link"), withDestinationURL: t.url("real"))
            t.write(base, to: "real/sym.md")
            let doc = try await t.open(t.url("link/sym.md"))
            t.info("opened via symlink: fileURL = \(doc.fileURL?.path.replacingOccurrences(of: t.work.path, with: "<work>") ?? "nil")")
            await t.sleep(150)
            for (i, path) in ["real/sym.md", "link/sym.md"].enumerated() {
                let r0 = doc.stats.silentReloads
                await t.sh("printf 'via %s\\n' \(i) > \(t.q(t.url(path))).tmp && mv \(t.q(t.url(path))).tmp \(t.q(t.url(path)))")
                let ok = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
                t.check(ok, "symlinked folder: atomic replace written through '\(path)' is picked up")
            }
            t.close(doc)
        }
        // 5. re-arm: 10 consecutive atomic replacements (each one leaves the old kqueue descriptor on a dead inode)
        do {
            let file = t.write(base, to: "rearm.md")
            let doc = try await t.open(file)
            await t.sleep(150)
            var missed = 0
            var total = 0.0
            for i in 1...10 {
                let r0 = doc.stats.silentReloads
                let done = await t.sh("printf 'gen %d\\n' \(i) > \(t.q(file)).tmp && mv \(t.q(file)).tmp \(t.q(file))")
                let ok = await t.waitFor(2500) { doc.stats.silentReloads > r0 }
                if !ok { missed += 1 } else { total += (firstReloadTrace(t, since: done - 50)?.t ?? done) - done }
                await t.sleep(120)
            }
            t.equal(missed, 0, "10 consecutive atomic replacements all detected (avg latency \(Int(total / 10)) ms, rebinds=\(doc.monitor?.rebindCount ?? 0))")
            t.close(doc)
        }
        // 5b. non-local file systems (SMB/NFS/...) get a stat poll instead of kqueue: exercised with the test hooks
        do {
            let file = t.write(base, to: "poll.md")
            var ticks = 0
            let m = ExternalChangeMonitor(path: file.path) { ticks += 1 }
            m.forcePolling = true; m.vnodeEnabled = false; m.pollInterval = 0.1
            m.start()
            await t.sleep(750)
            m.stop()
            t.check(m.isPolling || ticks > 0, "poll-only monitor (what non-local mounts get): \(ticks) callbacks in 0.75 s at a 100 ms interval, no kqueue involved")
            t.check(ticks >= 4 && ticks <= 9, "poll rate is about the configured interval (\(ticks))")
            let before = ticks
            await t.sleep(300)
            t.equal(ticks, before, "stop() really stops it")
        }
        // 6. idle cost: kqueue only, nothing scheduled
        do {
            let file = t.write(base, to: "idle.md")
            let doc = try await t.open(file)
            await t.sleep(1800)          // NSDocument's own xattr write at open produces one presenter echo ~1.1 s after open
            let c0 = doc.stats.checks
            await t.sleep(1500)
            t.equal(doc.stats.checks, c0, "idle document: zero checks / wake-ups in 1.5 s (no polling on a local file system)")
            t.check(doc.monitor?.isPolling == false, "monitor is not polling (local file system)")
            t.close(doc)
        }
    }
}
