#if LUFTIG_SELFTEST
// SelfTestAuditEditorKeys.swift - the editor driven the way a person does it: real key events through NSWindow.sendEvent (insertText: /
// doCommandBySelector: via interpretKeyEvents), clipboard through a PRIVATE pasteboard, undo / redo, navigation keys. After EVERY action:
// no exception, selection sane, the text equals an independent model where the action is predictable, every STYLED character equals a
// fresh Theme + lexAll, and (once settled) the visible part is styled.

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let auditEditorScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-keys", summary: "editor audit: random real key events / clipboard / undo on 6 documents; text == model, styled == fresh lex after every action", run: { t in try await auditKeys(t) }),
    ]

    private static let auditSample = """
        ---
        title: Sample
        ---

        # Heading one
        ## Heading two with `code`

        Setext title
        ============

        A paragraph with **bold**, *italic*, ~~strike~~, `inline code` and a [link](https://example.com).
        It continues on a second line.

        > quote line one
        > > nested quote
        > - item in a quote

        ```swift
        let x = 1
        ```

            indented code

        ---

        | a | b |
        |---|---|
        | 1 | 2 |

        - [ ] task
        - [x] done
        - item
          - nested

        1. one
        2. two

        <!-- comment -->

        """

    private static let auditChars = ["a", "b", "c", " ", " ", "#", "*", "_", "`", ">", "-", "[", "]", "(", ")", "|", "~", ":", "!", "<", "\\", "1", ".", "é", "日", "😀", "x", "y"]
    private static let auditStrings = ["```\n", "~~~\n", "> ", "# ", "- [ ] ", "---\n", "**bold**", "`code`", "[x](y)", "\n\n", "    ", "<!-- ", "-->", "Hello world ", "日本語", "👩‍💻", "e\u{301}"]

    /// A deterministic action sequence against one document. Returns the number of failed checks it found (for the caller's report).
    @MainActor static func auditKeysRun(_ t: SelfTest.T, label: String, doc: MarkdownDocument, host: EditorViewController, steps: Int, seed: UInt64, oracleEvery: Int) async {
        let layoutEvery = max(1, SelfTest.argument("audit-layout-every").flatMap { Int($0) } ?? 5)
        let tv = host.textView
        var rng = TestRNG(seed)
        let pb = AuditEd.privatePasteboard()
        defer { pb.releaseGlobally() }
        var failures = 0
        var log: [String] = []
        let um = tv.undoManager
        if SelfTest.flag("audit-no-styler") { tv.textStorage?.delegate = nil }
        func fail(_ what: String, step: Int) {
            failures += 1
            t.check(false, "\(label) step \(step): \(what)   [seed \(seed), last actions: \(log.suffix(6).joined(separator: " | "))]")
        }
        func ns() -> NSString { tv.string as NSString }
        for step in 0..<steps {
            if failures > 3 { break }
            let before = ns().copy() as! NSString
            let selBefore = tv.selectedRange()
            var expected: NSString? = nil
            var name = ""
            // random caret first (sometimes): a click somewhere / a selection
            if rng.chance(25) && before.length > 0 {
                let a = rng.int(before.length + 1)
                let b = rng.chance(40) ? min(before.length, a + rng.int(40)) : a
                tv.setSelectedRange(NSRange(location: a, length: b - a))
            }
            let sel = tv.selectedRange()
            func model(_ range: NSRange, _ s: String) -> NSString { before.replacingCharacters(in: range, with: s) as NSString }
            switch rng.int(100) {
            case 0..<30:
                let c = rng.pick(auditChars); name = "type \(c.debugDescription)"
                AuditEd.type(host, c); expected = model(sel, c)
            case 30..<38:
                let s = rng.pick(auditStrings); name = "insertText \(s.debugDescription)"
                tv.undoManager?.beginUndoGrouping(); tv.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)); tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
                expected = model(sel, s)
            case 38..<46:
                name = "return"; AuditEd.pressKey(host, AuditEd.Key.returnKey); expected = model(sel, "\n")
            case 46..<54:
                name = "backspace"; AuditEd.pressKey(host, AuditEd.Key.delete)
                if sel.length > 0 { expected = model(sel, "") }
                else if sel.location > 0 { expected = model(before.rangeOfComposedCharacterSequence(at: sel.location - 1), "") }
                else { expected = before }
            case 54..<58:
                name = "forward delete"; AuditEd.pressKey(host, AuditEd.Key.forwardDelete)
                if sel.length > 0 { expected = model(sel, "") }
                else if sel.location < before.length { expected = model(before.rangeOfComposedCharacterSequence(at: sel.location), "") }
                else { expected = before }
            case 58..<62:
                name = "tab"; AuditEd.pressKey(host, AuditEd.Key.tab); expected = model(sel, "\t")
            case 62..<63:
                name = "shift-tab"; AuditEd.pressKey(host, AuditEd.Key.tab, mods: [.shift]); expected = nil          // (no outdent feature: only invariants)
            case 63..<71:
                let k = rng.pick([AuditEd.Key.left, AuditEd.Key.right, AuditEd.Key.up, AuditEd.Key.down])
                let m = rng.pick([NSEvent.ModifierFlags([]), [.shift], [.option], [.command], [.shift, .option], [.shift, .command]])
                name = "arrow \(k) \(m.rawValue)"; AuditEd.pressKey(host, k, mods: m); expected = before
            case 71..<74:
                let k = rng.pick([AuditEd.Key.home, AuditEd.Key.end, AuditEd.Key.pageUp, AuditEd.Key.pageDown])
                name = "nav key \(k)"; AuditEd.pressKey(host, k); expected = before
            case 74..<78:
                let (k, m) = rng.pick([(AuditEd.Key.delete, NSEvent.ModifierFlags.option), (AuditEd.Key.delete, .command), (AuditEd.Key.forwardDelete, .option)])
                name = "delete key \(k) mods \(m.rawValue)"; AuditEd.pressKey(host, k, mods: m)
                if sel.length == 0, sel.location > 0 || k == AuditEd.Key.forwardDelete { expected = nil } else { expected = nil }
            case 78..<80:
                name = "ctrl-k / ctrl-o / ctrl-t"
                let c = rng.pick(["k", "o", "t"]); AuditEd.press(host, c, code: 0, mods: [.control]); expected = nil
            case 80..<86:
                if rng.chance(70) { name = "undo"; AuditEd.undo(host) } else { name = "redo"; AuditEd.redo(host) }
                expected = nil
            case 86..<88:
                name = "select all"; AuditEd.perform(host, #selector(NSText.selectAll(_:))); expected = before
            case 88..<90:
                name = "copy+paste"; pb.clearContents()
                _ = tv.writeSelection(to: pb, types: tv.writablePasteboardTypes)
                let copied = pb.string(forType: .string) ?? ""
                if tv.selectedRange().length > 0 && copied != before.substring(with: tv.selectedRange()) { fail("copied text differs from the selection: \(copied.debugDescription)", step: step) }
                tv.undoManager?.beginUndoGrouping(); _ = tv.readSelection(from: pb); tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
                expected = model(sel, copied)
            case 90..<92:
                name = "cut"; pb.clearContents()
                _ = tv.writeSelection(to: pb, types: tv.writablePasteboardTypes)
                tv.undoManager?.beginUndoGrouping(); tv.delete(nil); tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
                expected = sel.length > 0 ? model(sel, "") : before
            case 92..<95:
                name = "paste of a corpus snippet"; pb.clearContents()
                let snippet = SelfTestCorpus.markdown(bytes: 200 + rng.int(3000), seed: UInt64(step) &+ seed)
                pb.setString(snippet, forType: .string)
                tv.undoManager?.beginUndoGrouping(); _ = tv.readSelection(from: pb); tv.breakUndoCoalescing(); tv.undoManager?.endUndoGrouping()
                expected = model(sel, snippet)
            default:
                name = "jump"; let len = ns().length
                if len > 0 { tv.scrollRangeToVisible(NSRange(location: rng.int(len), length: 0)) }
                expected = before
            }
            log.append(name)
            if SelfTest.flag("audit-trace") { out("  step \(step): \(name) sel \(sel) -> \(tv.selectedRange()) len \(ns().length)") }
            if um?.groupingLevel ?? 0 != 0 { fail("undo grouping level left open: \(um!.groupingLevel)", step: step) }
            if !AuditEd.selectionSane(host) { fail("selection out of range after \(name): \(tv.selectedRanges) in text of \(ns().length)", step: step) }
            if let e = expected, !ns().isEqual(to: e as String) {
                // show the first difference only
                let a = ns(); var i = 0
                while i < min(a.length, e.length) && a.character(at: i) == e.character(at: i) { i += 1 }
                fail("\(name): text differs from the model at \(i) (len \(a.length) vs expected \(e.length)); sel before \(selBefore) -> \(sel)", step: step)
            }
            if step % 40 == 39 { await t.spin(1) }
            if step % 2 == 0 || step == steps - 1 {
                let uf = AuditEd.unfixedFonts(host)
                if !uf.isEmpty { fail("\(name): text carries the base font where AppKit's font fallback is needed (invisible glyphs): \(uf)", step: step) }
            }
            if step % 2 == 0 || step == steps - 1 {
                let mg = AuditEd.missingGlyphs(host)
                if !mg.isEmpty { fail("\(name): laid-out text with MISSING GLYPHS (renders blank): \(mg)", step: step) }
            }
            if SelfTest.flag("audit-layout") && step % layoutEvery == 0, let m = AuditEd.visibleLayoutMismatch(host) { fail("\(name): the laid-out visible text differs from a fresh layout of the same attributed string: \(m)", step: step) }
            if !SelfTest.flag("audit-no-oracle") && (step % oracleEvery == 0 || step == steps - 1) {
                // what the person's NEXT display pass sees: one real turn of the run loop (deferred restyles run), NO explicit styling
                await t.spin(2)
                let v0 = host.styler.visibleCharacterRange(tv)
                if v0.length > 0 && !host.styler.styled.contains(integersIn: v0.location..<NSMaxRange(v0)) {
                    fail("\(name): after one run loop turn the visible range \(NSStringFromRange(v0)) is not fully styled (unstyled text would be drawn); styled ranges around it \(host.styler.styled.rangeView.filter { NSIntersectionRange(NSRange(location: $0.lowerBound, length: $0.count), v0).length > 0 || abs($0.lowerBound - v0.location) < 3000 }.map { NSStringFromRange(NSRange(location: $0.lowerBound, length: $0.count)) })", step: step)
                }
                await AuditEd.settle(t, host, ms: 0)
                let r = AuditEd.styledMismatches(host)
                if r.bad > 0 { fail("\(name): \(r.bad) of \(r.compared) styled runs differ from a fresh lex; first \(r.first.map { "\(NSStringFromRange($0.range)) expected [\($0.expected)] actual [\($0.actual)]" })", step: step) }
                let vis = host.styler.visibleCharacterRange(tv)
                if vis.length > 0 && !host.styler.styled.contains(integersIn: vis.location..<NSMaxRange(vis)) {
                    fail("\(name): the visible range \(NSStringFromRange(vis)) is not fully styled after settling", step: step)
                }
            }
        }
        if failures == 0 { t.check(true, "\(label): \(steps) key / clipboard / undo actions: text == model, styled == fresh lex, selection sane") }
    }

    @MainActor static func auditKeys(_ t: SelfTest.T) async throws {
        let steps = SelfTest.argument("audit-steps").flatMap { Int($0) } ?? 300
        let seed = SelfTest.argument("audit-seed").flatMap { UInt64($0) } ?? 4242
        let cases: [(String, String)] = [
            ("sample", auditSample),
            ("corpus 150 KB", SelfTestCorpus.markdown(bytes: 150_000, seed: 31)),
            ("one character", "x"),
            ("blank lines only", "\n\n\n\n"),
            ("code fence open to the end", "```\ncode\n\n> not a quote\n# not a heading\n"),
            // text that lives on fallback fonts: every restyle of a paragraph has to restore them (and may only rewrite what changed)
            ("Chinese / Japanese / emoji 30 KB", auditCJKText(bytes: 30_000, seed: 21)),
            ("Arabic / Hebrew / emoji / combining marks", (0..<40).map { "# \($0 % 3 == 0 ? "عنوان" : "כותרת") \($0)\n\nمرحبا بالعالم **שלום עולם** `קוד` 😀 👩\u{200D}💻 e\u{301}a\u{308} 🇦🇹 ✅\n\n> اقتباس ציטוט\n\n```\n日本語 مرحبا\n```\n\n" }.joined()),
        ]
        for (i, c) in cases.enumerated() {
            let (doc, host, _) = try await openEditor(t, text: c.1, name: "audit-keys-\(i).md", size: NSSize(width: 860, height: 600))
            if i == 1 { host.styler.styleVisible(); t.scrollToTop(host, character: 60_000) }
            await auditKeysRun(t, label: c.0, doc: doc, host: host, steps: steps, seed: seed &+ UInt64(i), oracleEvery: i == 1 ? 3 : 1)
            t.close(doc)
        }
        // the empty untitled document
        let doc = try t.newUntitled()
        if let host = doc.host as? EditorViewController {
            await auditKeysRun(t, label: "empty untitled", doc: doc, host: host, steps: steps, seed: seed &+ 99, oracleEvery: 1)
        }
        t.close(doc)
    }
}
#endif
