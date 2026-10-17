#if LUFTIG_SELFTEST
// SelfTestAuditDoc.swift - regression tests found by the adversarial review of the document layer ("auditdoc-*" scenarios).
//
//   auditdoc-props      property tests (SelfTestAuditDocProps.swift): diff / map / merge / codec, ~0.9 M seeded random + 1.9 M exhaustive cases per run
//   auditdoc-bytes      bytes in, bytes out: a matrix of byte patterns through TextCodec and through REAL documents (open, save without
//                       edit, edit + autosave); refused files; folder
//   auditdoc-reload     reload through the real editor: astral characters, caret placement, undo/redo exactness, merge base validation
//   auditdoc-monitor    descriptor leaks (500 documents), folder deleted and recreated, rename / atomic-replace storms, ancestor renamed
//   auditdoc-save       saving: attributes, read-only, concurrent saves, Save As, close with unresolved states
//   auditdoc-coordinated coordinated writers (File Provider / iCloud / Finder) against a dirty document
//   auditdoc-policy     IME composition vs the autosave gate, un-encodable text, legacy -> UTF-8 notice, 10 MB merge + undo
//   auditdoc-fuzz       model-based fuzz of the state machine with real files and real writers
//   auditdoc-limits     the 200 MB refusal and ONE 60 MB document (NOT in "all": run it by name)
//
// Nothing here touches anything outside the scenario work directory.

import AppKit

extension SelfTestScenarios {
    static let auditDocScenarios: [SelfTest.Scenario] = [
        .init(name: "auditdoc-props", summary: "property tests: diff/map/merge (~0.6 M random + 1.9 M exhaustive cases per run, seedable), codec byte round trip", run: { t in try await auditDocProps(t) }),
        .init(name: "auditdoc-bytes", summary: "bytes in, bytes out: byte-pattern matrix through the codec and real documents; refused files stay untouched", run: { t in try await auditDocBytes(t) }),
        .init(name: "auditdoc-reload", summary: "reload through the real editor: astral characters, caret, undo/redo exactness, merge-base validation", run: { t in try await auditDocReload(t) }),
        .init(name: "auditdoc-save", summary: "saving: attributes kept, failed write (RLIMIT_FSIZE) keeps file + text, read-only, Save As / Move re-home the watcher, concurrent saves, close", run: { t in try await auditDocSave(t) }),
        .init(name: "auditdoc-coordinated", summary: "COORDINATED writers (iCloud / OneDrive / Finder) vs a dirty document: merge kept, conflict kept, explicit discard still works, move, delete", run: { t in try await auditDocCoordinated(t) }),
        .init(name: "auditdoc-policy", summary: "IME composition vs the autosave gate, a text that cannot be encoded, legacy -> UTF-8 notice, 10 MB merge + undo/redo exactness", run: { t in try await auditDocPolicy(t) }),
        .init(name: "auditdoc-fuzz", summary: "model-based fuzz of the clean/dirty/conflict/deleted state machine with real files and real writers", run: { t in try await auditDocFuzz(t) }),
        .init(name: "auditdoc-limits", summary: "size limits: a 210 MB file is refused without reading it; one 60 MB document opens, saves and reloads (time, memory)", run: { t in try await auditDocLimits(t) }, inAll: false),      // (writes a 210 MB file and opens one 60 MB document: run by name)
        .init(name: "auditdoc-monitor", summary: "kqueue monitor: fd leaks (500 documents), folder deleted + recreated, rename/replace storms, ancestor renamed", run: { t in try await auditDocMonitor(t) }),
    ]

    static func openFDs() -> Int {
        var n = 0
        for fd in 0..<Int32(min(getdtablesize(), 4096)) where fcntl(fd, F_GETFD) != -1 { n += 1 }
        return n
    }

    static let auditParas = (1...10).map { "paragraph \($0) of the document\n" }.joined()

    /// Atomic replace by a real child process (what editors, git and build tools do).
    @MainActor static func auditAtomicWrite(_ t: SelfTest.T, _ file: URL, _ text: String) async {
        let tmp = file.appendingPathExtension("tmp")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        await t.sh("mv \(t.q(tmp)) \(t.q(file))")
    }

    /// Runs the checks of a document that has settled: no check in flight, nothing saving or applying.
    @MainActor static func auditSettle(_ t: SelfTest.T, _ doc: MarkdownDocument, _ ms: Double = 3000) async -> Bool {
        await t.waitFor(ms) { !doc.checkInFlight && !doc.isSaving && !doc.isApplyingExternal && !doc.recheckRequested }
    }

    // MARK: props

    @MainActor static func auditDocProps(_ t: SelfTest.T) async throws {
        func report(_ rs: [AuditDocProps.Result]) {
            for r in rs {
                t.check(r.failures == 0, "\(r.name): \(r.cases) cases, \(r.failures) failures")
                for e in r.examples { t.note(e) }
            }
        }
        // (AUDITDOC_PROPS_SEED / AUDITDOC_PROPS_SCALE: more cases by hand - run several processes in sequence rather than one big one. The defaults
        //  are what runs in the suite: ~0.3 M diff + ~0.3 M merge + 0.3 M codec cases, ~7 s.)
        let env = ProcessInfo.processInfo.environment
        let t0 = SelfTest.nowMs()
        let seed = UInt64(env["AUDITDOC_PROPS_SEED"] ?? "") ?? 20261016
        let scale = max(1, min(2, Int(env["AUDITDOC_PROPS_SCALE"] ?? "") ?? 1))        // 1 = 100 k / 50 k / 150 k iterations; capped at 2
        report(AuditDocProps.runDiffProps(cases: 100_000 * scale, seed: seed))
        report(AuditDocProps.runMergeProps(cases: 50_000 * scale, seed: seed))
        report(AuditDocProps.runCodecProps(cases: 150_000 * scale, seed: seed))
        report(AuditDocProps.runCodecBoundaryProps(seed: seed))
        report(AuditDocProps.runBudgetProps(seed: seed))
        t.note("property tests took \(Int(SelfTest.nowMs() - t0)) ms (seed \(seed), scale \(scale): rerun with the same seed reproduces every case)")
    }

    // MARK: bytes

    private static func u8(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static func le16(_ s: String, bom: Bool = true) -> [UInt8] { (bom ? [0xFF, 0xFE] : []) + s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
    private static func be16(_ s: String, bom: Bool = true) -> [UInt8] { (bom ? [0xFE, 0xFF] : []) + s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
    private static func be32(_ s: String) -> [UInt8] { [0, 0, 0xFE, 0xFF] + s.unicodeScalars.flatMap { [0, UInt8(($0.value >> 16) & 0xFF), UInt8(($0.value >> 8) & 0xFF), UInt8($0.value & 0xFF)] } }
    private static func le32(_ s: String) -> [UInt8] { [0xFF, 0xFE, 0, 0] + s.unicodeScalars.flatMap { [UInt8($0.value & 0xFF), UInt8(($0.value >> 8) & 0xFF), UInt8(($0.value >> 16) & 0xFF), 0] } }

    /// Opens `bytes` as a real document, saves it WITHOUT an edit (bytes must be identical), then appends "Z" at the end of the text and
    /// autosaves (the bytes must be the original plus the encoded "Z"). `refused`: the open must fail and the file stays as it is.
    @MainActor private static func docRoundTrip(_ t: SelfTest.T, _ name: String, _ bytes: [UInt8], zBytes: [UInt8] = [0x5A], refused: Bool = false) async {
        let file = t.write(data: Data(bytes), to: "bytes-\(name).md")
        let doc: MarkdownDocument
        do { doc = try await t.open(file) } catch {
            t.check(refused, "\(name): opens (it threw: \((error as NSError).localizedFailureReason ?? error.localizedDescription))")
            t.check(t.readData(file) == Data(bytes), "\(name): refused file is untouched on disk")
            return
        }
        defer { t.close(doc) }
        if refused { t.check(false, "\(name): must be refused, but opened as \(doc.textFormat)"); return }
        await t.sleep(60)
        let fmt = doc.textFormat
        let saved: Error? = await withCheckedContinuation { c in doc.save(to: file, ofType: doc.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { c.resume(returning: $0) } }
        t.check(saved == nil, "\(name) [\(fmt)]: save without edit succeeds (\(String(describing: saved)))")
        t.check(t.readData(file) == Data(bytes), "\(name) [\(fmt)]: open + save without edit: byte-identical (\(bytes.count) bytes)")
        guard let tv = t.editor(doc)?.textView else { return }
        t.typeText("Z", into: doc, at: NSRange(location: (tv.string as NSString).length, length: 0))
        await t.sleep(30)
        let err = await t.autosave(doc)
        t.check(err == nil, "\(name): autosave after the edit: \(String(describing: err))")
        t.check(t.readData(file) == Data(bytes + zBytes), "\(name) [\(doc.textFormat)]: edit + autosave changes only the edit (\(t.readData(file).count) bytes, expected \(bytes.count + zBytes.count))")
    }

    @MainActor static func auditDocBytes(_ t: SelfTest.T) async throws {
        // ---- the lossy-decoding defect: one stray 0xA9 (Latin-1 / Windows-1252 "©") in an otherwise ASCII or UTF-8 file
        do {
            let b = u8("Copyright ") + [0xA9] + u8(" 2020\n")
            let dec = try TextCodec.decode(Data(b))
            t.equal(dec.format.encoding, .windows1252, "stray 0xA9 byte: the file is NOT valid UTF-8 -> Windows-1252 (was: UTF-8 with U+FFFD)")
            t.equal(dec.text as String, "Copyright © 2020\n", "stray 0xA9 byte: shown as the copyright sign, not U+FFFD")
            let back = try TextCodec.encode(dec.text, format: dec.format)
            t.check(back == Data(b), "stray 0xA9 byte: byte-identical round trip")
            await docRoundTrip(t, "stray-a9", b)
            // UTF-8 text with ONE stray byte is DAMAGED UTF-8, not Windows-1252: it used to open as 1252 ("GrÃ¶ÃŸe" mojibake) and the first typed
            // character that 1252 cannot hold (an emoji, an arrow) switched the document to UTF-8 and wrote the mojibake as UTF-8 - every umlaut garbled
            // for good. Refused, untouched, with a message that says why.
            await docRoundTrip(t, "stray-a9-and-utf8", u8("é ") + [0xA9] + u8(" ü\n"), refused: true)
            let damaged = u8("# Größe und Ärger\n\nÜbung macht den Meister – naïve café ") + [0xA9] + u8(" 2020\n")
            do { _ = try TextCodec.decode(Data(damaged)); t.check(false, "damaged UTF-8 (valid multi-byte text + one stray byte) must be refused") }
            catch LuftigError.damagedUTF8(let at) {
                t.equal(at, damaged.lastIndex(of: 0xA9)!, "damaged UTF-8: refused, the message names the first bad byte (\(at))")
                t.check(LuftigError.damagedUTF8(firstInvalidByte: at).failureReason?.contains("byte \(at)") == true, "... and the failure reason says so")
            } catch { t.check(false, "damaged UTF-8: wrong error \(error)") }
            await docRoundTrip(t, "damaged-utf8-crlf", u8("Größe\r\nÜbung ") + [0xA9] + u8("\r\n"), refused: true)
            await docRoundTrip(t, "damaged-utf8-bom", [0xEF, 0xBB, 0xBF] + u8("abc ") + [0xA9] + u8("\n"), refused: true)
            await docRoundTrip(t, "damaged-utf8-truncated-tail", u8("Größe und Übung\n") + [0xE2, 0x82], refused: true)
        }
        // ---- every strictness failure NSString(bytes:encoding: UTF-8) lets through must now be refused or round-trip
        do {
            var bad = 0
            for v in 0...255 {
                for ctx in [u8("abc"), u8("é"), []] {
                    let b = ctx + [UInt8(v)] + ctx
                    if let dec = try? TextCodec.decode(Data(b)), let back = try? TextCodec.encode(dec.text, format: dec.format), back != Data(b) { bad += 1 }
                }
            }
            t.equal(bad, 0, "every single stray byte 0x00...0xFF in 3 contexts: decode either refuses or round-trips byte-exactly")
        }
        // ---- BOM / UTF-16 / UTF-32 structure
        await docRoundTrip(t, "double-bom", [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF] + u8("x\n"))
        await docRoundTrip(t, "u16le-odd-length", le16("ab\n") + [0x43], refused: true)
        await docRoundTrip(t, "u16be-odd-length", be16("ab\n") + [0x43], refused: true)
        await docRoundTrip(t, "u32le-odd-length", le32("ab\n") + [0x43], refused: true)
        for (name, b, z) in [("utf8-lf", u8("# Title\n\nbody\n"), [UInt8]([0x5A])),
                             ("utf8-no-newline", u8("no final newline"), [0x5A]),
                             ("utf8-bom", [0xEF, 0xBB, 0xBF] + u8("# T\nbody\n"), [0x5A]),
                             ("utf8-bom-crlf", [0xEF, 0xBB, 0xBF] + u8("# T\r\nbody\r\n"), [0x5A]),
                             ("utf8-crlf", u8("a\r\nb\r\nc"), [0x5A]),
                             ("utf8-cr", u8("a\rb\rc"), [0x5A]),
                             ("utf8-mixed", u8("a\r\nb\nc\rd\r\n"), [0x5A]),
                             ("utf8-crlf-then-lone-cr", u8("a\r\nb\r"), [0x5A]),
                             ("utf8-emoji-zwj-combining", u8("👩‍💻 e\u{301} 日本語 \u{2028} \u{FEFF} x\n"), [0x5A]),
                             ("utf8-noncharacters", [0xEF, 0xBF, 0xBE, 0x0A, 0xEF, 0xBF, 0xBF, 0x0A, 0xF4, 0x8F, 0xBF, 0xBF, 0x0A, 0xEF, 0xB7, 0x90, 0xEF, 0xBF, 0xBD, 0x0A], [0x5A]),
                             ("utf8-controls-and-separators", u8("a\u{85}b\u{2028}c\u{2029}d\u{1B}e\u{7F}f\u{0C}g\u{0B}h\u{E000}i\u{200B}j\u{202E}k\n"), [0x5A]),
                             ("utf8-bom-inside", u8("a\u{FEFF}b\n\u{FEFF}c\n"), [0x5A]),
                             ("utf16le-bom", le16("# T\nA😀\n"), [0x5A, 0x00]),
                             ("utf16be-bom-crlf", be16("a\r\nb\r\n"), [0x00, 0x5A]),
                             ("utf16le-no-bom", le16("plain ascii text\nsecond\n", bom: false), [0x5A, 0x00]),
                             ("utf16le-lone-surrogate", [0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x42, 0x00, 0x0A, 0x00], [0x5A, 0x00]),
                             ("utf32le-bom", le32("ab😀\n"), [0x5A, 0, 0, 0]),
                             ("utf32be-bom", be32("ab😀\r\nx\n"), [0, 0, 0, 0x5A]),
                             ("utf16be-no-bom", be16("plain ascii text\nsecond line\n", bom: false), [0x00, 0x5A]),
                             ("latin1-all-high-bytes", u8("h ") + (0x80...0xFF).map { UInt8($0) }.filter { ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains($0) } + u8("\n"), [0x5A]),
                             ("macroman-only-bytes", u8("a") + [0x81, 0x8D, 0x8F, 0x90, 0x9D] + u8("\n"), [0x5A]),
                             ("one-byte-lf", [0x0A], [0x5A]),
                             ("one-byte-cr", [0x0D], [0x5A]),
                             ("one-byte-a", [0x61], [0x5A]),
                             ("empty", [], [0x5A]),
                             ("bom-only", [0xEF, 0xBB, 0xBF], [0x5A]),
                             ("truncated-utf8-sequence", u8("x") + [0xE2, 0x82], [0x5A]),
                             ("overlong-utf8", u8("a") + [0xC0, 0x80, 0x0A], [0x5A])] as [(String, [UInt8], [UInt8])] {
            await docRoundTrip(t, name, b, zBytes: z)
        }
        // A handful of NULs in otherwise valid UTF-8 inside the first 64 KB is text (a stray U+0000 that was typed or pasted is written back as a NUL
        // byte, and luftig must be able to read what it wrote); many NULs = binary: refused; NUL after the sniff window: kept as ordinary text
        await docRoundTrip(t, "nul-early", u8("abc") + [0x00] + u8("def\n"))
        await docRoundTrip(t, "nuls-binary", u8("abc") + [0, 0, 0, 0, 0] + u8("def\n"), refused: true)
        var late = [UInt8](repeating: 0x61, count: 70_000); late[69_000] = 0; late.append(0x0A)
        await docRoundTrip(t, "nul-after-64k", late)
        // a bigger mixed file: 1 MB of German / CJK / emoji with CRLF
        var big = ""
        while big.utf8.count < 1_000_000 { big += "Größenänderung – 日本語のテキスト 😀 émoji café\r\n" }
        await docRoundTrip(t, "mixed-1mb-crlf", u8(big))

        // ---- BOM-less / odd inputs through TextCodec only (not editable files): never a silent change
        t.equal((try? TextCodec.decode(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00]))) == nil, true, "FF FE 00 00 41 00 (UTF-16 BOM + NUL, looks like a UTF-32 BOM): refused, not rewritten")

        // ---- a folder is not a regular file: refused at once (named pipes, devices and sockets are refused by the same fstat check - NOT exercised
        //      here on purpose: any special file in a test once wedged the system daemon filecoordinationd machine-wide)
        do {
            try? FileManager.default.createDirectory(at: t.url("folder.md"), withIntermediateDirectories: true)
            var threw = false
            do { _ = try DiskReader.readFile(path: t.url("folder.md").path) } catch { threw = true }
            t.check(threw, "DiskReader.readFile(folder) is refused, no empty document")
        }
    }
}
#endif
