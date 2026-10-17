#if LUFTIG_SELFTEST
// Exploratory probes of the editor audit (not part of `all`).
import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorProbeScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-probe-big", summary: "(probe) first edit in the middle of a big document", run: { t in try await probeBig(t) }, inAll: false),
        .init(name: "audit-probe-find", summary: "(probe) find / replace-all / jump to selection in big documents", run: { t in try await probeFind(t) }, inAll: false),
        .init(name: "audit-probe-repl", summary: "(probe) where does the replace-all time go", run: { t in try await probeRepl(t) }, inAll: false),
        .init(name: "audit-scroll-glyphs", summary: "editor audit: real scrolling and jumps through a document with CJK / emoji / Hebrew / Arabic text: every laid-out character has a glyph and the font AppKit's fixing gives it", run: { t in try await probeScroll(t) }),
        .init(name: "audit-probe-nav", summary: "(probe) navigation keys and select-all edits in a 20 MB document", run: { t in try await probeNav(t) }, inAll: false),
    ]

    @MainActor static func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
    }

    @MainActor static func probeBig(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 10_000_000
        let src = t.corpusFile(bytes: bytes)
        func fresh(_ name: String) async throws -> (MarkdownDocument, EditorViewController) {
            let copy = t.url(name)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: src, to: copy)
            let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
            return (doc, doc.host as! EditorViewController)
        }
        // a. the spike's scenario: selection in the middle, never visited, then one keystroke
        for variant in ["a: setSelectedRange(mid) + insertText", "b: +ensureLayout(neighbourhood) first", "c: setSelectedRange + scrollRangeToVisible, then insertText", "d: real key event after scroll", "e: setSelectedRange(mid) + insertText, SECOND keystroke", "f: externally-applied edit at mid (replaceCharacters, no caret)"] {
            let (doc, host) = try await fresh("big-\(variant.prefix(1)).md")
            let tv = host.textView, lm = tv.layoutManager!
            let len = (tv.string as NSString).length
            var loc = (tv.string as NSString).lineRange(for: NSRange(location: len / 2, length: 0)).location
            loc = max(0, loc)
            var d1 = 0.0, d2 = 0.0
            switch variant.prefix(1) {
            case "a":
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                d1 = ms { t.typeText("a", into: doc, at: NSRange(location: loc, length: 0)) }
            case "b":
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                d2 = ms { lm.ensureLayout(forCharacterRange: NSRange(location: loc - 3000, length: 6000)) }
                d1 = ms { t.typeText("a", into: doc, at: NSRange(location: loc, length: 0)) }
            case "c":
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                d2 = ms { tv.scrollRangeToVisible(NSRange(location: loc, length: 0)) }
                d1 = ms { t.typeText("a", into: doc, at: NSRange(location: loc, length: 0)) }
            case "d":
                t.scrollToTop(host, character: loc)
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                d1 = ms { AuditEd.type(host, "a") }
            case "e":
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                d2 = ms { t.typeText("a", into: doc, at: NSRange(location: loc, length: 0)) }
                d1 = ms { t.typeText("b", into: doc, at: NSRange(location: loc + 1, length: 0)) }
            default:
                d1 = ms {
                    let um = tv.undoManager
                    um?.disableUndoRegistration()
                    tv.textStorage?.replaceCharacters(in: NSRange(location: loc, length: 0), with: "inserted line\n")
                    um?.enableUndoRegistration()
                }
            }
            t.note(String(format: "%@: %.1f ms (setup/prior step %.1f ms) at char %d of %d", variant, d1, d2, loc, len))
            t.close(doc)
        }
    }

    @MainActor static func probeFind(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 20_000_000
        let src = t.corpusFile(bytes: bytes)
        let copy = t.url("find.md")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
        let host = doc.host as! EditorViewController
        let tv = host.textView
        if SelfTest.flag("audit-no-styler") { tv.textStorage?.delegate = nil; t.note("STYLER DELEGATE REMOVED") }
        let text = tv.string as NSString
        let len = text.length
        // a match far away from the viewport: the first 'Setext ' heading after 70 % of the text
        var found = NSRange(location: NSNotFound, length: 0)
        let d0 = ms { found = text.range(of: "Setext ", options: [], range: NSRange(location: len * 7 / 10, length: len - len * 7 / 10)) }
        t.note(String(format: "NSString.range(of:) from 70 percent: %.1f ms -> %@", d0, NSStringFromRange(found)))
        var miss = NSRange(location: 0, length: 0)
        let d1 = ms { miss = text.range(of: "zzzz-not-there", options: [.caseInsensitive], range: NSRange(location: 0, length: len)) }
        t.note(String(format: "whole-document case-insensitive miss: %.1f ms %@", d1, NSStringFromRange(miss)))
        t.check(!host.styler.styled.contains(found.location), "setup: the match is not styled yet")
        // emulate NSTextFinder's next-match: selection + scrollRangeToVisible + find indicator
        let d2 = ms {
            tv.setSelectedRange(found)
            tv.scrollRangeToVisible(found)
            tv.showFindIndicator(for: found)
        }
        let vis = host.styler.visibleCharacterRange(tv)
        t.note(String(format: "find: select + scrollRangeToVisible + indicator: %.1f ms; visible %@ contains match: %@; styled: %@", d2, NSStringFromRange(vis), NSLocationInRange(found.location, vis) ? "yes" : "NO", host.styler.styled.contains(found.location) ? "yes" : "NO"))
        AuditEd.logMismatches(t, host, "styled part after the find jump")
        // the match is where the user sees it
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let gr = lm.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: gr, in: tc).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            t.note("match rect \(r) visibleRect \(tv.visibleRect) inside: \(tv.visibleRect.contains(r))")
        }

        // jump to selection (Cmd-J) for a far, unstyled selection
        let far = NSRange(location: len / 4, length: 10)
        tv.setSelectedRange(far)
        t.check(!host.styler.styled.contains(far.location), "setup: far selection not styled")
        let d3 = ms { _ = AuditEd.perform(host, #selector(NSResponder.centerSelectionInVisibleArea(_:))) }
        let vis3 = host.styler.visibleCharacterRange(tv)
        t.note(String(format: "Jump to Selection: %.1f ms; selection visible: %@; styled: %@", d3, NSLocationInRange(far.location, vis3) ? "yes" : "NO", host.styler.styled.contains(far.location) ? "yes" : "NO"))
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let gr = lm.glyphRange(forCharacterRange: far, actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: gr, in: tc).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            t.note("selection rect y \(r.midY) vs visible centre \(tv.visibleRect.midY)")
        }
        AuditEd.logMismatches(t, host, "styled part after Jump to Selection")

        do {
            var n: UInt32 = 0
            if let list = class_copyMethodList(NSTextView.self, &n) {
                var names: [String] = []
                for i in 0..<Int(n) { names.append(NSStringFromSelector(method_getName(list[i]))) }
                free(list)
                t.info("NSTextView methods mentioning finder/replace: \(names.filter { $0.lowercased().contains("finder") || $0.contains("replaceCharacters") || $0.contains("Replace") }.sorted())")
            }
            var pn: UInt32 = 0
            if let pl = class_copyProtocolList(NSTextView.self, &pn) { t.info("NSTextView protocols: \((0..<Int(pn)).map { NSStringFromProtocol(pl[$0]) })") }
        }
        // replace all: the NSTextFinderClient sequence (shouldReplaceCharacters, replaceCharacters per match in reverse, didReplaceCharacters)
        for (label, needle, repl) in [("rare word (~0.1 %)", "Setext", "SETEXT-X"), ("common word", "alpha", "ALPHA!")] {
            let s = tv.string as NSString
            var ranges: [NSRange] = []
            var pos = 0
            let dm = ms {
                while pos < s.length {
                    let r = s.range(of: needle, options: [], range: NSRange(location: pos, length: s.length - pos))
                    if r.location == NSNotFound { break }
                    ranges.append(r); pos = NSMaxRange(r)
                }
            }
            t.note(String(format: "%@: %d matches found in %.0f ms", label, ranges.count, dm))
            let um = tv.undoManager
            um?.beginUndoGrouping()
            let d4 = ms {
                // exactly what NSTextFinder's replace all sends its client (NSTextView adopts the NSTextFinderClient selectors informally)
                typealias ShouldFn = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> Bool
                typealias ReplFn = @convention(c) (AnyObject, Selector, NSRange, NSString) -> Void
                typealias DidFn = @convention(c) (AnyObject, Selector) -> Void
                func imp<F>(_ name: String, _ type: F.Type) -> F { unsafeBitCast(class_getMethodImplementation(NSTextView.self, NSSelectorFromString(name)), to: F.self) }
                let should = imp("shouldReplaceCharactersInRanges:withStrings:", ShouldFn.self)
                let rep = imp("replaceCharactersInRange:withString:", ReplFn.self)
                let did = imp("didReplaceCharacters", DidFn.self)
                if should(tv, NSSelectorFromString("shouldReplaceCharactersInRanges:withStrings:"), ranges.map { NSValue(range: $0) } as NSArray, ranges.map { _ in repl } as NSArray) {
                    for r in ranges.reversed() { rep(tv, NSSelectorFromString("replaceCharactersInRange:withString:"), r, repl as NSString) }
                    did(tv, NSSelectorFromString("didReplaceCharacters"))
                }
            }
            um?.endUndoGrouping()
            t.note(String(format: "%@: replace all (%d replacements): %.0f ms, restyles in didProcessEditing %d, stale %d", label, ranges.count, d4, host.styler.editRestyles, host.styler.staleEvents))
            let d5 = ms { um?.undo() }
            t.note(String(format: "%@: undo of the replace-all: %.0f ms", label, d5))
            AuditEd.logMismatches(t, host, "\(label): styled part after replace-all + undo")
            if ranges.count > 20000 { break }
        }
        t.close(doc)
    }

    @MainActor static func probeRepl(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 20_000_000
        let src = t.corpusFile(bytes: bytes)
        let copy = t.url("repl.md")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
        let host = doc.host as! EditorViewController
        let tv = host.textView, ts = tv.textStorage!
        func matches(_ needle: String, limit: Int) -> [NSRange] {
            let s = tv.string as NSString
            var r: [NSRange] = [], pos = 0
            while pos < s.length && r.count < limit {
                let m = s.range(of: needle, options: [], range: NSRange(location: pos, length: s.length - pos))
                if m.location == NSNotFound { break }
                r.append(m); pos = NSMaxRange(m)
            }
            return r
        }
        let um = tv.undoManager
        let n = 3000
        if SelfTest.flag("repl-loop") { t.note("looping the unbatched variant (for sampling)"); await t.spin(3000) }
        let loops = SelfTest.flag("repl-loop") ? 8 : 1
        for _ in 0..<loops { for (label, batched, undo, delegate) in [("storage.replaceCharacters, batched, no undo, styler ON", true, false, true), ("unbatched, no undo, styler ON", false, false, true), ("unbatched, no undo, styler OFF", false, false, false), ("unbatched, undo ON, styler OFF", false, true, false),
                                                 ("batched, no undo, styler OFF", true, false, false), ("batched, undo registration ON", true, true, true)] {
            let saved = ts.delegate
            if !delegate { ts.delegate = nil }
            let ranges = matches("alpha", limit: n)
            if !undo { um?.disableUndoRegistration() } else { um?.beginUndoGrouping() }
            let d = ms {
                if batched { ts.beginEditing() }
                for r in ranges.reversed() { ts.replaceCharacters(in: r, with: "ALPHA!") }
                if batched { ts.endEditing() }
            }
            if !undo { um?.enableUndoRegistration() } else { um?.endUndoGrouping() }
            ts.delegate = saved
            t.note(String(format: "%@: %d replacements in %.0f ms (%.0f us each)", label, ranges.count, d, d * 1000 / Double(max(1, ranges.count))))
            // put the text back so every variant works on the same text
            let back = matches("ALPHA!", limit: n)
            um?.disableUndoRegistration()
            ts.delegate = nil
            ts.beginEditing(); for r in back.reversed() { ts.replaceCharacters(in: r, with: "alpha") }; ts.endEditing()
            ts.delegate = saved
            um?.enableUndoRegistration(); um?.removeAllActions()
            host.styler.reset(); host.styler.styleVisible()
        } }
        t.close(doc)
    }

    @MainActor static func probeScroll(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 400_000
        let (doc, host, _) = try await openEditor(t, text: SelfTestCorpus.markdown(bytes: bytes, seed: 31), name: "ps.md", size: NSSize(width: 860, height: 600))
        let sv = host.scrollView, tv = host.textView
        var bad = 0, positions = 0
        var firstReports: [String] = []
        func check(_ label: String) {
            positions += 1
            let mg = AuditEd.missingGlyphs(host, extra: 200)
            let uf = AuditEd.unfixedFonts(host, maxReport: 1)
            if !mg.isEmpty || !uf.isEmpty { bad += 1; if firstReports.count < 4 { firstReports.append("\(label): missing glyphs \(mg) unfixed \(uf)") } }
        }
        let docH = tv.frame.height
        var y: CGFloat = 0
        // steps of a trackpad-like 250 pt, then a few big jumps (scroller drag)
        while y < min(docH, 60_000) {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
            check("scroll y=\(Int(y))")
            y += 250
        }
        for frac in [0.9, 0.3, 0.7, 0.5, 0.95, 0.1] {
            let yy = docH * frac
            sv.contentView.scroll(to: NSPoint(x: 0, y: yy)); sv.reflectScrolledClipView(sv.contentView)
            check("jump \(frac)")
        }
        t.note("\(positions) scroll positions checked: \(bad) with missing glyphs / unfixed fonts \(firstReports)")
        t.check(bad == 0, "scrolling a document with CJK / emoji / Hebrew / Arabic text: no missing glyphs at any of \(positions) positions")
        t.close(doc)
    }

    @MainActor static func probeNav(_ t: SelfTest.T) async throws {
        let bytes = Int(SelfTest.argument("bytes") ?? "") ?? 20_000_000
        let src = t.corpusFile(bytes: bytes)
        let copy = t.url("nav.md")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
        let host = doc.host as! EditorViewController
        let tv = host.textView, sv = host.scrollView
        let len = (tv.string as NSString).length
        func state() -> String {
            let vis = host.styler.visibleCharacterRange(tv)
            let styled = host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis))
            return "sel \(tv.selectedRange()) y \(Int(sv.contentView.bounds.origin.y)) / \(Int(tv.frame.height)) visible styled: \(styled)"
        }
        var d = ms { AuditEd.pressKey(host, AuditEd.Key.down, mods: [.command]) }
        t.note(String(format: "Cmd-Down: %.1f ms; %@", d, state()))
        d = ms { AuditEd.pressKey(host, AuditEd.Key.up, mods: [.command]) }
        t.note(String(format: "Cmd-Up: %.1f ms; %@", d, state()))
        d = ms { AuditEd.pressKey(host, AuditEd.Key.end) }
        t.note(String(format: "End key (scroll to end): %.1f ms; %@", d, state()))
        d = ms { AuditEd.pressKey(host, AuditEd.Key.home) }
        t.note(String(format: "Home key (scroll to start): %.1f ms; %@", d, state()))
        var worst = 0.0
        for i in 0..<40 {
            let x = ms { AuditEd.pressKey(host, AuditEd.Key.pageDown) }
            worst = max(worst, x)
            if i == 39 { t.note(String(format: "40x PageDown: worst %.1f ms; %@", worst, state())) }
        }
        // caret in the middle, then Cmd-Shift-Down (select to end), then Cmd-Shift-Up
        tv.setSelectedRange(NSRange(location: len / 2, length: 0))
        d = ms { AuditEd.pressKey(host, AuditEd.Key.down, mods: [.command, .shift]) }
        t.note(String(format: "Cmd-Shift-Down from the middle: %.1f ms; %@", d, state()))
        // select all
        d = ms { AuditEd.perform(host, #selector(NSText.selectAll(_:))) }
        t.note(String(format: "Select All: %.1f ms; %@", d, state()))
        // copy 20 MB to a private pasteboard
        let pb = AuditEd.privatePasteboard()
        d = ms { pb.clearContents(); _ = tv.writeSelection(to: pb, types: tv.writablePasteboardTypes) }
        t.note(String(format: "copy of the whole document to a private pasteboard: %.1f ms (%d bytes)", d, pb.string(forType: .string)?.utf8.count ?? -1))
        // type one character over the selection (replace everything)
        let rss0 = ProcessMetrics.residentBytes()
        d = ms { AuditEd.type(host, "x") }
        t.note(String(format: "Select All + type 'x' (replaces %d units): %.1f ms; text now %d units; RSS +%@", len, d, (tv.string as NSString).length, ProcessMetrics.mb(ProcessMetrics.residentBytes() - rss0)))
        d = ms { AuditEd.undo(host) }
        t.note(String(format: "undo of that: %.1f ms; text %d units (expected %d); %@", d, (tv.string as NSString).length, len, state()))
        d = ms { AuditEd.redo(host) }
        t.note(String(format: "redo of that: %.1f ms; text %d units", d, (tv.string as NSString).length))
        d = ms { AuditEd.undo(host) }
        // select all + paste of the pasteboard (20 MB)
        d = ms { tv.selectAll(nil); AuditEd.pressKey(host, AuditEd.Key.delete) }
        t.note(String(format: "Select All + Delete: %.1f ms; text now %d units", d, (tv.string as NSString).length))
        d = ms { AuditEd.undo(host) }
        t.note(String(format: "undo of Delete: %.1f ms; text %d units", d, (tv.string as NSString).length))
        d = ms { host.styler.styleVisible() }
        AuditEd.logMismatches(t, host, "after all that")
        pb.releaseGlobally()
        t.close(doc)
    }

}
#endif
