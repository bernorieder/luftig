#if LUFTIG_SELFTEST
// SelfTestTableRender.swift - table-render: tables drawn as a grid while the caret is elsewhere (TableRender.swift, View > Tables as Grids).
//   the table's characters have no glyphs and its rows are as tall as the drawn rows; a long cell wraps and makes its row taller; the caret entering the
//   table (setting the selection, a click into a cell, Select All) shows the Markdown, leaving it draws the grid again; typing in the shown table and
//   leaving it draws the new text; a narrower window gives narrower columns; a table in a quote is not drawn; the menu switch; the file never changes;
//   every state == a fresh restyle with the same selection.

import AppKit
import MarkdownKit

extension SelfTestScenarios {
    static let tableRenderScenarios: [SelfTest.Scenario] = [
        .init(name: "table-render", summary: "tables drawn as a grid while the caret is elsewhere: hidden glyphs, row heights, wrapping, the Markdown when the caret enters (selection, click, Select All), the switch, == a fresh restyle", run: { t in try await tableRender(t) }),
    ]

    static let renderSample = """
    # Tables

    Some text before the table.

    | Hesse | What it is | Reference |
    |---|:---:|---:|
    | Hermann Hesse | Author of *Steppenwolf* | 1877–1962 |
    | Hessian matrix | Matrix of **2nd-order** partials | `H_ij` |
    | Hesse (Hessen) | German federal state, with a long description that has to wrap inside its column because it is far too long | DE-HE |

    And some text after it.

    > | quoted | table |
    > |---|---|
    > | a | b |

    The end.

    """

    /// The drawn row on the line that holds `location`, if the line is drawn as a grid.
    @MainActor static func renderedRow(_ host: EditorViewController, at location: Int) -> TableRenderRow? {
        host.textView.textStorage?.attribute(.luftigTableRow, at: location, effectiveRange: nil) as? TableRenderRow
    }

    /// The line fragment of the line that holds `location` (container coordinates), found through the line's line break: a hidden (`.null`) glyph
    /// reports the fragment before it.
    @MainActor static func fragment(_ host: EditorViewController, at location: Int) -> NSRect {
        guard let lm = host.textView.layoutManager else { return .zero }
        let text = host.textView.string as NSString
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let br = max(line.location, NSMaxRange(line) - 1)
        lm.ensureLayout(forCharacterRange: NSRange(location: br, length: 1))
        return lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: br), effectiveRange: nil)
    }

    @MainActor static func glyphIsHidden(_ host: EditorViewController, at location: Int) -> Bool {
        guard let lm = host.textView.layoutManager else { return false }
        lm.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
        return lm.propertyForGlyph(at: lm.glyphIndexForCharacter(at: location)) == .null
    }

    @MainActor static func tableRender(_ t: SelfTest.T) async throws {
        let grids = EditorPreferences.renderTables
        EditorPreferences.renderTables = true
        defer { EditorPreferences.renderTables = grids }
        let (doc, host, url) = try await openEditor(t, text: renderSample, name: "grid.md", size: NSSize(width: 1000, height: 900))
        await t.spin(30)
        let tv = host.textView
        let text = { tv.string as NSString }
        host.styler.styleEverything()
        let header = text().range(of: "| Hesse |").location
        let hessian = text().range(of: "Hessian matrix").location
        let long = text().range(of: "German federal").location
        let quoted = text().range(of: "| quoted").location

        // ---- drawn: no glyphs, rows as tall as drawn, the long row taller, the delimiter row a thin line
        t.check(renderedRow(host, at: header)?.kind == .header && renderedRow(host, at: hessian)?.kind == .body, "the table is drawn as a grid while the caret is elsewhere")
        t.check(glyphIsHidden(host, at: hessian) && glyphIsHidden(host, at: header + 2), "its characters have no glyphs")
        let bodyRow = renderedRow(host, at: hessian), longRow = renderedRow(host, at: long)
        t.check(bodyRow != nil && abs(fragment(host, at: hessian).height - bodyRow!.height) < 0.5, "a row's line is as tall as the drawn row (\(fragment(host, at: hessian).height) vs \(bodyRow?.height ?? -1))")
        t.check((longRow?.height ?? 0) > (bodyRow?.height ?? 0) + 10, "a long cell wraps in its column and makes its row taller (\(longRow?.height ?? -1) vs \(bodyRow?.height ?? -1))")
        let delimiter = text().range(of: "|---|:---:|").location
        t.check(fragment(host, at: delimiter).height <= TableRenderer.delimiterHeight + 0.5, "the delimiter row is a thin line (\(fragment(host, at: delimiter).height) pt)")
        if let r = bodyRow {
            t.equal(r.cells.map { $0.string }, ["Hessian matrix", "Matrix of 2nd-order partials", "H_ij"], "the cells are drawn without the Markdown markers")
            t.check(r.edges.last! <= host.provider.tables.widthLimit + 0.5, "the table fits the text column (\(Int(r.edges.last!)) of \(Int(host.provider.tables.widthLimit)) pt)")
            let first = longRow?.cells.first?.string ?? ""
            t.equal(first, "Hesse (Hessen)", "... the first column of the long row")
        }
        if let h = renderedRow(host, at: header) {
            let font = h.cells.first?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            t.check(font.map { $0.fontDescriptor.symbolicTraits.contains(.bold) && !$0.isFixedPitch } ?? false, "the header is bold, in the text font (\(font?.fontName ?? "-"))")
        }
        t.check(renderedRow(host, at: quoted) == nil, "a table in a quote is shown as Markdown")
        assertMatchesFreshLex(t, host, "drawn")
        t.equal(tv.string, renderSample, "the text is unchanged")

        // ---- the caret enters: the Markdown, aligned; it leaves: the grid again
        tv.setSelectedRange(NSRange(location: hessian + 3, length: 0))
        await t.spin(20)
        t.check(renderedRow(host, at: hessian) == nil && renderedRow(host, at: header) == nil && !glyphIsHidden(host, at: hessian), "the caret in the table: its Markdown is shown")
        t.check(fragment(host, at: hessian).height < (bodyRow?.height ?? 0) + 30 && fragment(host, at: hessian).height == host.theme.bodyLineHeight, "... in lines of the text's height (\(fragment(host, at: hessian).height))")
        assertMatchesFreshLex(t, host, "shown as Markdown")
        tv.moveDown(nil); tv.moveDown(nil)
        await t.spin(20)
        t.check(renderedRow(host, at: hessian) == nil, "moving inside the table keeps the Markdown")
        tv.setSelectedRange(NSRange(location: text().range(of: "And some text").location + 3, length: 0))
        await t.spin(20)
        t.check(renderedRow(host, at: hessian) != nil, "the caret leaves: the grid again")
        assertMatchesFreshLex(t, host, "drawn again")

        // ---- keys out of the table: ⌥↓ from the last row, ↓ from it
        for (mods, label) in [(NSEvent.ModifierFlags.option, "⌥↓"), ([], "↓")] {
            tv.setSelectedRange(NSRange(location: text().range(of: "| DE-HE |").location + 3, length: 0))
            await t.spin(20)
            t.check(renderedRow(host, at: hessian) == nil, "\(label): the caret in the last row: Markdown")
            AuditEd.pressKey(host, 125, mods: mods)
            AuditEd.pressKey(host, 125, mods: mods)
            await t.spin(20)
            t.check(renderedRow(host, at: hessian) != nil, "\(label) twice: out of the table, which is drawn again (caret at \(tv.selectedRange().location))")
            assertMatchesFreshLex(t, host, "\(label) out of the table")
        }

        // ---- typing in the shown table, then leaving: the grid has the new text
        tv.setSelectedRange(NSRange(location: text().range(of: "partials").location + 8, length: 0))
        await t.spin(20)
        t.typeText(" (Hesse)", into: doc, at: tv.selectedRange())
        await t.spin(20)
        t.check(renderedRow(host, at: hessian) == nil, "typing in the table: still Markdown")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        await t.spin(20)
        t.equal(renderedRow(host, at: text().range(of: "Hessian matrix").location)?.cells[1].string, "Matrix of 2nd-order partials (Hesse)", "leaving it: the grid shows the new text")
        assertMatchesFreshLex(t, host, "after typing in the table")

        // ---- a click into a cell: the caret at the end of that cell's text, the Markdown shown
        let row = text().range(of: "Hermann Hesse").location
        if let r = renderedRow(host, at: row) {
            let f = fragment(host, at: row)
            let o = tv.textContainerOrigin
            let point = NSPoint(x: o.x + f.minX + (r.edges[1] + r.edges[2]) / 2, y: o.y + f.midY)
            t.check(host.clickIntoTable(at: point), "a click into a drawn table is taken")
            await t.spin(20)
            t.equal(tv.selectedRange().location, text().range(of: "*Steppenwolf*").location + 13, "... the caret at the end of the clicked cell's text")
            t.check(renderedRow(host, at: row) == nil, "... and the table shows its Markdown")
        } else { t.check(false, "no drawn row to click") }
        let outside = NSPoint(x: tv.textContainerOrigin.x + 20, y: tv.textContainerOrigin.y + fragment(host, at: 3).midY)
        t.check(!host.clickIntoTable(at: outside), "a click outside a table is left to the text view")

        // ---- a selection that passes over the table leaves it drawn; one that ends in it shows the Markdown
        tv.selectAll(nil)
        await t.spin(20)
        host.styler.styleEverything()
        t.check(renderedRow(host, at: header) != nil, "Select All: the table stays drawn (its rows are tinted)")
        assertMatchesFreshLex(t, host, "Select All")
        tv.setSelectedRange(NSRange(location: 2, length: hessian - 2))
        await t.spin(20)
        t.check(renderedRow(host, at: header) == nil, "a selection that ends in the table: the Markdown")
        assertMatchesFreshLex(t, host, "a selection ending in the table")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        await t.spin(20)
        host.styler.styleEverything()
        t.check(renderedRow(host, at: header) != nil, "... and the grid when the selection is gone")

        // ---- a table pasted at the caret: shown as Markdown while the caret is in it, drawn once it leaves (styled before the selection moved)
        let end = text().length
        tv.setSelectedRange(NSRange(location: end, length: 0))
        t.typeText("| x | y |\n|---|---|\n| 1 | 2 |", into: doc, at: NSRange(location: end, length: 0))
        await t.spin(20)
        let pasted = text().range(of: "| x | y |").location
        t.check(renderedRow(host, at: pasted) == nil, "a table typed at the caret, the caret at its end: Markdown")
        assertMatchesFreshLex(t, host, "after typing a table")
        t.typeText("\n\nAfter.\n", into: doc, at: tv.selectedRange())
        await t.spin(20)
        host.styler.styleEverything()
        t.check(renderedRow(host, at: pasted) != nil, "... drawn once the caret has left it")
        assertMatchesFreshLex(t, host, "after leaving the typed table")

        // ---- a narrower window: narrower columns, still within the column
        let wide = renderedRow(host, at: header)?.edges.last ?? 0
        host.view.window?.setContentSize(NSSize(width: 760, height: 900)); host.view.window?.contentView?.layoutSubtreeIfNeeded()
        await t.spin(40)
        host.styler.styleEverything()
        let narrow = renderedRow(host, at: header)?.edges.last ?? 0
        t.check(narrow < wide - 20 && narrow <= host.provider.tables.widthLimit + 0.5, "a narrower window: a narrower table (\(Int(wide)) -> \(Int(narrow)) pt, column \(Int(host.provider.tables.widthLimit)))")
        assertMatchesFreshLex(t, host, "narrower")

        // ---- the switch
        EditorPreferences.renderTables = false
        await t.spin(20)
        host.styler.styleEverything()
        t.check(renderedRow(host, at: header) == nil && !glyphIsHidden(host, at: hessian), "View > Tables as Grids off: Markdown")
        assertMatchesFreshLex(t, host, "switched off")
        EditorPreferences.renderTables = true
        await t.spin(20)
        host.styler.styleEverything()
        t.check(renderedRow(host, at: header) != nil, "... on: the grid")

        // ---- the file
        doc.updateChangeCount(.changeDone)
        let saved: Error? = await withCheckedContinuation { c in doc.save(to: url, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { c.resume(returning: $0) } }
        t.check(saved == nil && (try? String(contentsOf: url, encoding: .utf8)) == tv.string, "the saved file is the Markdown")
        t.close(doc)
    }
}
#endif
