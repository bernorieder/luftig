#if LUFTIG_SELFTEST
// SelfTestAuditDocReload.swift - auditdoc-reload and auditdoc-monitor (see SelfTestAuditDoc.swift for the list).

import AppKit

extension SelfTestScenarios {

    // MARK: reload through the real editor

    @MainActor static func auditDocReload(_ t: SelfTest.T) async throws {
        typealias P = AuditDocProps

        // ---- A. two distant changes (line diff path) one of which swaps an astral character for another with the same low surrogate:
        //         the hunk used to end between the halves of a pair; `String` bridging turned the lone high surrogate into U+FFFD
        do {
            var lines = (0..<400).map { "line \($0) " + String(repeating: "lorem ipsum dolor sit amet ", count: 4) + "\n" }
            lines[380] = "line 380 astral \u{1F600} end\n"
            let old = lines.joined()
            var l2 = lines
            l2[10] = "line 10 CHANGED\n"; l2[380] = "line 380 astral \u{1F200} end\n"
            let new = l2.joined()
            let doc = try await t.open(t.write(old, to: "astral-hunk.md"))
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(100)
            let report = host.applyExternalText(new as NSString, mode: .silent)
            let now = host.textView.string
            t.check(report.edits >= 2, "astral hunk: the line-diff path produced \(report.edits) edits (not one big replacement)")
            t.check(!now.contains("\u{FFFD}"), "astral hunk: no U+FFFD in the editor text after the reload")
            t.check(now == new, "astral hunk: the editor text equals the new file exactly")
            t.check(P.wellFormed(Array(now.utf16)), "astral hunk: no lone surrogate in the editor text")
            t.close(doc)
        }

        // ---- B. caret inside a replaced region that becomes emoji: it must not end up inside a surrogate pair
        do {
            let doc = try await t.open(t.write("hello world\nsecond line\n", to: "emoji-caret.md"))
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(100)
            host.textView.setSelectedRange(NSRange(location: 3, length: 0))
            let new = "\u{1F600}\u{1F600}\u{1F600} world\nsecond line\n"
            host.applyExternalText(new as NSString, mode: .silent)
            let sel = host.textView.selectedRange()
            let ns = host.textView.string as NSString
            t.check(!TextDiff.splitsPair(ns, sel.location), "caret in a replaced region: {\(sel.location),\(sel.length)} is not inside a surrogate pair")
            t.typeText("X", into: doc, at: sel)
            t.check(P.wellFormed(Array(host.textView.string.utf16)), "typing at that caret leaves no lone surrogate (units: \((host.textView.string as NSString).substring(to: 8).utf16.map { String(format: "%04X", $0) }))")
            // a selection that spans into the replacement
            host.textView.setSelectedRange(NSRange(location: 1, length: 2))
            host.applyExternalText("hello world\nsecond line\n" as NSString, mode: .silent)
            host.applyExternalText("\u{1F600}\u{1F601}\u{1F602}\u{1F603} world\nsecond line\n" as NSString, mode: .silent)
            let s2 = host.textView.selectedRange()
            let ns2 = host.textView.string as NSString
            t.check(!TextDiff.splitsPair(ns2, s2.location) && !TextDiff.splitsPair(ns2, NSMaxRange(s2)), "selection {\(s2.location),\(s2.length)} has both ends outside surrogate pairs")
            t.close(doc)
        }

        // ---- C. Undo / Redo exactness across merges (random, constructed separated edits: expected result known)
        do {
            var rng = AuditRNG(9051)
            var failures = 0
            var cases = 0
            for i in 0..<250 {
                let c = P.constructed(&rng, conflict: false, crlf: false)
                guard let expected = c.expected, c.mine != c.base, expected != c.mine, !c.base.isEmpty else { continue }      // (expected == mine: the merge changes nothing, there is no undo step)
                let base = String(decoding: c.base, as: UTF16.self), mine = String(decoding: c.mine, as: UTF16.self), merged = String(decoding: expected, as: UTF16.self)
                let doc = try await t.open(t.write(base, to: "undo-\(i).md"))
                guard let host = doc.host as? EditorViewController else { continue }
                let tv = host.textView
                cases += 1
                // "typing": the user's edit as one undoable edit
                host.applyExternalText(mine as NSString, mode: .undoable)
                host.applyExternalText(merged as NSString, mode: .undoable)             // the merge
                var bad: String? = tv.string == merged ? nil : "merge result differs"
                doc.undoManager?.undo()
                if bad == nil, tv.string != mine { bad = "undo #1 did not give the pre-merge text" }
                doc.undoManager?.redo()
                if bad == nil, tv.string != merged { bad = "redo did not give the merged text back" }
                doc.undoManager?.undo(); doc.undoManager?.undo()
                if bad == nil, tv.string != base { bad = "undo #2 did not give the original text" }
                doc.undoManager?.redo(); doc.undoManager?.redo()
                if bad == nil, tv.string != merged { bad = "redo x2 did not give the merged text" }
                if let bad { failures += 1; if failures <= 3 { t.info("case \(i): \(bad)\n base=\(P.show(c.base))\n mine=\(P.show(c.mine))\n merged=\(P.show(expected))") } }
                t.close(doc)
            }
            t.equal(failures, 0, "Undo/Redo across a merge returns exactly the pre-merge / merged text (\(cases) random multi-hunk cases)")
        }
        // ... and with the real flow: typing, a real external write, merge, Undo
        do {
            var rng = AuditRNG(77)
            var failures = 0, cases = 0, merges = 0
            for i in 0..<40 {
                let c = P.constructed(&rng, conflict: false, crlf: false)
                guard let expected = c.expected, c.mine != c.base, c.theirs != c.base, c.mine != c.theirs, expected != c.mine, !c.base.isEmpty else { continue }
                let base = String(decoding: c.base, as: UTF16.self), mine = String(decoding: c.mine, as: UTF16.self)
                let theirs = String(decoding: c.theirs, as: UTF16.self), merged = String(decoding: expected, as: UTF16.self)
                let file = t.write(base, to: "flow-\(i).md")
                let doc = try await t.open(file)
                guard let host = doc.host as? EditorViewController else { continue }
                cases += 1
                await t.sleep(30)
                doc.monitor?.stop()
                // type the difference base -> mine, hunk by hunk (descending, so ranges stay valid)
                let edits = TextDiff.edits(old: base as NSString, new: mine as NSString)
                for e in edits.reversed() { t.typeText((mine as NSString).substring(with: e.newRange), into: doc, at: e.oldRange) }
                await t.sleep(10)
                guard host.textView.string == mine else { failures += 1; t.info("case \(i): typing did not produce `mine`"); t.close(doc); continue }
                await auditAtomicWrite(t, file, theirs)
                doc.checkForExternalChange("audit")
                _ = await t.waitFor(3000) { doc.stats.merges + doc.stats.conflicts > 0 }
                _ = await auditSettle(t, doc)
                var bad: String? = nil
                if doc.stats.merges == 1 { merges += 1; if host.textView.string != merged { bad = "merged text differs from the expected one" } }
                else if doc.stats.conflicts > 0 { bad = "separated edits ended in a conflict" }
                else { bad = "neither merge nor conflict" }
                if bad == nil {
                    doc.undoManager?.undo()
                    if host.textView.string != mine { bad = "Undo after the merge did not give back my text" }
                    doc.undoManager?.redo()
                    if bad == nil, host.textView.string != merged { bad = "Redo after the merge did not give the merged text" }
                    if bad == nil, !doc.isDocumentEdited { bad = "merged document must still be dirty" }
                }
                if let bad { failures += 1; if failures <= 3 { t.info("flow case \(i): \(bad)\n base=\(P.show(c.base))\n mine=\(P.show(c.mine))\n theirs=\(P.show(c.theirs))") } }
                t.close(doc)
            }
            t.equal(failures, 0, "real typing + real external write + merge + Undo/Redo: \(cases) cases, \(merges) merged, no deviation")
        }

        // ---- D. merge base validation: an edit that reached the text WITHOUT the delegate hook (`editorWillChangeText`) makes the lazily
        //         captured base contain text that is not on disk; the old code then read the other tool's file as "deleted BYPASS" and merged
        //         the user's text away. Now: no merge, a conflict banner, nothing lost.
        do {
            let file = t.write(auditParas, to: "base-bypass.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(150)
            doc.monitor?.stop()
            let tv = host.textView
            doc.undoManager?.disableUndoRegistration()
            tv.textStorage?.replaceCharacters(in: NSRange(location: (tv.string as NSString).length, length: 0), with: "BYPASS line typed without the delegate\n")
            doc.undoManager?.enableUndoRegistration()
            doc.updateChangeCount(.changeDone)
            t.check(doc.baseSnapshot == nil, "setup: the bypassing edit captured no base")
            t.typeText(" MINE", into: doc, at: NSRange(location: (tv.string as NSString).range(of: "paragraph 8 of the document").upperBound, length: 0))
            await t.sleep(30)
            t.check(doc.baseSnapshot?.contains("BYPASS") == true, "setup: the base was captured late and contains the bypassing edit (text that is NOT on disk)")
            let mine = tv.string
            await auditAtomicWrite(t, file, auditParas.replacingOccurrences(of: "paragraph 2 of the document", with: "paragraph 2 EDITED BY TOOL"))
            doc.checkForExternalChange("audit")
            _ = await t.waitFor(3000) { doc.stats.merges + doc.stats.conflicts > 0 }
            _ = await auditSettle(t, doc)
            t.check(tv.string.contains("BYPASS line typed without the delegate"), "the user's text survives (merge refused instead of dropping it)")
            t.equal(tv.string, mine, "editor text untouched")
            t.equal(doc.syncState, .conflict, "state conflict: the banner asks the user (\(host.bannerText))")
            t.check(host.bannerVisible && host.bannerButtonTitles.contains("Reload from Disk"), "banner offers the choice")
            t.close(doc)
        }

        // ---- E. File > Reload from Disk on a file that cannot be shown: the error must be presented, not swallowed
        do {
            let file = t.write(auditParas, to: "reload-error.md")
            let doc = try await t.open(file)
            await t.sleep(150)
            doc.monitor?.stop()
            t.typeText("EDIT ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00, 0xFF, 0x00]).write(to: file)      // binary now
            UITrap.reset(); UITrap.alertChooser = { a in a.buttons.firstIndex(of: "Reload") ?? 0 }
            doc.luftigReloadFromDisk(nil)
            await t.sleep(400)
            t.check(UITrap.alerts.count >= 2, "Reload from Disk of an unreadable file: confirmation + an ERROR alert (\(UITrap.alerts.map { $0.message }))")
            t.check((t.editor(doc)?.textView.string ?? "").hasPrefix("EDIT "), "the typed text is still there")
            t.close(doc)
        }

        // ---- E2. a keystroke has been applied but its undo group is still open (NSDocument counts the change when the group closes, at the end
        //          of the event cycle): the document does not look edited yet. An external change arriving right then must not diff the typed
        //          character away (it used to: silent reload + removeAllActions inside the open group)
        do {
            let file = t.write(auditParas, to: "open-group.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            doc.monitor?.stop()
            let um = doc.undoManager!
            um.beginUndoGrouping()
            host.textView.setSelectedRange(NSRange(location: 0, length: 0))
            host.textView.insertText("TYPED ", replacementRange: NSRange(location: 0, length: 0))
            host.textView.breakUndoCoalescing()
            t.check(!doc.isDocumentEdited && um.groupingLevel == 1, "setup: keystroke applied, group still open, document not yet edited")
            await auditAtomicWrite(t, file, auditParas + "external line\n")
            doc.checkForExternalChange("audit")
            await t.sleep(250)
            t.check(host.textView.string.hasPrefix("TYPED "), "open undo group + external change: the typed text is NOT discarded (text starts '\(host.textView.string.prefix(12))')")
            t.equal(doc.stats.silentReloads, 0, "no silent reload while the group is open")
            if um.groupingLevel > 0 { um.endUndoGrouping() }          // the event cycle ends: the document becomes edited
            _ = await t.waitFor(3000) { doc.stats.merges + doc.stats.conflicts > 0 }
            _ = await auditSettle(t, doc)
            t.check(host.textView.string.hasPrefix("TYPED ") && host.textView.string.hasSuffix("external line\n"), "after the group closed the external change is MERGED with the typed text (merges \(doc.stats.merges), conflicts \(doc.stats.conflicts))")
            t.check(doc.isDocumentEdited, "document is dirty (my text is not on disk yet)")
            t.close(doc)
        }

        // ---- F. 10 MB document, viewport and selection in the middle, external change above AND below
        do {
            var lines: [String] = []
            lines.reserveCapacity(150_000)
            for i in 0..<150_000 { lines.append("Line \(i) - the quick brown fox jumps over the lazy dog \(i * 7919 % 10007) and more words to fill it up") }
            let file = t.write(lines.joined(separator: "\n") + "\n", to: "mid10.md")
            let doc = try await t.open(file, size: NSSize(width: 800, height: 600))
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            let tv = host.textView
            let target = (tv.string as NSString).range(of: "Line 75000 - ")
            tv.setSelectedRange(NSRange(location: target.location + 5, length: 4))
            tv.scrollRangeToVisible(NSRange(location: target.location, length: 10))
            let selBefore = (tv.string as NSString).substring(with: tv.selectedRange())
            let topLine = { () -> String in
                guard let a = ViewportAnchor.capture(in: tv) else { return "<none>" }
                let s = tv.string as NSString
                return s.substring(with: s.lineRange(for: NSRange(location: a.characterIndex, length: 0))).trimmingCharacters(in: .newlines)
            }
            var topBefore = topLine()
            // let the layout settle (drawing lays out the visible lines, TextKit then corrects its estimate of everything above) BEFORE
            // looking at the top line: the reload must preserve what the user sees, not what TextKit estimated a moment earlier
            for _ in 0..<3 {
                if let v = host.view as NSView? { v.layoutSubtreeIfNeeded(); if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep) } }
                await t.sleep(150)
            }
            let topSettled = topLine()
            t.note("10 MB: top line right after the scroll '\(topBefore.prefix(12))', after settling '\(topSettled.prefix(12))'")
            topBefore = topSettled
            var l2 = lines
            l2.insert(contentsOf: (0..<40).map { "INSERTED \($0)" }, at: 100)
            l2[120_000] = "CHANGED BELOW"
            let newText = l2.joined(separator: "\n") + "\n"
            let r0 = doc.stats.silentReloads
            let w0 = SelfTest.nowMs()
            try newText.write(to: t.url("mid10.tmp"), atomically: false, encoding: .utf8)
            await t.sh("mv \(t.q(t.url("mid10.tmp"))) \(t.q(file))")
            let ok = await t.waitFor(6000) { doc.stats.silentReloads > r0 }
            t.check(ok, "10 MB: external change above and below the viewport was reloaded")
            t.check(host.currentText.isEqual(to: newText), "10 MB: the editor text equals the new file")
            t.equal((tv.string as NSString).substring(with: tv.selectedRange()), selBefore, "10 MB: the selection in the middle still covers '\(selBefore)'")
            let topNow = topLine()
            await t.sleep(400)
            t.note("10 MB: top line right after the reload: '\(topNow.prefix(12))', 400 ms later: '\(topLine().prefix(12))', before: '\(topBefore.prefix(12))'")
            t.equal(topLine(), topBefore, "10 MB: the same line is still at the top of the window")
            if let a = doc.stats.lastApply {
                t.note(String(format: "10 MB reload: %d edits, diff %.1f ms, apply total %.1f ms (main thread), %.0f ms from write to shown", a.edits, a.diffSeconds * 1000, a.seconds * 1000, SelfTest.nowMs() - w0))
                t.check(a.edits == 2 && a.changedUnits < 2000, "10 MB: two small edits, not a whole-text replacement (\(a.edits) edits, \(a.changedUnits) units)")
                t.check(a.seconds < 1.5, "10 MB: the apply stays far below a second on the main thread (\(Int(a.seconds * 1000)) ms)")
            }
            t.close(doc)
        }
    }

    // MARK: monitor

    @MainActor static func auditDocMonitor(_ t: SelfTest.T) async throws {
        // ---- A. descriptors: 500 documents opened and closed (windows on every 4th, an edit on every 3rd)
        do {
            for i in 0..<500 { t.write("document \(i)\n", to: "fd/f\(i).md") }
            let before = openFDs()
            var leaked = 0
            for i in 0..<500 {
                let d = try await t.open(t.url("fd/f\(i).md"), window: i % 4 == 0)
                if i % 3 == 0 && i % 4 == 0 { t.typeText("x", into: d, at: NSRange(location: 0, length: 0)) }
                if i % 50 == 0 { t.check(d.monitor != nil, "document \(i): monitor armed") }
                t.close(d)
                if d.monitor != nil { leaked += 1 }
            }
            await t.sleep(300)
            let after = openFDs()
            t.equal(leaked, 0, "500 documents closed: none still holds a monitor")
            t.check(after <= before + 2, "file descriptors: \(before) before, \(after) after 500 open/close cycles (no leak)")
            t.check(NSDocumentController.shared.documents.isEmpty, "no document left open")
        }

        // ---- B. the FOLDER of the open file is deleted and recreated (git checkout of a branch without it, rm -rf + regenerate)
        do {
            let file = t.url("gone/doc.md")
            t.write(auditParas, to: "gone/doc.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            await t.sh("rm -rf \(t.q(t.url("gone")))")
            let gone = await t.waitFor(5000) { doc.syncState == .deletedOnDisk }
            t.check(gone, "folder deleted: the document knows (banner: \(host.bannerText))")
            t.check(doc.monitor?.isRecovering == true, "the monitor now waits for the folder (recovery poll), kqueue has nothing left to watch")
            await t.sh("mkdir \(t.q(t.url("gone"))) && printf 'recreated content\\n' > \(t.q(file))")
            let back = await t.waitFor(4000) { host.currentText.isEqual(to: "recreated content\n") }
            t.check(back, "folder recreated with the file: the document reloads it by itself (state \(doc.syncState), trigger \(doc.stats.lastReloadTrigger))")
            t.check(doc.syncState == .inSync && !host.bannerVisible, "banner gone, in sync")
            await t.sleep(400)
            t.check(doc.monitor?.isRecovering == false, "recovery poll stopped once the folder is back")
            let r0 = doc.stats.silentReloads
            let s = SelfTest.nowMs()
            await t.sh("printf 'appended later\\n' >> \(t.q(file))")
            let ok2 = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.check(ok2 && doc.stats.lastReloadTrigger == "fswatch", "a LATER write is seen by the kqueue monitor again (\(Int(SelfTest.nowMs() - s)) ms, trigger \(doc.stats.lastReloadTrigger))")
            t.close(doc)
        }
        // ... the same while the document has unsaved edits: typed text survives, the recreated file is merged / conflicts
        do {
            let file = t.url("gone2/doc.md")
            t.write(auditParas, to: "gone2/doc.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            t.typeText(" MINE", into: doc, at: NSRange(location: (host.textView.string as NSString).range(of: "paragraph 8 of the document").upperBound, length: 0))
            await t.sleep(30)
            await t.sh("rm -rf \(t.q(t.url("gone2")))")
            _ = await t.waitFor(5000) { doc.syncState == .deletedOnDisk }
            let err = await t.autosave(doc)
            t.check((err as NSError?)?.code == NSUserCancelledError && !FileManager.default.fileExists(atPath: t.url("gone2").path), "deleted folder + dirty document: the autosave is held back and does not resurrect the folder")
            t.write(auditParas.replacingOccurrences(of: "paragraph 2 of the document", with: "paragraph 2 NEW"), to: "gone2/doc.md")     // creates the folder again
            let merged = await t.waitFor(4000) { doc.stats.merges + doc.stats.conflicts > 0 }
            t.check(merged, "folder + file recreated by a tool while I have unsaved edits: handled (merges \(doc.stats.merges), conflicts \(doc.stats.conflicts))")
            t.check(host.textView.string.contains("paragraph 8 of the document MINE"), "my typed text is still in the editor")
            t.close(doc)
        }

        // ---- C. atomic-replace storm: 200 replacements by a child process, ~5 ms apart
        do {
            let file = t.write("start\n", to: "storm.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            let fd0 = openFDs()
            await t.sh("i=1; while [ $i -le 200 ]; do printf 'generation %d\\n' $i > \(t.q(file)).tmp && mv \(t.q(file)).tmp \(t.q(file)); sleep 0.005; i=$((i+1)); done")
            _ = await t.waitFor(4000) { host.currentText.isEqual(to: "generation 200\n") }
            _ = await auditSettle(t, doc)
            t.check(host.currentText.isEqual(to: "generation 200\n"), "after 200 atomic replacements the editor shows the LAST generation: '\(host.currentText.substring(to: min(20, host.currentText.length)).trimmingCharacters(in: .newlines))'")
            t.check(host.currentText.isEqual(to: t.read(file)), "editor == file")
            t.check(!doc.isDocumentEdited && doc.syncState == .inSync, "clean, in sync")
            t.check(doc.stats.silentReloads <= 60, "the burst was coalesced (\(doc.stats.silentReloads) reloads for 200 replacements, \(doc.monitor?.eventCount ?? 0) kqueue events, \(doc.monitor?.rebindCount ?? 0) re-binds)")
            await t.sleep(300)
            t.check(openFDs() <= fd0 + 1, "no descriptor leak in the storm (\(fd0) -> \(openFDs()))")
            // and it is still alive afterwards
            let r0 = doc.stats.silentReloads
            await auditAtomicWrite(t, file, "after the storm\n")
            let alive = await t.waitFor(2000) { doc.stats.silentReloads > r0 }
            t.check(alive, "the monitor still sees the next atomic replace")
            t.close(doc)
        }
        // ---- D. rename loop: file moved away and back 100 times (same content)
        do {
            let file = t.write(auditParas, to: "loop.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            t.typeText("DIRTY ", into: doc, at: NSRange(location: 0, length: 0))       // dirty during the loop: nothing may be lost or flagged deleted for good
            await t.sleep(30)
            await t.sh("i=0; while [ $i -lt 100 ]; do mv \(t.q(file)) \(t.q(file)).x; mv \(t.q(file)).x \(t.q(file)); i=$((i+1)); done")
            await t.sleep(2500)
            _ = await auditSettle(t, doc)
            t.check(host.textView.string.hasPrefix("DIRTY "), "rename loop: typed text intact")
            t.check(doc.syncState == .inSync && !host.bannerVisible, "rename loop: back in sync, no stale banner (state \(doc.syncState), banner '\(host.bannerText)')")
            t.equal(t.read(file), auditParas, "rename loop: the file itself is untouched")
            let err = await t.autosave(doc)
            t.check(err == nil && t.read(file) == "DIRTY " + auditParas, "rename loop: autosave afterwards writes the typed text (\(String(describing: err)))")
            t.close(doc)
        }
        // ---- E. ancestor folder renamed: the document follows, the monitor follows
        do {
            let file = t.url("anc/sub/doc.md")
            t.write(auditParas, to: "anc/sub/doc.md")
            let doc = try await t.open(file)
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            await t.sh("mv \(t.q(t.url("anc"))) \(t.q(t.url("anc-renamed")))")
            let followed = await t.waitFor(4000) { doc.fileURL?.path.contains("anc-renamed") == true }
            t.check(followed, "ancestor folder renamed: the document follows (\(doc.fileURL?.lastPathComponent ?? "nil"))")
            await t.sleep(1800)
            t.check(doc.syncState == .inSync && !host.bannerVisible, "no 'deleted' banner")
            let r0 = doc.stats.silentReloads
            await t.sh("printf 'added\\n' >> \(t.q(t.url("anc-renamed/sub/doc.md")))")
            let picked = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.check(picked, "a write at the new location is picked up (trigger \(doc.stats.lastReloadTrigger))")
            t.close(doc)
        }
        // ---- F. a symlink that is swapped: opened as <link>/doc.md, the link retargeted to another folder (kqueue sees nothing: no object we
        //         hold changed) - activation / the file presenter must still notice
        do {
            try? FileManager.default.createDirectory(at: t.url("dirA"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: t.url("dirB"), withIntermediateDirectories: true)
            t.write("from A\n", to: "dirA/doc.md"); t.write("from B\n", to: "dirB/doc.md")
            try? FileManager.default.removeItem(at: t.url("swap"))
            try FileManager.default.createSymbolicLink(at: t.url("swap"), withDestinationURL: t.url("dirA"))
            let doc = try await t.open(t.url("swap/doc.md"))
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            t.note("opened via the symlinked folder: fileURL = \(doc.fileURL?.path.replacingOccurrences(of: t.work.path, with: "<w>") ?? "nil")")
            await t.sleep(300)
            await t.sh("ln -sfh \(t.q(t.url("dirB"))) \(t.q(t.url("swap")))")           // (-h: replace the LINK, do not descend into the folder it points to)
            await t.sleep(300)
            let viaKqueue = host.currentText.isEqual(to: "from B\n")
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            let viaActivation = await t.waitFor(1500) { host.currentText.isEqual(to: "from B\n") }
            t.note("symlink retargeted: seen by the monitor within 300 ms: \(viaKqueue); after app activation: \(viaActivation)")
            t.check(viaActivation, "the retargeted folder link is noticed at the latest when the app is activated")
            t.close(doc)
        }
        // ---- G. callbacks into a document that was closed while a writer keeps going
        do {
            let file = t.write("start\n", to: "dead.md")
            let fd0 = openFDs()
            for round in 0..<20 {
                let doc = try await t.open(file)
                await t.sleep(5)
                let writer = Process()
                writer.executableURL = URL(fileURLWithPath: "/bin/sh")
                writer.arguments = ["-c", "i=0; while [ $i -lt 40 ]; do printf 'x %d %d\\n' \(round) $i >> \(t.q(file)); sleep 0.01; i=$((i+1)); done"]
                try writer.run()
                await t.sleep(80)
                t.close(doc)                // the writer is still running: events keep coming for a dead document
                while writer.isRunning { await t.sleep(20) }
            }
            await t.sleep(600)
            t.check(openFDs() <= fd0 + 1, "20 documents closed while a writer kept writing: no descriptor leak, no crash (\(fd0) -> \(openFDs()))")
        }
    }
}
#endif
