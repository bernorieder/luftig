#if LUFTIG_SELFTEST
// SelfTestFixTyping.swift - fix-typing-after-save: text typed after an autosave is never thrown away by a reload.
//
// The defect (luftig 1.0.5, found in daily use in a OneDrive folder): NSTextView COALESCES typing into one undo action. After an autosave, the
// letters typed next went into the same undo action, nothing new was registered with the undo manager, and NSDocument's change count did not move:
// the document said "not edited" while the editor held text that was not on disk. A File Provider client (OneDrive) writes the file after every
// upload with a coordinated write; NSDocument then reverts by itself (relinquish -> reacquire -> revert(toContentsOf:)), our revert saw a clean
// document and applied the disk text: the last letters vanished and the caret jumped back.
// The other tests never saw it: their key presses break the coalescing after every key (SelfTestAuditEditorSupport.press). The headless app does
// not coalesce like a real event loop either, so C/D/E set the change count wrong by hand: whatever makes it lag, text that is not on disk is never
// replaced silently (MarkdownDocument.editorHasUnsavedText), and every save breaks the coalescing (EditorHost.documentWillSave).

import AppKit

extension SelfTestScenarios {
    static let fixTypingScenarios: [SelfTest.Scenario] = [
        .init(name: "fix-typing-after-save", summary: "letters typed after an autosave make the document dirty and survive a coordinated write, an NSDocument revert and an external change, also when the change count missed them", run: { t in try await fixTypingAfterSave(t) }),
    ]

    /// Keys typed like a person types: each in its own turn of the run loop, with no undo group of the test's own (the undo manager groups by
    /// event: a group opens only when something is registered, and a key the text view coalesces into the typing before registers nothing).
    @MainActor static func typeCoalesced(_ t: SelfTest.T, _ host: EditorViewController, _ s: String) async {
        guard let window = host.view.window else { return }
        let tv = host.textView
        if window.firstResponder !== tv { window.makeFirstResponder(tv) }
        for ch in s {
            let um = tv.undoManager
            um?.beginUndoGrouping()
            window.sendEvent(AuditEd.keyEvent(window, characters: String(ch), code: 0))
            um?.endUndoGrouping()
            await t.sleep(5)
        }
    }

    @MainActor static func fixTypingAfterSave(_ t: SelfTest.T) async throws {
        let start = "# Notes\n\nThe first paragraph.\n"
        // ---- A. typed, autosaved, typed again: the document is dirty, the next autosave writes the letters
        do {
            let f = t.write(start, to: "typing-a.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: (start as NSString).length - 1, length: 0))
            await typeCoalesced(t, host, " One")
            await t.sleep(50)                                           // (NSDocument counts the change at the end of the event cycle)
            t.check(doc.isDocumentEdited, "typed: the document is edited")
            let e1 = await t.autosave(doc)
            t.check(e1 == nil && t.read(f).contains("paragraph. One\n") && !doc.isDocumentEdited, "autosaved: on disk, not edited (\(String(describing: e1)))")
            await typeCoalesced(t, host, " two")
            await t.sleep(50)
            t.check(doc.isDocumentEdited, "letters typed after the autosave make the document edited again (the typing must not be folded into the saved undo step)")
            let e2 = await t.autosave(doc)
            t.check(e2 == nil && t.read(f).contains("One two\n"), "... and the next autosave writes them (\(t.read(f).debugDescription))")
            host.textView.undoManager?.undo()
            t.check(!host.textView.string.contains("two") && host.textView.string.contains("One"), "Undo takes back the typing since the save, not the saved typing (\(host.textView.string.debugDescription))")
            t.close(doc)
        }
        // ---- B. typed after an autosave, then a coordinated write of the SAME bytes (a File Provider after its upload): nothing is lost
        do {
            let f = t.write(start, to: "typing-b.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: (start as NSString).length - 1, length: 0))
            await typeCoalesced(t, host, " One")
            _ = await t.autosave(doc)
            let onDisk = t.read(f)
            await typeCoalesced(t, host, " two")
            await auditCoordinated(f, text: onDisk)                     // same content, new modification date: NSDocument relinquishes and reverts
            await t.sleep(2500)
            t.check(host.textView.string.contains("One two\n"), "a coordinated write of the saved text does not take the letters typed since (\(host.textView.string.debugDescription))")
            t.equal(host.textView.selectedRange().location, (host.textView.string as NSString).range(of: "One two").location + 7, "... and the caret stays after them")
            let e = await t.autosave(doc)
            t.check(e == nil && t.read(f).contains("One two\n"), "... and they reach the file (\(String(describing: e)))")
            t.close(doc)
        }
        // ---- C. the same with a coordinated write of OTHER text in another paragraph: merged, nothing lost
        do {
            let f = t.write(start + "\nA second paragraph.\n", to: "typing-c.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: (start as NSString).length - 1, length: 0))
            await typeCoalesced(t, host, " One")
            _ = await t.autosave(doc)
            await typeCoalesced(t, host, " two")
            await auditCoordinated(f, text: t.read(f).replacingOccurrences(of: "A second", with: "THEIR second"))
            await t.sleep(2500)
            let txt = host.textView.string
            t.check(txt.contains("One two\n") && txt.contains("THEIR second"), "a coordinated change elsewhere is merged with the letters typed since the autosave (\(txt.debugDescription))")
            t.close(doc)
        }
        // ---- D. an NSDocument-initiated revert while the editor holds text that is not on disk (whatever the change count says) keeps the text
        do {
            let f = t.write(start, to: "typing-d.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: (start as NSString).length - 1, length: 0))
            await typeCoalesced(t, host, " One")
            _ = await t.autosave(doc)
            await typeCoalesced(t, host, " two")
            doc.updateChangeCount(.changeCleared)                       // the change count is wrong, for whatever reason
            try? doc.revert(toContentsOf: f, ofType: doc.fileType ?? "net.daringfireball.markdown")
            await t.sleep(300)
            t.check(host.textView.string.contains("One two\n"), "NSDocument's revert to an unchanged file keeps text that is not on disk, even with a clean change count")
            t.check(doc.isDocumentEdited, "... and the document is edited again, so that the autosave writes it")
            let e = await t.autosave(doc)
            t.check(e == nil && t.read(f).contains("One two\n"), "... which it does (\(String(describing: e)))")
            t.close(doc)
        }
        // ---- E. the same wrong change count, and another tool changes another paragraph: merged, not a silent reload over the typed letters
        do {
            let f = t.write(start + "\nA second paragraph.\n", to: "typing-e.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: (start as NSString).length - 1, length: 0))
            await typeCoalesced(t, host, " One")
            _ = await t.autosave(doc)
            await typeCoalesced(t, host, " two")
            doc.updateChangeCount(.changeCleared)
            try? t.read(f).replacingOccurrences(of: "A second", with: "THEIR second").write(to: f, atomically: true, encoding: .utf8)
            await t.sleep(1500)
            let txt = host.textView.string
            t.check(txt.contains("One two\n") && txt.contains("THEIR second"), "an external change meets letters the change count missed: merged (\(txt.debugDescription))")
            t.check(doc.isDocumentEdited, "... and the document is edited")
            t.close(doc)
        }
    }
}
#endif
