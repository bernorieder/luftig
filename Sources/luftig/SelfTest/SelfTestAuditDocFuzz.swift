#if LUFTIG_SELFTEST
// SelfTestAuditDocFuzz.swift - auditdoc-fuzz: model-based fuzz of the clean / dirty / conflicted / deleted state machine with REAL files and
// REAL child-process writers (regular files only).
//
// Every step is one of: the user types a unique token line, another tool inserts a token line (atomic replace or in-place append), the file is
// deleted, the file is re-created, an autosave, a short wait, "Reload from Disk" / "Keep My Version" on a conflict banner. At verification points
// (forced checks, settled) the laws of the document layer are checked:
//
//   U  every token the user typed is still in the editor (unless the user chose "Reload from Disk")
//   E  every token another tool wrote is still in the file (luftig never overwrites an external change the user did not agree to: "Keep My Version")
//   M  in state inSync every token on disk is in the editor (it was reloaded or merged); clean => editor == file
//   C  conflict => a banner is up and the file was not touched by luftig
//   S  a successful autosave of a dirty, in-sync document leaves file == editor
//   F  nothing stuck (checkInFlight, isSaving, isApplyingExternal, recheck, open undo group)
//
// Seeded (the failure message names the seed, sequence and the step log). 40 sequences of 6-14 steps by default (~35 s).

import AppKit

extension SelfTestScenarios {

    @MainActor static func auditDocFuzz(_ t: SelfTest.T) async throws {
        // (AUDITDOC_FUZZ_SEED / AUDITDOC_FUZZ_SEQUENCES: longer explorations by hand; the defaults are what runs in the suite)
        let env = ProcessInfo.processInfo.environment
        let seed = UInt64(env["AUDITDOC_FUZZ_SEED"] ?? "") ?? 424_242
        var rng = AuditRNG(seed)
        let sequences = min(400, Int(env["AUDITDOC_FUZZ_SEQUENCES"] ?? "") ?? 40)
        var failures = 0
        var steps = 0
        var merges = 0, conflicts = 0, reloads = 0, deletions = 0, keeps = 0, discards = 0
        try? FileManager.default.createDirectory(at: t.url("fz"), withIntermediateDirectories: true)
        UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Cancel") ?? 0 }

        for seq in 0..<sequences {
            let file = t.url("fz/f\(seq).md")
            let base = (0..<rng.range(3...24)).map { "line \($0) of sequence \(seq)\n" }.joined()      // short files: the edits of both sides touch more often
            t.write(base, to: "fz/f\(seq).md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(60)
            var typed: [String] = [], ext: [String] = []
            var log: [String] = []
            var counter = 0
            var lastDisk = base
            var violation: String? = nil
            var usedCoordinated = false
            func token(_ who: String) -> String { counter += 1; return "\(who)\(seq)x\(counter)" }
            func diskText() -> String? { (try? String(contentsOf: file, encoding: .utf8)).map { lastDisk = $0; return $0 } }
            func lineStarts(_ s: String) -> [Int] {
                let ns = s as NSString
                var out = [0]
                var i = 0
                while i < ns.length { if ns.character(at: i) == 10 && i + 1 < ns.length { out.append(i + 1) }; i += 1 }
                return out
            }
            func fail(_ s: String) { if violation == nil { violation = s } }

            func verify(_ label: String) async {
                for _ in 0..<2 {
                    doc.checkForExternalChange("fuzz")
                    _ = await auditSettle(t, doc, 4000)
                    await t.sleep(5)
                }
                let ed = host.textView.string
                let disk = diskText()
                if !(await auditSettle(t, doc, 1)) { fail("\(label): stuck flags (inFlight \(doc.checkInFlight) saving \(doc.isSaving) applying \(doc.isApplyingExternal) recheck \(doc.recheckRequested))") }
                if (doc.undoManager?.groupingLevel ?? 0) != 0 { fail("\(label): undo group left open") }
                for tok in typed where !ed.contains(tok) { fail("\(label): U violated - typed token \(tok) is gone from the editor (state \(doc.syncState))") }
                if let disk {
                    for tok in ext where !disk.contains(tok) { fail("\(label): E violated - external token \(tok) vanished from the file (state \(doc.syncState), edited \(doc.isDocumentEdited))") }
                    if doc.syncState == .inSync {
                        for tok in ext where disk.contains(tok) && !ed.contains(tok) { fail("\(label): M violated - external token \(tok) is on disk but not in the editor although the document is in sync") }
                        if !doc.isDocumentEdited && ed != disk { fail("\(label): clean document but editor != file") }
                    }
                    if doc.syncState == .conflict && !host.bannerVisible { fail("\(label): conflict without a banner") }
                }
            }

            let nSteps = rng.range(6...14)
            for step in 0..<nSteps where violation == nil {
                steps += 1
                let r = rng.int(100)
                let exists = FileManager.default.fileExists(atPath: file.path)
                switch r {
                case 0..<30:       // the user types a token line at a random line start
                    let tok = token("U")
                    let at = rng.pick(lineStarts(host.textView.string))
                    let alerts0 = UITrap.alerts.count
                    t.typeText(tok + "\n", into: doc, at: NSRange(location: at, length: 0))
                    log.append("type \(tok)@\(at)")
                    await t.sleep(25)
                    if UITrap.alerts.count > alerts0 {
                        log.append("ALERT \(UITrap.alerts.last!.message) / \(UITrap.alerts.last!.buttons)")
                        _ = await t.waitFor(600) { !host.textView.string.contains(tok) }          // (the answered sheet undoes the refused edit asynchronously)
                    }
                    // NSDocument's own pre-edit check: typing into a CLEAN document whose file is gone (in the 1.6 s before luftig has noticed and marks the
                    // document edited) raises "The file cannot be found - Duplicate / Cancel" and REFUSES the edit as a whole (nothing typed, nothing lost).
                    if host.textView.string.contains(tok) { typed.append(tok) } else { log.append("(edit refused by AppKit, file exists: \(FileManager.default.fileExists(atPath: file.path)))") }
                case 30..<52:      // another tool inserts a line, atomic replace
                    guard exists, let cur = diskText() else { log.append("(atomic skipped)"); continue }
                    let tok = token("E")
                    let at = rng.pick(lineStarts(cur))
                    let new = (cur as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: tok + "\n")
                    if rng.chance(35) {           // a COORDINATED writer (File Provider / iCloud / Finder): NSDocument reacts by itself ~0.5 s later
                        await auditCoordinated(file, text: new); usedCoordinated = true
                        ext.append(tok); lastDisk = new; log.append("ext-coordinated \(tok)@\(at)")
                    } else {
                        await auditAtomicWrite(t, file, new)
                        ext.append(tok); lastDisk = new; log.append("ext-atomic \(tok)@\(at)")
                    }
                case 52..<60:      // another tool appends in place
                    guard exists else { log.append("(append skipped)"); continue }
                    let tok = token("E")
                    await t.sh("printf '%s\\n' \(tok) >> \(t.q(file))")
                    ext.append(tok); lastDisk += tok + "\n"; log.append("ext-append \(tok)")
                case 60..<66:      // the file is deleted
                    guard exists else { log.append("(rm skipped)"); continue }
                    _ = diskText()          // (the model's idea of the file: what the tool deletes is what the next "recreate" starts from)
                    await t.sh("rm -f \(t.q(file))")
                    log.append("rm")
                case 66..<74:      // the file is re-created by another tool
                    guard !exists else { log.append("(recreate skipped)"); continue }
                    let tok = token("E")
                    let (a, b) = (lastDisk, tok + "\n")
                    let at = rng.pick(lineStarts(a))
                    let new = (a as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: b)
                    await auditAtomicWrite(t, file, new)
                    ext.append(tok); lastDisk = new; log.append("recreate \(tok)@\(at)")
                case 74..<86:      // autosave
                    let wasEdited = doc.isDocumentEdited
                    let stateBefore = doc.syncState
                    let err = await t.autosave(doc)
                    log.append("autosave -> \(err == nil ? "ok" : ((err as NSError?)?.code == NSUserCancelledError ? "held back" : "ERROR \(err!)"))")
                    if let nsErr = err as NSError?, nsErr.code != NSUserCancelledError, stateBefore == .inSync, FileManager.default.fileExists(atPath: file.path) {
                        fail("autosave of an in-sync document failed: \(nsErr.localizedDescription)")
                    }
                    if err == nil, wasEdited, stateBefore == .inSync, doc.syncState == .inSync, let d = diskText(), d != host.textView.string {
                        fail("S violated - successful autosave but file != editor (\(d.count) vs \(host.textView.string.count) chars)")
                    }
                case 86..<94:      // wait a little: lets the monitor / presenter deliver
                    let ms = Double(rng.range(0...140))
                    await t.sleep(ms); log.append("wait \(Int(ms))")
                case 94..<97:      // conflict banner: reload from disk (the user discards their text)
                    if doc.syncState == .conflict {
                        host.pressBannerButton("Reload from Disk")
                        await t.sleep(20)
                        let shown = host.textView.string          // the disk version the banner was about (the file itself may be gone by now)
                        typed.removeAll { !shown.contains($0) }
                        discards += 1; log.append("banner: Reload from Disk")
                    } else { log.append("(no conflict)") }
                default:           // conflict banner: keep my version (the user chooses to overwrite the other tool's change)
                    if doc.syncState == .conflict {
                        host.pressBannerButton("Keep My Version")
                        await t.sleep(20)
                        let ed = host.textView.string
                        ext.removeAll { !ed.contains($0) }
                        keeps += 1; log.append("banner: Keep My Version")
                    } else { log.append("(no conflict)") }
                }
                if ProcessInfo.processInfo.environment["AUDITDOC_FUZZ_VERBOSE"] != nil { log.append("[docs=\(NSDocumentController.shared.documents.count) alerts=\(UITrap.alerts.count) state=\(doc.syncState) edited=\(doc.isDocumentEdited) url=\(doc.fileURL?.lastPathComponent ?? "nil")]") }
                if rng.chance(35) { await verify("after step \(step)") }
            }
            if usedCoordinated { await t.sleep(900) }          // (NSDocument's own reaction to a coordinated write arrives ~0.5 s after the write)
            if violation == nil { await verify("final") }
            // a file that is gone must end up flagged (grace period 1.6 s), with the typed text still open
            if violation == nil, !FileManager.default.fileExists(atPath: file.path) {
                let flagged = await t.waitFor(3500) { doc.syncState == .deletedOnDisk }
                if !flagged { fail("file deleted: the document never noticed (state \(doc.syncState))") }
                else {
                    deletions += 1
                    if !host.bannerVisible { fail("deleted: no banner") }
                    if !doc.isDocumentEdited { fail("deleted: document must count as edited (closing has to ask)") }
                    for tok in typed where !host.textView.string.contains(tok) { fail("deleted: typed token \(tok) lost") }
                }
            }
            merges += doc.stats.merges; conflicts += doc.stats.conflicts; reloads += doc.stats.silentReloads
            if let v = violation {
                failures += 1
                if failures <= 3 { t.info("sequence \(seq): \(v)\n      log: \(log.joined(separator: "; "))\n      alerts: \(UITrap.alerts)") }
            }
            t.close(doc)
        }
        t.equal(failures, 0, "state-machine fuzz (seed \(seed)): \(sequences) sequences, \(steps) steps, no law violated (merges \(merges), conflicts \(conflicts), silent reloads \(reloads), deletions seen \(deletions), keep \(keeps), reload-discard \(discards))")
    }
}
#endif
