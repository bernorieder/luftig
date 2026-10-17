#if LUFTIG_SELFTEST
// SelfTestAuditDocSave.swift - auditdoc-save (see SelfTestAuditDoc.swift for the list).

import AppKit

extension SelfTestScenarios {

    static func auditXattrs(_ path: String) -> [String] {
        let n = listxattr(path, nil, 0, 0)
        guard n > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: n)
        listxattr(path, &buf, n, 0)
        return buf.split(separator: 0).map { String(cString: Array($0) + [0]) }
    }

    @MainActor static func auditDocSave(_ t: SelfTest.T) async throws {
        let paras = auditParas

        // ---- A. permissions, extended attributes and the creation date survive the safe-save (new inode) of an autosave
        do {
            let f = t.write(paras, to: "attrs.md")
            chmod(f.path, 0o640)
            setxattr(f.path, "com.example.audit", "hello", 5, 0, 0)
            let birth0 = (try? FileManager.default.attributesOfItem(atPath: f.path)[.creationDate] as? Date) ?? nil
            await t.sleep(1100)
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err = await t.autosave(doc)
            await t.sleep(150)
            var st = stat(); stat(f.path, &st)
            let birth1 = (try? FileManager.default.attributesOfItem(atPath: f.path)[.creationDate] as? Date) ?? nil
            t.check(err == nil && t.read(f) == "TYPED " + paras, "attrs: autosave wrote the text (\(String(describing: err)))")
            t.equal(String(st.st_mode & 0o7777, radix: 8), "640", "permissions 0640 kept")
            t.check(auditXattrs(f.path).contains("com.example.audit"), "extended attribute kept: \(auditXattrs(f.path))")
            t.check(birth0 == birth1, "creation date kept (\(String(describing: birth0)) -> \(String(describing: birth1)))")
            t.close(doc)
        }
        // ---- B. hard link: documented limitation, recorded (NSDocument's safe save replaces the inode; the other name keeps the old content)
        do {
            let a = t.write(paras, to: "hard-a.md")
            try FileManager.default.linkItem(at: a, to: t.url("hard-b.md"))
            let doc = try await t.open(a)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            _ = await t.autosave(doc)
            await t.sleep(150)
            t.check(t.read(a) == "TYPED " + paras, "hard link: the opened name has the edit")
            t.note("hard link: the OTHER name now \(t.read(t.url("hard-b.md")) == paras ? "keeps the OLD content (link broken by the safe save, the usual macOS document behaviour)" : "has the new content")")
            t.close(doc)
        }
        // ---- C. a write that FAILS (file size limit stands in for a full disk): the file on disk is untouched, no temp file is left behind,
        //         the text is kept, the document stays dirty, and the next save (limit lifted) succeeds
        do {
            var big = ""
            while big.utf8.count < 400_000 { big += "A line of text that is long enough to make the file big, \(big.utf8.count)\n" }
            let f = t.write(big, to: "fsize.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            signal(SIGXFSZ, SIG_IGN)
            var old = rlimit(); getrlimit(RLIMIT_FSIZE, &old)
            var small = rlimit(rlim_cur: 100_000, rlim_max: old.rlim_max)
            setrlimit(RLIMIT_FSIZE, &small)
            UITrap.reset()
            let err = await t.autosave(doc)
            setrlimit(RLIMIT_FSIZE, &old)
            await t.sleep(300)
            t.check(err != nil, "failed write: the autosave reports an error (\((err as NSError?)?.localizedDescription ?? "nil"))")
            t.equal(t.read(f), big, "failed write: the file on disk is byte-for-byte what it was")
            let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: t.work.path)) ?? []).filter { $0.hasPrefix("fsize.md.") || $0.contains(".sb-") }
            t.check(leftovers.isEmpty, "failed write: no temporary file left behind \(leftovers)")
            t.check(doc.isDocumentEdited && (t.editor(doc)?.textView.string ?? "").hasPrefix("TYPED "), "failed write: the text is kept and the document is still dirty")
            t.check(!doc.isSaving, "failed write: isSaving is not stuck")
            let again = await t.autosave(doc)
            await t.sleep(300)
            t.check(again == nil && t.read(f) == "TYPED " + big, "after the limit is lifted the next autosave writes everything (\(String(describing: again)))")
            t.close(doc)
        }
        // ---- D. read-only file / read-only folder at OPEN time: NSDocument refuses the edit and asks (Unlock / Duplicate / Cancel). Nothing may be
        //         written, nothing may be half-typed, the document must not end up "edited" without a way to save it.
        do {
            let f = t.write(paras, to: "ro.md")
            chmod(f.path, 0o444)
            let doc = try await t.open(f)
            await t.sleep(150)
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(300)
            _ = await t.autosave(doc)
            await t.sleep(200)
            t.check(t.read(f) == paras, "read-only file: nothing written")
            t.check(UITrap.alerts.count == 1 && UITrap.alerts[0].message.contains("locked"), "read-only file: the user is told why the edit is refused (alerts: \(UITrap.alerts.map { $0.message }))")
            t.check((t.editor(doc)?.textView.string ?? "") == paras && !doc.isDocumentEdited, "read-only file, Cancel: the edit was refused as a whole (no half-typed text, not marked edited)")
            // ... and Unlock: the edit goes through and is saved
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Unlock") ?? 0 }
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(300)
            let err = await t.autosave(doc)
            await t.sleep(200)
            t.check((t.editor(doc)?.textView.string ?? "").hasPrefix("TYPED ") && err == nil && t.read(f) == "TYPED " + paras, "read-only file, Unlock: the edit is accepted and the autosave writes it (\(String(describing: err)))")
            t.close(doc)
            chmod(f.path, 0o644)
        }
        do {
            try? FileManager.default.createDirectory(at: t.url("rodir"), withIntermediateDirectories: true)
            let f = t.write(paras, to: "rodir/in-ro-dir.md")
            chmod(t.url("rodir").path, 0o555)
            let doc = try await t.open(f)
            await t.sleep(150)
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(300)
            _ = await t.autosave(doc)
            await t.sleep(200)
            t.check(t.read(f) == paras, "read-only folder: the file is untouched")
            t.check(UITrap.alerts.count == 1 && UITrap.alerts[0].message.contains("permission"), "read-only folder: the user is told why (alerts: \(UITrap.alerts.map { $0.message }))")
            t.check((t.editor(doc)?.textView.string ?? "") == paras && !doc.isDocumentEdited, "read-only folder, Cancel: the edit was refused as a whole")
            t.close(doc)
            chmod(t.url("rodir").path, 0o755)
        }
        // ---- D2. the file / folder BECOMES read-only after the document was opened and edited: the autosave fails, the error is shown, the typed
        //          text stays and the document stays dirty; once the permission is back the next save writes everything
        do {
            let f = t.write(paras, to: "ro-later.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            chmod(f.path, 0o444)
            UITrap.reset()
            let err = await t.autosave(doc)
            await t.sleep(300)
            t.check(err != nil && t.read(f) == paras, "file made read-only after the edit: the autosave reports an error (\((err as NSError?)?.localizedDescription ?? "nil")) and the file is untouched")
            t.check((t.editor(doc)?.textView.string ?? "").hasPrefix("TYPED ") && doc.isDocumentEdited && !doc.isSaving, "... the typed text is kept, the document is still dirty, isSaving is not stuck")
            chmod(f.path, 0o644)
            let again = await t.autosave(doc)
            t.check(again == nil && t.read(f) == "TYPED " + paras && !doc.isDocumentEdited, "permission back: the next autosave writes the text (\(String(describing: again)))")
            t.close(doc)
        }
        do {
            try? FileManager.default.createDirectory(at: t.url("rodir2"), withIntermediateDirectories: true)
            let f = t.write(paras, to: "rodir2/x.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            chmod(t.url("rodir2").path, 0o555)
            UITrap.reset()
            let err = await t.autosave(doc)
            await t.sleep(300)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: t.url("rodir2").path)) ?? []
            t.check(err != nil && t.read(f) == paras && left == ["x.md"], "folder made read-only after the edit: the autosave reports an error, the file is untouched, no temp file (\(left))")
            t.check((t.editor(doc)?.textView.string ?? "").hasPrefix("TYPED ") && doc.isDocumentEdited && !doc.isSaving, "... the typed text is kept, still dirty")
            chmod(t.url("rodir2").path, 0o755)
            let again = await t.autosave(doc)
            t.check(again == nil && t.read(f) == "TYPED " + paras, "permission back: the next autosave writes the text (\(String(describing: again)))")
            t.close(doc)
        }
        // ---- E. Save As: the watcher follows the NEW file, the old one is left alone and no longer watched
        do {
            let a = t.write(paras, to: "sa-old.md")
            let doc = try await t.open(a)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let b = t.url("sa-new.md")
            let err: Error? = await withCheckedContinuation { c in doc.save(to: b, ofType: doc.fileType!, for: .saveAsOperation) { c.resume(returning: $0) } }
            await t.sleep(600)
            t.check(err == nil && t.read(b) == "TYPED " + paras, "Save As: the new file has the text (\(String(describing: err)))")
            t.equal(t.read(a), paras, "Save As: the old file is untouched")
            t.equal(doc.fileURL?.lastPathComponent, "sa-new.md", "Save As: the document now represents the new file")
            t.check(!doc.isDocumentEdited && doc.syncState == .inSync, "Save As: clean and in sync")
            let r0 = doc.stats.silentReloads
            await t.sh("printf 'to the OLD file\\n' >> \(t.q(a))")
            await t.sleep(900)
            t.check(doc.stats.silentReloads == r0 && !host.textView.string.contains("to the OLD file"), "Save As: a change to the OLD file is ignored")
            await t.sh("printf 'to the NEW file\\n' >> \(t.q(b))")
            let saw = await t.waitFor(2500) { doc.stats.silentReloads > r0 }
            t.check(saw && host.textView.string.hasSuffix("to the NEW file\n"), "Save As: a change to the NEW file is picked up (trigger \(doc.stats.lastReloadTrigger))")
            t.close(doc)
        }
        // ---- F. Save As over an existing file that is open in another window
        do {
            let a = t.write(paras, to: "so-a.md"), b = t.write("other document\n", to: "so-b.md")
            let da = try await t.open(a), db = try await t.open(b)
            await t.sleep(200)
            t.typeText("TYPED ", into: da, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err: Error? = await withCheckedContinuation { c in da.save(to: b, ofType: da.fileType!, for: .saveAsOperation) { c.resume(returning: $0) } }
            await t.sleep(1200)
            t.check(err == nil && t.read(b) == "TYPED " + paras, "Save As over an open file: written (\(String(describing: err)))")
            t.check(!NSDocumentController.shared.documents.contains(db) || db.isClosed, "the other document that had that file open is closed by AppKit")
            t.check(da.fileURL?.lastPathComponent == "so-b.md" && !da.isDocumentEdited, "the saved document represents the file")
            t.close(da); t.close(db)
        }
        // ---- G. File > Move To: the watcher follows
        do {
            let a = t.write(paras, to: "mv-old.md")
            try? FileManager.default.createDirectory(at: t.url("moved"), withIntermediateDirectories: true)
            let doc = try await t.open(a)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            let dst = t.url("moved/mv-new.md")
            let err: Error? = await withCheckedContinuation { c in doc.move(to: dst) { c.resume(returning: $0) } }
            await t.sleep(800)
            t.check(err == nil && FileManager.default.fileExists(atPath: dst.path) && !FileManager.default.fileExists(atPath: a.path), "Move To: the file moved (\(String(describing: err)))")
            t.check(doc.syncState == .inSync && !host.bannerVisible, "Move To: no 'deleted' banner")
            let r0 = doc.stats.silentReloads
            await t.sh("printf 'moved append\\n' >> \(t.q(dst))")
            let saw = await t.waitFor(2500) { doc.stats.silentReloads > r0 }
            t.check(saw, "Move To: a change at the new place is picked up (trigger \(doc.stats.lastReloadTrigger))")
            t.close(doc)
        }
        // ---- H. autosave, explicit save and a save to the own file, all at once, 20 rounds: nothing stuck, disk == editor
        do {
            let f = t.write(paras, to: "race.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            var ok = true
            for round in 0..<20 {
                t.typeText("r\(round) ", into: doc, at: NSRange(location: 0, length: 0))
                await t.sleep(10)
                let g = DispatchGroup()
                var errors: [Error] = []
                g.enter(); doc.autosave(withImplicitCancellability: false) { e in if let e { errors.append(e) }; g.leave() }
                g.enter(); doc.save(to: f, ofType: doc.fileType!, for: .saveOperation) { e in if let e { errors.append(e) }; g.leave() }
                g.enter(); doc.save(to: f, ofType: doc.fileType!, for: .autosaveInPlaceOperation) { e in if let e { errors.append(e) }; g.leave() }
                _ = await t.waitFor(3000) { g.wait(timeout: .now()) == .success }
                await t.sleep(20)
                if !errors.isEmpty || doc.isSaving || t.read(f) != (t.editor(doc)?.textView.string ?? "") { ok = false; t.info("round \(round): errors=\(errors) isSaving=\(doc.isSaving)") }
            }
            t.check(ok, "20 rounds of simultaneous autosave + save + autosave: no error, nothing stuck, the file always equals the editor text")
            t.check(doc.syncState == .inSync && !doc.checkInFlight, "state afterwards: inSync, no check stuck")
            t.close(doc)
        }
        // ---- I. saving while another process keeps replacing the file (atomic, 200 times): never a crash, never a stuck flag, and
        //         the other tool's last version is never silently lost (it ends in the editor, or the document is in conflict)
        do {
            let f = t.write(paras, to: "storm-save.md")
            let doc = try await t.open(f)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            UITrap.reset(); UITrap.alertChooser = { _ in 2 }          // Cancel in any sheet
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/bin/sh")
            writer.arguments = ["-c", "i=1; while [ $i -le 150 ]; do sed -n 1,9p \(t.q(f)) > \(t.q(f)).tmp; printf 'TOOLGEN %d\\n' $i >> \(t.q(f)).tmp; mv \(t.q(f)).tmp \(t.q(f)); sleep 0.01; i=$((i+1)); done"]
            try writer.run()
            var n = 0
            while writer.isRunning && n < 60 {
                t.typeText("t\(n) ", into: doc, at: NSRange(location: 0, length: 0))
                _ = await t.autosave(doc)
                n += 1
                await t.sleep(8)
            }
            while writer.isRunning { await t.sleep(20) }
            _ = await auditSettle(t, doc, 5000)
            await t.sleep(800)
            _ = await auditSettle(t, doc, 5000)
            let disk = t.read(f)
            let lastGen = disk.components(separatedBy: "\n").filter { $0.hasPrefix("TOOLGEN") }.last ?? "?"
            t.note("storm + saves: \(n) typed+autosaved rounds, \(doc.stats.merges) merges, \(doc.stats.conflicts) conflicts, \(doc.stats.silentReloads) reloads; last tool line on disk: \(lastGen); state \(doc.syncState)")
            t.check(!doc.isSaving && !doc.checkInFlight && !doc.isApplyingExternal, "nothing stuck after the storm")
            t.check(doc.syncState == .inSync || doc.syncState == .conflict, "state is inSync or conflict (not lost): \(doc.syncState)")
            if doc.syncState == .conflict { t.check(host.bannerVisible, "conflict: the banner is up") }
            else { t.check(!doc.isDocumentEdited ? host.currentText.isEqual(to: disk) : true, "in sync and clean: the editor shows the file") }
            t.check(disk.contains("TOOLGEN"), "the tool's content is on disk (never replaced wholesale by an old editor text)")
            t.close(doc)
        }
        // ---- J. closing: a dirty, in-sync document is saved by the close (autosave in place), nothing is asked
        do {
            let f = t.write(paras, to: "close-dirty.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            UITrap.reset()
            let probe = CloseProbe()
            doc.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            _ = await t.waitFor(3000) { probe.result != nil }
            t.check(probe.result == true && t.read(f) == "TYPED " + paras && UITrap.alerts.isEmpty, "close of a dirty in-sync document: saved, closes, no question (alerts \(UITrap.alerts.map { $0.message }))")
            t.close(doc)
        }
        // ---- K. Duplicate
        do {
            let f = t.write(paras, to: "dup.md")
            let doc = try await t.open(f)
            await t.sleep(150)
            t.typeText("TYPED ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            if let dup = try? doc.duplicate() as? MarkdownDocument {
                await t.sleep(200)
                t.equal((t.editor(dup)?.textView.string ?? "<no window>"), "TYPED " + paras, "Duplicate: the copy (which already has its window) holds the current text")
                t.check(dup.fileURL == nil && dup.monitor == nil, "Duplicate: untitled, no watcher")
                t.close(dup)
            } else { t.check(false, "Duplicate did not produce a MarkdownDocument") }
            t.close(doc)
        }
        t.check(UITrap.violations.isEmpty, "UITrap: no panel URL outside the work dir")
    }
}
#endif
