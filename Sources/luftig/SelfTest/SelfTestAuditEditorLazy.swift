#if LUFTIG_SELFTEST
// SelfTestAuditEditorLazy.swift - the lazy styler under abuse: random sequences of scroll / jump / edit / undo / redo / font size / resize /
// readable width / external reload / select-all-replace on documents of several sizes. After EVERY operation: no exception, the selection is
// sane, the undo grouping level is 0, the text equals a model where the operation is predictable; once settled, every STYLED character equals a
// fresh Theme + lexAll of the current text and the visible part is styled; text that needs a fallback font has it. Every few steps the laid-out
// visible text is compared with a fresh layout of a copy.
//
//   --audit-steps N   operations per document (default 250 for small, 100 for the 3 MB document)
//   --audit-seed S    first seed
//   --audit-trace     print every operation

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorLazyScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-lazy", summary: "editor audit: random scroll / jump / edit / undo / font size / resize / reload sequences on 4 documents; styled == fresh lex after every operation", run: { t in try await auditLazy(t) }),
    ]

    private static let lazyPieces = ["```\n", "~~~\n", "```swift\n", "> ", "# ", "## ", "- [ ] ", "- ", "1. ", "---\n", "===\n", "**", "`", "[a](b)", "\n", "\n\n", "    ", "\t", "<!-- ", "-->", "| a | b |\n|---|---|\n",
                                     "Hello world ", "日本語", "😀", "שלום", "مرحبا", "e\u{301}", "\\", "*", "_", "~~", "$$", "---\ntitle: x\n---\n", "\r\n"]

    private static func lazyRandomLine(_ rng: inout TestRNG) -> String {
        rng.pick(["alpha **bravo** charlie", "# Heading ", "> quote ", "```", "~~~", "    indented", "- item", "text 日本語 😀", "", "| a | b |", "---", "<!-- c -->", "plain words here"])
    }

    /// An external version of `text`: a few line-level changes (insert, delete, duplicate, fence flip, append).
    private static func lazyExternalVersion(_ text: NSString, _ rng: inout TestRNG) -> NSString {
        var s = text as String
        var lines = s.components(separatedBy: "\n")
        guard lines.count > 2 else { return (s + "\nexternal line\n") as NSString }
        for _ in 0..<(1 + rng.int(4)) {
            let i = rng.int(lines.count)
            switch rng.int(5) {
            case 0: lines.insert(lazyRandomLine(&rng), at: i)
            case 1: lines.remove(at: i)
            case 2: lines.insert(lines[i], at: i)
            case 3: lines.insert(rng.chance(50) ? "```" : "~~~", at: i)
            default: lines.append(lazyRandomLine(&rng))
            }
            if lines.isEmpty { lines = [""] }
        }
        s = lines.joined(separator: "\n")
        return s as NSString
    }

    @MainActor static func lazyRun(_ t: SelfTest.T, label: String, host: EditorViewController, doc: MarkdownDocument, steps: Int, seed: UInt64, oracleEvery: Int, layoutEvery: Int) async {
        let tv = host.textView, sv = host.scrollView
        guard let window = host.view.window else { t.check(false, "\(label): no window"); return }
        var rng = TestRNG(seed)
        var failures = 0
        var log: [String] = []
        let um = tv.undoManager
        let savedFont = EditorPreferences.fontSize, savedRW = EditorPreferences.readableWidth
        defer { EditorPreferences.fontSize = savedFont; EditorPreferences.readableWidth = savedRW }
        func fail(_ what: String, step: Int) {
            failures += 1
            t.check(false, "\(label) step \(step): \(what)   [seed \(seed), last operations: \(log.suffix(6).joined(separator: " | "))]")
        }
        func ns() -> NSString { tv.string as NSString }
        func grouped(_ body: () -> Void) { um?.beginUndoGrouping(); body(); tv.breakUndoCoalescing(); um?.endUndoGrouping() }
        var counts: [String: Int] = [:]
        var syncUnstyled = 0
        var syncFirst: [String] = []
        defer { if SelfTest.flag("audit-sync-visible") { t.note("\(label): NOT styled synchronously when the operation returned: \(syncUnstyled) of \(steps) operations \(syncFirst)") } }
        for step in 0..<steps {
            if failures > 3 { break }
            let before = ns().copy() as! NSString
            let len = before.length
            if let at = SelfTest.argument("audit-dump-at").flatMap({ Int($0) }), at == step {
                try? (before as String).write(toFile: (SelfTest.argument("audit-dump-dir") ?? NSTemporaryDirectory()) + "/dump-\(label.replacingOccurrences(of: " ", with: "-")).md", atomically: true, encoding: .utf8)
                out("  DUMP before step \(step): window \(window.contentView?.frame.size ?? .zero) font \(host.fontSize) readable \(host.readableWidthEnabled) scroll y \(sv.contentView.bounds.origin.y) selection \(tv.selectedRange()) inset \(tv.textContainerInset)")
            }
            var expected: NSString? = nil
            var name = ""
            let visible = host.styler.visibleCharacterRange(tv)
            switch rng.int(100) {
            case 0..<14:        // real scrolling: the clip view moves, the styler reacts to boundsDidChange only
                let h = max(1, tv.frame.height - sv.contentView.bounds.height)
                let y = rng.chance(50) ? min(h, sv.contentView.bounds.origin.y + CGFloat(rng.int(1200)) - 400) : h * CGFloat(rng.int(1001)) / 1000
                name = "scroll to y=\(Int(y))"
                sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, y))); sv.reflectScrolledClipView(sv.contentView)
                expected = before
            case 14..<20:       // jumps
                if rng.chance(50) { name = "scrollRangeToVisible"; tv.scrollRangeToVisible(NSRange(location: rng.int(len + 1), length: 0)) }
                else {
                    let none = NSEvent.ModifierFlags([]), cmd = NSEvent.ModifierFlags.command
                    let keys: [(UInt16, NSEvent.ModifierFlags)] = [(AuditEd.Key.down, cmd), (AuditEd.Key.up, cmd), (AuditEd.Key.pageDown, none), (AuditEd.Key.pageUp, none), (AuditEd.Key.end, none), (AuditEd.Key.home, none)]
                    let k = rng.pick(keys)
                    name = "key \(k.0) \(k.1.rawValue)"; AuditEd.pressKey(host, k.0, mods: k.1)
                }
                expected = before
            case 20..<52:      // an edit: insertText with an explicit replacement range, at the start / end / near the viewport / anywhere
                var loc: Int
                switch rng.int(6) { case 0: loc = 0; case 1: loc = len; case 2, 3: loc = min(len, max(0, visible.location + rng.int(max(1, visible.length)))); default: loc = rng.int(len + 1) }
                loc = min(loc, len)
                if loc < len { loc = before.rangeOfComposedCharacterSequence(at: loc).location }          // (a caret inside a grapheme cluster is not something a keyboard can produce)
                var rlen = rng.chance(60) ? 0 : rng.int(min(len - loc, rng.chance(10) ? 4000 : 40) + 1)
                rlen = min(rlen, len - loc)
                if rlen > 0 { rlen = NSMaxRange(before.rangeOfComposedCharacterSequences(for: NSRange(location: loc, length: rlen))) - loc }
                let s: String
                switch rng.int(10) {
                case 0: s = SelfTestCorpus.markdown(bytes: 300 + rng.int(6000), seed: UInt64(step) &+ seed)
                case 1: s = ""
                default: s = (0..<(1 + rng.int(3))).map { _ in rng.pick(lazyPieces) }.joined()
                }
                name = "insertText \(s.count > 30 ? "(\(s.count) chars)" : s.debugDescription) at \(loc) over \(rlen)"
                let r = NSRange(location: loc, length: rlen)
                tv.setSelectedRange(r)
                grouped { tv.insertText(s, replacementRange: r) }
                expected = before.replacingCharacters(in: r, with: s) as NSString
                if s.contains("\r") { expected = nil }          // (AppKit may normalise CR / CRLF)
            case 52..<62:       // typing through the real key path at a random caret
                var at = rng.chance(50) ? min(len, visible.location + rng.int(max(1, visible.length))) : rng.int(len + 1)
                if at < len { at = before.rangeOfComposedCharacterSequence(at: at).location }
                tv.setSelectedRange(NSRange(location: at, length: 0))
                let c = rng.pick(["a", " ", "#", "`", "~", ">", "-", "é", "日", "😀"])
                name = "type \(c.debugDescription) at \(at)"
                AuditEd.type(host, c)
                expected = before.replacingCharacters(in: NSRange(location: at, length: 0), with: c) as NSString
            case 62..<72:
                if rng.chance(65) { name = "undo"; AuditEd.undo(host) } else { name = "redo"; AuditEd.redo(host) }
                expected = nil
            case 72..<78:
                let size = min(EditorPreferences.fontSizeRange.upperBound, max(EditorPreferences.fontSizeRange.lowerBound, host.fontSize + CGFloat(rng.int(9)) - 4))
                name = "font size \(host.fontSize) -> \(size)"
                EditorPreferences.fontSize = rng.chance(10) ? (rng.chance(50) ? EditorPreferences.fontSizeRange.upperBound : EditorPreferences.fontSizeRange.lowerBound) : size
                expected = before
            case 78..<84:
                let w = CGFloat(360 + rng.int(900)), h = CGFloat(240 + rng.int(700))
                name = "resize to \(Int(w)) x \(Int(h))"
                window.setContentSize(NSSize(width: w, height: h)); window.contentView?.layoutSubtreeIfNeeded()
                expected = before
            case 84..<86:
                name = "toggle readable width"; host.luftigToggleReadableWidth(nil); expected = before
            case 86..<93:      // an external change arrives (clean: silent reload; the test applies it through the host like the document layer does)
                let new = lazyExternalVersion(before, &rng)
                let mode: ExternalApplyMode = rng.chance(50) ? .silent : .undoable
                name = "external change (\(mode == .silent ? "silent" : "undoable"), \(before.length) -> \(new.length) units)"
                host.applyExternalText(new, mode: mode)
                expected = new
            case 93..<95:
                name = "select all + replace by one line"; tv.selectAll(nil)
                let s = lazyRandomLine(&rng)
                grouped { tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                expected = s as NSString
            case 95..<96:
                name = "select all + delete"; tv.selectAll(nil); grouped { tv.delete(nil) }; expected = ""
            default:
                name = "edit at the very end"; let s = rng.pick(lazyPieces)
                tv.setSelectedRange(NSRange(location: len, length: 0))
                grouped { tv.insertText(s, replacementRange: NSRange(location: len, length: 0)) }
                expected = before.appending(s) as NSString
                if s.contains("\r") { expected = nil }
            }
            log.append(name)
            counts[String(name.split(separator: " ").first ?? ""), default: 0] += 1
            if SelfTest.flag("audit-trace") { out("  step \(step): \(name) -> len \(ns().length) sel \(tv.selectedRange())") }
            if SelfTest.flag("audit-sync-visible") {
                // right when the call returns, BEFORE the run loop turns: is what would be drawn now styled?
                let vs = host.styler.visibleCharacterRange(tv)
                if vs.length > 0 && !host.styler.styled.contains(integersIn: vs.location..<NSMaxRange(vs)) { syncUnstyled += 1; if syncFirst.count < 4 { syncFirst.append("step \(step) \(name)") } }
            }
            if (um?.groupingLevel ?? 0) != 0 { fail("undo grouping level left open: \(um!.groupingLevel)", step: step) }
            if !AuditEd.selectionSane(host) { fail("selection out of range after \(name): \(tv.selectedRanges) in a text of \(ns().length)", step: step) }
            if let e = expected, !ns().isEqual(to: e as String) {
                let a = ns(); var i = 0
                while i < min(a.length, e.length) && a.character(at: i) == e.character(at: i) { i += 1 }
                let detail = a.length <= 60 ? " before \(before.debugDescription) selection \(tv.selectedRange()) actual \((a as String).debugDescription) expected \((e as String).debugDescription)" : ""
                fail("\(name): text differs from the model at \(i) (len \(a.length) vs expected \(e.length))\(detail)", step: step)
            }
            if host.styler.styled.last.map({ $0 >= ns().length }) ?? false { fail("\(name): the styled set reaches beyond the end of the text (\(host.styler.styled.last ?? -1) >= \(ns().length))", step: step) }
            if step % 25 == 24 { await t.spin(1) }
            if step % oracleEvery == 0 || step == steps - 1 {
                // what the person's NEXT display pass sees: one real turn of the run loop (deferred restyles run), NO explicit styling
                await t.spin(2)
                let v0 = host.styler.visibleCharacterRange(tv)
                if v0.length > 0 && !host.styler.styled.contains(integersIn: v0.location..<NSMaxRange(v0)) {
                    fail("\(name): after one run loop turn the visible range \(NSStringFromRange(v0)) is not fully styled (unstyled text would be drawn)", step: step)
                }
                await AuditEd.settle(t, host, ms: 0)
                let r = AuditEd.styledMismatches(host)
                if r.bad > 0 { fail("\(name): \(r.bad) of \(r.compared) styled runs differ from a fresh lex; first \(r.first.map { "\(NSStringFromRange($0.range)) expected [\($0.expected)] actual [\($0.actual)]" })", step: step) }
                let vis = host.styler.visibleCharacterRange(tv)
                if vis.length > 0 && !host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)) { fail("\(name): the visible range \(NSStringFromRange(vis)) is not fully styled after settling", step: step) }
                let uf = AuditEd.unfixedFonts(host)
                if !uf.isEmpty { fail("\(name): text carries the base font where AppKit's font fallback is needed (invisible glyphs): \(uf)", step: step) }
                let mg = AuditEd.missingGlyphs(host)
                if !mg.isEmpty { fail("\(name): laid-out text with MISSING GLYPHS (renders blank): \(mg)", step: step) }
            }
            if layoutEvery > 0 && step % layoutEvery == layoutEvery - 1, let m = AuditEd.visibleLayoutMismatch(host) { fail("\(name): the laid-out visible text differs from a fresh layout: \(m)", step: step) }
        }
        if failures == 0 { t.check(true, "\(label): \(steps) operations (\(counts.sorted { $0.value > $1.value }.prefix(7).map { "\($0.key) \($0.value)" }.joined(separator: ", "))...): text == model, styled == fresh lex, visible part styled, fonts and glyphs present") }
    }

    @MainActor static func auditLazy(_ t: SelfTest.T) async throws {
        let steps = SelfTest.argument("audit-steps").flatMap { Int($0) }
        let layoutOverride = SelfTest.argument("audit-layout-every").flatMap { Int($0) }
        let seed = SelfTest.argument("audit-seed").flatMap { UInt64($0) } ?? 9100
        let cases: [(String, String, Int, Int, Int)] = [
            ("tiny sample", "# T\n\nfirst paragraph\n\n```\ncode\n```\n\n> quote\n", 250, 1, 5),
            ("corpus 120 KB", SelfTestCorpus.markdown(bytes: 120_000, seed: 41), 250, 2, 12),
            ("corpus 600 KB", SelfTestCorpus.markdown(bytes: 600_000, seed: 42), 160, 3, 40),
            ("corpus 3 MB", SelfTestCorpus.markdown(bytes: 3_000_000, seed: 43), 70, 4, 0),
        ]
        for (i, c) in cases.enumerated() {
            let (doc, host, _) = try await openEditor(t, text: c.1, name: "audit-lazy-\(i).md", size: NSSize(width: 860, height: 600))
            await lazyRun(t, label: c.0, host: host, doc: doc, steps: steps ?? c.2, seed: seed &+ UInt64(i), oracleEvery: c.3, layoutEvery: layoutOverride ?? c.4)
            t.close(doc)
        }
    }
}
#endif
