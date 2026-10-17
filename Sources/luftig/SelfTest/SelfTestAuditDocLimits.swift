#if LUFTIG_SELFTEST
// SelfTestAuditDocLimits.swift - auditdoc-limits: the size limits, measured. ONE 60 MB document (never more than one at a time) and the
// 200 MB refusal with ONE 210 MB ASCII file (refused by size before a byte is read, so no memory is spent on it).

import AppKit

extension SelfTestScenarios {

    /// Resident memory footprint of this process in MB (phys_footprint).
    static func auditFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    @MainActor static func auditDocLimits(_ t: SelfTest.T) async throws {
        // ---- A. 210 MB ASCII file: refused by size, nothing allocated, file untouched
        do {
            let f = t.url("huge-210mb.md")
            await t.sh("yes 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' | head -c 210000000 > \(t.q(f))")
            var st = stat(); stat(f.path, &st)
            t.equal(Int(st.st_size), 210_000_000, "setup: a 210 MB ASCII file")
            let m0 = auditFootprintMB()
            let s0 = SelfTest.nowMs()
            var refusal = "none"
            do { _ = try DiskReader.readFile(path: f.path) } catch LuftigError.tooLarge(let b, let l) { refusal = "tooLarge \(b) > \(l)" } catch { refusal = "other: \(error)" }
            let ms = SelfTest.nowMs() - s0
            t.check(refusal.hasPrefix("tooLarge"), "DiskReader.readFile: \(refusal) in \(String(format: "%.2f", ms)) ms")
            t.check(ms < 200, "refusal is immediate (\(String(format: "%.1f", ms)) ms): the size is checked before anything is read")
            UITrap.reset()
            var opened = false
            do { let d = try await t.open(f); opened = true; t.close(d) } catch { t.note("open refused: \((error as NSError).localizedFailureReason ?? error.localizedDescription)") }
            t.check(!opened, "opening the 210 MB file through NSDocumentController fails (no empty document appears)")
            t.check(NSDocumentController.shared.documents.isEmpty, "no document was created")
            let m1 = auditFootprintMB()
            t.check(m1 - m0 < 60, "memory: \(Int(m0)) -> \(Int(m1)) MB (the refused file cost no memory)")
            var st2 = stat(); stat(f.path, &st2)
            t.check(st2.st_size == st.st_size && st2.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, "the refused file is untouched")
            try? FileManager.default.removeItem(at: f)
        }
        // ---- B. one 60 MB document: open, type, autosave, external change; memory and time
        do {
            var chunk = ""
            for i in 0..<9000 { chunk += "Zeile \(i): Größenänderung – 日本語 😀 the quick brown fox jumps over the lazy dog\n" }
            let chunkData = Data(chunk.utf8)
            var data = Data()
            data.reserveCapacity(60_500_000)
            while data.count < 60_000_000 { data.append(chunkData) }
            let f = t.write(data: data, to: "big-60mb.md")
            let size = data.count
            data = Data()
            let m0 = auditFootprintMB()
            let s0 = SelfTest.nowMs()
            let doc = try await t.open(f, size: NSSize(width: 800, height: 600))
            let openMs = SelfTest.nowMs() - s0
            guard let host = doc.host as? EditorViewController else { t.check(false, "no host"); return }
            await t.sleep(300)
            let m1 = auditFootprintMB()
            t.note(String(format: "60 MB open: %.0f ms on the main thread, footprint %.0f -> %.0f MB, %d UTF-16 units", openMs, m0, m1, host.currentText.length))
            t.check(m1 < 1500, "60 MB document: memory footprint \(Int(m1)) MB stays far below the 6 GB watchdog")
            t.check(openMs < 4000, "60 MB document opens in \(Int(openMs)) ms (no hang)")
            t.check(doc.textFormat.encoding == .utf8 && doc.textFormat.lineEnding == .lf, "decoded as \(doc.textFormat)")
            let e0 = SelfTest.nowMs()
            t.typeText("X", into: doc, at: NSRange(location: 0, length: 0))
            let typeMs = SelfTest.nowMs() - e0
            await t.sleep(30)          // (NSDocument counts the change when the undo group has closed)
            t.note(String(format: "60 MB: first keystroke at the top %.0f ms", typeMs))
            let a0 = SelfTest.nowMs()
            let err = await t.autosave(doc)
            let saveMs = SelfTest.nowMs() - a0
            t.note(String(format: "60 MB autosave (encode + safe save): %.0f ms", saveMs))
            var st = stat(); stat(f.path, &st)
            t.check(err == nil && Int(st.st_size) == size + 1, "60 MB autosave wrote exactly the original bytes plus the typed character (\(st.st_size) vs \(size + 1))")
            // external append: reload through the minimal-diff path
            let r0 = doc.stats.silentReloads
            let x0 = SelfTest.nowMs()
            await t.sh("printf 'appended by another tool\\n' >> \(t.q(f))")
            let ok = await t.waitFor(8000) { doc.stats.silentReloads > r0 }
            t.note(String(format: "60 MB external append: reloaded after %.0f ms (apply %.0f ms on the main thread)", SelfTest.nowMs() - x0, (doc.stats.lastApply?.seconds ?? 0) * 1000))
            t.check(ok && host.currentText.hasSuffix("appended by another tool\n"), "60 MB: the external append is shown")
            t.check(auditFootprintMB() < 2000, "60 MB: footprint after the reload \(Int(auditFootprintMB())) MB")
            t.close(doc)
            try? FileManager.default.removeItem(at: f)
        }
    }
}
#endif
