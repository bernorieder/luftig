#if LUFTIG_SELFTEST
// SelfTestScenarios.swift - registry + the pure (no document) scenarios: codec, diff
// More scenarios: SelfTestReload.swift (clean reload matrix, UX), SelfTestDirty.swift (merge/conflict/save gate),
// SelfTestApp.swift (lifecycle, menu, new/untitled, refusal), SelfTestBench.swift (numbers).

import AppKit

enum SelfTestScenarios {
    static let all: [SelfTest.Scenario] = [
        .init(name: "codec", summary: "encodings, BOM, line endings: decode + byte-exact round trip", run: { t in try await codec(t) }),
        .init(name: "diff", summary: "minimal edits, position mapping, 3-way merge (fuzzed)", run: { t in try await diff(t) }),
    ] + reloadScenarios + dirtyScenarios + appScenarios + benchScenarios + integrationScenarios + renderScenarios + auditShellScenarios + robustScenarios + perfScenarios + settingsScenarios + indentScenarios + matrixScenarios + fixSettingsScenarios + fixScrollScenarios + fixWindowsScenarios + lookScenarios + mergeLookScenarios + chromeScenarios + editingScenarios + tableScenarios + shotScenarios + fixTypingScenarios + tableRenderScenarios

    // MARK: codec

    @MainActor static func codec(_ t: SelfTest.T) async throws {
        func roundTrip(_ name: String, _ bytes: [UInt8], text: String?, enc: TextEncodingKind, bom: Bool, le: LineEnding) {
            let d = Data(bytes)
            do {
                let dec = try TextCodec.decode(d)
                if let text { t.equal(dec.text as String, text, "\(name): text") }
                t.equal(dec.format, TextFormat(encoding: enc, hasBOM: bom, lineEnding: le), "\(name): format")
                let back = try TextCodec.encode(dec.text, format: dec.format)
                t.check(back == d, "\(name): byte-identical round trip (\(d.count) bytes)")
            } catch { t.check(false, "\(name): threw \(error)") }
        }
        let u8 = { (s: String) in Array(s.utf8) }
        roundTrip("utf8 LF", u8("# Hi\nline\n"), text: "# Hi\nline\n", enc: .utf8, bom: false, le: .lf)
        roundTrip("utf8 no newline at all", u8("just text"), text: "just text", enc: .utf8, bom: false, le: .lf)
        roundTrip("utf8 + BOM", [0xEF, 0xBB, 0xBF] + u8("# Hi\n"), text: "# Hi\n", enc: .utf8, bom: true, le: .lf)
        roundTrip("utf8 CRLF", u8("a\r\nb\r\nc\r\n"), text: "a\nb\nc\n", enc: .utf8, bom: false, le: .crlf)
        roundTrip("utf8 CRLF, no final newline", u8("a\r\nb"), text: "a\nb", enc: .utf8, bom: false, le: .crlf)
        roundTrip("utf8 CR only (classic Mac)", u8("a\rb\rc\r"), text: "a\nb\nc\n", enc: .utf8, bom: false, le: .cr)
        roundTrip("utf8 mixed LF/CRLF kept literally", u8("a\r\nb\nc\r\n"), text: "a\r\nb\nc\r\n", enc: .utf8, bom: false, le: .mixed)
        roundTrip("utf8 lone CR + LF mixed", u8("a\rb\nc"), text: "a\rb\nc", enc: .utf8, bom: false, le: .mixed)
        roundTrip("utf8 CRLF + BOM", [0xEF, 0xBB, 0xBF] + u8("x\r\ny\r\n"), text: "x\ny\n", enc: .utf8, bom: true, le: .crlf)
        roundTrip("utf8 non-ASCII", u8("Größe – 日本語 😀\n"), text: "Größe – 日本語 😀\n", enc: .utf8, bom: false, le: .lf)
        roundTrip("empty file", [], text: "", enc: .utf8, bom: false, le: .lf)
        roundTrip("BOM only", [0xEF, 0xBB, 0xBF], text: "", enc: .utf8, bom: true, le: .lf)
        let utf16le: [UInt8] = [0xFF, 0xFE] + "Hé\nA😀\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        roundTrip("utf16 LE + BOM", utf16le, text: "Hé\nA😀\n", enc: .utf16LE, bom: true, le: .lf)
        let utf16be: [UInt8] = [0xFE, 0xFF] + "Hé\r\nA\r\n".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        roundTrip("utf16 BE + BOM, CRLF", utf16be, text: "Hé\nA\n", enc: .utf16BE, bom: true, le: .crlf)
        let noBomLE: [UInt8] = "plain ascii text\nsecond\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        roundTrip("utf16 LE without BOM (heuristic)", noBomLE, text: "plain ascii text\nsecond\n", enc: .utf16LE, bom: false, le: .lf)
        let utf32le: [UInt8] = [0xFF, 0xFE, 0, 0] + "ab\n".unicodeScalars.flatMap { s -> [UInt8] in let v = s.value; return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), 0] }
        roundTrip("utf32 LE + BOM", utf32le, text: "ab\n", enc: .utf32LE, bom: true, le: .lf)
        // legacy fallbacks
        roundTrip("windows-1252 (invalid as UTF-8)", [0x48, 0xE9, 0x6C, 0x6C, 0x6F, 0x20, 0x80, 0x0A], text: "Héllo €\n", enc: .windows1252, bom: false, le: .lf)
        roundTrip("mac roman (bytes undefined in 1252)", [0x41, 0x81, 0x42, 0x0A], text: "AÅB\n", enc: .macRoman, bom: false, le: .lf)
        roundTrip("windows-1252 CRLF", [0x61, 0xE9, 0x0D, 0x0A, 0x62, 0x0D, 0x0A], text: "aé\nb\n", enc: .windows1252, bom: false, le: .crlf)

        // refusals
        do { _ = try TextCodec.decode(Data([0x41, 0x00, 0x42, 0x00, 0x00, 0xFF, 0x01, 0x02, 0x03, 0x00, 0x00])); t.check(false, "binary data must be refused") }
        catch let e as LuftigError { if case .binaryFile = e { t.check(true, "binary data (NUL bytes) is refused: \(e.localizedDescription)") } else { t.check(false, "wrong error \(e)") } }
        catch { t.check(false, "wrong error type \(error)") }
        let bigPath = t.url("sparse.bin").path
        t.check(FileManager.default.createFile(atPath: bigPath, contents: nil), "create sparse file")
        let fd = open(bigPath, O_WRONLY); ftruncate(fd, 201 * 1024 * 1024); close(fd)      // sparse: no disk space used, nothing is read
        do { _ = try DiskReader.readFile(path: bigPath); t.check(false, "201 MB file must be refused") }
        catch let e as LuftigError { if case .tooLarge = e { t.check(true, "201 MB file refused before reading: \(e.localizedDescription)") } else { t.check(false, "wrong error \(e)") } }
        catch { t.check(false, "wrong error type \(error)") }

        // encode behaviour
        let fmtCRLF = TextFormat(encoding: .utf8, hasBOM: false, lineEnding: .crlf)
        let folded = try TextCodec.encode("a\r\nb\rc\n", format: fmtCRLF)
        t.check(folded == Data("a\r\nb\r\nc\r\n".utf8), "pasted CR/CRLF in a CRLF document are folded, not doubled")
        do { _ = try TextCodec.encode("a😀", format: TextFormat(encoding: .windows1252, hasBOM: false, lineEnding: .lf)); t.check(false, "emoji in 1252 must throw") }
        catch LuftigError.notRepresentable { t.check(true, "unrepresentable character in a legacy encoding throws notRepresentable (document falls back to UTF-8)") }
        catch { t.check(false, "wrong error \(error)") }
        t.check(FastHash.hash64(UnsafeRawBufferPointer(start: nil, count: 0)) != FastHash.hash64(Data([0]).withUnsafeBytes { $0 }), "hash differs for empty vs one zero byte")
        var seen = Set<UInt64>()
        for i in 0..<2000 { var d = Data(count: 37 + i % 5); d[i % d.count] = UInt8(i & 0xFF); d.append(UInt8(i >> 8)); seen.insert(d.withUnsafeBytes { FastHash.hash64($0) }) }
        t.check(seen.count >= 1990, "hash: 2000 near-identical inputs give \(seen.count) distinct values")
    }

    // MARK: diff

    @MainActor static func diff(_ t: SelfTest.T) async throws {
        func apply(_ edits: [TextEdit], old: NSString, new: NSString) -> NSString {
            let m = NSMutableString(string: old as String)
            for e in edits.reversed() { m.replaceCharacters(in: e.oldRange, with: new.substring(with: e.newRange)) }
            return m
        }
        // --- fixed cases
        let a: NSString = "one\ntwo\nthree\nfour\n"
        t.check(TextDiff.edits(old: a, new: a).isEmpty, "equal strings -> no edits")
        let e1 = TextDiff.edits(old: a, new: "one\ntwo\nthree\nfour\nfive\n")
        t.equal(e1, [TextEdit(oldRange: NSRange(location: a.length, length: 0), newRange: NSRange(location: a.length, length: 5))], "append at end -> one pure insertion")
        let e2 = TextDiff.edits(old: a, new: "one\nTWO\nthree\nfour\n")
        t.equal(e2.count, 1, "one changed line -> one edit")
        t.equal(NSStringFromRange(e2[0].oldRange), NSStringFromRange(NSRange(location: 4, length: 3)), "edit covers exactly the changed characters")
        // emoji: never split a surrogate pair
        let em1: NSString = "a😀b", em2: NSString = "a😁b"
        let ee = TextDiff.edits(old: em1, new: em2)
        t.check(apply(ee, old: em1, new: em2).isEqual(em2), "surrogate pair replaced as a whole: \(ee)")
        t.check(ee.allSatisfy { ($0.oldRange.length % 2 == 0) && $0.oldRange.location == 1 }, "edit starts at the pair boundary")

        // --- two distant edits in a big text become two small edits (line diff), not one huge one
        var lines: [String] = []
        for i in 0..<4000 { lines.append("line \(i) of the document with some text") }
        let old = lines.joined(separator: "\n") + "\n" as NSString
        var l2 = lines; l2[10] = "line 10 CHANGED"; l2[3900] = "line 3900 CHANGED TOO"; l2.insert("a new line", at: 2000)
        let new = l2.joined(separator: "\n") + "\n" as NSString
        let multi = TextDiff.edits(old: old, new: new)
        t.equal(multi.count, 3, "3 separate changes in 4000 lines -> 3 edits")
        t.check(multi.reduce(0) { $0 + $1.oldRange.length + $1.newRange.length } < 200, "total replaced size is tiny (\(multi.reduce(0) { $0 + $1.oldRange.length + $1.newRange.length }) units) instead of ~\(old.length / 2)")
        t.check(apply(multi, old: old, new: new).isEqual(new), "applying the 3 edits yields the new text")
        // a caret in the unchanged middle stays on the same character
        let probe = old.range(of: "line 3000 of").location
        let mapped = TextDiff.map(probe, through: multi)
        t.check(new.substring(from: mapped).hasPrefix("line 3000 of"), "caret in unchanged text maps to the same text after edits above it")
        // fully different texts: bail out to ONE edit (no pathological diff time)
        var other: [String] = []; for i in 0..<4000 { other.append("totally different \(i * 7 % 1013)") }
        let t0 = SelfTest.nowMs()
        let bail = TextDiff.edits(old: old, new: other.joined(separator: "\n") + "\n" as NSString)
        t.check(bail.count == 1, "unrelated texts: single replacement (\(bail.count) edit), computed in \(Int(SelfTest.nowMs() - t0)) ms")

        // --- fuzz: random edits on small texts, line diff forced (threshold 0), all invariants
        var rng = SystemRandomNumberGenerator()
        let alphabet = ["a", "b", "c", "\n", "\n", " ", "😀", "é"]
        func randomText(_ n: Int) -> String { (0..<n).map { _ in alphabet.randomElement(using: &rng)! }.joined() }
        var fuzzFailures = 0
        let opts = TextDiff.Options(maxHunks: 64, maxLineEditDistance: 500, lineDiffThresholdUnits: 0)
        for iter in 0..<3000 {
            let base = randomText(Int.random(in: 0...60, using: &rng)) as NSString
            var mutated = base as String
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                let u = Array(mutated.utf16)
                let p = Int.random(in: 0...u.count, using: &rng), q = Int.random(in: p...u.count, using: &rng)
                mutated = String(decoding: u[0..<p], as: UTF16.self) + randomText(Int.random(in: 0...6, using: &rng)) + String(decoding: u[q...], as: UTF16.self)
            }
            let new = mutated as NSString
            let edits = TextDiff.edits(old: base, new: new, options: opts)
            let ok = apply(edits, old: base, new: new).isEqual(new)
            var sorted = true
            for i in 1..<max(1, edits.count) where NSMaxRange(edits[i - 1].oldRange) > edits[i].oldRange.location { sorted = false }
            var mapOK = true
            for pos in [0, base.length / 2, base.length] {
                let m = TextDiff.map(pos, through: edits)
                if m < 0 || m > new.length { mapOK = false }
            }
            if !ok || !sorted || !mapOK { fuzzFailures += 1; if fuzzFailures <= 3 { t.info("fuzz #\(iter) failed: ok=\(ok) sorted=\(sorted) map=\(mapOK) edits=\(edits) old=\(base.debugDescription) new=\(new.debugDescription)") } }
        }
        t.equal(fuzzFailures, 0, "3000 fuzzed edit lists apply correctly, are ordered and map positions in range")

        // --- 3-way merge
        let base: NSString = "# Title\n\nintro\n\n## A\nalpha\n\n## B\nbeta\n\n## C\ngamma\n"
        let mine: NSString = "# Title\n\nintro\n\n## A\nalpha MINE\n\n## B\nbeta\n\n## C\ngamma\n"
        let theirs: NSString = "# Title\n\nintro\n\n## A\nalpha\n\n## B\nbeta\n\n## C\ngamma THEIRS\nmore\n"
        let merged = Diff3.merge(base: base, mine: mine, theirs: theirs)
        t.equal(merged as String?, "# Title\n\nintro\n\n## A\nalpha MINE\n\n## B\nbeta\n\n## C\ngamma THEIRS\nmore\n", "merge: edits in different sections both survive")
        t.check(Diff3.merge(base: base, mine: mine, theirs: "# Title\n\nintro\n\n## A\nalpha THEIRS\n\n## B\nbeta\n\n## C\ngamma\n") == nil, "merge: both changed the same line -> conflict (nil)")
        t.equal(Diff3.merge(base: base, mine: mine, theirs: mine) as String?, mine as String, "merge: identical change on both sides is accepted")
        t.equal(Diff3.merge(base: base, mine: base, theirs: theirs) as String?, theirs as String, "merge: nothing typed -> theirs")
        t.equal(Diff3.merge(base: base, mine: mine, theirs: base) as String?, mine as String, "merge: nothing changed on disk -> mine")
        t.check(Diff3.merge(base: base, mine: "x\n" + (base as String) as NSString, theirs: "y\n" + (base as String) as NSString) == nil, "merge: both insert at the same place -> conflict")
        t.equal(Diff3.merge(base: "", mine: "m\n", theirs: "") as String?, "m\n", "merge: empty base")
        // fuzz: independent edits far apart always merge to exactly base + both edits
        var mergeFailures = 0
        for iter in 0..<500 {
            let n = Int.random(in: 8...30, using: &rng)
            let bl = (0..<n).map { "line \($0) \(Int.random(in: 0...9, using: &rng))\n" }
            let i = Int.random(in: 0..<(n / 2 - 1), using: &rng), j = Int.random(in: (n / 2 + 1)..<n, using: &rng)
            let insertMine = Bool.random(), removeNext = Bool.random() && j + 1 < n
            var ml = bl, tl = bl, exp = bl
            tl[j] = "THEIRS edit \(iter)\n"; if removeNext { tl.remove(at: j + 1) }
            ml[i] = "MINE edit \(iter)\n"; if insertMine { ml.insert("mine extra\n", at: i) }
            exp[j] = tl[j]; if removeNext { exp.remove(at: j + 1) }
            exp[i] = "MINE edit \(iter)\n"; if insertMine { exp.insert("mine extra\n", at: i) }
            let r = Diff3.merge(base: bl.joined() as NSString, mine: ml.joined() as NSString, theirs: tl.joined() as NSString)
            if (r as String?) != exp.joined() { mergeFailures += 1; if mergeFailures <= 2 { t.info("merge fuzz #\(iter) mismatch:\nbase=\(bl.joined().debugDescription)\nmine=\(ml.joined().debugDescription)\ntheirs=\(tl.joined().debugDescription)\ngot=\((r as String?)?.debugDescription ?? "nil")\nexp=\(exp.joined().debugDescription)") } }
        }
        t.equal(mergeFailures, 0, "500 fuzzed independent edit pairs merge cleanly and keep both edits")
    }
}
#endif
