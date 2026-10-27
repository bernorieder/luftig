#if LUFTIG_SELFTEST
// SelfTestTables.swift - tables aligned on screen, and Format > Align Table (TableAlignment.swift).
//   table-align        the pipes of every row line up (measured in the laid-out text): outer pipes or none, a quote, bold / code / CJK / emoji /
//                      a combining accent in cells; the file is unchanged; an aligned source, a tab, a too wide table are left alone
//   table-align-edit   a keystroke in one cell re-aligns the whole table, also a long table styled lazily from its middle; a table over the size
//                      bound is never aligned; the window getting narrower / wider than a table drops / restores its alignment; == a fresh restyle
//   table-format       Format > Align Table: the rewritten source (widths, colons, right / centred columns, quotes, missing cells, escaped pipes,
//                      wide characters), the caret stays in its cell, one undo step, a second run changes nothing, the menu item only in a table

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let tableScenarios: [SelfTest.Scenario] = [
        .init(name: "table-align", summary: "tables aligned on screen: the pipes of every row line up (outer pipes or none, quotes, bold / code / CJK / emoji / combining cells), the file unchanged, aligned / tab / too wide tables left alone", run: { t in try await tableAlign(t) }),
        .init(name: "table-align-edit", summary: "a keystroke re-aligns the whole table (also a long one styled from its middle), the size bound, narrower / wider window, == a fresh restyle", run: { t in try await tableAlignEdit(t) }),
        .init(name: "table-format", summary: "Format > Align Table: the rewritten source, the caret in its cell, one undo step, idempotent, the menu item only in a table", run: { t in try await tableFormat(t) }),
    ]

    // MARK: helpers

    /// The x positions (text container coordinates) of the closing pipes of each row of the table whose header line starts with `header`.
    @MainActor static func closingPipes(_ host: EditorViewController, header: String) -> [[CGFloat]] {
        let tv = host.textView
        let text = ns(tv)
        let at = text.range(of: header).location
        guard at != NSNotFound, let lm = tv.layoutManager, let tc = tv.textContainer else { return [] }
        let runs = MarkdownStyler().lexAll(text)
        let all = TableAligner.lines(runs, text: text, in: NSRange(location: 0, length: text.length))
        guard let first = all.firstIndex(where: { $0.start <= at && at < max($0.next, $0.start + 1) }) else { return [] }
        var rows: [[CGFloat]] = []
        var i = first
        while i < all.count, all[i].isTable, i == first || !all[i].isHeader {
            let line = all[i]
            var xs: [CGFloat] = []
            var sawText = false
            for p in line.start..<line.end {
                let c = text.character(at: p)
                let style = runs.first { NSLocationInRange(p, $0.range) }?.style ?? MDStyle()
                guard style.contains(.table) else { continue }
                if c == 0x7C && style.contains(.tableDelimiter) {
                    if sawText {
                        lm.ensureLayout(forCharacterRange: NSRange(location: p, length: 1))
                        let g = lm.glyphRange(forCharacterRange: NSRange(location: p, length: 1), actualCharacterRange: nil)
                        xs.append(lm.boundingRect(forGlyphRange: g, in: tc).minX)
                    }
                    sawText = true
                } else if c != 0x20 {
                    sawText = true
                }
            }
            rows.append(xs)
            i += 1
        }
        return rows
    }

    /// True when every column's closing pipes are at the same x (within half a point) in every row that has one, and there are at least two rows.
    static func pipesAligned(_ rows: [[CGFloat]]) -> Bool {
        guard rows.count >= 2 else { return false }
        let columns = rows.map(\.count).max() ?? 0
        for k in 0..<columns {
            let xs = rows.compactMap { $0.count > k ? $0[k] : nil }
            if let lo = xs.min(), let hi = xs.max(), hi - lo > 0.5 { return false }
        }
        return columns > 0
    }

    /// Characters of `range` that carry a `.kern` attribute.
    @MainActor static func kernCount(_ host: EditorViewController, in range: NSRange? = nil) -> Int {
        let ts = host.textView.textStorage!
        var n = 0
        ts.enumerateAttribute(.kern, in: range ?? NSRange(location: 0, length: ts.length)) { v, r, _ in if v != nil { n += r.length } }
        return n
    }

    @MainActor static func tableRange(_ host: EditorViewController, header: String) -> NSRange {
        let text = ns(host.textView)
        let at = text.range(of: header).location
        let runs = MarkdownStyler().lexAll(text)
        let all = TableAligner.lines(runs, text: text, in: NSRange(location: 0, length: text.length))
        guard let first = all.firstIndex(where: { $0.start <= at && at < $0.next }) else { return NSRange(location: 0, length: 0) }
        var last = first
        while last + 1 < all.count, all[last + 1].isTable, !all[last + 1].isHeader { last += 1 }
        return NSRange(location: all[first].start, length: all[last].end - all[first].start)
    }

    // MARK: table-align

    static let alignSample = """
    # Tables

    | Name | Role | Notes |
    |---|:---:|--:|
    | Ada | engineer | wrote the **first** program |
    | Grace Hopper | admiral | `COBOL` and more |
    | x | | last |

    Rows without outer pipes:

    alpha | b | c
    --- | --- | ---
    d | eeeeeeee | f

    > | quoted | table |
    > |---|---|
    > | a | a longer cell |

    | wide 日本語 | emoji | accent |
    |---|---|---|
    | 中 | 😀 | cafe\u{301} |
    | abc | 👍🏽 ok | e\u{301}e\u{301} |

    |x|cafe\u{301}|👍🏽|日|
    |---|---|---|---|
    |longer|a|b|c|

    | aligned | already |
    | ------- | ------- |
    | a       | b       |

    | tab\tcell | x |
    |---|---|
    | y | z |

    | this table is far too wide for the column | because its cells are long | and there are many of them | so it cannot fit |
    |---|---|---|---|
    | a | b | c | d |

    The end.

    """

    @MainActor static func tableAlign(_ t: SelfTest.T) async throws {
        let (doc, host, url) = try await openEditor(t, text: alignSample, name: "tables.md", size: NSSize(width: 900, height: 900))
        host.styler.styleEverything()
        for header in ["| Name |", "alpha |", "> | quoted |", "| wide 日本語 |", "|x|caf"] {
            let rows = closingPipes(host, header: header)
            t.check(pipesAligned(rows), "\(header) the closing pipes of every row line up: \(rows.map { $0.map { Int($0.rounded()) } })")
        }
        t.equal(kernCount(host, in: tableRange(host, header: "| aligned |")), 0, "a table aligned in the source gets no extra space")
        let tabRows = closingPipes(host, header: "| tab\t")
        t.check(kernCount(host, in: tableRange(host, header: "| tab\t")) == 0, "a table with a tab gets no extra space (\(tabRows.map { $0.map { Int($0) } }))")
        let wide = tableRange(host, header: "| this table")
        t.check(kernCount(host, in: wide) == 0, "a table wider than the column (\(Int(host.provider.tables.widthLimit)) pt) is left as it is")
        t.check(kernCount(host) > 0, "the other tables carry the extra space (\(kernCount(host)) characters)")
        t.equal(host.textView.string, alignSample, "the text is unchanged")
        assertMatchesFreshLex(t, host, "the whole sample")
        // the caret moves through the aligned cells character by character, and a click in the space before a pipe lands next to the pipe
        let tv = host.textView
        let row = ns(tv).range(of: "| Ada |")
        tv.setSelectedRange(NSRange(location: row.location + 5, length: 0))         // after "Ada"
        tv.moveRight(nil)
        t.equal(tv.selectedRange().location, row.location + 6, "→ moves one character (into the space before the pipe)")
        tv.moveRight(nil)
        t.equal(tv.selectedRange().location, row.location + 7, "→ again: past the pipe")
        // saving writes exactly the text (the extra space is not in it)
        doc.updateChangeCount(.changeDone)
        let saved: Error? = await withCheckedContinuation { c in doc.save(to: url, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { c.resume(returning: $0) } }
        t.check(saved == nil, "saved")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        t.equal(onDisk, alignSample, "the saved file is the source, without the alignment")
        t.close(doc)
    }

    // MARK: table-align-edit

    @MainActor static func tableAlignEdit(_ t: SelfTest.T) async throws {
        // 1. typing in one cell re-aligns every row
        do {
            var rows = (1...12).map { "| r\($0) | value \($0) | x |" }
            rows.insert("|---|---|---|", at: 0)
            let text = "Intro.\n\n| key | value | z |\n" + rows.joined(separator: "\n") + "\n\nAfter.\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "edit.md")
            let tv = host.textView
            host.styler.styleEverything()
            t.check(pipesAligned(closingPipes(host, header: "| key |")), "before: aligned")
            let at = ns(tv).range(of: "| r5 |").location + 4
            var allAligned = true
            for ch in "longer and longer" {
                t.typeText(String(ch), into: doc, at: NSRange(location: tv.selectedRange().location == 0 ? at : tv.selectedRange().location, length: 0))
                if !pipesAligned(closingPipes(host, header: "| key |")) { allAligned = false }
            }
            t.check(allAligned, "after every keystroke in one cell, every row is aligned to it")
            let widest = closingPipes(host, header: "| key |")
            t.check(widest.count == 14 && widest[0][0] > 100, "the first column follows the longest cell (\(Int(widest[0][0])) pt)")
            for _ in 0..<5 { let l = tv.selectedRange().location; t.typeText("", into: doc, at: NSRange(location: l - 1, length: 1)) }
            t.check(pipesAligned(closingPipes(host, header: "| key |")), "after Backspace: aligned")
            tv.undoManager?.undo()
            t.check(pipesAligned(closingPipes(host, header: "| key |")), "after Undo: aligned")
            assertMatchesFreshLex(t, host, "after the edits")
            t.close(doc)
        }
        // 2. a long table styled lazily from its middle, and an edit far below its header
        do {
            let body = (1...420).map { "| row \($0) | some text \($0 * 7) | \(String(repeating: "#", count: $0 % 9)) |" }.joined(separator: "\n")
            let text = "# Long\n\n" + String(repeating: "Paragraph.\n\n", count: 40) + "| head | text | marks |\n|---|---|---|\n" + body + "\n\nAfter.\n"
            t.check((text as NSString).length < 24_000 + 2_000 && body.utf16.count < TableAligner.maxTableUnits, "setup: the table is under the bound (\(body.utf16.count) units)")
            let (doc, host, _) = try await openEditor(t, text: text, name: "long.md")
            let tv = host.textView
            let mid = ns(tv).range(of: "| row 300 |").location
            t.scrollToTop(host, character: mid)
            host.styler.styleVisible()
            assertMatchesFreshLex(t, host, range: visibleRange(host), "the middle of a long table, styled lazily")
            t.check(kernCount(host, in: visibleRange(host)) > 0, "... and aligned")
            var times: [Double] = []
            for ch in "a much longer cell text" {
                let t0 = SelfTest.nowMs()
                t.typeText(String(ch), into: doc, at: NSRange(location: tv.selectedRange().location > mid ? tv.selectedRange().location : mid + 9, length: 0))
                times.append(SelfTest.nowMs() - t0)
            }
            times.sort()
            t.note(String(format: "typing in row 300 of a %d-row table: median %.1f ms, max %.1f ms per keystroke (incl. restyling the whole table)", 420, times[times.count / 2], times.last!))
            t.check(times[times.count / 2] < 60, "typing in a long table stays fast (median \(String(format: "%.1f", times[times.count / 2])) ms)")
            t.scrollToTop(host, character: ns(tv).range(of: "| head |").location)
            host.styler.styleVisible()
            assertMatchesFreshLex(t, host, range: visibleRange(host), "the top of the table, after an edit 300 rows below it")
            host.styler.styleEverything()
            t.check(pipesAligned(closingPipes(host, header: "| head |")), "every row of the long table is aligned")
            assertMatchesFreshLex(t, host, "the whole document")
            t.close(doc)
        }
        // 3. a table over the size bound is never aligned, from wherever it is styled
        do {
            let body = (1...1100).map { "| row \($0) | text \($0) | y |" }.joined(separator: "\n")
            t.check(body.utf16.count > TableAligner.maxTableUnits, "setup: the table is over the bound (\(body.utf16.count) units)")
            let text = "| big | table | z |\n|---|---|---|\n" + body + "\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "big.md")
            t.scrollToTop(host, character: (text as NSString).length / 2)
            host.styler.styleVisible()
            t.typeText("xyz", into: doc, at: NSRange(location: ns(host.textView).range(of: "| row 600 |").location + 2, length: 0))
            host.styler.styleEverything()
            t.equal(kernCount(host), 0, "no row of a table over the bound gets extra space")
            assertMatchesFreshLex(t, host, "the big table")
            t.close(doc)
        }
        // 4. the window gets narrower than a table, and wider again
        do {
            let text = "Text.\n\n| a fairly long header cell for this column | x |\n|---|---|\n| x | another long header cell, also long |\n\nEnd.\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "resize.md", size: NSSize(width: 1400, height: 500))
            let window = host.view.window!
            host.styler.styleEverything()
            t.check(pipesAligned(closingPipes(host, header: "| a fairly")), "wide window (\(Int(host.provider.tables.widthLimit)) pt): aligned")
            window.setContentSize(NSSize(width: 900, height: 500)); window.contentView?.layoutSubtreeIfNeeded()
            await t.spin(30)
            host.styler.styleEverything()
            t.check(kernCount(host) == 0, "a window narrower than the aligned table (\(Int(host.provider.tables.widthLimit)) pt): no alignment (no extra wrapping)")
            assertMatchesFreshLex(t, host, "narrow")
            window.setContentSize(NSSize(width: 1400, height: 500)); window.contentView?.layoutSubtreeIfNeeded()
            await t.spin(30)
            host.styler.styleVisible()
            t.check(pipesAligned(closingPipes(host, header: "| a fairly")), "wide again: aligned again")
            assertMatchesFreshLex(t, host, "wide again")
            t.close(doc)
        }
    }

    // MARK: table-format

    /// The pure formatter on `text` with the caret at `caret`: the new text and caret (or nil: no change).
    static func formatted(_ text: String, caret: Int = 0) -> (String, Int)? {
        let ns = text as NSString
        let runs = MarkdownStyler().lexAll(ns)
        let lines = TableAligner.lines(runs, text: ns, in: NSRange(location: 0, length: ns.length))
        guard let first = lines.firstIndex(where: \.isTable) else { return nil }
        var last = first
        while last + 1 < lines.count, lines[last + 1].isTable, !lines[last + 1].isHeader { last += 1 }
        guard let c = TableFormatter.change(text: ns, runs: runs, lines: Array(lines[first...last]), caret: caret) else { return nil }
        return (ns.replacingCharacters(in: c.range, with: c.replacement), c.selection.location)
    }

    @MainActor static func tableFormat(_ t: SelfTest.T) async throws {
        let cases: [(String, String, String)] = [
            ("widths, a centred column", "| a | bb |\n|---|:-:|\n| ccc | d |", "| a   | bb  |\n| --- | :-: |\n| ccc |  d  |"),
            ("no outer pipes", "a | b\n--|--\nccc | d", "| a   | b   |\n| --- | --- |\n| ccc | d   |"),
            ("a right-aligned column", "| n |\n|--:|\n| 1 |\n| 100 |", "|   n |\n| --: |\n|   1 |\n| 100 |"),
            ("a left-aligned column", "| n |\n|:--|\n| 12345 |", "| n     |\n| :---- |\n| 12345 |"),
            ("wide characters count two", "| 日本 | x |\n|---|---|\n| a | y |", "| 日本 | x   |\n| ---- | --- |\n| a    | y   |"),
            ("in a quote", "> | a | b |\n> |---|---|\n> | c | dd |", "> | a   | b   |\n> | --- | --- |\n> | c   | dd  |"),
            ("a missing cell", "| a | b |\n|---|---|\n| c |", "| a   | b   |\n| --- | --- |\n| c   |     |"),
            ("an escaped pipe", "| a \\| b | c |\n|---|---|\n| d | e |", "| a \\| b | c   |\n| ------ | --- |\n| d      | e   |"),
            ("bold and code", "| **x** | `y` |\n|---|---|\n| z | w |", "| **x** | `y` |\n| ----- | --- |\n| z     | w   |"),
            ("CRLF line breaks", "| a | b |\r\n|---|---|\r\n| ccc | d |\r\n", "| a   | b   |\r\n| --- | --- |\r\n| ccc | d   |\r\n"),
        ]
        for (label, input, expected) in cases {
            let out = formatted(input)?.0
            t.equal(out, expected, "\(label)")
            if let out { t.check(formatted(out) == nil, "\(label): a second run changes nothing") }
        }
        // the caret stays in its cell: after "cc" of "ccc"
        let src = "| a | bb |\n|---|:-:|\n| ccc | d |"
        let caret = (src as NSString).range(of: "ccc").location + 2
        if let (out, newCaret) = formatted(src, caret: caret) {
            t.equal(newCaret, (out as NSString).range(of: "ccc").location + 2, "the caret stays after \"cc\" (\(newCaret))")
        } else { t.check(false, "the caret case formats") }
        let caret2 = (src as NSString).range(of: "d |").location + 1
        if let (out, newCaret) = formatted(src, caret: caret2) {
            t.equal(newCaret, (out as NSString).range(of: "d  |").location + 1, "after the last cell's text: still right after it")
        }

        // the editor: the menu item, one undo step, no extra space on screen afterwards
        let text = "Before.\n\n| name | value |\n|---|--:|\n| alpha | 1 |\n| b | 22222 |\n\nAfter.\n"
        let (doc, host, _) = try await openEditor(t, text: text, name: "format.md")
        let tv = host.textView
        let item = NSMenuItem(title: "Align Table", action: #selector(LuftigEditorActions.luftigAlignTable(_:)), keyEquivalent: "")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        t.check(!host.validateMenuItem(item), "Align Table is disabled outside a table")
        tv.setSelectedRange(NSRange(location: ns(tv).range(of: "alpha").location + 3, length: 0))
        t.check(host.validateMenuItem(item), "... and enabled in one")
        host.styler.styleEverything()
        t.check(kernCount(host) > 0, "before: aligned on screen with extra space")
        host.luftigAlignTable(nil)
        let expected = "Before.\n\n| name  | value |\n| ----- | ----: |\n| alpha |     1 |\n| b     | 22222 |\n\nAfter.\n"
        t.equal(tv.string, expected, "the table is aligned in the text")
        t.equal(tv.selectedRange().location, ns(tv).range(of: "alpha").location + 3, "the caret is still after \"alp\"")
        await t.spin(5)
        t.check(doc.isDocumentEdited, "the document is edited")
        host.styler.styleEverything()
        t.equal(kernCount(host), 0, "an aligned source needs no extra space on screen")
        host.luftigAlignTable(nil)
        t.equal(tv.string, expected, "a second Align Table changes nothing")
        tv.undoManager?.undo()
        t.equal(tv.string, text, "one Undo restores the table")
        t.check(tv.undoManager?.canUndo == false, "... and it was a single step")
        tv.undoManager?.redo()
        t.equal(tv.string, expected, "Redo")
        assertMatchesFreshLex(t, host, "after Align Table")
        t.close(doc)
    }
}
#endif
