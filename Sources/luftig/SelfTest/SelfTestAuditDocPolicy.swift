#if LUFTIG_SELFTEST
// SelfTestAuditDocPolicy.swift - auditdoc-policy: transitions of the clean / dirty / conflicted / deleted policy that the first spike did not cover.
// Regular files only; everything inside the scenario work directory.

import AppKit

extension SelfTestScenarios {

    @MainActor static func auditDocPolicy(_ t: SelfTest.T) async throws {
        let paras = auditParas
        UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }

        // ---- A. IME composition + an autosave tick + an external change (the autosave gate used to merge UNDER the marked text: AppKit then drops the
        //         composition, the preedit letters stay in the text as ordinary characters and the commit adds the real characters after them)
        for dirty in [false, true] {
            let tag = dirty ? "dirty" : "clean"
            let f = t.write(paras, to: "ime-\(tag).md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(150)
            doc.monitor?.stop()
            let tv = host.textView
            if dirty { t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0)); await t.sleep(20) }
            let at = (tv.string as NSString).range(of: "paragraph 5 of the document").upperBound
            tv.setSelectedRange(NSRange(location: at, length: 0))
            let um = doc.undoManager!
            um.beginUndoGrouping()
            tv.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: at, length: 0))
            um.endUndoGrouping()
            t.check(tv.hasMarkedText(), "[\(tag)] setup: composing")
            await auditAtomicWrite(t, f, paras.replacingOccurrences(of: "paragraph 9", with: "THEIRS 9"))
            let err = await t.autosave(doc)           // the 3 s timer fires in the middle of the composition
            t.check(tv.hasMarkedText(), "[\(tag)] an autosave tick during composition does not end the composition")
            t.check(!tv.string.contains("THEIRS"), "[\(tag)] ... and the other tool's text is NOT applied under the marked text yet")
            t.check((err as NSError?)?.code == NSUserCancelledError, "[\(tag)] ... the autosave is held back silently (\(String(describing: err)))")
            um.beginUndoGrouping(); tv.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0)); tv.breakUndoCoalescing(); um.endUndoGrouping()
            t.check(tv.string.contains("document你") && !tv.string.contains("documentni"), "[\(tag)] the commit replaces the preedit letters (no stray 'ni')")
            let merged = await t.waitFor(3000) { tv.string.contains("THEIRS 9") }
            t.check(merged, "[\(tag)] after the composition the other tool's change is merged in by itself (merges \(doc.stats.merges), reloads \(doc.stats.silentReloads))")
            t.check(tv.string.contains("document你") && (!dirty || tv.string.hasPrefix("MINE\n")), "[\(tag)] ... the typed text is intact")
            _ = await auditSettle(t, doc)
            let again = await t.autosave(doc)
            t.check(again == nil && t.read(f).contains("document你") && t.read(f).contains("THEIRS 9") && !t.read(f).contains("documentni"), "[\(tag)] the next autosave writes the merged text (\(String(describing: again)))")
            t.close(doc)
        }

        // ---- B. a text that cannot be encoded as UTF-8 AT ALL (a lone surrogate): the save fails, the text stays, and the FORMAT is left alone. The
        //         legacy-encoding fallback ("switch to UTF-8") used to run first and drop the BOM of a UTF-8 file on its way to failing.
        do {
            let bytes = [0xEF, 0xBB, 0xBF] + Array("abc\n".utf8)
            let f = t.write(data: Data(bytes), to: "lone-bom-utf8.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(150)
            let tv = host.textView
            t.equal(doc.textFormat.description, "UTF-8+BOM, LF", "[bom-utf8] setup: format")
            let um = doc.undoManager!
            um.beginUndoGrouping(); tv.setSelectedRange(NSRange(location: 0, length: 0)); tv.insertText(NSString(characters: [0xD83D], length: 1), replacementRange: NSRange(location: 0, length: 0)); tv.breakUndoCoalescing(); um.endUndoGrouping()
            t.check((tv.string as NSString).character(at: 0) == 0xD83D, "[bom-utf8] setup: the text holds a lone surrogate")
            await t.sleep(30)
            UITrap.reset()
            let err = await t.autosave(doc)
            t.check(err != nil, "[bom-utf8] a text with a lone surrogate cannot be saved as UTF-8: the autosave fails (\((err as NSError?)?.localizedDescription ?? "nil"))")
            t.equal(doc.textFormat.description, "UTF-8+BOM, LF", "[bom-utf8] ... and the format is unchanged (the BOM is still there)")
            t.check(t.readData(f) == Data(bytes), "[bom-utf8] ... the file on disk is untouched")
            um.beginUndoGrouping(); tv.insertText("Z", replacementRange: NSRange(location: 0, length: 1)); tv.breakUndoCoalescing(); um.endUndoGrouping()
            await t.sleep(30)
            let again = await t.autosave(doc)
            t.check(again == nil && t.readData(f) == Data([0xEF, 0xBB, 0xBF] + Array("Zabc\n".utf8)), "[bom-utf8] after the text is fixed the save keeps the BOM (\(String(describing: again)); \(t.readData(f).map { String(format: "%02X", $0) }.joined(separator: " ")))")
            t.close(doc)
        }

        // ---- B2. a Windows-1252 file gets a character that encoding cannot hold: the file becomes UTF-8 (the typed text is kept) - and the user is TOLD
        do {
            let f = t.write(data: Data(Array("caf".utf8) + [0xE9] + Array(" au lait\n".utf8)), to: "legacy-to-utf8.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(150)
            t.equal(doc.textFormat.description, "Windows-1252, LF", "[1252] setup: opened as Windows-1252")
            t.typeText("→ ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err = await t.autosave(doc)
            await t.sleep(100)
            t.check(err == nil && t.readData(f) == Data(Array("→ café au lait\n".utf8)), "[1252] the text is kept and the file is now UTF-8 (\(String(describing: err)))")
            t.check(host.bannerVisible && host.bannerText.contains("UTF-8"), "[1252] ... the user is told (banner: '\(host.bannerText)')")
            t.close(doc)
        }

        // ---- C. a 10 MB document: typed text at the top, another tool changes lines far below -> merged (one undoable edit), fast, and Undo returns EXACTLY
        //         the pre-merge text
        do {
            var lines: [String] = []
            lines.reserveCapacity(150_000)
            for i in 0..<150_000 { lines.append("Line \(i) - the quick brown fox jumps over the lazy dog \(i * 7919 % 10007) and more words to fill it up") }
            let text = lines.joined(separator: "\n") + "\n"
            let f = t.write(text, to: "merge10.md")
            let doc = try await t.open(f, size: NSSize(width: 800, height: 600))
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            doc.monitor?.stop()
            t.typeText("MINE ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let pre = host.textView.string
            var l2 = lines
            l2[120_000] = "CHANGED BY ANOTHER TOOL"; l2[149_000] = "CHANGED TOO"
            try (l2.joined(separator: "\n") + "\n").write(to: t.url("merge10.tmp"), atomically: false, encoding: .utf8)
            await t.sh("mv \(t.q(t.url("merge10.tmp"))) \(t.q(f))")
            let w0 = SelfTest.nowMs()
            doc.checkForExternalChange("audit")
            let ok = await t.waitFor(6000) { doc.stats.merges + doc.stats.conflicts > 0 }
            t.check(ok && doc.stats.merges == 1, "10 MB: typed text at the top + two far-away changes by another tool: merged (merges \(doc.stats.merges), conflicts \(doc.stats.conflicts))")
            if let a = doc.stats.lastApply {
                t.note(String(format: "10 MB merge: %d edits, apply %.0f ms on the main thread, %.0f ms from the check to shown", a.edits, a.seconds * 1000, SelfTest.nowMs() - w0))
                t.check(a.seconds < 1.5, "10 MB merge: the apply stays far below a second on the main thread (\(Int(a.seconds * 1000)) ms)")
            }
            let merged = host.textView.string
            t.check(merged.hasPrefix("MINE Line 0 ") && merged.contains("CHANGED BY ANOTHER TOOL") && merged.contains("CHANGED TOO") && doc.isDocumentEdited, "10 MB: the editor holds my text and both changes, still dirty")
            doc.undoManager?.undo()
            t.check(host.textView.string == pre, "10 MB: Undo after the merge returns EXACTLY the pre-merge text")
            doc.undoManager?.redo()
            t.check(host.textView.string == merged, "10 MB: Redo gives the merged text back")
            t.close(doc)
        }
        t.check(UITrap.violations.isEmpty, "UITrap: no panel URL outside the work dir")
    }
}
#endif
