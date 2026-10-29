#if LUFTIG_SELFTEST
// SelfTestAuditDocCoord.swift - auditdoc-coordinated: COORDINATED writers (NSFileCoordinator: what iCloud Drive, OneDrive / Dropbox File Provider
// clients and the Finder do) meeting a DIRTY document. Regular files only; everything inside the scenario work directory.
//
// The defect this guards against: NSDocument reacts to a coordinated write by itself (relinquishPresentedItem(toWriter:) -> reacquirer ->
// _revertToVersion:preservingFirst: -> revert(toContentsOf:)), whether or not the document has unsaved edits. Our revert override applied the disk
// text over the editor text and marked the document clean: the merge our own check had just made - and the typed text with it - vanished silently.

import AppKit

extension SelfTestScenarios {

    /// A coordinated write / delete / move by an NSFileCoordinator on another thread (the accessor runs off the main thread, like a sync client).
    @MainActor static func auditCoordinated(_ file: URL, delete: Bool = false, moveTo: URL? = nil, text: String = "") async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let co = NSFileCoordinator(filePresenter: nil)
                var err: NSError?
                if let dst = moveTo {
                    co.coordinate(writingItemAt: file, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &err) { a, b in
                        try? FileManager.default.moveItem(at: a, to: b)
                    }
                } else {
                    co.coordinate(writingItemAt: file, options: delete ? .forDeleting : .forReplacing, error: &err) { u in
                        if delete { try? FileManager.default.removeItem(at: u) } else { try? Data(text.utf8).write(to: u) }
                    }
                }
                c.resume()
            }
        }
    }

    @MainActor static func auditDocCoordinated(_ t: SelfTest.T) async throws {
        let paras = auditParas
        UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }

        // ---- A. typed text + a coordinated write to ANOTHER paragraph: both survive (merge), the document stays dirty, the next autosave writes both
        do {
            let f = t.write(paras, to: "coord-merge.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset()
            await auditCoordinated(f, text: paras.replacingOccurrences(of: "paragraph 9", with: "THEIRS 9"))
            await t.sleep(2500)                                          // the coordinated writer's relinquish / reacquire round trip takes ~0.5 s
            let txt = host.textView.string
            t.check(txt.contains("MINE\n") && txt.contains("THEIRS 9 of the document"), "coordinated write over typed text: typed text AND the other tool's change are in the editor (\(txt.contains("MINE") ? "MINE" : "no MINE"), \(txt.contains("THEIRS") ? "THEIRS" : "no THEIRS"))")
            t.check(doc.isDocumentEdited, "... the document is still dirty (my text is not on disk yet)")
            t.equal(doc.syncState, .inSync, "... in sync (merged)")
            t.check(UITrap.alerts.isEmpty, "... no alert (\(UITrap.alerts.map { $0.message }))")
            let err = await t.autosave(doc)
            t.check(err == nil && t.read(f).hasPrefix("MINE\n") && t.read(f).contains("THEIRS 9 of the document"), "... the next autosave writes the merged text (\(String(describing: err)))")
            t.close(doc)
        }
        // ---- B. typed text + a coordinated write to the SAME line: conflict, nothing discarded, the banner stays until the user decides
        do {
            let f = t.write(paras, to: "coord-conflict.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            let at = (host.textView.string as NSString).range(of: "paragraph 5 of the document").upperBound
            t.typeText(" MINE", into: doc, at: NSRange(location: at, length: 0))
            await t.sleep(30)
            UITrap.reset()
            let theirs = paras.replacingOccurrences(of: "paragraph 5 of the document", with: "paragraph 5 THEIRS")
            await auditCoordinated(f, text: theirs)
            await t.sleep(2500)
            t.check(host.textView.string.contains("paragraph 5 of the document MINE"), "coordinated write to the same line: my typed text is still in the editor")
            t.equal(doc.syncState, .conflict, "... state conflict")
            t.check(host.bannerVisible && host.bannerButtonTitles.contains("Keep My Version"), "... the banner is up and asks (\(host.bannerText))")
            t.check(doc.isDocumentEdited, "... still dirty")
            t.equal(t.read(f), theirs, "... the other tool's file is untouched")
            let held = await t.autosave(doc)
            t.check((held as NSError?)?.code == NSUserCancelledError && t.read(f) == theirs, "... autosave is held back")
            host.pressBannerButton("Keep My Version")
            await t.sleep(30)
            let err = await t.autosave(doc)
            t.check(err == nil && t.read(f).contains("paragraph 5 of the document MINE"), "... Keep My Version, then the autosave writes my text (\(String(describing: err)))")
            t.close(doc)
        }
        // ---- C. two coordinated writes in a row while dirty
        do {
            let f = t.write(paras, to: "coord-two.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            await auditCoordinated(f, text: paras.replacingOccurrences(of: "paragraph 9", with: "THEIRS 9"))
            await t.sleep(150)
            await auditCoordinated(f, text: paras.replacingOccurrences(of: "paragraph 9", with: "THEIRS 9").replacingOccurrences(of: "paragraph 3", with: "SECOND 3"))
            await t.sleep(2500)
            let txt = host.textView.string
            t.check(txt.hasPrefix("MINE\n") && txt.contains("THEIRS 9") && txt.contains("SECOND 3"), "two coordinated writes while dirty: typed text and both changes are in the editor")
            t.check(doc.isDocumentEdited && doc.syncState == .inSync, "... dirty and in sync (\(doc.syncState))")
            t.close(doc)
        }
        // ---- D. a CLEAN document follows a coordinated write (once, no dirty flash), selection kept
        do {
            let f = t.write(paras, to: "coord-clean.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            host.textView.setSelectedRange(NSRange(location: 3, length: 0))
            await auditCoordinated(f, text: paras.replacingOccurrences(of: "paragraph 9", with: "THEIRS 9"))
            await t.sleep(2500)
            t.check(host.textView.string.contains("THEIRS 9") && !doc.isDocumentEdited, "clean document + coordinated write: reloaded, not dirty")
            t.equal(host.textView.selectedRange(), NSRange(location: 3, length: 0), "... selection kept")
            t.close(doc)
        }
        // ---- E. the explicit commands still discard typed text (the guard only stops NSDocument's own revert)
        do {
            let f = t.write(paras, to: "coord-explicit.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            doc.monitor?.stop()
            t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            // NSDocument-initiated revert with unsaved edits: not applied
            try doc.revert(toContentsOf: f, ofType: doc.fileType ?? "net.daringfireball.markdown")
            await t.sleep(100)
            t.check(host.textView.string.hasPrefix("MINE\n") && doc.isDocumentEdited, "revert(toContentsOf:) with unsaved edits (what NSDocument calls after a coordinated write): typed text kept, still dirty")
            // File > Reload from Disk (confirmation answered with Reload): discards, undoable
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Reload") ?? 0 }
            doc.luftigReloadFromDisk(nil)
            await t.sleep(300)
            t.check(host.textView.string == paras && !doc.isDocumentEdited, "File > Reload from Disk: the typed text is discarded on request")
            doc.undoManager?.undo()
            t.check(host.textView.string.hasPrefix("MINE\n"), "... and Undo brings it back")
            // a CLEAN document: revert(toContentsOf:) applies the disk text (that is what NSDocument asks for after a coordinated write). Clean for real:
            // Redo puts the reloaded text back, so the editor holds the disk text again (with "MINE" still in the editor, a cleared change count alone
            // is a document whose unsaved text the revert must keep: pitfall 40, fix-typing-after-save)
            doc.undoManager?.redo()
            doc.updateChangeCount(.changeCleared)
            doc.undoManager?.removeAllActions()
            try? Data((paras + "extra\n").utf8).write(to: f)
            try doc.revert(toContentsOf: f, ofType: doc.fileType ?? "net.daringfireball.markdown")
            t.check(host.textView.string == paras + "extra\n" && !doc.isDocumentEdited, "clean document: revert(toContentsOf:) shows the file")
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }
            t.close(doc)
        }
        // ---- F. coordinated MOVE (what the Finder does on rename / drag): the dirty document follows the file, nothing is lost, nothing resurrected
        do {
            let f = t.write(paras, to: "coord-move-old.md")
            try? FileManager.default.createDirectory(at: t.url("coord-moved"), withIntermediateDirectories: true)
            let dst = t.url("coord-moved/coord-move-new.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset()
            await auditCoordinated(f, moveTo: dst)
            await t.sleep(2500)
            t.equal(doc.fileURL?.lastPathComponent, "coord-move-new.md", "coordinated move: the document follows the file")
            t.check(host.textView.string.hasPrefix("MINE\n") && doc.isDocumentEdited, "... typed text kept, still dirty")
            t.check(doc.syncState == .inSync && !host.bannerVisible, "... no 'deleted' banner (state \(doc.syncState))")
            let err = await t.autosave(doc)
            t.check(err == nil && t.read(dst).hasPrefix("MINE\n") && !FileManager.default.fileExists(atPath: f.path), "... the autosave writes the NEW place and does not recreate the old one (\(String(describing: err)))")
            t.check(UITrap.alerts.isEmpty, "... no alert (\(UITrap.alerts.map { $0.message }))")
            t.close(doc)
        }
        // ---- G. coordinated DELETE while dirty: the text stays, the banner offers Save Again, closing asks, nothing is resurrected by the autosave
        do {
            let f = t.write(paras, to: "coord-del.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(200)
            t.typeText("MINE\n", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset()
            await auditCoordinated(f, delete: true)
            let gone = await t.waitFor(5000) { doc.syncState == .deletedOnDisk }
            t.check(gone && NSDocumentController.shared.documents.contains(doc), "coordinated delete: the document stays open and knows (state \(doc.syncState))")
            t.check(host.textView.string.hasPrefix("MINE\n") && host.bannerVisible, "... typed text kept, banner up (\(host.bannerText))")
            let err = await t.autosave(doc)
            t.check((err as NSError?)?.code == NSUserCancelledError && !FileManager.default.fileExists(atPath: f.path), "... the autosave is held back and does not resurrect the file")
            t.close(doc)
        }
        t.check(UITrap.violations.isEmpty, "UITrap: no panel URL outside the work dir")
    }
}
#endif
