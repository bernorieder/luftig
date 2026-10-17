#if LUFTIG_SELFTEST
// SelfTestBench.swift - numbers for docs/spike-document.md. Budgets are loose (CI-safe); the printed numbers are the point.
//   luftig --selftest bench,open-perf

import AppKit

/// Counts the longest gap between ticks of a 1 ms main-queue timer = how long the main thread was blocked.
@MainActor final class StallMeter {
    private var timer: DispatchSourceTimer?
    private var last = SelfTest.nowMs()
    private(set) var maxGap = 0.0
    func start() {
        last = SelfTest.nowMs(); maxGap = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
        t.setEventHandler { [self] in let n = SelfTest.nowMs(); maxGap = max(maxGap, n - last); last = n }
        timer = t; t.resume()
    }
    func stop() -> Double { timer?.cancel(); timer = nil; return maxGap }
}

extension SelfTestScenarios {
    static let benchScenarios: [SelfTest.Scenario] = [
        .init(name: "bench", summary: "read / hash / decode / encode / text storage timings at 1 MB and 10 MB (release build!)", run: { t in try await bench(t) }),
    ]

    static func makeMarkdown(bytes target: Int, flavour: String, lineEnding: String = "\n") -> Data {
        let paragraphs: [String]
        switch flavour {
        case "mixed": paragraphs = ["Größenänderung überprüfen: Café, naïve, Zoë, Ångström – “typografische Anführungszeichen” und … Auslassungen.",
                                    "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.",
                                    "- Listenpunkt mit `Code` und **fett** und *kursiv* sowie ein [Link](https://example.com/pfad?x=1) — fertig",
                                    "> Zitat: „Das ist ein Test“ (ß, ä, ö, ü)", "日本語のテキストもここにあります。中文文本也在这里。😀 emoji"]
        default: paragraphs = ["The quick brown fox jumps over the lazy dog, again and again - nothing special about this sentence at all.",
                               "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.",
                               "- list item with `inline code` and **bold** and *emphasis* and a [link](https://example.com/path?x=1)",
                               "> quoted text that goes on for a while to make lines vary in length", "```swift\nlet x = 42 // code\n```"]
        }
        var s = ""
        s.reserveCapacity(target + 2000)
        var i = 0
        while s.utf8.count < target {
            s += "## Heading \(i)\n\n"
            for p in paragraphs { s += p + "\n" }
            s += "\n"
            i += 1
        }
        if lineEnding != "\n" { s = s.replacingOccurrences(of: "\n", with: lineEnding) }
        return Data(s.utf8)
    }

    @MainActor static func median(_ runs: Int = 7, _ body: () -> Void) -> (med: Double, min: Double) {
        var ts: [Double] = []
        for _ in 0..<runs { let t0 = DispatchTime.now().uptimeNanoseconds; body(); ts.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
        ts.sort()
        return (ts[ts.count / 2], ts[0])
    }

    @MainActor static func bench(_ t: SelfTest.T) async throws {
        #if DEBUG
        t.note("build: DEBUG - numbers are meaningless, use a release build")
#else
        t.note("build: release")
#endif
        func line(_ label: String, _ r: (med: Double, min: Double), bytes: Int? = nil) {
            let rate = bytes.map { String(format: "  (%.1f GB/s)", Double($0) / 1e9 / (r.med / 1000)) } ?? ""
            t.note(String(format: "%-58@ median %8.2f ms  min %8.2f ms%@", label as NSString, r.med, r.min, rate))
        }
        for (flavour, size, lineEnding) in [("ascii", 1_000_000, "\n"), ("ascii", 10_000_000, "\n"), ("mixed", 1_000_000, "\n"), ("mixed", 10_000_000, "\n"), ("ascii", 10_000_000, "\r\n")] {
            let data = makeMarkdown(bytes: size, flavour: flavour, lineEnding: lineEnding)
            let name = "bench-\(flavour)-\(size)\(lineEnding == "\n" ? "" : "-crlf").md"
            let url = t.write(data: data, to: name)
            t.info("=== \(flavour) \(data.count / 1000) KB, \(lineEnding == "\n" ? "LF" : "CRLF") ===")
            line("read(2) whole file (DiskReader.readFile)", median { _ = try? DiskReader.readFile(path: url.path) }, bytes: data.count)
            line("Data(contentsOf:, .alwaysMapped) + touch every page", median { if let d = try? Data(contentsOf: url, options: .alwaysMapped) { d.withUnsafeBytes { p in var s = 0; var i = 0; while i < p.count { s &+= Int(p[i]); i += 4096 }; _ = s } } })
            line("FastHash.hash64", median { _ = data.withUnsafeBytes { FastHash.hash64($0) } }, bytes: data.count)
            var decoded: DecodedText?
            line("TextCodec.decode (-> NSString, line endings normalised)", median { decoded = try? TextCodec.decode(data) }, bytes: data.count)
            guard let dec = decoded else { t.check(false, "decode failed"); continue }
            let storage = NSTextStorage()
            line("NSTextStorage.replaceCharacters(all, with: decoded text)", median { storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: dec.text as String) })
            line("TextCodec.encode(decoded NSString)", median { _ = try? TextCodec.encode(dec.text, format: dec.format) }, bytes: data.count)
            line("TextCodec.encode(NSTextStorage.string) [what data(ofType:) does]", median { _ = try? TextCodec.encode(storage.string as NSString, format: dec.format) }, bytes: data.count)
            line("whole open path: readFile + decode + hash (= read(from:))", median { if let (d, s) = try? DiskReader.readFile(path: url.path) { _ = try? TextCodec.decode(d); _ = DiskReader.state(of: d, signature: s) } })
            let back = try TextCodec.encode(dec.text, format: dec.format)
            t.check(back == data, "\(name): decode+encode is byte-identical")
            let edits = median { _ = TextDiff.edits(old: dec.text, new: dec.text) }
            line("TextDiff.edits(identical texts) = prefix scan of the whole text", edits, bytes: data.count)
        }
        // typing latency in a big document: first keystroke after a sync point (captures the merge base) vs later keystrokes
        for (size, capture) in [(200_000, true), (10_000_000, true), (10_000_000, false)] {
            MarkdownDocument.captureMergeBase = capture
            defer { MarkdownDocument.captureMergeBase = true }
            let url = t.write(data: makeMarkdown(bytes: size, flavour: "ascii"), to: "typing-\(size)-\(capture).md")
            let doc = try await t.open(url)
            guard let host = doc.host as? EditorViewController else { continue }
            let tv = host.textView
            _ = tv.layoutManager?.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 600), in: tv.textContainer!)
            var times: [Double] = []
            for i in 0..<40 {
                let loc = tv.string.utf16.count / 2 + i
                let t0 = DispatchTime.now().uptimeNanoseconds
                t.typeText("a", into: doc, at: NSRange(location: loc, length: 0))
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            let rest = times.dropFirst().sorted()
            t.note(String(format: "typing in a %d KB document, merge base %@: FIRST keystroke after open %.2f ms; later keystrokes median %.2f ms, max %.2f ms (no styling, no layout of the whole text)", size / 1000, capture ? "captured" : "NOT captured", times[0], rest[rest.count / 2], rest.last ?? 0))
            t.close(doc)
        }
        // the SIGBUS hazard of mmap, demonstrated in a child process (so the runner survives)
        let victim = t.write(String(repeating: "x", count: 1 << 20), to: "sigbus.txt")
        let script = """
        import Foundation
        let fd = open("\(victim.path)", O_RDWR)
        var st = stat(); fstat(fd, &st)
        let p = mmap(nil, Int(st.st_size), PROT_READ, MAP_SHARED, fd, 0)!
        ftruncate(fd, 0)                       // "cat > file" / a build tool truncating the file we have mapped
        let b = p.assumingMemoryBound(to: UInt8.self)
        print(b[100])                          // touching a page past the new EOF
        """
        let swiftFile = t.url("sigbus.swift")
        try? script.write(to: swiftFile, atomically: false, encoding: .utf8)
        let exe = t.url("sigbus")
        await t.sh("swiftc -O \(t.q(swiftFile)) -o \(t.q(exe)) 2>/dev/null")
        let status = await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            let p = Process(); p.executableURL = exe; p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
        t.note("mmap + truncate by another writer: child process terminated with status \(status) (\(status == 10 ? "SIGBUS = crash" : "exit/signal \(status)")) - that is why DiskReader uses read(2)")
    }
}
#endif
