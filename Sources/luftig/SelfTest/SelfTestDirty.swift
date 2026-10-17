#if LUFTIG_SELFTEST
// SelfTestDirty.swift - external change while the document has unsaved edits; the save gate; deleted/moved files.

import AppKit

/// Receiver for NSDocument.canClose(withDelegate:shouldClose:contextInfo:)
final class CloseProbe: NSObject {
    var result: Bool?
    @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { result = shouldClose }
}

extension SelfTestScenarios {
    static let dirtyScenarios: [SelfTest.Scenario] = [
        .init(name: "dirty-merge", summary: "typed edit + non-overlapping external edit: 3-way merge, undoable, autosave writes both", run: { t in try await dirtyMerge(t) }),
        .init(name: "dirty-conflict", summary: "overlapping edits: banner, autosave held back, save sheet, Reload/Keep/Overwrite, undo", run: { t in try await dirtyConflict(t) }),
        .init(name: "save-gate", summary: "autosave/save racing ahead of every watcher; NSDocument's stock 'changed by another application' sheet never appears", run: { t in try await saveGate(t) }),
        .init(name: "autosave-off", summary: "the same policy with autosavesInPlace = false (classic Save): reload, merge, conflict, stock sheet never appears", run: { t in try await autosaveOff(t) }),
        .init(name: "deleted-moved", summary: "rm / mv / rename / recreate while open (clean and dirty); close with unresolved states", run: { t in try await deletedMoved(t) }),
    ] + auditDocScenarios      // SelfTestAuditDoc*.swift (the document-layer audit)

    private static let paras = (1...10).map { "paragraph \($0) of the document\n" }.joined()

    @MainActor private static func atomicWrite(_ t: SelfTest.T, _ file: URL, _ text: String) async {
        let tmp = file.appendingPathExtension("tmp")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        await t.sh("mv \(t.q(tmp)) \(t.q(file))")
    }

    // MARK: merge

    @MainActor static func dirtyMerge(_ t: SelfTest.T) async throws {
        MarkdownDocument.mergeBannerSeconds = 1.0
        defer { MarkdownDocument.mergeBannerSeconds = 8 }
        let file = t.write(paras, to: "merge.md")
        let doc = try await t.open(file)
        guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
        let tv = host.textView
        await t.sleep(200)
        // the user types at the END of paragraph 8
        let p8 = (tv.string as NSString).range(of: "paragraph 8 of the document").location
        let typeAt = p8 + "paragraph 8 of the document".utf16.count
        t.typeText(" MINE", into: doc, at: NSRange(location: typeAt, length: 0))
        await t.sleep(30)
        t.check(doc.isDocumentEdited, "typed: document is dirty")
        t.check(doc.baseSnapshot != nil, "typed: merge base captured at the first edit")
        let mine = tv.string
        // another tool edits paragraph 2 and appends a line
        let theirsText = paras.replacingOccurrences(of: "paragraph 2 of the document", with: "paragraph 2 EDITED BY TOOL") + "appended by tool\n"
        await atomicWrite(t, file, theirsText)
        let ok = await t.waitFor(3000) { doc.stats.merges >= 1 }
        t.check(ok, "external change merged into the dirty document (latency incl. write ~ \(Int(SelfTest.nowMs() - SelfTest.nowMs())) ms)")
        let expected = theirsText.replacingOccurrences(of: "paragraph 8 of the document", with: "paragraph 8 of the document MINE")
        t.equal(tv.string, expected, "editor text = disk change + typed text")
        t.check(doc.isDocumentEdited, "still dirty (merged text differs from disk)")
        t.equal(doc.syncState, .inSync, "state inSync (no conflict)")
        t.check(host.bannerVisible && host.bannerText.contains("Merged"), "info banner: \(host.bannerText)")
        t.check(UITrap.alerts.isEmpty, "no alert")
        t.equal(t.read(file), theirsText, "file on disk untouched by us so far (still the tool's version)")
        let bannerShownAt = SelfTest.nowMs()
        let faded = await t.waitFor(3000) { !host.bannerVisible }
        t.check(faded, "the info banner fades by itself after \(MarkdownDocument.mergeBannerSeconds) s (\(Int(SelfTest.nowMs() - bannerShownAt)) ms)")
        // undo: one step takes the merge back, a second one the typing
        doc.undoManager?.undo()
        t.equal(tv.string, mine, "Undo #1 reverts the merge (back to my typed text)")
        doc.undoManager?.redo()
        t.equal(tv.string, expected, "Redo re-applies the merge")
        // autosave writes the merged text; no stock alert
        let err = await t.autosave(doc)
        t.check(err == nil, "autosave after merge succeeded (\(String(describing: err)))")
        t.equal(t.read(file), expected, "disk now has BOTH changes")
        await t.sleep(200)
        t.check(!doc.isDocumentEdited, "clean after autosave")
        t.check(UITrap.alerts.isEmpty, "no stock 'changed by another application' alert at any point")
        // a following external change meets a clean document and reloads silently
        let reloads0 = doc.stats.silentReloads
        await atomicWrite(t, file, expected + "second tool edit\n")
        let ok2 = await t.waitFor(3000) { doc.stats.silentReloads > reloads0 }
        t.check(ok2 && tv.string == expected + "second tool edit\n", "next external change: silent reload again")
        t.close(doc)
    }

    // MARK: conflict

    @MainActor static func dirtyConflict(_ t: SelfTest.T) async throws {
        func setup(_ name: String) async throws -> (MarkdownDocument, EditorViewController, URL, String) {
            UITrap.reset()
            let file = t.write(paras, to: name)
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { throw NSError(domain: "t", code: 1) }
            await t.sleep(200)
            let tv = host.textView
            let r = (tv.string as NSString).range(of: "paragraph 3 of the document")
            t.typeText("paragraph 3 MINE", into: doc, at: r)
            await t.sleep(30)
            let mine = tv.string
            await atomicWrite(t, file, paras.replacingOccurrences(of: "paragraph 3 of the document", with: "paragraph 3 THEIRS"))
            let ok = await t.waitFor(3000) { doc.syncState == .conflict }
            t.check(ok, "\(name): overlapping edits -> conflict state")
            return (doc, host, file, mine)
        }
        let theirs = paras.replacingOccurrences(of: "paragraph 3 of the document", with: "paragraph 3 THEIRS")

        // --- state + banner + autosave held back
        do {
            let (doc, host, file, mine) = try await setup("c1.md")
            t.equal(host.textView.string, mine, "conflict: the typed text is still in the editor")
            t.equal(host.bannerButtonTitles, ["Reload from Disk", "Keep My Version"], "banner offers Reload / Keep: \(host.bannerText)")
            t.check(doc.isDocumentEdited, "conflict: still dirty")
            t.equal(t.read(file), theirs, "conflict: disk has the other tool's version")
            let err = await t.autosave(doc)
            t.check((err as NSError?)?.code == NSUserCancelledError, "autosave is held back with NSUserCancelledError (silent): \(String(describing: err))")
            t.equal(t.read(file), theirs, "autosave did not touch the file")
            t.check(UITrap.alerts.isEmpty, "no alert for the held-back autosave")
            // does NSDocument hammer us with autosave retries?
            let saves0 = t.traces.filter { $0.msg.hasPrefix("save(op=") }.count
            await t.sleep(1500)
            t.check(t.traces.filter { $0.msg.hasPrefix("save(op=") }.count - saves0 <= 1, "no autosave retry storm while the conflict is open")
            t.close(doc)
        }
        // --- explicit save -> sheet: Cancel
        do {
            let (doc, host, file, mine) = try await setup("c2.md")
            UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }
            UITrap.reset()
            doc.save(nil)
            await t.sleep(300)
            t.equal(UITrap.alerts.count, 1, "explicit save shows ONE sheet")
            t.check(UITrap.alerts.first.map { $0.buttons == ["Overwrite File", "Reload from Disk", "Cancel"] } ?? false, "sheet buttons: \(UITrap.alerts.first?.buttons ?? []) - \"\(UITrap.alerts.first?.message ?? "")\"")
            t.equal(t.read(file), theirs, "Cancel: disk untouched")
            t.equal(host.textView.string, mine, "Cancel: text untouched")
            t.equal(doc.syncState, .conflict, "Cancel: still in conflict")
            t.close(doc)
        }
        // --- explicit save -> sheet: Overwrite File
        do {
            let (doc, host, file, mine) = try await setup("c3.md")
            UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Overwrite File") ?? 0 }
            UITrap.reset()
            doc.save(nil)
            let ok = await t.waitFor(3000) { self.fileEquals(t, file, mine) }
            t.check(ok, "Overwrite File: disk now has my version")
            await t.sleep(300)
            t.equal(doc.syncState, .inSync, "Overwrite: in sync again")
            t.check(!doc.isDocumentEdited, "Overwrite: clean")
            t.check(!host.bannerVisible, "Overwrite: banner gone")
            t.equal(UITrap.alerts.count, 1, "Overwrite: exactly the one sheet (no stock NSDocument alert on top)")
            t.close(doc)
        }
        // --- explicit save -> sheet: Reload from Disk, then Undo brings my text back
        do {
            let (doc, host, file, mine) = try await setup("c4.md")
            UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Reload from Disk") ?? 0 }
            UITrap.reset()
            doc.save(nil)
            let ok = await t.waitFor(3000) { host.textView.string == theirs }
            t.check(ok, "Reload from Disk (sheet): editor shows the other version")
            t.equal(t.read(file), theirs, "disk untouched")
            t.check(!doc.isDocumentEdited, "reloaded: clean")
            t.check(doc.undoManager?.canUndo == true, "reload is an undoable edit")
            doc.undoManager?.undo()
            t.equal(host.textView.string, mine, "Undo after 'Reload from Disk' brings MY text back (typed work is recoverable)")
            t.check(doc.isDocumentEdited, "after that Undo the document is dirty again (differs from disk)")
            doc.undoManager?.redo()
            t.equal(host.textView.string, theirs, "Redo -> disk version again")
            t.close(doc)
        }
        // --- banner buttons
        do {
            let (doc, host, file, mine) = try await setup("c5.md")
            host.pressBannerButton("Keep My Version")
            await t.sleep(100)
            t.equal(doc.syncState, .inSync, "Keep My Version: conflict resolved")
            t.check(doc.isDocumentEdited, "Keep My Version: still dirty (nothing written yet)")
            t.equal(t.read(file), theirs, "Keep My Version: disk not touched yet")
            let err = await t.autosave(doc)
            t.check(err == nil, "Keep My Version: the next autosave goes through without any alert (\(String(describing: err)))")
            t.equal(t.read(file), mine, "... and writes my version")
            t.check(UITrap.alerts.isEmpty, "no alert")
            t.close(doc)
        }
        do {
            let (doc, host, _, mine) = try await setup("c6.md")
            host.pressBannerButton("Reload from Disk")
            await t.sleep(100)
            t.equal(host.textView.string, theirs, "banner Reload from Disk: editor == disk")
            t.check(!doc.isDocumentEdited && doc.syncState == .inSync && !host.bannerVisible, "clean, in sync, banner hidden")
            doc.undoManager?.undo()
            t.equal(host.textView.string, mine, "Undo restores my text")
            t.close(doc)
        }
        // --- the other tool reverts its change while the conflict is open: conflict disappears by itself
        do {
            let (doc, host, file, mine) = try await setup("c7.md")
            await atomicWrite(t, file, paras)
            let ok = await t.waitFor(3000) { doc.syncState == .inSync }
            t.check(ok && !host.bannerVisible, "disk reverted to the base: conflict state and banner clear themselves")
            t.equal(host.textView.string, mine, "my text untouched")
            t.close(doc)
        }
        // --- a second external change while a conflict is open updates the offered disk version
        do {
            let (doc, host, file, mine) = try await setup("c8.md")
            await atomicWrite(t, file, paras.replacingOccurrences(of: "paragraph 3 of the document", with: "paragraph 3 THEIRS v2"))
            await t.sleep(600)
            t.equal(doc.stats.conflicts, 2, "second disk version while in conflict is tracked")
            host.pressBannerButton("Reload from Disk")
            await t.sleep(100)
            t.check(host.textView.string.contains("THEIRS v2"), "Reload loads the LATEST disk version")
            _ = mine
            t.close(doc)
        }
        // --- unreadable: file turns into binary
        do {
            let file = t.write(paras, to: "bin.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            let before = host.textView.string
            let tmp = file.appendingPathExtension("tmp")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00, 0xFF, 0x00]).write(to: tmp)
            await t.sh("mv \(t.q(tmp)) \(t.q(file))")
            let ok = await t.waitFor(3000) { doc.syncState == .unreadable }
            t.check(ok, "file replaced by binary data: unreadable state (\(host.bannerText))")
            t.equal(host.textView.string, before, "editor keeps the text")
            let err = await t.autosave(doc)
            t.check(err == nil || (err as NSError?)?.code == NSUserCancelledError, "clean doc: autosave is a no-op / held back")
            t.close(doc)
        }
        // --- Save As... while in conflict: the escape hatch must work (stock Save As would autosave first and fail silently)
        do {
            let (doc, _, file, mine) = try await setup("c10.md")
            let copy = t.url("c10-my-copy.md")
            UITrap.panelChooser = { _ in copy }
            UITrap.reset()
            doc.saveAs(nil)
            let ok = await t.waitFor(3000) { FileManager.default.fileExists(atPath: copy.path) }
            if !ok { t.note("Save As debug: panels=\(UITrap.panels) violations=\(UITrap.violations) alerts=\(UITrap.alerts) copy=\(copy.path) root=\(UITrap.allowedRoot?.path ?? "nil")") }
            t.check(ok && t.read(copy) == mine, "Save As… in conflict: my version is written to the new file")
            await t.sleep(300)
            t.equal(t.read(file), theirs, "Save As… in conflict: the other tool's file is untouched")
            t.check(doc.fileURL?.lastPathComponent == "c10-my-copy.md" && doc.syncState == .inSync && !doc.isDocumentEdited, "document now represents the new file, in sync, clean (fileURL \(doc.fileURL?.lastPathComponent ?? "nil"))")
            t.close(doc)
        }
        // --- closing a window with an unresolved conflict: ask, never fail silently
        for (label, choice, expectClose, expectDisk) in [("Cancel", "Cancel", false, "theirs"), ("Discard My Changes", "Discard My Changes", true, "theirs"), ("Overwrite File", "Overwrite File", true, "mine")] {
            let (doc, _, file, mine) = try await setup("c9-\(label.prefix(3)).md")
            UITrap.alertChooser = { a in a.buttons.firstIndex(of: choice) ?? 0 }
            UITrap.reset()
            let probe = CloseProbe()
            doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            _ = await t.waitFor(3000) { probe.result != nil }
            t.equal(UITrap.alerts.count, 1, "close with conflict [\(label)]: one sheet \(UITrap.alerts.first?.buttons ?? [])")
            t.equal(probe.result, expectClose, "close with conflict [\(label)]: shouldClose")
            t.equal(t.read(file), expectDisk == "mine" ? mine : theirs, "close with conflict [\(label)]: disk has \(expectDisk)")
            if expectClose == false { t.close(doc) }
        }
    }

    @MainActor static func fileEquals(_ t: SelfTest.T, _ f: URL, _ s: String) -> Bool { t.read(f) == s }

    // MARK: save gate

    @MainActor static func saveGate(_ t: SelfTest.T) async throws {
        // 1. clean doc, external replace, then type + autosave: NSDocument's own modification-date check must stay quiet
        do {
            let file = t.write(paras, to: "g1.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            let r0 = doc.stats.silentReloads
            await atomicWrite(t, file, paras + "external\n")
            _ = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.typeText("typed ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err = await t.autosave(doc)
            t.check(err == nil && UITrap.alerts.isEmpty, "silent reload, then type + autosave: no stock alert, err=\(String(describing: err))")
            t.equal(t.read(file), "typed " + paras + "external\n", "autosave wrote typed text + the reloaded content")
            _ = host
            t.close(doc)
        }
        // 2. mtime-only change (touch): signature differs, content same -> no reload, and later autosave is still quiet
        do {
            let file = t.write(paras, to: "g2.md")
            let doc = try await t.open(file)
            await t.sleep(1500)
            let r0 = doc.stats.silentReloads
            await t.sh("sleep 1.1; touch \(t.q(file))")
            await t.sleep(600)
            t.equal(doc.stats.silentReloads, r0, "touch: no reload (content identical)")
            t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err = await t.autosave(doc)
            t.check(err == nil && UITrap.alerts.isEmpty, "after touch + typing: autosave quiet (modification date kept in sync), err=\(String(describing: err))")
            t.close(doc)
        }
        // 3. THE RACE: monitor + presenter cannot have delivered yet when the autosave fires (monitor stopped, write, immediate autosave)
        do {
            let file = t.write(paras, to: "g3.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            doc.monitor?.stop()
            t.typeText(" MINE", into: doc, at: NSRange(location: (host.textView.string as NSString).range(of: "paragraph 8 of the document").upperBound, length: 0))
            await t.sleep(30)
            await atomicWrite(t, file, paras.replacingOccurrences(of: "paragraph 1 of", with: "paragraph 1 TOOL of"))
            let err = await t.autosave(doc)          // immediately: nobody noticed the change yet
            t.check(err == nil && UITrap.alerts.isEmpty, "race (non-overlapping): the save gate merges first, autosave succeeds, no alert (\(String(describing: err)))")
            let disk = t.read(file)
            t.check(disk.contains("paragraph 1 TOOL of") && disk.contains("paragraph 8 of the document MINE"), "disk has both the tool's and my change")
            t.close(doc)
        }
        do {
            let file = t.write(paras, to: "g4.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            doc.monitor?.stop()
            let r = (host.textView.string as NSString).range(of: "paragraph 5 of the document")
            t.typeText("paragraph 5 MINE", into: doc, at: r)
            await t.sleep(30)
            let theirs = paras.replacingOccurrences(of: "paragraph 5 of the document", with: "paragraph 5 TOOL")
            await atomicWrite(t, file, theirs)
            let err = await t.autosave(doc)
            t.check((err as NSError?)?.code == NSUserCancelledError && UITrap.alerts.isEmpty, "race (overlapping): autosave held back silently, banner instead of a sheet")
            t.equal(t.read(file), theirs, "tool's version survives")
            t.equal(doc.syncState, .conflict, "state conflict")
            t.check(host.bannerVisible, "banner visible: \(host.bannerText)")
            t.close(doc)
        }
        // 3b. Reload from Disk (File menu, manual counterpart of the automatic reload): discards edits, undoable
        do {
            let file = t.write(paras, to: "g6.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            t.typeText("DISCARD ME ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Reload") ?? 0 }
            doc.luftigReloadFromDisk(nil)
            let ok = await t.waitFor(3000) { host.textView.string == paras }
            t.check(ok && UITrap.alerts.count == 1, "Reload from Disk: confirmation sheet \(UITrap.alerts.first?.buttons ?? []), then editor == file")
            t.check(!doc.isDocumentEdited, "reloaded: clean")
            doc.undoManager?.undo()
            t.check(host.textView.string.hasPrefix("DISCARD ME "), "Reload from Disk is undoable (discarded text can be brought back)")
            t.close(doc)
        }
        // 3c. NSDocument's own Revert (Versions: "Last Opened Version") is the system's business; just record what it does
        do {
            let file = t.write(paras, to: "g7.md")
            let doc = try await t.open(file)
            await t.sleep(200)
            t.typeText("X", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset(); UITrap.alertChooser = { _ in 0 }
            doc.revertToSaved(nil)
            await t.sleep(500)
            t.note("stock revertToSaved on an autosave-in-place document: alerts=\(UITrap.alerts.map { $0.message + " " + "\($0.buttons)" }), text after=\((doc.host?.currentText ?? "").substring(to: 3).debugDescription) (Versions based: 'Last Opened Version' needs a stored version)")
            t.close(doc)
        }
        // 4. explicit Save on a CLEAN document whose file changed unnoticed: reload, nothing lost
        do {
            let file = t.write(paras, to: "g5.md")
            let doc = try await t.open(file)
            await t.sleep(200)
            doc.monitor?.stop()
            await atomicWrite(t, file, paras + "tool\n")
            UITrap.reset()
            doc.save(nil)
            await t.sleep(500)
            t.equal(t.read(file), paras + "tool\n", "Save on a clean doc: the tool's change is neither lost nor re-written differently")
            t.check(UITrap.alerts.isEmpty, "no alert")
            t.close(doc)
        }
    }

    // MARK: autosavesInPlace == false

    @MainActor static func autosaveOff(_ t: SelfTest.T) async throws {
        MarkdownDocument.autosavesInPlaceEnabled = false
        defer { MarkdownDocument.autosavesInPlaceEnabled = true }
        // clean reload
        do {
            let file = t.write(paras, to: "o1.md")
            let doc = try await t.open(file)
            await t.sleep(200)
            let r0 = doc.stats.silentReloads
            await atomicWrite(t, file, paras + "tool\n")
            let reloaded = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.check(reloaded, "autosavesInPlace=false: clean document reloads silently (class autosavesInPlace = \(MarkdownDocument.autosavesInPlace))")
            t.close(doc)
        }
        // merge, then ⌘S writes the merged text with no stock sheet
        do {
            let file = t.write(paras, to: "o2.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            t.typeText(" MINE", into: doc, at: NSRange(location: (host.textView.string as NSString).range(of: "paragraph 8 of the document").upperBound, length: 0))
            await t.sleep(30)
            await atomicWrite(t, file, paras.replacingOccurrences(of: "paragraph 1 of", with: "paragraph 1 TOOL of"))
            let merged = await t.waitFor(3000) { doc.stats.merges >= 1 }
            t.check(merged, "autosavesInPlace=false: dirty document merges the external change")
            UITrap.reset()
            doc.save(nil)
            let ok = await t.waitFor(3000) { t.read(file).contains("paragraph 8 of the document MINE") && t.read(file).contains("paragraph 1 TOOL of") }
            await t.sleep(300)
            t.check(ok && UITrap.alerts.isEmpty && !doc.isDocumentEdited, "⌘S writes both changes, no sheet (alerts: \(UITrap.alerts.map { $0.message }))")
            t.close(doc)
        }
        // conflict: ⌘S -> our sheet only
        do {
            let file = t.write(paras, to: "o3.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            t.typeText("paragraph 5 MINE", into: doc, at: (host.textView.string as NSString).range(of: "paragraph 5 of the document"))
            await t.sleep(30)
            await atomicWrite(t, file, paras.replacingOccurrences(of: "paragraph 5 of the document", with: "paragraph 5 TOOL"))
            let conflicted = await t.waitFor(3000) { doc.syncState == .conflict }
            t.check(conflicted, "autosavesInPlace=false: conflict detected")
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }
            doc.save(nil)
            await t.sleep(300)
            t.check(UITrap.alerts.count == 1 && UITrap.alerts[0].buttons.contains("Overwrite File"), "⌘S in conflict: exactly our sheet \(UITrap.alerts.first?.buttons ?? [])")
            // the classic draft autosave (autosaveElsewhere) must not confuse the bookkeeping
            let err = await t.autosave(doc)
            t.note("draft autosave (autosavesInPlace=false) while in conflict: err=\(String(describing: err)); disk untouched: \(t.read(file).contains("paragraph 5 TOOL"))")
            t.check(t.read(file).contains("paragraph 5 TOOL"), "draft autosave did not write the real file")
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Overwrite File") ?? 0 }
            doc.save(nil)
            _ = await t.waitFor(3000) { t.read(file).contains("paragraph 5 MINE") }
            t.check(t.read(file).contains("paragraph 5 MINE"), "Overwrite File writes my version")
            t.close(doc)
        }
        // draft autosave of a clean-but-edited doc must not be mistaken for an external change afterwards
        do {
            let file = t.write(paras, to: "o4.md")
            let doc = try await t.open(file)
            await t.sleep(1500)
            t.typeText("typed ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let r0 = doc.stats.silentReloads, m0 = doc.stats.merges, c0 = doc.stats.conflicts
            _ = await t.autosave(doc)
            await t.sleep(1500)
            t.check(doc.stats.silentReloads == r0 && doc.stats.merges == m0 && doc.stats.conflicts == c0, "draft autosave (op autosaveElsewhere) triggers no reload/merge/conflict")
            t.equal(t.read(file), paras, "real file untouched by the draft autosave")
            t.close(doc)
        }
    }

    // MARK: deleted / moved

    @MainActor static func deletedMoved(_ t: SelfTest.T) async throws {
        // a) rm: banner + dirty + autosave held back (must not resurrect the file); Save Again recreates
        do {
            let file = t.write(paras, to: "d1.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            await t.sh("rm \(t.q(file))")
            let ok = await t.waitFor(4000) { doc.syncState == .deletedOnDisk }
            t.check(ok, "rm: after the grace period the document knows the file is gone (banner: \(host.bannerText))")
            t.check(doc.isDocumentEdited, "deleted: marked as edited so that closing asks")
            t.equal(host.bannerButtonTitles, ["Save Again…"], "banner offers Save Again…")
            let err = await t.autosave(doc)
            t.check((err as NSError?)?.code == NSUserCancelledError, "autosave does not resurrect the deleted file (\(String(describing: err)))")
            t.check(!FileManager.default.fileExists(atPath: file.path), "file still gone")
            UITrap.reset()
            UITrap.panelChooser = { _ in file }          // the user confirms the Save panel as it is offered
            doc.save(nil)
            let ok2 = await t.waitFor(3000) { FileManager.default.fileExists(atPath: file.path) }
            t.note("⌘S on a deleted file: panels shown=\(UITrap.panels.map { "\($0.kind) name=\($0.nameField)" }), alerts=\(UITrap.alerts.map { $0.message })")
            await t.sleep(500)
            t.note("after confirm: alerts=\(UITrap.alerts.map { $0.message + " / " + $0.info }) panels=\(UITrap.panels.count) fileURL=\(doc.fileURL?.lastPathComponent ?? "nil") exists=\(FileManager.default.fileExists(atPath: file.path)) edited=\(doc.isDocumentEdited)")
            t.check(ok2 && t.read(file) == paras, "explicit Save recreates the file with the document's text")
            await t.sleep(300)
            t.check(doc.syncState == .inSync && !doc.isDocumentEdited, "back in sync, clean")
            t.close(doc)
        }
        // b) rm, then the file comes back (restored from trash, recreated by a tool) with new content: silent reload
        do {
            let file = t.write(paras, to: "d2.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            await t.sh("rm \(t.q(file))")
            _ = await t.waitFor(4000) { doc.syncState == .deletedOnDisk }
            await t.sh("printf 'brand new content\\n' > \(t.q(file))")
            let ok = await t.waitFor(3000) { host.textView.string == "brand new content\n" }
            t.check(ok, "file recreated with new content: reloaded")
            await t.sleep(300)
            t.check(doc.syncState == .inSync && !doc.isDocumentEdited && !host.bannerVisible, "clean, in sync, banner hidden")
            t.close(doc)
        }
        // c) mv to another folder / rename in place: NSDocument follows (presenter), our monitor retargets, later changes are seen
        for (label, dest) in [("move to another folder", "elsewhere/m1.md"), ("rename in place", "m2-renamed.md")] {
            try? FileManager.default.createDirectory(at: t.url("elsewhere"), withIntermediateDirectories: true)
            let file = t.write(paras, to: label.hasPrefix("move") ? "m1.md" : "m2.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            let dst = t.url(dest)
            await t.sh("mv \(t.q(file)) \(t.q(dst))")
            let followed = await t.waitFor(4000) { doc.fileURL?.lastPathComponent == dst.lastPathComponent }
            t.check(followed, "\(label): NSDocument updates fileURL (\(doc.fileURL?.path.replacingOccurrences(of: t.work.path, with: "<work>") ?? "nil"))")
            await t.sleep(2200)
            t.check(doc.syncState == .inSync && !host.bannerVisible && !doc.isDocumentEdited, "\(label): no deleted-banner, still clean")
            let r0 = doc.stats.silentReloads
            await t.sh("printf 'after move\\n' >> \(t.q(dst))")
            let ok = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.check(ok && host.textView.string.hasSuffix("after move\n"), "\(label): external change at the NEW location is picked up")
            t.close(doc)
        }
        // c2) close a deleted + dirty document: sheet offers Save Again…
        do {
            let file = t.write(paras, to: "d4.md")
            let doc = try await t.open(file)
            await t.sleep(200)
            await t.sh("rm \(t.q(file))")
            _ = await t.waitFor(4000) { doc.syncState == .deletedOnDisk }
            UITrap.reset()
            UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Save Again") ?? 0 }
            UITrap.panelChooser = { _ in file }
            let probe = CloseProbe()
            doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            _ = await t.waitFor(3000) { probe.result != nil }
            t.check(probe.result == true && t.read(file) == paras, "close deleted doc: sheet \(UITrap.alerts.first?.buttons ?? []) -> Save Again recreates the file, then closes")
            t.close(doc)
        }
        // d) dirty + rm: typed text is kept, Save Again writes it
        do {
            let file = t.write(paras, to: "d3.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { return }
            await t.sleep(200)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            await t.sh("rm \(t.q(file))")
            _ = await t.waitFor(4000) { doc.syncState == .deletedOnDisk }
            await t.sh("printf 'tool recreated it\\n' > \(t.q(file))")
            await t.sleep(800)
            t.check(host.textView.string.hasPrefix("TYPED "), "dirty + deleted + recreated by tool: typed text still there (state \(doc.syncState))")
            t.check(doc.syncState == .conflict, "-> conflict (the new file is a different version): banner \(host.bannerText)")
            t.close(doc)
        }
    }
}
#endif
