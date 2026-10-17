#if LUFTIG_SELFTEST
// SelfTestRobustRegress.swift - `robust-regress`: one check group per DEFECT the robustness review found in the application.
//
// Each group failed on the code before its fix and passes now; they run in `--selftest all`.
//
//   textkit-leak       TextKit stack of a closed document stays in memory               (fix: EditorViewController.deinit detaches the layout manager)
//   nul-save           luftig writes a file that it then refuses to open ("binary")     (fix: TextCodec.decode: an incidental NUL in valid UTF-8 is text)
//   utf16-odd          an odd-length UTF-16 file loses its last byte on the next save   (fix: TextCodec.decode refuses a partial code unit)
//   close-missing      Close of a dirty document does nothing, silently, for ~1.6 s after the file vanished   (fix: canClose looks at the file first)
//
// With --known the groups for defects WITHOUT a fix are included as well (they fail on purpose; the review reports them):
//   symlink-save       an open document whose file was replaced by a symlink can no longer be saved ("The file doesn't exist")
//   undo-merge         undoing a merged-in external change (and the typing before it) leaves a document that is CLEAN and "in sync" but shows
//                      other text than the file; the next keystroke autosaves it over the external change without a word
//
// Run:  luftig-SelfTest --selftest robust-regress [--known]

import AppKit
import MarkdownKit

extension Robust {

    @MainActor static func regress(_ t: SelfTest.T) async throws {
        RobustWatchdog.shared.start(); RobustCrash.install()
        let saved = NSDocumentController.shared.autosavingDelay
        NSDocumentController.shared.autosavingDelay = 3      // the shipping value
        defer { NSDocumentController.shared.autosavingDelay = saved }
        let only = SelfTest.argument("only")?.split(separator: ",").map(String.init)
        func want(_ name: String) -> Bool { only == nil || only!.contains(name) }
        if want("nul-save") { try await regressNulSave(t) }
        if want("utf16-odd") { try await regressOddUTF16(t) }
        if want("close-missing") { try await regressCloseMissing(t) }
        if want("textkit-leak") { try await regressTextKitLeak(t) }
        if SelfTest.flag("known"), want("symlink-save") { try await regressSymlinkSave(t) }
        if SelfTest.flag("known"), want("undo-merge") { try await regressUndoMerge(t) }
    }

    // MARK: - textkit-leak

    /// 24 distinct 100 KB documents are open together and closed the way a person closes windows (a pause after the last edit, then canClose + close).
    /// Afterwards - AppKit gets 9 s - nothing of what they created may be alive: not the text view, not the text storage, not the layout manager.
    @MainActor static func regressTextKitLeak(_ t: SelfTest.T) async throws {
        t.info("---- textkit-leak ----")
        let n = 24
        var lives: [LiveSet] = []
        var docs: [MarkdownDocument] = []
        for i in 0..<n {
            let f = t.url("tk-\(i).md")
            try RobustFiles.writeCorpus(f, bytes: 100_000, seed: UInt64(60 + i))
            let d = try await t.open(f, size: NSSize(width: 800, height: 600))
            docs.append(d); lives.append(LiveSet(d))
            if i % 3 == 0 { t.typeText("edit ", into: d, at: NSRange(location: 0, length: 0)) }
        }
        await t.spin(80)
        let probe = CloseProbe()
        for d in docs {
            probe.result = nil
            d.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            _ = await t.waitFor(5000) { probe.result != nil }
            if probe.result != true { d.updateChangeCount(.changeCleared) }
            d.close()
        }
        docs.removeAll()
        func textKitAlive() -> Int { lives.filter { $0.storage != nil || $0.layout != nil || $0.tv != nil || $0.vc != nil || $0.styler != nil }.count }
        let done = await t.waitFor(9000) { textKitAlive() == 0 }
        let alive = textKitAlive()
        t.check(done, "textkit-leak: after closing \(n) documents, none of their text views / text storages / layout managers is alive after 9 s (\(alive) of \(n) still are: \(lives.first(where: { !$0.alive.isEmpty })?.alive ?? []))")
        for i in 0..<n { try? FileManager.default.removeItem(at: t.url("tk-\(i).md")) }
    }

    // MARK: - nul-save

    /// A U+0000 in the text (typed, or pasted from a terminal / PDF) is written as a NUL byte. The file must still be one that luftig opens again:
    /// today the "binary file" test (a NUL in the first 64 KB) refuses what luftig itself just wrote.
    @MainActor static func regressNulSave(_ t: SelfTest.T) async throws {
        t.info("---- nul-save ----")
        let f = t.write("# nul test\n\nbefore\n", to: "nul.md")
        let d = try await t.open(f)
        t.typeText("a\u{0}b", into: d, at: NSRange(location: 5, length: 0))
        await t.sleep(40)
        let err = await t.autosave(d)
        t.close(d)
        await t.spin(30)
        let data = t.readData(f)
        t.check(err == nil && data.contains(0), "nul-save: the autosave wrote the NUL byte (\(data.count) bytes, error \(String(describing: err)))")
        var readable = true, why = ""
        do { _ = try TextCodec.decode(data) } catch { readable = false; why = "\(error)" }
        t.check(readable, "nul-save: TextCodec reads back the file luftig just wrote (\(readable ? "ok" : why))")
        var reopened: MarkdownDocument?
        do { reopened = try await t.open(f) } catch { why = "\((error as NSError).localizedFailureReason ?? error.localizedDescription)" }
        t.check(reopened != nil, "nul-save: the document can be opened again (\(reopened != nil ? "ok" : why))")
        if let r = reopened {
            t.check((r.host?.currentText ?? "") .contains("a\u{0}b"), "nul-save: the reopened text still contains what was typed")
            t.close(r)
        }
        // ... while real binary data is still refused
        var refused = false
        do { _ = try TextCodec.decode(Data((0..<4096).map { UInt8($0 & 0xFF) })) } catch LuftigError.binaryFile { refused = true } catch {}
        t.check(refused, "nul-save: binary data (all byte values, NULs among them) is still refused")
        var refusedPNG = false
        do { _ = try TextCodec.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52] + [UInt8](repeating: 0, count: 64))) } catch LuftigError.binaryFile { refusedPNG = true } catch {}
        t.check(refusedPNG, "nul-save: a PNG-like header with NUL padding is still refused")
    }

    // MARK: - utf16-odd

    /// UTF-16 file (BOM) with a stray trailing byte. Either luftig refuses it, or - if it opens - one keystroke + autosave must change nothing but that
    /// keystroke. Today it opens and the stray byte is dropped on save.
    @MainActor static func regressOddUTF16(_ t: SelfTest.T) async throws {
        t.info("---- utf16-odd ----")
        var bytes: [UInt8] = [0xFF, 0xFE]
        for ch in "Hello\nworld".utf16 { bytes.append(UInt8(ch & 0xFF)); bytes.append(UInt8(ch >> 8)) }
        bytes.append(0x41)
        let f = t.write(data: Data(bytes), to: "odd16.md")
        var d: MarkdownDocument?
        var why = ""
        do { d = try await t.open(f) } catch { why = (error as NSError).localizedFailureReason ?? error.localizedDescription }
        guard let doc = d else { t.check(true, "utf16-odd: an odd-length UTF-16 file is refused (\(why))"); return }
        t.typeText("x", into: doc, at: NSRange(location: 0, length: 0))
        await t.sleep(40)
        let err = await t.autosave(doc)
        t.close(doc)
        await t.spin(30)
        let disk = [UInt8](t.readData(f))
        let expected: [UInt8] = [0xFF, 0xFE, 0x78, 0x00] + Array(bytes[2...])
        t.check(err == nil && disk == expected, "utf16-odd: the file opened, so one keystroke + autosave must keep every other byte (expected \(expected.count) bytes, found \(disk.count): the trailing stray byte \(disk.count < expected.count ? "was dropped" : "is kept"))")
    }

    // MARK: - close-missing

    /// A dirty document whose file has just been deleted (Finder "Move to Trash", `git checkout`, a build tool). The user presses Cmd-W within the
    /// grace period of the missing-file detection (~1.6 s). The answer must be a sheet (or a close), never silence.
    @MainActor static func regressCloseMissing(_ t: SelfTest.T) async throws {
        t.info("---- close-missing ----")
        let f = t.write("# close test\n\nline\n", to: "close-missing.md")
        let d = try await t.open(f)
        t.typeText("typed ", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(60)                                    // the change is registered: autosave in place is pending
        t.check(d.isDocumentEdited, "close-missing: the document is edited before the file disappears")
        await t.sh("rm -f \(t.q(f))")
        await t.sleep(120)                                   // the vnode events have arrived, the 1.6 s grace period has not run out
        UITrap.reset()
        UITrap.alertChooser = { rec in rec.buttons.firstIndex(of: "Discard My Changes") ?? 0 }
        let probe = CloseProbe()
        d.canClose(withDelegate: probe, shouldClose: #selector(CloseProbe.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        let answered = await t.waitFor(4000) { probe.result != nil }
        let sheets = UITrap.alerts
        t.check(answered, "close-missing: canClose answers within 4 s")
        t.check(probe.result == true || !sheets.isEmpty,
                "close-missing: Close of a dirty document whose file just vanished is not refused in silence (closed: \(String(describing: probe.result)), sheets shown: \(sheets.map { $0.message }), state \(d.syncState))")
        d.updateChangeCount(.changeCleared); d.close()
        UITrap.alertChooser = { _ in 0 }
    }

    // MARK: - undo-merge (known defect, no fix)

    @MainActor static func regressUndoMerge(_ t: SelfTest.T) async throws {
        t.info("---- undo-merge (known, unfixed) ----")
        let f = t.write("A\nB\nC\n", to: "undo-merge.md")
        let d = try await t.open(f)
        guard let h = t.editor(d), let um = h.textView.undoManager else { return }
        t.typeText("x", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(60)
        await t.sh("printf 'D\\n' >> \(t.q(f))")
        let merged = await t.waitFor(4000) { d.stats.merges >= 1 }
        t.check(merged && h.currentText.isEqual(to: "xA\nB\nC\nD\n"), "undo-merge: the non-overlapping external append is merged into the typed text (\(h.currentText.debugDescription))")
        var steps = 0
        while um.canUndo && steps < 5 { um.undo(); steps += 1 }
        await t.sleep(80)
        let disk = t.read(f)
        let text = h.currentText as String
        t.note("undo-merge: after \(steps) undo steps the editor shows \(text.debugDescription), the file holds \(disk.debugDescription); document edited: \(d.isDocumentEdited), state \(d.syncState)")
        t.check(text == disk || d.isDocumentEdited || d.syncState != .inSync,
                "undo-merge: a document that shows different text than the file is not 'clean and in sync' (editor \(text.debugDescription) vs file \(disk.debugDescription), edited \(d.isDocumentEdited), state \(d.syncState))")
        d.updateChangeCount(.changeCleared); d.close()
    }

    // MARK: - symlink-save (known defect, no fix)

    @MainActor static func regressSymlinkSave(_ t: SelfTest.T) async throws {
        t.info("---- symlink-save (known, unfixed) ----")
        let f = t.write("# doc\n\nhello\n", to: "sym-doc.md"), other = t.write("# other\n\nworld\n", to: "sym-other.md")
        let d = try await t.open(f)
        await t.sh("rm -f \(t.q(f)) && ln -s \(t.q(other)) \(t.q(f))")
        _ = await t.waitFor(3000) { d.host?.currentText.contains("world") == true }
        t.typeText("X", into: d, at: NSRange(location: 0, length: 0))
        await t.sleep(50)
        UITrap.reset()
        let err = await t.autosave(d)
        t.check(err == nil, "symlink-save: a document whose file was replaced by a symlink to a regular file can still be saved (error: \(err.map { "\(($0 as NSError).code) \(($0 as NSError).localizedDescription.prefix(70))" } ?? "none"))")
        d.updateChangeCount(.changeCleared); d.close()
    }
}
#endif
