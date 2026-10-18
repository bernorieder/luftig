#if LUFTIG_SELFTEST
// SelfTestIntegration.swift - scenarios that test the INTEGRATION of lexer, theme, lazy styler, text view and document, not the parts:
//   theme            contrast ratios in light + dark (printed), attribute contract of every construct
//   style-differential   ~2000 random edits while the lazy styler runs, then every character == fresh Theme + lexAll
//   style-live       typing a heading, opening a fence (bounded re-lex / stale tail), IME composition, huge paste, undo
//   reload-restyle   external append / replace while open and scrolled: selection + scroll kept AND new text correctly styled
//   font-size        Cmd + / - / 0: styled and not yet styled text, persisted, applied to a second window
//   window           default size, title bar, readable column geometry, spell checking default
//   open-perf        100 KB .. 20 MB through NSDocumentController: first screen laid out + styled + drawn vs the budget
//   typing           keystroke latency incl. restyle + layout + redraw at 200 KB and 10 MB
//   idle             20 MB document, idle: no CPU, no timers, the file monitor is quiet
//   memory           RSS after opening 10 MB / 20 MB
//   render           (SelfTestRender.swift) PNG of the real editor window

import AppKit
import MarkdownKit

/// Thread-safe byte collector for child process output.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

extension SelfTestScenarios {
    static let integrationScenarios: [SelfTest.Scenario] = [
        .init(name: "theme", summary: "contrast ratios of every colour (light + dark, printed) and the attribute contract of the Theme", run: { t in try await themeScenario(t) }),
        .init(name: "style-differential", summary: "2000 random edits with the lazy styler running; then every character == fresh Theme + MarkdownStyler.lexAll", run: { t in try await styleDifferential(t) }),
        .init(name: "style-live", summary: "typing a heading, opening a fence (stale tail), IME composition, huge paste, undo", run: { t in try await styleLive(t) }),
        .init(name: "reload-restyle", summary: "external append/replace while open and scrolled: selection + scroll preserved AND new text correctly styled", run: { t in try await reloadRestyle(t) }),
        .init(name: "font-size", summary: "Cmd + / - / 0 change styled and not yet styled text consistently, persist, apply to a second window", run: { t in try await fontSize(t) }),
        .init(name: "window", summary: "default window size, title bar, readable column geometry, spell checking default, tabbing", run: { t in try await windowScenario(t) }),
        .init(name: "open-perf", summary: "open 100 KB / 1 MB / 10 MB / 20 MB: first screen laid out + styled + drawn vs the DESIGN.md budget (warm medians + cold processes)", run: { t in try await openPerf(t) }),
        .init(name: "typing", summary: "keystroke latency (insert + restyle + layout + redraw) in a 200 KB and a 10 MB document", run: { t in try await typing(t) }),
        .init(name: "idle", summary: "after opening 20 MB: no CPU over 3 s, no timers, quiet file monitor", run: { t in try await idle(t) }),
        .init(name: "memory", summary: "RSS after opening 10 MB (informational, asserts < 600 MB)", run: { t in try await memory(t) }),
        .init(name: "open-cold", summary: "(internal) one cold open in this process: --input f.md", run: { t in try await openCold(t) }, inAll: false),
        .init(name: "corpus", summary: "(internal) write the generated test corpus: --bytes N --out f.md [--seed S]", run: { t in
            guard let n = SelfTest.argument("bytes").flatMap({ Int($0) }), let out = SelfTest.argument("out") else { t.check(false, "usage: --selftest corpus --bytes N --out f.md"); return }
            let text = SelfTestCorpus.markdown(bytes: n, seed: UInt64(SelfTest.argument("seed") ?? "1") ?? 1)
            try text.write(toFile: out, atomically: true, encoding: .utf8)
            t.check(true, "wrote \(text.utf8.count) bytes, \((text as NSString).length) units to \(out)")
        }, inAll: false),
        .init(name: "memory-child", summary: "(internal) RSS of a fresh process with one document: --input f.md", run: { t in try await memoryChild(t) }, inAll: false),
    ] + auditEditorScenarios + auditEditorClipboardScenarios + auditEditorAppearanceScenarios + auditEditorIMEScenarios + auditEditorLeakScenarios + auditEditorProbeScenarios + auditEditorLazyScenarios + auditEditorRegressScenarios + auditEditorFixProbeScenarios + auditEditorFenceBigScenarios + auditEditorBigLineScenarios + auditEditorLazyFixScenarios + auditEditorRunSizeScenarios

    // MARK: helpers

    @MainActor static func openEditor(_ t: SelfTest.T, text: String, name: String, size: NSSize = NSSize(width: 860, height: 700)) async throws -> (MarkdownDocument, EditorViewController, URL) {
        let url = t.write(text, to: name)
        let doc = try await t.open(url, size: size)
        guard let host = doc.host as? EditorViewController else { throw NSError(domain: "t", code: 9, userInfo: [NSLocalizedDescriptionKey: "no editor host"]) }
        return (doc, host, url)
    }

    static func ns(_ tv: NSTextView) -> NSString { tv.string as NSString }

    /// Characters currently visible (what the styler would style, without margin).
    @MainActor static func visibleRange(_ host: EditorViewController) -> NSRange { host.styler.visibleCharacterRange(host.textView) }

    /// Assert that the storage equals a fresh lex for `range` (default whole text). `label` names the check.
    @MainActor static func assertMatchesFreshLex(_ t: SelfTest.T, _ host: EditorViewController, range: NSRange? = nil, _ label: String) {
        guard let ts = host.textView.textStorage else { return }
        let r = StyleOracle.compare(storage: ts, settings: host.theme.settings, range: range)      // the editor's own settings: fonts / spacing are part of the oracle (SelfTestSettings.swift)
        t.check(r.mismatches == 0, "\(label): \(r.checkedRuns) runs compared with a fresh Theme + lexAll, \(r.mismatches) mismatches")
        for m in r.first { t.info("mismatch at \(NSStringFromRange(m.range)): expected [\(m.expected)] actual [\(m.actual)]") }
        if let m = r.first.first, SelfTest.flag("debug-mismatch") {
            let text = ts.string as NSString
            let ctx = NSRange(location: max(0, m.range.location - 120), length: min(text.length - max(0, m.range.location - 120), m.range.length + 260))
            t.info("context: \(text.substring(with: ctx).debugDescription)")
            var p = ctx.location
            while p < NSMaxRange(ctx) {
                var eff = NSRange(location: 0, length: 0)
                let a = ts.attributes(at: p, longestEffectiveRange: &eff, in: ctx)
                t.info("  actual run \(NSStringFromRange(eff)) \(text.substring(with: NSRange(location: eff.location, length: min(30, eff.length))).debugDescription) \(StyleOracle.describe(a))")
                p = NSMaxRange(eff)
            }
            for run in MarkdownStyler().lexAll(text) where NSIntersectionRange(run.range, ctx).length > 0 {
                t.info("  lex run \(NSStringFromRange(run.range)) \(run.style)")
            }
        }
    }

    // MARK: theme

    @MainActor static func themeScenario(_ t: SelfTest.T) async throws {
        // ---- contrast ratios, light and dark (WCAG 2): text >= 4.5:1 against the surface it sits on, markers >= 3:1
        for (name, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            let bg = Contrast.rgba(Palette.background, appearance: appearance)
            let surfaces: [Palette.Surface: (r: Double, g: Double, b: Double, a: Double)] = [
                .plain: bg,
                .code: Contrast.over(Contrast.rgba(Palette.codeBand, appearance: appearance), bg),
                .quote: Contrast.over(Contrast.rgba(Palette.quoteBand, appearance: appearance), bg),
                .pill: Contrast.over(Contrast.rgba(Palette.inlinePill, appearance: appearance), bg),
            ]
            t.info(String(format: "[%@] background rgb(%.0f, %.0f, %.0f)", name, bg.r * 255, bg.g * 255, bg.b * 255))
            var worst: (String, Double) = ("", 99)
            for row in Palette.textColorsToCheck {
                let ratio = Contrast.ratio(Contrast.rgba(row.color, appearance: appearance), on: surfaces[row.surface]!)
                if ratio - row.minRatio < worst.1 - 4.5 + 0.0001 && ratio < worst.1 { worst = (row.name, ratio) }
                t.check(ratio >= row.minRatio, String(format: "%@  %@ %5.2f : 1   (needs %.1f)", name, row.name.padding(toLength: 34, withPad: " ", startingAt: 0), ratio, row.minRatio))
            }
            // the caret colour on the page and on a code band
            let caret = Contrast.rgba(Palette.accent, appearance: appearance)
            t.check(Contrast.ratio(caret, on: surfaces[.plain]!) >= 3 && Contrast.ratio(caret, on: surfaces[.code]!) >= 3, "\(name) insertion point colour >= 3:1 on the page and on code bands")
        }

        // ---- attribute contract, on a real editor, after styling everything
        let sample = """
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

        """
        let (doc, host, _) = try await openEditor(t, text: sample, name: "theme.md")
        host.styler.styleEverything()
        let tv = host.textView, ts = tv.textStorage!, text = ns(tv)
        let theme = host.theme
        func loc(_ s: String) -> Int { text.range(of: s).location }
        func attrs(_ s: String, _ off: Int = 0) -> [NSAttributedString.Key: Any] { ts.attributes(at: loc(s) + off, effectiveRange: nil) }
        func font(_ s: String, _ off: Int = 0) -> NSFont { attrs(s, off)[.font] as! NSFont }
        func traits(_ f: NSFont) -> NSFontTraitMask { NSFontManager.shared.traits(of: f) }

        let body = font("A paragraph")
        t.equal(body.pointSize, theme.baseSize, "body font size == the base size (\(theme.baseSize))")
        for level in 1...2 {
            let f = font(level == 1 ? "Heading one" : "Heading two")
            t.equal(f.pointSize, theme.headingSize(level), "H\(level) size == round(base x \(Theme.headingScales[level])) = \(theme.headingSize(level))")
            t.check(traits(f).contains(.boldFontMask), "H\(level) is bold")
        }
        let ratio1 = theme.headingSize(1) / theme.baseSize, ratio2 = theme.headingSize(2) / theme.baseSize
        t.check(ratio1 > 1.5 && ratio1 < 1.7 && ratio2 > 1.28 && ratio2 < 1.42, String(format: "headings are 'a bit bigger': H1 %.2fx, H2 %.2fx", ratio1, ratio2))
        t.check(traits(font("bold", 0)).contains(.boldFontMask), "**bold** is bold weight")
        t.check(traits(font("italic", 0)).contains(.italicFontMask), "*italic* is a real italic")
        t.check(attrs("strike", 0)[.strikethroughStyle] != nil, "~~strike~~ has a strikethrough line")
        t.check(font("inline code", 0).isFixedPitch && font("inline code", 0).pointSize < body.pointSize, "inline code is monospaced and slightly smaller than the body")
        t.check(attrs("link", 0)[.underlineStyle] != nil, "link text is underlined")
        t.check(font("let x", 0).isFixedPitch, "code block is monospaced")
        t.check(font("| a | b |", 2).isFixedPitch, "table is monospaced (pipes align)")
        t.check(font("title: Sample", 0).isFixedPitch, "front matter is monospaced")
        t.check((attrs("[ ] task")[.foregroundColor] as? NSColor) === Palette.taskUnchecked, "unchecked task marker is dim")
        t.check((attrs("[x] done")[.foregroundColor] as? NSColor) === Palette.accent, "checked task marker is the accent colour")
        t.check((attrs("**bold**")[.foregroundColor] as? NSColor) === Palette.marker, "syntax markers (**) are dimmed")

        // ---- uniform line heights, identical paragraph style over a whole line incl. its newline, decoration marks
        var lineIssues: [String] = []
        var nonUniform = 0
        var blockIssues = 0
        let oracle = MarkdownStyler().lexAll(text)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            let first = ts.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil) as? NSParagraphStyle
            var p = enclosing.location
            while p < NSMaxRange(enclosing) {
                var eff = NSRange(location: 0, length: 0)
                let ps = ts.attribute(.paragraphStyle, at: p, longestEffectiveRange: &eff, in: enclosing) as? NSParagraphStyle
                if ps == nil || !(ps!.isEqual(first)) { lineIssues.append("line at \(enclosing.location): paragraph style differs at \(p)") }
                if let ps, ps.minimumLineHeight != ps.maximumLineHeight || ps.minimumLineHeight <= 0 { nonUniform += 1 }
                p = NSMaxRange(eff)
            }
        }
        t.check(lineIssues.isEmpty, "every line has ONE paragraph style across all its runs incl. the newline \(lineIssues.prefix(2))")
        t.equal(nonUniform, 0, "every paragraph style has minimumLineHeight == maximumLineHeight")
        for run in oracle {
            let s = run.style
            for i in stride(from: run.range.location, to: NSMaxRange(run.range), by: 1) {
                let mark = BlockMark.decode(ts.attribute(.luftigBlock, at: i, effectiveRange: nil))
                if s.contains(.codeBlock) || s.contains(.codeFence) { if mark?.kind != .code { blockIssues += 1 } }
                else if s.contains(.horizontalRule) { if mark?.kind != .rule { blockIssues += 1 } }
                else if s.contains(.blockquote) { if mark?.kind != .quote { blockIssues += 1 } }
                else if mark != nil { blockIssues += 1 }
                if s.contains(.inlineCode) != (ts.attribute(.luftigInline, at: i, effectiveRange: nil) != nil) { blockIssues += 1 }
            }
        }
        t.equal(blockIssues, 0, "`.luftigBlock` on every character of code / quote / rule lines incl. newline (and only there); `.luftigInline` on inline code incl. backticks")
        let nested = BlockMark.decode(ts.attribute(.luftigBlock, at: loc("nested quote"), effectiveRange: nil))
        t.check(nested?.kind == .quote && nested?.depth == 2, "nested quote line carries depth 2: \(String(describing: nested))")
        let prefix = BlockMark.decode(ts.attribute(.luftigBlock, at: loc("> > nested"), effectiveRange: nil))
        t.check(prefix?.depth == 2, "the `> ` prefix of a nested quote line has the same depth as the line: \(String(describing: prefix))")
        let setextTitle = ts.attribute(.paragraphStyle, at: loc("Setext title"), effectiveRange: nil) as? NSParagraphStyle
        let setextLine = ts.attribute(.paragraphStyle, at: loc("============"), effectiveRange: nil) as? NSParagraphStyle
        t.check(setextTitle?.minimumLineHeight == theme.lineHeight(headingLevel: 1) && setextLine?.minimumLineHeight == theme.bodyLineHeight && setextLine?.paragraphSpacingBefore == 0,
                "setext underline is a plain dim line (body height, no spacing), the title keeps the heading height")
        assertMatchesFreshLex(t, host, "sample document")
        t.close(doc)
    }

    // MARK: style-differential

    /// The edit alphabet: characters and strings that change block / inline structure.
    private static let editChars = ["a", "b", " ", " ", "#", "*", "_", "`", ">", "-", "[", "]", "(", ")", "|", "~", ":", "!", "<", "\\", "1", ".", "\t", "é", "日", "😀"]
    private static let editStrings = ["```\n", "~~~\n", "> ", "# ", "## ", "- [ ] ", "- ", "1. ", "---\n", "| a | b |\n|---|---|\n", "<!-- ", "-->", "**", "~~", "\n\n",
                                      "    ", "***", "[x](y)", "`code`", "---\ntitle: x\n---\n"]

    @MainActor static func differentialRun(_ t: SelfTest.T, label: String, maxEditRegion: Int, seed: UInt64, edits: Int, settingsChurn: Bool = false) async throws {
        let text0 = SelfTestCorpus.markdown(bytes: 120_000, seed: seed)
        let (doc, host, _) = try await openEditor(t, text: text0, name: "diff-\(label).md")
        host.provider.maxEditRegion = maxEditRegion
        let tv = host.textView
        var rng = TestRNG(seed &* 977)
        let t0 = SelfTest.nowMs()
        var undone = 0, pasted = 0, scrolls = 0
        for step in 0..<edits {
            let text = ns(tv)
            let len = text.length
            func randomLocation() -> Int {
                var l = rng.int(len + 1)
                if rng.chance(35) && len > 0 { let r = text.lineRange(for: NSRange(location: min(l, len - 1), length: 0)); l = rng.chance(50) ? r.location : max(r.location, NSMaxRange(r) - 1) }
                return l
            }
            switch rng.int(100) {
            case 0..<42:
                t.typeText(rng.pick(editChars), into: doc, at: NSRange(location: randomLocation(), length: 0))
            case 42..<56:
                t.typeText(rng.pick(editStrings), into: doc, at: NSRange(location: randomLocation(), length: 0))
            case 56..<66:
                t.typeText("\n", into: doc, at: NSRange(location: randomLocation(), length: 0))
            case 66..<80:
                let l = randomLocation(), n = min(1 + rng.int(3), l)
                if n > 0 { t.typeText("", into: doc, at: NSRange(location: l - n, length: n)) }
            case 80..<87:
                // a paste of 1...40 lines (sometimes ~20 KB) of corpus text
                let size = rng.chance(10) ? 20_000 : 200 + rng.int(2000)
                let snippet = SelfTestCorpus.markdown(bytes: size, seed: UInt64(step) &+ seed)
                t.typeText(snippet, into: doc, at: NSRange(location: randomLocation(), length: 0))
                pasted += 1
            case 87..<91:
                let l = randomLocation()
                let r = text.lineRange(for: NSRange(location: min(l, max(0, len - 1)), length: 0))
                if len > 0 { t.typeText("", into: doc, at: NSRange(location: r.location, length: min(r.length + (rng.chance(30) ? 400 : 0), len - r.location))) }
            case 91..<95:
                if let um = tv.undoManager {
                    if rng.chance(70) { if um.canUndo { um.undo(); undone += 1 } } else if um.canRedo { um.redo() }
                }
            default:
                // scroll somewhere (the lazy styler styles what becomes visible), sometimes by a jump through scrollRangeToVisible
                if len > 0 {
                    let target = rng.int(len)
                    if rng.chance(50) { t.scrollToTop(host, character: target) } else { tv.scrollRangeToVisible(NSRange(location: target, length: 0)); host.styler.styleVisible() }
                    scrolls += 1
                }
            }
            if step % 40 == 39 { await t.spin(1) }       // let scheduled restyles (stale tails) run, like the run loop does between events
            if settingsChurn && step % 140 == 139 { churnSettings(&rng) }       // settings-oracle: a font, size, spacing or column setting changes under the user's hands
            if step % 500 == 499 { host.styler.styleVisible() }
        }
        let elapsed = SelfTest.nowMs() - t0
        await t.spin(30)
        host.styler.styleVisible()
        let styledBefore = host.styler.styled.count
        t.note(String(format: "%@: %d edits (%d undos, %d pastes, %d scrolls) in %.0f ms (%.2f ms per edit incl. layout), %d restyles in didProcessEditing, %d stale tails, %d of %d units styled before the final fill",
                      label, edits, undone, pasted, scrolls, elapsed, elapsed / Double(edits), host.styler.editRestyles, host.styler.staleEvents, styledBefore, ns(tv).length))
        // 1. what is on screen right now must already be right (lazy styling happened while we edited and scrolled)
        assertMatchesFreshLex(t, host, range: visibleRange(host), "\(label): the visible part, before any forced fill")
        // 2. force-style the whole document and compare EVERY character
        host.styler.styleEverything()
        t.check(host.styler.styled.contains(integersIn: 0..<ns(tv).length), "\(label): the whole document is marked styled")
        assertMatchesFreshLex(t, host, "\(label): whole document after \(edits) edits")
        t.close(doc)
    }

    @MainActor static func styleDifferential(_ t: SelfTest.T) async throws {
        // reproduce one soak run: --diff-seed S [--diff-bound N]
        if let seed = SelfTest.argument("diff-seed").flatMap({ UInt64($0) }) {
            try await differentialRun(t, label: "repro seed \(seed)", maxEditRegion: SelfTest.argument("diff-bound").flatMap { Int($0) } ?? 60_000, seed: seed, edits: 2000)
            return
        }
        try await differentialRun(t, label: "A (default re-lex bound)", maxEditRegion: 60_000, seed: 11, edits: 2000)
        try await differentialRun(t, label: "B (4 KB re-lex bound: stale tails)", maxEditRegion: 4_000, seed: 23, edits: 2000)
        // optional soak: --diff-seeds N runs N more random documents / edit sequences (alternating the re-lex bound), not part of `all`
        if let n = SelfTest.argument("diff-seeds").flatMap({ Int($0) }) {
            for i in 0..<n { try await differentialRun(t, label: "soak seed \(100 + i)", maxEditRegion: i % 2 == 0 ? 60_000 : 2_000, seed: UInt64(100 + i), edits: 2000) }
        }
    }

    // MARK: style-live

    @MainActor static func styleLive(_ t: SelfTest.T) async throws {
        // 1. typing "# " turns a plain line into a heading, no undo entries for the restyle, one Undo restores the text
        do {
            let (doc, host, _) = try await openEditor(t, text: "plain line\nsecond line\n", name: "live1.md")
            let tv = host.textView, theme = host.theme
            t.equal(t.fontOf(tv, at: 0)?.pointSize, theme.baseSize, "before: plain line has the body font")
            t.typeText("# ", into: doc, at: NSRange(location: 0, length: 0))
            let f = t.fontOf(tv, at: 3)
            t.equal(f?.pointSize, theme.headingSize(1), "typing `# ` makes the line a heading at once (font \(f?.pointSize ?? 0) pt)")
            let ps = tv.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            t.equal(ps?.minimumLineHeight, theme.lineHeight(headingLevel: 1), "... with the heading's fixed line height")
            t.equal(t.fontOf(tv, at: (tv.string as NSString).range(of: "second").location)?.pointSize, theme.baseSize, "the next line is untouched")
            tv.undoManager?.undo()
            t.equal(tv.string, "plain line\nsecond line\n", "ONE Undo restores the text (the restyle registered no undo entries)")
            t.equal(t.fontOf(tv, at: 0)?.pointSize, theme.baseSize, "... and the line is plain again")
            t.check(tv.undoManager?.canUndo != true, "nothing else on the undo stack")
            assertMatchesFreshLex(t, host, "after typing + undo")
            t.close(doc)
        }
        // 2. opening a code fence near the top of a document without a later re-convergence: bounded re-lex, stale tail, restyled lazily
        do {
            let (doc, host, _) = try await openEditor(t, text: SelfTestCorpus.markdown(bytes: 300_000, seed: 5), name: "live2.md")
            let tv = host.textView
            host.provider.maxEditRegion = 300
            let events0 = host.styler.staleEvents
            let mid = ns(tv).length / 2
            t.scrollToTop(host, character: mid)                    // something far away is styled already: it must be restyled after the edit
            let beforeMid = StyleOracle.compare(storage: tv.textStorage!, baseSize: host.theme.baseSize, range: visibleRange(host)).mismatches
            t.equal(beforeMid, 0, "setup: the middle of the document is styled correctly")
            t.typeText("```\n", into: doc, at: NSRange(location: (ns(tv).range(of: "\n\n").location) + 2, length: 0))
            t.check(host.styler.staleEvents > events0, "an opening fence near the top of a big document hits the re-lex bound (stale events \(host.styler.staleEvents - events0))")
            await t.spin(30)           // the scheduled restyle of the visible text
            assertMatchesFreshLex(t, host, range: visibleRange(host), "visible part right after the edit (the fence flipped everything below it)")
            t.scrollToTop(host, character: 0)
            assertMatchesFreshLex(t, host, range: visibleRange(host), "top of the document")
            host.styler.styleEverything()
            assertMatchesFreshLex(t, host, "whole document")
            tv.undoManager?.undo()
            host.styler.styleVisible()
            host.styler.styleEverything()
            assertMatchesFreshLex(t, host, "whole document after Undo")
            t.close(doc)
        }
        // 3. IME: no restyle while composing (the marked text keeps its own attributes), restyled after the commit
        do {
            let (doc, host, _) = try await openEditor(t, text: "# Title\n\nbody text\n", name: "live3.md")
            let tv = host.textView, theme = host.theme
            // (headless: no events, so undo groups are opened by hand, like a key event would)
            func grouped(_ body: () -> Void) { let um = tv.undoManager; um?.beginUndoGrouping(); body(); um?.endUndoGrouping() }
            tv.setSelectedRange(NSRange(location: 7, length: 0))
            let r0 = host.styler.editRestyles
            grouped { tv.setMarkedText("ab", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 7, length: 0)) }
            t.check(tv.hasMarkedText(), "composition started (hasMarkedText)")
            grouped { tv.setMarkedText("abc", selectedRange: NSRange(location: 3, length: 0), replacementRange: tv.markedRange()) }
            t.equal(host.styler.editRestyles, r0, "0 restyles were applied while composing (\(host.styler.editRestyles - r0))")
            t.equal(tv.string, "# Titleabc\n\nbody text\n", "composed text is in the document")
            grouped { tv.insertText("abc", replacementRange: tv.markedRange()) }
            await t.spin(10)
            t.check(!tv.hasMarkedText(), "composition committed")
            t.equal(t.fontOf(tv, at: 8)?.pointSize, theme.headingSize(1), "after the commit the heading line is restyled (font \(t.fontOf(tv, at: 8)?.pointSize ?? 0) pt)")
            assertMatchesFreshLex(t, host, "after IME commit")
            // cancel: composition removed again
            grouped { tv.setMarkedText("zz", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0)) }
            tv.unmarkText()
            grouped { tv.insertText("", replacementRange: NSRange(location: 0, length: 2)) }
            await t.spin(10)
            host.styler.styleVisible()
            assertMatchesFreshLex(t, host, "after a cancelled composition")
            t.close(doc)
        }
        // 4. a huge paste is never lexed synchronously: styled set forgotten, visible part restyled lazily
        do {
            let (doc, host, _) = try await openEditor(t, text: SelfTestCorpus.markdown(bytes: 100_000, seed: 8), name: "live4.md")
            let tv = host.textView
            let big = SelfTestCorpus.markdown(bytes: 700_000, seed: 9)
            let t0 = SelfTest.nowMs()
            t.typeText(big, into: doc, at: NSRange(location: 1000, length: 0))
            let ms = SelfTest.nowMs() - t0
            t.note(String(format: "paste of %d KB into a 100 KB document: %.1f ms (insert + layout bookkeeping; the paste is not lexed synchronously)", big.utf8.count / 1000, ms))
            t.check(host.styler.styled.count < ns(tv).length / 2, "after a huge paste the styled set was forgotten (\(host.styler.styled.count) of \(ns(tv).length) units) and refills lazily")
            host.styler.styleVisible()
            assertMatchesFreshLex(t, host, range: visibleRange(host), "visible part after the huge paste")
            host.styler.styleEverything()
            assertMatchesFreshLex(t, host, "whole document after the huge paste")
            t.close(doc)
        }
        // 6. an empty untitled document: the very first characters typed are styled like any others
        do {
            let doc = try t.newUntitled()
            guard let host = doc.host as? EditorViewController else { t.check(false, "no editor host for the untitled document"); return }
            let tv = host.textView
            t.equal(tv.string, "", "untitled document starts empty")
            t.typeText("# Hello\n\nsome `code` and **bold**\n", into: doc)
            t.equal(t.fontOf(tv, at: 3)?.pointSize, host.theme.headingSize(1), "untitled: the first typed line is a heading right away")
            t.check(tv.textStorage?.attribute(.luftigInline, at: (tv.string as NSString).range(of: "`code`").location, effectiveRange: nil) != nil, "untitled: inline code has its pill mark")
            assertMatchesFreshLex(t, host, "untitled document after typing")
            t.close(doc)
        }
        // 5. the decorations survive an edit that changes a block (code band grows, quote ends)
        do {
            let (doc, host, _) = try await openEditor(t, text: "```\ncode\n```\n\n> quote\n\ntext\n", name: "live5.md")
            let tv = host.textView, ts = tv.textStorage!
            func mark(_ s: String) -> (kind: BlockKind, depth: Int)? { BlockMark.decode(ts.attribute(.luftigBlock, at: ns(tv).range(of: s).location, effectiveRange: nil)) }
            t.check(mark("code")?.kind == .code && mark("> quote")?.kind == .quote && mark("text") == nil, "setup: code, quote and plain lines carry their marks")
            t.typeText("more ", into: doc, at: NSRange(location: ns(tv).range(of: "text").location, length: 0))
            t.check(mark("more") == nil, "typing in a plain line does not add a mark")
            t.typeText("```\n", into: doc, at: NSRange(location: ns(tv).range(of: "> quote").location, length: 0))      // the quote line becomes the first line of a new code block
            host.styler.styleVisible()
            assertMatchesFreshLex(t, host, "after turning the quote into a code block")
            t.close(doc)
        }
    }

    // MARK: reload-restyle

    /// The character at the top of the window once TextKit 1's lazy layout has settled around it: every layout query near the
    /// viewport replaces estimated heights by real ones, so the very first answer can differ from the second by a line.
    @MainActor static func settledAnchor(_ host: EditorViewController) -> ViewportAnchor? {
        let tv = host.textView
        var last: ViewportAnchor? = nil
        for _ in 0..<5 {
            guard let a = ViewportAnchor.capture(in: tv), let lm = tv.layoutManager else { return last }
            let from = max(0, a.characterIndex - 3000)
            lm.ensureLayout(forCharacterRange: NSRange(location: from, length: min(ns(tv).length, a.characterIndex + 3000) - from))
            if let l = last, l.characterIndex == a.characterIndex, abs(l.offsetIntoLine - a.offsetIntoLine) < 0.5 { return a }
            last = a
        }
        return last
    }

    @MainActor static func reloadRestyle(_ t: SelfTest.T) async throws {
        let base = SelfTestCorpus.markdown(bytes: 400_000, seed: 3)
        let (doc, host, file) = try await openEditor(t, text: base, name: "rr.md")
        let tv = host.textView, sv = host.scrollView
        let theme = host.theme
        func topLine() -> String {
            guard let a = settledAnchor(host) else { return "<none>" }
            let s = tv.string as NSString
            return s.substring(with: s.lineRange(for: NSRange(location: min(a.characterIndex, max(0, s.length - 1)), length: 0))).trimmingCharacters(in: .newlines)
        }
        func externalWrite(_ text: String, atomic: Bool = true) async -> Bool {
            let reloads0 = doc.stats.silentReloads
            if atomic {
                let tmp = file.appendingPathExtension("tmp")
                try? text.write(to: tmp, atomically: false, encoding: .utf8)
                await t.sh("mv \(t.q(tmp)) \(t.q(file))")
            } else {
                try? text.write(to: file, atomically: false, encoding: .utf8)
            }
            let ok = await t.waitFor(4000) { doc.stats.silentReloads > reloads0 }
            await t.sleep(80)
            return ok
        }
        let mid = ns(tv).length / 2
        t.scrollToTop(host, character: mid)
        let visible = visibleRange(host)
        let selRange = NSRange(location: visible.location + 120, length: 30)
        tv.setSelectedRange(selRange)
        let selText = ns(tv).substring(with: selRange)
        let topBefore = topLine()
        let y0 = sv.contentView.bounds.origin.y
        let anchorBefore = settledAnchor(host)
        t.check(host.styler.styled.count < ns(tv).length / 2, "setup: only part of the document is styled (\(host.styler.styled.count) of \(ns(tv).length) units)")

        // ---- 1. append at the END (far below the viewport): selection and scroll untouched, new text styled once it is shown
        let appended = "\n# APPENDED heading\n\nSome **appended** text with `code` and a [link](https://example.com).\n\n```swift\nlet appended = true\n```\n\n> an appended quote\n"
        let ok1 = await externalWrite(base + appended)
        t.check(ok1, "append: external write picked up")
        t.equal(tv.string, base + appended, "append: editor text equals the file")
        t.equal(tv.selectedRange(), selRange, "append: selection unchanged")
        t.equal(ns(tv).substring(with: tv.selectedRange()), selText, "append: still the same selected text")
        let anchorAfter = settledAnchor(host)
        t.check(anchorAfter?.characterIndex == anchorBefore?.characterIndex && abs((anchorAfter?.offsetIntoLine ?? -99) - (anchorBefore?.offsetIntoLine ?? 99)) < 1.5,
                "append: the same character is at the same place in the window (char \(anchorBefore?.characterIndex ?? -1) at +\(anchorBefore?.offsetIntoLine ?? -1) pt -> \(anchorAfter?.characterIndex ?? -1) at +\(anchorAfter?.offsetIntoLine ?? -1); scroll y \(Int(y0)) -> \(Int(sv.contentView.bounds.origin.y)): TextKit 1 re-estimates the height of unlaid-out text, so the absolute offset may move by a line)")
        t.equal(topLine(), topBefore, "append: the same line is at the top")
        t.check(!doc.isDocumentEdited && doc.undoManager?.canUndo != true, "append: clean, undo history cleared")
        assertMatchesFreshLex(t, host, range: visibleRange(host), "append: the visible part is still right")
        let endLoc = ns(tv).range(of: "# APPENDED heading").location
        t.scrollToTop(host, character: endLoc)
        t.equal(t.fontOf(tv, at: endLoc + 4)?.pointSize, theme.headingSize(1), "append: the appended heading is styled as H1 when shown")
        t.check(BlockMark.decode(tv.textStorage!.attribute(.luftigBlock, at: ns(tv).range(of: "let appended").location, effectiveRange: nil))?.kind == .code, "append: the appended code block has its band mark")
        assertMatchesFreshLex(t, host, range: NSRange(location: max(0, endLoc - 2000), length: min(ns(tv).length, endLoc + 1500) - max(0, endLoc - 2000)), "append: the end of the document")
        t.scrollToTop(host, character: mid)
        tv.setSelectedRange(selRange)

        // ---- 2. replace with text inserted ABOVE the viewport (atomic replace, like an editor or an agent): selection mapped, same top line
        let cur = tv.string as NSString
        let insertAt = cur.lineRange(for: NSRange(location: 3000, length: 0)).location
        let inserted = "## INSERTED ABOVE\n\n" + (0..<40).map { "inserted line \($0) with **bold** and `code`\n" }.joined() + "\n"
        let replaced = cur.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: inserted)
        let topBefore2 = topLine()
        let y1 = sv.contentView.bounds.origin.y
        let ok2 = await externalWrite(replaced)
        t.check(ok2, "replace above: external write picked up")
        t.equal(tv.string, replaced, "replace above: editor text equals the file")
        t.equal(tv.selectedRange(), NSRange(location: selRange.location + (inserted as NSString).length, length: selRange.length), "replace above: selection moved by the inserted length")
        t.equal(ns(tv).substring(with: tv.selectedRange()), selText, "replace above: same selected text")
        t.equal(topLine(), topBefore2, "replace above: the same line is at the top of the viewport (scroll anchor)")
        t.check(abs(sv.contentView.bounds.origin.y - y1) > 100, "replace above: the scroll offset really compensated (\(Int(y1)) -> \(Int(sv.contentView.bounds.origin.y)) pt)")
        assertMatchesFreshLex(t, host, range: visibleRange(host), "replace above: the visible part is correctly styled")
        t.scrollToTop(host, character: ns(tv).range(of: "## INSERTED ABOVE").location)
        t.equal(t.fontOf(tv, at: ns(tv).range(of: "## INSERTED ABOVE").location + 4)?.pointSize, theme.headingSize(2), "replace above: the inserted heading is H2 when shown")

        // ---- 3. a change that flips the block structure of everything below it (opening fence at the top, no closing one)
        t.scrollToTop(host, character: mid)
        let flipped = "``````\n" + replaced          // a 6-backtick fence is never closed by the corpus' 3-backtick fences: everything below becomes code
        let topBefore3 = topLine()
        let ok3 = await externalWrite(flipped)
        t.check(ok3, "fence at the top: external write picked up")
        t.equal(tv.string, flipped, "fence at the top: editor text equals the file")
        await t.spin(40)
        host.styler.styleVisible()
        t.equal(topLine(), topBefore3, "fence at the top: same line at the top of the viewport")
        assertMatchesFreshLex(t, host, range: visibleRange(host), "fence at the top: the visible part (now all code) is correctly styled")
        t.check(BlockMark.decode(tv.textStorage!.attribute(.luftigBlock, at: visibleRange(host).location, effectiveRange: nil))?.kind == .code, "fence at the top: the visible text carries the code mark")

        // ---- 4. replace everything by something unrelated (one big hunk): reset path
        let other = SelfTestCorpus.markdown(bytes: 250_000, seed: 77)
        let ok4 = await externalWrite(other)
        t.check(ok4, "unrelated content: external write picked up")
        t.equal(tv.string, other, "unrelated content: editor text equals the file")
        host.styler.styleVisible()
        assertMatchesFreshLex(t, host, range: visibleRange(host), "unrelated content: the visible part")
        host.styler.styleEverything()
        assertMatchesFreshLex(t, host, "unrelated content: whole document")
        t.check(UITrap.alerts.isEmpty, "no alert was shown")
        t.close(doc)
    }

    // MARK: font-size

    @MainActor static func fontSize(_ t: SelfTest.T) async throws {
        let saved = EditorPreferences.fontSize
        defer { EditorPreferences.fontSize = saved }
        EditorPreferences.fontSize = EditorPreferences.defaultFontSize
        // 6000 lines, an H1 every 25 lines: a heading is always near the viewport, and one is far away (never styled, never laid out)
        let text = (0..<6000).map { $0 % 25 == 0 ? "# Heading \($0)" : "Line \($0) lorem ipsum dolor sit amet, consectetur adipiscing elit" }.joined(separator: "\n") + "\n"
        let (docA, a, _) = try await openEditor(t, text: text, name: "fs-a.md")
        let (docB, b, _) = try await openEditor(t, text: text, name: "fs-b.md")            // the second window
        let tv = a.textView
        let mid = (tv.string as NSString).range(of: "# Heading 3000").location
        t.scrollToTop(a, character: mid)
        let defaultSize = EditorPreferences.defaultFontSize
        t.equal(a.fontSize, defaultSize, "start: default size \(defaultSize)")
        let farHeading = ns(tv).range(of: "# Heading 5950").location                      // never styled, never laid out
        let nearHeading = mid                                                           // styled (at the top of the viewport)
        t.check(!a.styler.styled.contains(farHeading), "setup: a far-away heading is NOT styled yet")
        t.equal(t.fontOf(tv, at: nearHeading + 3)?.pointSize, a.theme.headingSize(1), "setup: the near heading is styled (H1 \(a.theme.headingSize(1)) pt)")
        let topBefore = ViewportAnchor.capture(in: tv)

        for (label, action, expected) in [("Bigger (Cmd +)", { a.luftigIncreaseFontSize(nil) }, defaultSize + 1), ("Bigger again", { a.luftigIncreaseFontSize(nil) }, defaultSize + 2),
                                          ("Smaller (Cmd -)", { a.luftigDecreaseFontSize(nil) }, defaultSize + 1)] as [(String, () -> Void, CGFloat)] {
            action()
            let th = a.theme
            t.equal(a.fontSize, expected, "\(label): fontSize \(expected)")
            t.equal(th.baseSize, expected, "\(label): a new Theme with base \(expected)")
            t.equal(t.fontOf(tv, at: nearHeading + 3)?.pointSize, th.headingSize(1), "\(label): the already styled heading is H1 = \(th.headingSize(1)) pt")
            t.equal(t.fontOf(tv, at: nearHeading - 1)?.pointSize, expected, "\(label): the text before it has the new body size")
            t.equal(t.fontOf(tv, at: farHeading + 3)?.pointSize, expected, "\(label): NOT yet styled text has the new BASE size \(expected) (no stale font)")
            let farPara = tv.textStorage!.attribute(.paragraphStyle, at: farHeading + 3, effectiveRange: nil) as? NSParagraphStyle
            t.equal(farPara?.minimumLineHeight, th.bodyLineHeight, "\(label): not yet styled text has the new uniform line height \(th.bodyLineHeight)")
            t.equal(UserDefaults.standard.double(forKey: EditorPreferences.fontSizeKey), Double(expected), "\(label): persisted in UserDefaults")
            t.equal(b.fontSize, expected, "\(label): the SECOND window follows (\(b.fontSize))")
            t.equal(t.fontOf(b.textView, at: 3)?.pointSize == nil ? 0 : (t.fontOf(b.textView, at: 3)!.pointSize > 0 ? 1 : 0), 1, "\(label): second window text has a font")
            assertMatchesFreshLex(t, a, range: visibleRange(a), "\(label): visible part == fresh lex with the new theme")
        }
        // jump to the far heading: styled with the NEW theme
        t.scrollToTop(a, character: farHeading)
        t.equal(t.fontOf(tv, at: farHeading + 3)?.pointSize, a.theme.headingSize(1), "far heading, styled when scrolled to, uses the new theme (\(a.theme.headingSize(1)) pt)")
        assertMatchesFreshLex(t, a, range: visibleRange(a), "far region after the font change")
        // the line at the top of the window stays at the top
        t.scrollToTop(a, character: mid)
        let anchorNow = ViewportAnchor.capture(in: tv)
        a.luftigResetFontSize(nil)
        t.equal(a.fontSize, defaultSize, "Actual Size (Cmd 0): back to \(defaultSize)")
        t.equal(UserDefaults.standard.double(forKey: EditorPreferences.fontSizeKey), Double(defaultSize), "Actual Size persisted")
        let anchorAfter = ViewportAnchor.capture(in: tv)
        t.check(anchorNow != nil && anchorAfter != nil && abs(anchorNow!.characterIndex - anchorAfter!.characterIndex) < 400, "the text at the top of the window stays at the top (char \(anchorNow?.characterIndex ?? -1) -> \(anchorAfter?.characterIndex ?? -1))")
        _ = topBefore
        EditorPreferences.fontSize = 100
        t.equal(EditorPreferences.fontSize, EditorPreferences.fontSizeRange.upperBound, "font size is clamped (max \(EditorPreferences.fontSizeRange.upperBound))")
        EditorPreferences.fontSize = 1
        t.equal(EditorPreferences.fontSize, EditorPreferences.fontSizeRange.lowerBound, "font size is clamped (min \(EditorPreferences.fontSizeRange.lowerBound))")
        EditorPreferences.fontSize = defaultSize
        // a window opened AFTER a change starts with the persisted size
        EditorPreferences.fontSize = 20
        let (docC, c, _) = try await openEditor(t, text: "# Title\n\ntext\n", name: "fs-c.md")
        t.equal(c.fontSize, 20, "a window opened later starts with the persisted size")
        t.equal(t.fontOf(c.textView, at: 3)?.pointSize, c.theme.headingSize(1), "... and its text is styled with it")
        EditorPreferences.fontSize = defaultSize
        for d in [docA, docB, docC] { t.close(d) }
    }

    // MARK: window

    @MainActor static func windowScenario(_ t: SelfTest.T) async throws {
        let savedReadable = EditorPreferences.readableWidth
        defer { EditorPreferences.readableWidth = savedReadable }
        EditorPreferences.readableWidth = true
        let (doc, host, file) = try await openEditor(t, text: "# Title\n\nbody\n", name: "win.md", size: NSSize(width: 1400, height: 800))
        guard let w = doc.windowControllers.first?.window else { t.check(false, "no window"); return }
        let defaultSize = EditorWindowController.defaultContentSize()
        t.check(defaultSize.width <= 860 && defaultSize.width >= 700 && defaultSize.height >= 600 && defaultSize.height <= 1000, "default content size ~860 x 1000, fitted to the screen: \(defaultSize)")
        t.equal(w.title, "win.md", "title bar shows the document name")
        t.equal(w.representedURL?.standardizedFileURL.path, file.standardizedFileURL.path, "proxy icon: representedURL is the file")
        t.check(!w.isDocumentEdited, "edited dot is off for a clean document")
        t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))
        await t.sleep(30)
        t.check(w.isDocumentEdited, "edited dot turns on after typing")
        let tv = host.textView
        // readable column
        w.setContentSize(NSSize(width: 1400, height: 800)); w.contentView?.layoutSubtreeIfNeeded()
        let width = host.scrollView.contentView.bounds.width
        let col = tv.textContainer!.size.width - 0
        t.check(abs(col - 760) < 1.5 && tv.textContainerInset.width > 100, "wide window (\(Int(width)) pt): text column \(Int(col)) pt centred, inset \(Int(tv.textContainerInset.width)) pt")
        t.check(tv.textContainerInset.width >= DecorationMetrics.bandOutset + 1, "the inset leaves room for the band outset")
        w.setContentSize(NSSize(width: 700, height: 800)); w.contentView?.layoutSubtreeIfNeeded()
        t.check(tv.textContainer!.size.width < 700 && tv.textContainerInset.width == host.padding.textInsetHorizontal, "narrow window: column fills the window with the minimum inset (\(Int(tv.textContainerInset.width)) pt = the padding)")
        host.luftigToggleReadableWidth(nil)
        w.setContentSize(NSSize(width: 1400, height: 800)); w.contentView?.layoutSubtreeIfNeeded()
        let area = host.scrollView.contentView.bounds.width                          // (the outline on the left takes its 220 pt from the window first)
        let extra = CGFloat(0)                                      // (the right side has `textTrailingExtra` more air than the left: pitfall 34)
        let inset = host.padding.textInsetHorizontal
        t.check(tv.textContainerInset.width == inset && abs(tv.textContainer!.size.width - (area - 2 * inset - extra)) < 1.5 && area > 1100, "Wrap to Readable Width OFF: the text fills the text area of the 1400 pt window (\(Int(tv.textContainer!.size.width)) of \(Int(area)) pt, inset \(Int(inset)))")
        host.luftigToggleReadableWidth(nil)
        t.check(EditorPreferences.readableWidth && abs(tv.textContainer!.size.width - 760) < 1.5, "ON again: column back to 760 pt")
        // configuration of the text view
        t.check(!tv.isContinuousSpellCheckingEnabled && !tv.isGrammarCheckingEnabled, "spell checking is off by default")
        host.luftigToggleSpellChecking(nil)
        t.check(tv.isContinuousSpellCheckingEnabled, "Toggle Spell Checking turns it on")
        host.luftigToggleSpellChecking(nil)
        t.check(tv.usesFindBar && tv.isIncrementalSearchingEnabled, "the native find bar is used (usesFindBar)")
        t.check(tv.textLayoutManager == nil, "the text view is TextKit 1 (textLayoutManager == nil)")
        t.check(tv.layoutManager?.allowsNonContiguousLayout == true, "non-contiguous layout is ON")
        t.check(!tv.isRichText && tv.allowsUndo, "plain text, undo enabled")
        t.check(!tv.isAutomaticQuoteSubstitutionEnabled && !tv.isAutomaticDashSubstitutionEnabled && !tv.isAutomaticTextReplacementEnabled && !tv.isAutomaticLinkDetectionEnabled && !tv.smartInsertDeleteEnabled, "substitutions are off")
        t.check(tv.undoManager === doc.undoManager, "the text view uses the document's undo manager")
        t.check(tv.delegate === host && tv.textStorage?.delegate === host.styler, "delegates: view controller (editWillChange) and LazyStyler (didProcessEditing)")
        t.check(tv.textContainer!.lineFragmentPadding == 0, "lineFragmentPadding == 0 (text starts at the column edge)")
        // About panel data: name + version from Info.plist
        let opts = AppDelegate.aboutPanelOptions()
        t.check(opts[.credits] != nil, "About panel has a credits line")
        let info = Bundle.main.infoDictionary ?? [:]
        t.equal(info["CFBundleShortVersionString"] as? String, "1.0.0", "Info.plist version is 1.0.0 (shown by the About panel)")
        t.check((info["CFBundleName"] as? String)?.hasPrefix("luftig") == true, "Info.plist name: \(info["CFBundleName"] as? String ?? "nil")")
        t.close(doc)
    }

    // MARK: open-perf

    /// One open of `url`: document + window + text view + first screen laid out, styled and drawn. Returns the phases in ms.
    @MainActor static func openOnce(_ url: URL, width: Double = 900, height: Double = 700) async throws -> (doc: MarkdownDocument, total: Double, read: Double, window: Double, layout: Double, draw: Double, stall: Double) {
        let meter = StallMeter()
        meter.start()
        let t0 = SelfTest.nowMs()
        let (d, _) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
        let t1 = SelfTest.nowMs()
        guard let md = d as? MarkdownDocument else { throw NSError(domain: "t", code: 3) }
        md.makeWindowControllers()
        guard let w = md.windowControllers.first?.window, let host = md.host as? EditorViewController else { throw NSError(domain: "t", code: 4) }
        w.setContentSize(NSSize(width: width, height: height))
        w.contentView?.layoutSubtreeIfNeeded()
        let t2 = SelfTest.nowMs()
        host.styler.styleVisible()
        _ = host.textView.layoutManager?.ensureLayout(forBoundingRect: host.textView.visibleRect, in: host.textView.textContainer!)
        let t3 = SelfTest.nowMs()
        if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: host.scrollView.bounds) { host.scrollView.cacheDisplay(in: host.scrollView.bounds, to: rep) }
        let t4 = SelfTest.nowMs()
        return (md, t4 - t0, t1 - t0, t2 - t1, t3 - t2, t4 - t3, meter.stop())
    }

    @MainActor static func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    /// Runs this executable again as a fresh process and returns its stdout.
    @MainActor static func runChild(_ t: SelfTest.T, _ args: [String]) async -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        return await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            let box = DataBox()
            pipe.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }
            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                box.append(pipe.fileHandleForReading.readDataToEndOfFile())
                c.resume(returning: String(decoding: box.data, as: UTF8.self))
            }
            do { try p.run() } catch { c.resume(returning: "") }
        }
    }

    @MainActor static func openCold(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest open-cold --input f.md"); return }
        let r = try await openOnce(URL(fileURLWithPath: input))
        out("COLD_OPEN_MS \(String(format: "%.2f", r.total)) read \(String(format: "%.2f", r.read)) window \(String(format: "%.2f", r.window)) layout \(String(format: "%.2f", r.layout)) draw \(String(format: "%.2f", r.draw))")
        t.check(true, "cold open \(r.total) ms")
        t.close(r.doc)
    }

    @MainActor static func openPerf(_ t: SelfTest.T) async throws {
        #if DEBUG
        t.note("build: DEBUG - the numbers are meaningless, use a release build")
        #endif
        // budget table of docs/DESIGN.md: 1 MB < 100 ms, 10 MB < 400 ms (the 100 KB and 20 MB rows use the same limits as the nearest row)
        let rows: [(label: String, bytes: Int, budget: Double, runs: Int)] = [("100 KB", 100_000, 100, 7), ("1 MB", 1_000_000, 100, 7), ("10 MB", 10_000_000, 400, 5), ("20 MB", 20_000_000, 400, 3)]
        var first = true
        for row in rows {
            let url = t.corpusFile(bytes: row.bytes)
            _ = try? Data(contentsOf: url)                      // warm file cache, like a recently used file
            var totals: [Double] = [], draws: [Double] = [], stalls: [Double] = []
            var last: (read: Double, window: Double, layout: Double, draw: Double) = (0, 0, 0, 0)
            var firstRun = 0.0
            for i in 0..<row.runs {
                let r = try await openOnce(url)
                totals.append(r.total); draws.append(r.draw); stalls.append(r.stall)
                last = (r.read, r.window, r.layout, r.draw)
                if i == 0 && first { firstRun = r.total }
                // what was opened is really on screen styled: the first heading / lines are styled, text equals the file
                if i == 0, let host = r.doc.host as? EditorViewController {
                    t.check(host.currentText.length > row.bytes / 2 && host.styler.styled.contains(0), "\(row.label): loaded (\(host.currentText.length) units), first screen styled")
                    let vis = visibleRange(host)
                    assertMatchesFreshLex(t, host, range: vis, "\(row.label): the first screen (\(vis.length) units)")
                }
                t.close(r.doc)
                await t.spin(5)
            }
            let med = median(totals)
            t.note(String(format: "%@: median %.1f ms [min %.1f max %.1f] of %d fresh documents; last run: read+decode %.1f, window+text %.1f, style+layout %.1f, draw %.1f; longest main-thread stall %.1f ms%@",
                          row.label, med, totals.min() ?? 0, totals.max() ?? 0, row.runs, last.read, last.window, last.layout, last.draw, stalls.max() ?? 0, first ? String(format: "; the very first open of the process (cold AppKit) %.1f ms", firstRun) : ""))
            first = false
            t.check(med < row.budget, String(format: "%@ open -> first screen laid out + styled + drawn: median %.1f ms %@ budget %.0f ms: %@", row.label, med, med < row.budget ? "<" : ">=", row.budget, med < row.budget ? "PASS" : "FAIL"))
        }
        // cold, separate processes (fresh AppKit, fresh caches except the file cache): median of 3
        for (label, bytes, budget) in [("1 MB", 1_000_000, 100.0), ("10 MB", 10_000_000, 400.0)] {
            let url = t.corpusFile(bytes: bytes)
            var runs: [Double] = []
            for i in 0..<3 {
                let outText = await runChild(t, ["--selftest", "open-cold", "--input", url.path, "--workdir=\(t.work.path)/cold\(i)"])
                if let line = outText.split(separator: "\n").first(where: { $0.hasPrefix("COLD_OPEN_MS") }), let v = Double(line.split(separator: " ")[1]) { runs.append(v) }
            }
            let med = median(runs)
            t.note("\(label) in a FRESH process (includes the first-window AppKit warm-up): \(runs.map { String(format: "%.1f", $0) }) ms")
            t.check(runs.count == 3 && med < budget, String(format: "%@ cold open: median of 3 fresh processes %.1f ms %@ budget %.0f ms: %@", label, med, med < budget ? "<" : ">=", budget, med < budget ? "PASS" : "FAIL"))
        }
        // concurrent reading (the document spike's switch) for the record
        let mixed = t.corpusFile(bytes: 10_000_000)
        for concurrent in [false, true] {
            MarkdownDocument.concurrentReading = concurrent
            let r = try await openOnce(mixed)
            t.note(String(format: "10 MB, concurrentReading=%@: total %.1f ms, longest main-thread stall %.1f ms", concurrent ? "true " : "false", r.total, r.stall))
            t.close(r.doc)
        }
        MarkdownDocument.concurrentReading = false
    }

    // MARK: typing

    @MainActor static func typing(_ t: SelfTest.T) async throws {
        // Two numbers per keystroke:
        //   REAL      insertText + restyle + layout + redraw of the DIRTY region (the edited line +- one line, full width) - what a key press costs
        //   UPPER     insertText + restyle + layout + FULL redraw of everything visible - an upper bound (the spike's measure)
        // The budget (8 ms / 16 ms) is asserted on REAL; UPPER must stay below 2x the budget (it moves with machine load: the very same
        // code measured 4.0-5.3 ms on a quiet machine and 6-8 ms while other processes were busy; file read+decode were 50 % slower then too).
        for (label, bytes, budgetMedian, budgetP95) in [("200 KB", 200_000, 8.0, 16.0), ("10 MB", 10_000_000, 16.0, 32.0)] {
            // edited documents are COPIES: the cached corpus file must never be written (autosave)
            let src = t.corpusFile(bytes: bytes)
            let copy = t.url("typing-\(bytes).md")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: src, to: copy)
            let doc = try await t.open(copy, size: NSSize(width: 900, height: 700))
            guard let host = doc.host as? EditorViewController else { continue }
            let tv = host.textView
            let len = ns(tv).length
            for (position, frac) in [("start", 0.0), ("middle", 0.5), ("end", 0.97)] {
                let tNav = SelfTest.nowMs()
                t.scrollToTop(host, character: Int(Double(len) * frac))                      // "getting there" (a jump), not a keystroke
                let navMs = SelfTest.nowMs() - tNav
                let vis = visibleRange(host)
                var loc = vis.location + min(vis.length / 2, 400)
                loc = (ns(tv).lineRange(for: NSRange(location: loc, length: 0))).location
                tv.setSelectedRange(NSRange(location: loc, length: 0))
                var real: [Double] = [], upper: [Double] = []
                for i in 0..<70 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    t.typeText(i % 11 == 10 ? "#" : "a", into: doc, at: NSRange(location: loc + i, length: 0))
                    _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    // the dirty region: the edited line fragment +- one line, full width
                    var strip = tv.visibleRect
                    if let lm = tv.layoutManager {
                        let g = lm.glyphIndexForCharacter(at: min(loc + i, max(0, lm.numberOfGlyphs - 1)))
                        let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).offsetBy(dx: 0, dy: tv.textContainerOrigin.y)
                        strip = NSRect(x: 0, y: r.minY - r.height, width: tv.bounds.width, height: r.height * 3).intersection(tv.visibleRect)
                    }
                    let stripInScroll = host.scrollView.convert(strip, from: tv)
                    if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: stripInScroll) { host.scrollView.cacheDisplay(in: stripInScroll, to: rep) }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    if let rep = host.scrollView.bitmapImageRepForCachingDisplay(in: host.scrollView.bounds) { host.scrollView.cacheDisplay(in: host.scrollView.bounds, to: rep) }
                    let t3 = DispatchTime.now().uptimeNanoseconds
                    real.append(Double(t2 - t0) / 1e6)
                    upper.append(Double(t1 - t0 + t3 - t2) / 1e6)
                }
                func stats(_ a: [Double]) -> (med: Double, p95: Double, max: Double) { let s = a.dropFirst(10).sorted(); return (s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last ?? 0) }
                let r = stats(real), u = stats(upper)
                t.note(String(format: "%@ doc, caret at the %@: keystroke REAL (insert + restyle + layout + dirty-strip redraw) median %.2f ms, p95 %.2f, max %.2f; UPPER bound (full redraw) median %.2f, p95 %.2f; getting there (jump + style) %.1f ms",
                              label, position, r.med, r.p95, r.max, u.med, u.p95, navMs))
                let ok = r.med < budgetMedian && r.p95 < budgetP95
                t.check(ok, String(format: "%@ typing at the %@: median %.2f ms < %.0f and p95 %.2f ms < %.0f: %@", label, position, r.med, budgetMedian, r.p95, budgetP95, ok ? "PASS" : "FAIL"))
                t.check(u.med < budgetMedian * 2 && u.p95 < budgetP95 * 2, String(format: "%@ typing at the %@, upper bound with a FULL redraw: median %.2f ms, p95 %.2f ms (< 2x budget)", label, position, u.med, u.p95))
            }
            // the restyle alone (what didProcessEditing costs per keystroke): lexer + attribute application
            let before = host.styler.appliedRunCount
            t.typeText("b", into: doc, at: NSRange(location: ns(tv).length / 2, length: 0))
            t.note("one keystroke applied \(host.styler.appliedRunCount - before) runs in the edited region")
            t.close(doc)
        }
    }

    // MARK: idle, memory

    @MainActor static func idle(_ t: SelfTest.T) async throws {
        let url = t.corpusFile(bytes: 20_000_000)
        let r = try await openOnce(url, width: 900, height: 800)
        let doc = r.doc
        guard let host = doc.host as? EditorViewController else { return }
        t.note(String(format: "20 MB opened in %.1f ms", r.total))
        // scroll a little and let everything settle: the lazy styling is demand driven, there is no background fill to wait for
        for frac in [0.0, 0.3, 0.6] { t.scrollToTop(host, character: Int(20_000_000 * frac)) }
        t.scrollToTop(host, character: 0)
        await t.sleep(2000)                              // NSDocument's own xattr write at open echoes through the presenter ~1.1 s later
        let checks0 = doc.stats.checks
        let cpu0 = ProcessMetrics.cpuSeconds()
        let t0 = SelfTest.nowMs()
        try? await Task.sleep(nanoseconds: 3_000_000_000)        // ONE wake-up (t.sleep polls every 2 ms and would measure itself)
        let cpu = ProcessMetrics.cpuSeconds() - cpu0
        let wall = (SelfTest.nowMs() - t0) / 1000
        t.note(String(format: "idle for %.2f s: %.1f ms of CPU time (%.2f %% of one core), file-monitor checks %d, polling %@", wall, cpu * 1000, cpu / wall * 100, doc.stats.checks - checks0, doc.monitor?.isPolling == true ? "yes" : "no"))
        t.check(cpu / wall < 0.01, String(format: "CPU while idle: %.2f %% of one core over %.1f s (< 1 %%)", cpu / wall * 100, wall))
        t.equal(doc.stats.checks, checks0, "the file monitor did nothing while idle (0 checks)")
        t.check(doc.monitor?.isPolling == false, "no stat polling on a local file system (kqueue only)")
        t.check(host.styler.styled.count < 2_000_000, "only the viewport neighbourhood is styled (\(host.styler.styled.count) of 20 000 000 units): no background fill")
        t.close(doc)
    }

    /// Runs in a FRESH process (the parent process has generated 20 MB corpora, which would pollute RSS).
    @MainActor static func memoryChild(_ t: SelfTest.T) async throws {
        guard let input = SelfTest.argument("input") else { t.check(false, "usage: --selftest memory-child --input f.md"); return }
        let base = ProcessMetrics.residentBytes()
        let r = try await openOnce(URL(fileURLWithPath: input))
        guard let host = r.doc.host as? EditorViewController else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: input)[.size] as? Int) ?? 10_000_000
        let afterOpen = ProcessMetrics.residentBytes()
        for frac in [0.5, 0.25, 0.75, 0.9, 0.0] { t.scrollToTop(host, character: Int(Double(size) * frac)) }
        let afterScroll = ProcessMetrics.residentBytes()
        out("RSS \(base) \(afterOpen) \(afterScroll)")
        t.close(r.doc)
        t.check(true, "measured")
    }

    @MainActor static func memory(_ t: SelfTest.T) async throws {
        for (label, bytes) in [("10 MB", 10_000_000), ("20 MB", 20_000_000)] {
            let url = t.corpusFile(bytes: bytes)
            let outText = await runChild(t, ["--selftest", "memory-child", "--input", url.path, "--workdir=\(t.work.path)/mem\(bytes)"])
            guard let line = outText.split(separator: "\n").first(where: { $0.hasPrefix("RSS ") }) else { t.check(false, "\(label): the child process reported nothing"); continue }
            let v = line.split(separator: " ").dropFirst().compactMap { Int($0) }
            guard v.count == 3 else { t.check(false, "\(label): bad report \(line)"); continue }
            t.note("\(label) document, fresh process: RSS \(ProcessMetrics.mb(v[0])) before opening -> \(ProcessMetrics.mb(v[1])) after opening (+\(ProcessMetrics.mb(v[1] - v[0]))) -> \(ProcessMetrics.mb(v[2])) after scrolling to 5 places (+\(ProcessMetrics.mb(v[2] - v[0])) over the empty app)")
            t.check(v[2] < 600 * 1_048_576, "RSS with a \(label) document open and scrolled around: \(ProcessMetrics.mb(v[2])) < 600 MB")
        }
    }
}
#endif
