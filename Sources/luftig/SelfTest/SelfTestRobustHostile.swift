#if LUFTIG_SELFTEST
// SelfTestRobustHostile.swift - `hostile` (pathological / enormous regular files through the real open path, main-thread stall
// measured) and `resource-policy` (memory per MB, the 200 MB limit, several large documents).
//
// Every case is opened through NSDocumentController (the same entry as Finder / Open Panel / Dock), then - if it opened - drawn,
// typed into at the start / middle / end, scrolled to the middle and the end, reloaded after an external append, re-fonted and closed.
// Each synchronous step is timed (a synchronous step is a main-thread stall), the async open is covered by RobustWatchdog.
// A case that blocks for longer than its hang limit ends the process (status 3) with a `sample` of the main thread.

import AppKit
import Darwin
import MarkdownKit

extension Robust {

    // MARK: - cases

    enum Outcome { case refused, opens, either }

    struct HostileCase {
        let name: String
        let summary: String
        let outcome: Outcome
        /// Approximate size for the report.
        var approxBytes = 0
        /// Cases listed here run in `--selftest all` (small, must be fast); the rest only when named.
        var smoke = false
        /// Hang limit (ms): the case is abandoned (process exit 3 + sample) when the main thread is stuck for longer.
        var hangLimitMs: Double = 90_000
        /// Skip the interaction steps (keystrokes, scrolls...) for cases that are only about the open path.
        var openOnly = false
        /// Expected stall budget for the open (ms) when `smoke`; heavy cases are informational unless --strict.
        var make: @MainActor (URL, SelfTest.T) throws -> Void
    }

    static func u8(_ s: String) -> [UInt8] { Array(s.utf8) }

    @MainActor static let hostileCases: [HostileCase] = {
        var c: [HostileCase] = []
        let text = "# Title\n\nSome *emphasis* and `code` and a [link](http://x.y).\n\n> quote\n\n```\ncode\n```\n\n- item\n"
        c.append(.init(name: "binary-64k", summary: "64 KB of random bytes", outcome: .refused, approxBytes: 65_536, smoke: true,
                       make: { u, _ in try RobustFiles.writeRandom(u, bytes: 65_536) }))
        c.append(.init(name: "nul-early", summary: "valid ASCII text with a NUL at offset 10 (an incidental NUL in valid UTF-8 is text: luftig writes such a file itself, see nul-save)", outcome: .opens, approxBytes: 1000, smoke: true,
                       make: { u, _ in var d = u8(text); d.insert(0, at: 10); try Data(d).write(to: u) }))
        c.append(.init(name: "nul-late", summary: "ASCII markdown with a NUL byte at offset 100 000 (beyond the 64 KB sniff)", outcome: .opens, approxBytes: 200_000, smoke: true,
                       make: { u, _ in var d = Array(SelfTestCorpus.markdown(bytes: 200_000, seed: 4, nonASCII: false).utf8); d[100_000] = 0; try Data(d).write(to: u) }))
        c.append(.init(name: "invalid-utf8", summary: "markdown with one stray 0xFF byte (damaged UTF-8: refused untouched; opening it as Windows-1252 would garble every umlaut)", outcome: .refused, approxBytes: 100_000, smoke: true,
                       make: { u, _ in var d = Array(SelfTestCorpus.markdown(bytes: 100_000, seed: 5, nonASCII: true).utf8); d[5_000] = 0xFF; try Data(d).write(to: u) }))
        c.append(.init(name: "utf16-odd-bom", summary: "UTF-16 LE with BOM and an odd number of bytes", outcome: .either, approxBytes: 100, smoke: true,
                       make: { u, _ in var d: [UInt8] = [0xFF, 0xFE]; for ch in "Hello\nworld".utf16 { d.append(UInt8(ch & 0xFF)); d.append(UInt8(ch >> 8)) }; d.append(0x41); try Data(d).write(to: u) }))
        c.append(.init(name: "utf16-odd-nobom", summary: "UTF-16 LE without BOM, odd length", outcome: .either, approxBytes: 100, smoke: true,
                       make: { u, _ in var d: [UInt8] = []; for ch in "Hello there\nworld and more text".utf16 { d.append(UInt8(ch & 0xFF)); d.append(UInt8(ch >> 8)) }; d.append(0x41); try Data(d).write(to: u) }))
        c.append(.init(name: "utf16-lone-surrogate", summary: "UTF-16 LE with BOM and an unpaired surrogate", outcome: .either, approxBytes: 100, smoke: true,
                       make: { u, _ in var d: [UInt8] = [0xFF, 0xFE]; for ch in [UInt16(0x48), 0xD800, 0x49, 0x0A] { d.append(UInt8(ch & 0xFF)); d.append(UInt8(ch >> 8)) }; try Data(d).write(to: u) }))
        c.append(.init(name: "bom-only", summary: "a UTF-8 BOM and nothing else", outcome: .opens, approxBytes: 3, smoke: true,
                       make: { u, _ in try Data([0xEF, 0xBB, 0xBF]).write(to: u) }))
        c.append(.init(name: "empty", summary: "zero bytes", outcome: .opens, approxBytes: 0, smoke: true,
                       make: { u, _ in try Data().write(to: u) }))
        c.append(.init(name: "cesu-surrogates", summary: "UTF-8 bytes of an encoded surrogate pair (ED A0 80 ED B0 80)", outcome: .opens, approxBytes: 100, smoke: true,
                       make: { u, _ in try Data(u8("a") + [0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80] + u8("b\n")).write(to: u) }))
        c.append(.init(name: "separators", summary: "U+2028 / U+2029 / U+0085 / lone CR / vertical tab / form feed inside Markdown", outcome: .opens, approxBytes: 400, smoke: true,
                       make: { u, _ in try Data(u8("# head\u{2028}ing continues\n\n> quote\u{2029}after\n\n```\u{85}fence\u{0B}vt\u{0C}ff\n```\n\nplain\rcr\n- a\u{2028}b\n")).write(to: u) }))
        c.append(.init(name: "long-path", summary: "file on a path of ~1000 characters", outcome: .opens, approxBytes: 100, smoke: true,
                       make: { u, t in
            // u is only used for the name: build the deep directory below the scenario directory
            // a real path of ~1015 characters (PATH_MAX is 1024): the symlink `u` is short, the file it points to is not
            // from the REAL path of the work directory: the default one (/var/folders/...) is a link to /private/var/..., and the system resolves it
            // before it opens the file, which made a 1016-character path 1024 characters long (PATH_MAX): refused on a machine whose TMPDIR is that long
            var real = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            var dir = (realpath(t.work.path, &real) != nil ? URL(fileURLWithPath: String(cString: real)) : t.work).appendingPathComponent("lp")
            let comp = String(repeating: "d", count: 96)
            var total = dir.path.count
            while total + 1 + 96 + 1 + 14 < 1015 { dir.appendPathComponent(comp); total += 97 }
            if total + 1 + 14 < 1015 { let rest = 1015 - total - 1 - 14 - 1; if rest > 0 { dir.appendPathComponent(String(repeating: "e", count: rest)) } }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("deep-file-xx.md")
            try Data(u8(text)).write(to: f)
            try? FileManager.default.removeItem(at: u)
            try FileManager.default.createSymbolicLink(at: u, withDestinationURL: f)       // the case opens `u`'s target path below
            deepPathNote = f.path
        }))
        c.append(.init(name: "unreadable", summary: "chmod 000", outcome: .refused, approxBytes: 100, smoke: true,
                       make: { u, _ in try Data(u8(text)).write(to: u); chmod(u.path, 0) }))
        c.append(.init(name: "symlink-loop", summary: "a.md -> b.md -> a.md", outcome: .refused, approxBytes: 0, smoke: true,
                       make: { u, t in
            let b = t.url("symlink-loop-b.md")
            try? FileManager.default.removeItem(at: u); try? FileManager.default.removeItem(at: b)
            symlink(b.path, u.path); symlink(u.path, b.path)
        }))
        c.append(.init(name: "directory", summary: "a directory called x.md", outcome: .refused, approxBytes: 0, smoke: true,
                       make: { u, _ in try? FileManager.default.removeItem(at: u); try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false) }))
        // ---- heavy
        c.append(.init(name: "random-20m", summary: "20 MB of pseudo-random bytes (seeded generator)", outcome: .refused, approxBytes: 20 << 20,
                       make: { u, _ in try RobustFiles.writeRandom(u, bytes: 20 << 20) }))
        c.append(.init(name: "single-line-1m", summary: "one line of 1 MB (words)", outcome: .opens, approxBytes: 1 << 20, hangLimitMs: 60_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("word "), count: (1 << 20) / 5) }))
        c.append(.init(name: "single-line-5m", summary: "one line of 5 MB (words)", outcome: .opens, approxBytes: 5_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("word "), count: 1_000_000) }))
        c.append(.init(name: "single-line-minified-json", summary: "one line of 5 MB of minified JSON (no spaces: one giant unbreakable word)", outcome: .opens, approxBytes: 5_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("{\"a\":[1,2,3],\"b\":\"x\"},"), count: 5_000_000 / 22, prefix: u8("["), suffix: u8("{}]")) }))
        c.append(.init(name: "blank-lines-5m", summary: "5 million blank lines", outcome: .opens, approxBytes: 5_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: [10], count: 5_000_000) }))
        c.append(.init(name: "quotes-2m-oneline", summary: "2 million '>' on one line", outcome: .opens, approxBytes: 2_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: [62], count: 2_000_000, suffix: u8(" text\n")) }))
        c.append(.init(name: "quotes-2m-lines", summary: "2 million lines of '>' (one 2M-line block quote)", outcome: .opens, approxBytes: 4_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8(">\n"), count: 2_000_000) }))
        c.append(.init(name: "quotes-nested-lines", summary: "100 000 lines of '> > > > > > > > text'", outcome: .opens, approxBytes: 2_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("> > > > > > > > text\n"), count: 100_000) }))
        c.append(.init(name: "list-nesting-100k", summary: "one line of 100 000 nested list markers '- - - - ...'", outcome: .opens, approxBytes: 200_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("- "), count: 100_000, suffix: u8("leaf\n")) }))
        c.append(.init(name: "list-indent-3k", summary: "a list nested 3000 levels deep by indentation (4.5 MB)", outcome: .opens, approxBytes: 4_500_000, hangLimitMs: 120_000,
                       make: { u, _ in
            var s = String(); s.reserveCapacity(5_000_000)
            for i in 0..<3000 { s += String(repeating: " ", count: i) + "- item \(i)\n" }
            try s.write(to: u, atomically: false, encoding: .utf8)
        }))
        c.append(.init(name: "list-indent-100k-lines", summary: "100 000 list items, each indented by (i mod 8) spaces", outcome: .opens, approxBytes: 1_500_000, hangLimitMs: 120_000,
                       make: { u, _ in
            var s = String(); s.reserveCapacity(2_000_000)
            for i in 0..<100_000 { s += String(repeating: "  ", count: i % 8) + "- item \(i)\n" }
            try s.write(to: u, atomically: false, encoding: .utf8)
        }))
        c.append(.init(name: "backticks-1m", summary: "1 million backticks on one line", outcome: .opens, approxBytes: 1_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: [96], count: 1_000_000, suffix: u8("\n")) }))
        c.append(.init(name: "backticks-lines-300k", summary: "300 000 lines of ``` (alternating fences)", outcome: .opens, approxBytes: 1_200_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("```\n"), count: 300_000) }))
        c.append(.init(name: "stars-5m-oneline", summary: "5 MB of '*' on one line", outcome: .opens, approxBytes: 5_000_000, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: [42], count: 5_000_000, suffix: u8("\n")) }))
        c.append(.init(name: "stars-lines-10m", summary: "10 MB of lines of 79 '*' (rule / emphasis candidates)", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: [UInt8](repeating: 42, count: 79) + [10], count: (10 << 20) / 80) }))
        c.append(.init(name: "inline-quadratic", summary: "5 MB of 60 000-char lines '*a **b ' (emphasis delimiter storms)", outcome: .opens, approxBytes: 5 << 20, hangLimitMs: 180_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("*a **b "), count: 8_000, suffix: u8("\n")); let h = try FileHandle(forWritingTo: u); h.seekToEndOfFile(); let line = Data((0..<8_000).flatMap { _ in u8("*a **b ") } + [10]); for _ in 0..<95 { h.write(line) }; try h.close() }))
        c.append(.init(name: "brackets-lines", summary: "5 MB of 60 000-char lines '[a](' / '![' / '<a ' storms", outcome: .opens, approxBytes: 5 << 20, hangLimitMs: 180_000,
                       make: { u, _ in
            let unitsList = ["[a](", "![", "<a ", "[[", "_a_", "~~a "]
            FileManager.default.createFile(atPath: u.path, contents: nil)
            let h = try FileHandle(forWritingTo: u)
            for i in 0..<90 { let unit = u8(unitsList[i % unitsList.count]); var line = [UInt8](); while line.count < 60_000 { line += unit }; line.append(10); try h.write(contentsOf: Data(line)) }
            try h.close()
        }))
        c.append(.init(name: "table-wide", summary: "a table with 100 000 columns", outcome: .opens, approxBytes: 400_000, hangLimitMs: 120_000,
                       make: { u, _ in
            let row = u8(String(repeating: "| a ", count: 100_000) + "|\n")
            let sep = u8(String(repeating: "|---", count: 100_000) + "|\n")
            try Data(row + sep + row + row).write(to: u)
        }))
        c.append(.init(name: "html-comment-open", summary: "'<!--' followed by 10 MB of text, never closed", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeCorpus(u, bytes: 10 << 20, seed: 9, nonASCII: false); let d = try Data(contentsOf: u); try (Data(u8("<!-- never closed\n")) + d).write(to: u) }))
        c.append(.init(name: "crlf-20m", summary: "20 MB with CRLF line endings", outcome: .opens, approxBytes: 20 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("a line of text with some *emphasis* and `code`\r\n"), count: (20 << 20) / 47) }))
        c.append(.init(name: "cr-only-20m", summary: "20 MB with classic-Mac CR line endings", outcome: .opens, approxBytes: 20 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("a line of text with some *emphasis* and `code`\r"), count: (20 << 20) / 46) }))
        c.append(.init(name: "utf16-20m", summary: "20 MB of UTF-16 (BOM, non-ASCII)", outcome: .opens, approxBytes: 20 << 20, hangLimitMs: 120_000,
                       make: { u, _ in
            var unit: [UInt8] = []
            for ch in "Größe – 日本語 text with *emphasis*\n".utf16 { unit.append(UInt8(ch & 0xFF)); unit.append(UInt8(ch >> 8)) }
            try RobustFiles.writeRepeating(u, unit: unit, count: (20 << 20) / unit.count, prefix: [0xFF, 0xFE])
        }))
        c.append(.init(name: "emoji-10m", summary: "10 MB of emoji / surrogate pairs", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("😀👩‍💻🎉 text\n"), count: (10 << 20) / 28) }))
        c.append(.init(name: "rtl-10m", summary: "10 MB of right-to-left text", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("مرحبا بالعالم שלום עולם **bold** `code`\n"), count: (10 << 20) / 70) }))
        c.append(.init(name: "cjk-10m", summary: "10 MB of Chinese / Japanese text lines (every character 3 bytes in UTF-8)", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("日本語のテキストと中文的内容 **強調** `コード` 한국어\n"), count: (10 << 20) / 70) }))
        c.append(.init(name: "accents-10m", summary: "10 MB of Latin text with an accent in every word (UTF-16 backing store, no complex scripts)", outcome: .opens, approxBytes: 10 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("Größenänderung café naïve Zoë Ångström **fett** `code`\n"), count: (10 << 20) / 60) }))
        c.append(.init(name: "corpus-20m-mixed", summary: "20 MB of the standard Markdown corpus with 2 % non-ASCII words", outcome: .opens, approxBytes: 20 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeCorpus(u, bytes: 20 << 20, seed: 3, nonASCII: true) }))
        c.append(.init(name: "corpus-20m-ascii", summary: "20 MB of the standard Markdown corpus, ASCII only", outcome: .opens, approxBytes: 20 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeCorpus(u, bytes: 20 << 20, seed: 3, nonASCII: false) }))
        c.append(.init(name: "combining-1m", summary: "1 MB of one base letter plus combining marks (a grapheme cluster of 1M scalars)", outcome: .opens, approxBytes: 2 << 20, hangLimitMs: 120_000,
                       make: { u, _ in try RobustFiles.writeRepeating(u, unit: u8("\u{0301}"), count: 1 << 20, prefix: u8("e"), suffix: u8("\n")) }))
        return c
    }()

    nonisolated(unsafe) static var deepPathNote = ""

    // MARK: - runner

    struct StepTimes { var items: [(String, Double)] = []
        mutating func add(_ n: String, _ ms: Double) { items.append((n, ms)) }
        var worst: (String, Double) { items.max(by: { $0.1 < $1.1 }) ?? ("-", 0) }
        func line() -> String { items.map { "\($0.0) \(String(format: "%.0f", $0.1))" }.joined(separator: ", ") }
    }

    struct HostileResult {
        var name: String
        var opened: Bool
        var error: String?
        var openMs: Double
        var worstStep: (String, Double)
        var steps: StepTimes
        var rssMB: Double
    }

    @MainActor static func hostile(_ t: SelfTest.T) async throws {
        let wd = RobustWatchdog.shared
        wd.start(); RobustCrash.install()
        RobustPrefs.reset()
        defer { RobustPrefs.reset() }
        let all = hostileCases
        let sel = SelfTest.argument("cases")
        if sel == "list" {
            for c in all { t.note("\(c.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(c.smoke ? "[smoke] " : "        ")\(c.summary)") }
            return
        }
        var cases: [HostileCase]
        if let sel, sel != "all" {
            let names = sel.split(separator: ",").map(String.init)
            cases = []
            for n in names { guard let c = all.first(where: { $0.name == n }) else { t.check(false, "unknown case \(n)"); continue }; cases.append(c) }
        } else if sel == "all" { cases = all } else { cases = all.filter { $0.smoke } }
        if isSmoke { cases = cases.filter { $0.smoke } }
        let strict = SelfTest.flag("strict")
        var results: [HostileResult] = []
        for c in cases {
            wd.hangLimitMs = SelfTest.argument("hang-limit").flatMap { Double($0) } ?? c.hangLimitMs
            let r = try await runHostile(t, c, strict: strict)
            results.append(r)
        }
        wd.hangLimitMs = 60_000
        t.note("---- hostile summary ----")
        for r in results {
            t.note(String(format: "%@ %@ open %.0f ms, worst step %@ %.0f ms [%@], rss %.0f MB%@", r.name.padding(toLength: 26, withPad: " ", startingAt: 0),
                          r.opened ? "OPENED " : "refused", r.openMs, r.worstStep.0, r.worstStep.1, StallBudget.grade(r.worstStep.1), r.rssMB,
                          r.error.map { "  (\($0.prefix(70)))" } ?? ""))
        }
    }

    @MainActor static func runHostile(_ t: SelfTest.T, _ c: HostileCase, strict: Bool) async throws -> HostileResult {
        let wd = RobustWatchdog.shared
        let dir = t.work.appendingPathComponent(c.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(c.name).md")
        let tGen = now()
        do { try c.make(file, t) } catch { t.check(false, "\(c.name): could not create the test file: \(error)"); return HostileResult(name: c.name, opened: false, error: "setup", openMs: 0, worstStep: ("-", 0), steps: StepTimes(), rssMB: 0) }
        var target = file
        if c.name == "long-path" { target = URL(fileURLWithPath: deepPathNote) }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        t.info(String(format: "== case %@ (%@; %.1f MB; generated in %.0f ms)", c.name, c.summary, Double(size) / 1_048_576, now() - tGen))
        let original: Data? = (c.smoke && c.outcome != .refused && size < 8_000_000) ? try? Data(contentsOf: target) : nil
        let rss0 = RobustResources.rss()

        // ---- open
        wd.label = "hostile \(c.name): open"
        wd.reset()
        let t0 = now()
        var doc: MarkdownDocument?
        var openError: String?
        do {
            let (d, _) = try await NSDocumentController.shared.openDocument(withContentsOf: target, display: false)
            doc = d as? MarkdownDocument
        } catch { openError = (error as NSError).localizedFailureReason ?? error.localizedDescription }
        let openMs = now() - t0
        let openStall = wd.maxStallMs()
        var steps = StepTimes()
        steps.add("open(main-thread stall)", openStall)

        switch c.outcome {
        case .refused: t.check(doc == nil, "\(c.name): is refused (\(openError ?? "OPENED instead")) after \(Int(openMs)) ms")
        case .opens: t.check(doc != nil, "\(c.name): opens (\(openError.map { "refused: \($0)" } ?? "ok")) after \(Int(openMs)) ms")
        case .either: t.note("\(c.name): \(doc != nil ? "opened" : "refused: \(openError ?? "?")") after \(Int(openMs)) ms")
        }
        guard let d = doc else {
            if c.smoke || strict { t.check(openStall < 250, String(format: "%@: a refusal costs < 250 ms of main thread (%.0f ms; %.0f ms wall)", c.name, openStall, openMs)) }
            else { t.note(String(format: "%@: refusal took %.0f ms of main thread (%.0f ms wall) [%@]", c.name, openStall, openMs, StallBudget.grade(openStall))) }
            try? await cleanupCase(c, dir)
            return HostileResult(name: c.name, opened: false, error: openError, openMs: openMs, worstStep: ("open", openStall), steps: steps, rssMB: RobustResources.mb(RobustResources.rss() - rss0))
        }

        // ---- window + first screen
        wd.label = "hostile \(c.name): window"
        var tv: NSTextView!
        var host: EditorViewController!
        let tw = time { t.attachWindow(d, size: NSSize(width: 860, height: 700)) }
        steps.add("window+first screen", tw)
        host = t.editor(d)
        tv = host?.textView
        guard host != nil else { t.check(false, "\(c.name): no editor"); t.close(d); return HostileResult(name: c.name, opened: true, error: nil, openMs: openMs, worstStep: steps.worst, steps: steps, rssMB: 0) }
        let units = (tv.string as NSString).length
        t.info("\(c.name): \(units) UTF-16 units, \(d.textFormat)")
        if let original, c.name != "long-path" { await roundTrip(t, c.name, d, host, file: target, original: original) }
        steps.add("draw", { wd.label = "hostile \(c.name): draw"; return time { _ = t.renderPNG(d.windowControllers.first!.window!) } }())
        let rssOpen = RobustResources.rss()

        if !c.openOnly {
            func at(_ f: Double) -> Int { min(max(0, Int(Double(units) * f)), units) }
            // an external append on the clean document: reload (diff + apply + restyle)
            wd.label = "hostile \(c.name): external append"
            let before = d.stats.silentReloads + d.stats.merges + d.stats.conflicts
            wd.reset()
            let tAppend = now()
            await t.sh("printf '\\nappended-by-hostile-test\\n' >> \(t.q(file))")
            let reloaded = await t.waitFor(min(c.hangLimitMs, 20_000)) { d.stats.silentReloads + d.stats.merges + d.stats.conflicts > before || d.syncState != .inSync }
            let st = wd.maxStallMs()
            steps.add("external append -> reload", st)
            t.info(String(format: "%@: external append %@ after %.0f ms (main-thread stall %.0f ms, state %@)", c.name, reloaded ? "seen" : "NOT seen", now() - tAppend, st, "\(d.syncState)"))
            t.check(reloaded && d.syncState == .inSync, "\(c.name): a clean document follows an external append (state \(d.syncState))")
            // keystrokes: the start, the middle and the end
            for (nm, f) in [("key@start", 0.0), ("key@middle", 0.5), ("key@end", 1.0)] {
                wd.label = "hostile \(c.name): \(nm)"
                steps.add(nm, time { t.typeText("x", into: d, at: NSRange(location: at(f), length: 0)) })
            }
            for (nm, f) in [("scroll@middle", 0.5), ("scroll@end", 0.999)] {
                wd.label = "hostile \(c.name): \(nm)"
                steps.add(nm, time { t.scrollToTop(host, character: at(f)); _ = t.renderPNG(d.windowControllers.first!.window!) })
            }
            // font size
            wd.label = "hostile \(c.name): font size"
            let fs0 = EditorPreferences.fontSize
            steps.add("font size +1", time { EditorPreferences.fontSize = fs0 + 1 })
            EditorPreferences.fontSize = fs0
        }
        wd.label = "hostile \(c.name): close"
        steps.add("close", time { t.close(d) })
        await t.spin(20)
        let worst = steps.worst
        t.info(c.name + ": " + steps.line())
        let rssPeak = RobustResources.mb(rssOpen - rss0)
        t.info(String(format: "%@: worst step %@ %.0f ms [%@]; RSS +%.0f MB after open", c.name, worst.0, worst.1, StallBudget.grade(worst.1), rssPeak))
        // stall budgets: hard for the small smoke cases, informational for the heavy ones unless --strict
        if c.smoke || strict { t.check(worst.1 < 250, String(format: "%@: no step blocks the main thread for >= 250 ms (worst: %@ %.0f ms)", c.name, worst.0, worst.1)) }
        try? await cleanupCase(c, dir)
        return HostileResult(name: c.name, opened: true, error: nil, openMs: openMs, worstStep: worst, steps: steps, rssMB: rssPeak)
    }

    /// Type one character at the start, autosave, and compare the file with the original: the ONLY difference may be that character
    /// (after a BOM). Anything else (a dropped odd byte, a normalised line ending, a changed encoding) is the editor altering a file the
    /// user did not ask it to alter.
    @MainActor static func roundTrip(_ t: SelfTest.T, _ name: String, _ d: MarkdownDocument, _ host: EditorViewController, file: URL, original: Data) async {
        t.typeText("x", into: d, at: NSRange(location: 0, length: 0))
        let edited0 = d.isDocumentEdited
        await t.sleep(30)          // NSDocument registers the change on the next run-loop turn(s)
        t.note("\(name): isDocumentEdited right after typing: \(edited0), 30 ms later: \(d.isDocumentEdited)")
        let err = await t.autosave(d)
        let disk = (try? Data(contentsOf: file)) ?? Data()
        var bom = 0
        let o = [UInt8](original)
        if o.starts(with: [0xEF, 0xBB, 0xBF]) { bom = 3 } else if o.starts(with: [0xFF, 0xFE]) || o.starts(with: [0xFE, 0xFF]) { bom = 2 }
        let x: [UInt8]
        switch d.textFormat.encoding {
        case .utf16LE: x = [0x78, 0]
        case .utf16BE: x = [0, 0x78]
        case .utf32LE: x = [0x78, 0, 0, 0]
        case .utf32BE: x = [0, 0, 0, 0x78]
        default: x = [0x78]
        }
        let expected = Data(Array(o[0..<min(bom, o.count)]) + x + Array(o[min(bom, o.count)...]))
        if err != nil { t.check(false, "\(name): autosave after one keystroke failed: \(err!)"); return }
        if disk == expected { t.check(true, "\(name): one keystroke + autosave changes exactly that character (\(disk.count) bytes, \(d.textFormat))"); return }
        var firstDiff = 0
        let a = [UInt8](disk), b = [UInt8](expected)
        while firstDiff < min(a.count, b.count) && a[firstDiff] == b[firstDiff] { firstDiff += 1 }
        checkKnown(t, false, "\(name): one keystroke + autosave ALTERED the file beyond the typed character: \(original.count) bytes originally, \(disk.count) written (expected \(expected.count)), first difference at byte \(firstDiff), format now \(d.textFormat)", defect: "utf16-odd")
    }

    @MainActor static func cleanupCase(_ c: HostileCase, _ dir: URL) async throws {
        chmod(dir.appendingPathComponent("\(c.name).md").path, 0o644)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - the reader against a writer that shrinks and regrows the file

    /// `reader-race`: DiskReader.readFile (the one function behind open, every external-change check and the post-save verification) is called in a
    /// loop while a child process truncates the file and regrows it in chunks (the file shrinks and grows WHILE it is being read). Every call must
    /// return (no hang, no crash, no exception), and the pair (bytes, signature) it returns should describe one file state.
    @MainActor static func readerRace(_ t: SelfTest.T) async throws {
        let wd = RobustWatchdog.shared
        wd.start(); RobustCrash.install()
        let reads = intArg("reads", smoke: 150, full: 1500)
        let f = t.url("race.md")
        try RobustFiles.writeRepeating(f, unit: Array("0123456789abcdef".utf8), count: 4096)      // 64 KB
        let script = "perl -e 'my $f=$ARGV[0]; for my $i (1..\(reads * 3)) { open(F, \">\", $f); for my $c (1..12) { syswrite(F, \"x\" x 40000); select(undef,undef,undef,0.0003) } close(F); }' \(t.q(f))"
        let writer = Task { await t.sh(script) }
        var done = 0, inconsistent = 0, empty = 0, maxMs = 0.0, errors: [String: Int] = [:], sizes = Set<Int>()
        wd.label = "reader-race: \(reads) reads"; wd.reset()
        while done < reads {
            let t0 = now()
            do {
                let r = try DiskReader.readFile(path: f.path)
                if r.data.count != Int(r.signature.size) { inconsistent += 1 }
                if r.data.isEmpty { empty += 1 }
                if sizes.count < 40 { sizes.insert(r.data.count) }
            } catch { errors["\(error)", default: 0] += 1 }
            maxMs = max(maxMs, now() - t0)
            done += 1
            if done % 10 == 0 { await t.spin(1) }
        }
        let stall = wd.maxStallMs()
        _ = await writer.value          // the writer's loop is finite (3 x reads rewrites); wait for it
        await t.spin(50)
        t.note(String(format: "reader-race: %d reads while the file shrinks and regrows: %d returned bytes that do not match the signature's size, %d empty, %d distinct sizes seen, errors %@, slowest read %.0f ms, longest main-thread stall %.0f ms", done, inconsistent, empty, sizes.count, "\(errors)", maxMs, stall))
        t.check(errors.isEmpty, "reader-race: no read threw (\(errors))")
        t.check(maxMs < 500, String(format: "reader-race: no read took longer than 500 ms (%.0f ms)", maxMs))
        // after the writer stopped, the file is stable and a read is consistent again
        await t.spin(300)
        if let r = try? DiskReader.readFile(path: f.path) { t.check(r.data.count == Int(r.signature.size), "reader-race: a read of the settled file is consistent (\(r.data.count) bytes)") }
        try? FileManager.default.removeItem(at: f)
    }

    // MARK: - event storms

    /// `storm`: thousands of external-change events (a build tool, `git checkout`, a sync client) against an open document. A real child process
    /// writes through ONE descriptor (touch / append) or replaces the file atomically N times; the document must stay responsive (main-thread
    /// stall), answer with a bounded number of checks, end up showing exactly what is on disk and not grow in memory.
    ///   --selftest storm --events 5000 --size 1,20     (smoke inside `all`: 300 events on a 1 MB file)
    @MainActor static func storm(_ t: SelfTest.T) async throws {
        let wd = RobustWatchdog.shared
        wd.start(); RobustCrash.install()
        let events = intArg("events", smoke: 300, full: 5000)
        let sizes = (SelfTest.argument("size") ?? (isSmoke ? "1" : "1,20")).split(separator: ",").compactMap { Int($0) }
        let kinds = (SelfTest.argument("kinds") ?? "touch,append,atomic").split(separator: ",").map(String.init)
        for mb in sizes {
            for kind in kinds {
                let f = t.url("storm-\(kind)-\(mb).md")
                try RobustFiles.writeCorpus(f, bytes: mb << 20, seed: 50 + UInt64(mb))
                let d = try await t.open(f, size: NSSize(width: 860, height: 700))
                guard let h = t.editor(d) else { t.check(false, "storm: no editor"); continue }
                t.scrollToTop(h, character: h.currentText.length / 3)
                await t.spin(200)
                let s0 = d.stats, ev0 = d.monitor?.eventCount ?? 0, dl0 = d.monitor?.deliveryCount ?? 0
                let rss0 = RobustResources.rss(), cpu0 = ProcessMetrics.cpuSeconds()
                let p = t.q(f)
                let script: String
                var storm = events
                switch kind {
                case "swap":
                    // `git checkout other-branch` / a code generator: the whole file is replaced by an unrelated one of the same size (atomic rename), 6 times
                    storm = 6
                    let alts = (0..<2).map { t.url("storm-swap-alt\($0)-\(mb).md") }
                    try RobustFiles.writeCorpus(alts[0], bytes: mb << 20, seed: 900 + UInt64(mb))
                    try RobustFiles.writeCorpus(alts[1], bytes: mb << 20, seed: 910 + UInt64(mb))
                    script = "for i in 1 2 3; do cp \(t.q(alts[0])) \(p).tmp && mv \(p).tmp \(p); sleep 0.7; cp \(t.q(alts[1])) \(p).tmp && mv \(p).tmp \(p); sleep 0.7; done"
                case "touch": script = "perl -e 'for (1..\(events)) { utime(undef, undef, $ARGV[0]) }' \(p)"
                case "append": script = "perl -e 'open(F, \">>\", $ARGV[0]); select((select(F), $|=1)[0]); for (1..\(events)) { syswrite(F, \"storm line $_ with some *markdown* text\\n\"); select(undef,undef,undef,0.0005) }' \(p)"
                default: script = "perl -e 'my $f=$ARGV[0]; for my $i (1..\(events)) { open(T, \">\", \"$f.tmp\"); print T \"# storm $i\\n\\nbody\\n\" x 20; close T; rename(\"$f.tmp\", $f); select(undef,undef,undef,0.0005) }' \(p)"
                }
                wd.label = "storm \(kind) \(mb) MB: \(events) events"
                wd.reset()
                let tw = now()
                await t.sh(script)
                let writerMs = now() - tw
                let stallDuring = wd.maxStallMs()
                // the document must catch up: nothing in flight for 400 ms, editor == disk
                var quietSince = now(), last = d.stats.checks
                let caught = await t.waitFor(20_000) {
                    if d.stats.checks != last || d.checkInFlight || d.isApplyingExternal { last = d.stats.checks; quietSince = now(); return false }
                    return now() - quietSince > 400
                }
                let st = d.stats
                let disk = try? DiskReader.readFile(path: f.path)
                let decoded = disk.flatMap { try? TextCodec.decode($0.data) }
                let same = decoded.map { $0.text.isEqual(to: h.currentText as String) } ?? false
                let cpu = ProcessMetrics.cpuSeconds() - cpu0
                let rssMB = RobustResources.mb(RobustResources.rss() - rss0)
                t.note(String(format: "%@ %d MB, %d events in %.0f ms: monitor saw %d events -> %d deliveries -> %d checks (%d reloads, %d hash-only); longest main-thread stall %.0f ms; CPU %.2f s; RSS %+.0f MB; caught up: %@",
                              kind, mb, storm, writerMs, (d.monitor?.eventCount ?? 0) - ev0, (d.monitor?.deliveryCount ?? 0) - dl0, st.checks - s0.checks,
                              st.silentReloads - s0.silentReloads, st.hashUnchanged - s0.hashUnchanged, stallDuring, cpu, rssMB, caught ? "yes" : "NO"))
                if SelfTest.flag("vmmap") { t.note("  libmalloc's cache of freed large blocks (vmmap 'Malloc Large (empty)', virtual / resident / dirty): \(RobustResources.vmmapLargeEmpty() ?? "n/a"); malloc in use \(RobustResources.mbs(RobustResources.heapInUse())); footprint \(RobustResources.mbs(RobustResources.footprint()))") }
                t.check(caught, "storm \(kind) \(mb) MB: the document went quiet within 20 s of the last event")
                t.check(same, "storm \(kind) \(mb) MB: the editor shows exactly what is on disk afterwards (state \(d.syncState), \(h.currentText.length) units)")
                t.check(stallDuring < (mb >= 10 ? 1000 : 250), String(format: "storm %@ %d MB: longest main-thread stall during the storm %.0f ms", kind, mb, stallDuring))
                t.check((d.monitor?.deliveryCount ?? 0) - dl0 <= Int(writerMs / 1000 * 12) + 12, "storm \(kind) \(mb) MB: deliveries are rate-limited (\((d.monitor?.deliveryCount ?? 0) - dl0) in \(Int(writerMs)) ms)")
                if mb < 10 { t.check(rssMB < Double(mb) * 6 + 60, String(format: "storm %@ %d MB: memory did not grow (RSS %+.0f MB)", kind, mb, rssMB)) }
                else { t.note(String(format: "storm %@ %d MB: RSS %+.0f MB after the storm (informational: freed large blocks stay resident, see the leaks / resource-policy notes)", kind, mb, rssMB)) }
                t.close(d)
                await t.spin(50)
                if let idle = SelfTest.argument("idle").flatMap({ Double($0) }) {
                    // does the process give the memory back when it is left alone?  (--idle SECONDS: footprint after 0 / idle/4 / idle/2 / idle seconds)
                    var line = ""
                    for frac in [0.0, 0.25, 0.5, 1.0] {
                        await t.spin(frac == 0 ? 10 : idle * 1000 * (frac == 0.25 ? 0.25 : (frac == 0.5 ? 0.25 : 0.5)))
                        line += String(format: "%@ %.0f s: footprint %.0f MB, malloc in use %.0f MB; ", frac == 0 ? "closed" : "after", frac == 0 ? 0 : idle * frac, RobustResources.mb(RobustResources.footprint()), RobustResources.mb(RobustResources.heapInUse()))
                    }
                    t.note("  idle decay after \(kind) \(mb) MB: " + line)
                }
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    // MARK: - resource policy

    @MainActor static func resourcePolicy(_ t: SelfTest.T) async throws {
        let wd = RobustWatchdog.shared
        wd.start(); RobustCrash.install()
        let full = SelfTest.flag("full")
        var sizes = [1, 5, 10, 20]
        if isSmoke || !full { sizes = isSmoke ? [1, 5] : [1, 5, 10, 20] }
        func doc(_ file: URL) async throws -> MarkdownDocument { try await t.open(file, size: NSSize(width: 860, height: 700)) }

        // ---- memory per MB of text (footprint = resident + compressed), ASCII and mixed. The first MB carries a fixed cost (window, fonts, layout caches):
        // the check is on documents >= 5 MB and the slope between the smallest and the largest size is reported.
        t.note("---- memory per open document ----")
        var fixed: [(Int, Bool, Double)] = []
        for ascii in [true, false] {
            for mbSize in sizes {
                let f = t.url("mem-\(mbSize)-\(ascii).md")
                try RobustFiles.writeCorpus(f, bytes: mbSize << 20, seed: 6, nonASCII: !ascii)
                await t.spin(50)
                let base = RobustResources.footprint(), baseRSS = RobustResources.rss()
                wd.label = "resource-policy: open \(mbSize) MB"
                let d = try await doc(f)
                _ = t.renderPNG(d.windowControllers.first!.window!)
                let fp = RobustResources.footprint() - base, rss = RobustResources.rss() - baseRSS
                t.note(String(format: "%2d MB %@: footprint +%.0f MB (%.1f per MB of file), RSS +%.0f MB", mbSize, ascii ? "ASCII" : "mixed", RobustResources.mb(fp), RobustResources.mb(fp) / Double(mbSize), RobustResources.mb(rss)))
                // typing in the middle must not copy the document again: footprint after one keystroke
                let units = (d.host?.currentText.length ?? 0)
                t.typeText("x", into: d, at: NSRange(location: units / 2, length: 0))
                let fp2 = RobustResources.footprint() - base
                t.note(String(format: "         after one keystroke in the middle: footprint +%.0f MB", RobustResources.mb(fp2)))
                fixed.append((mbSize, ascii, RobustResources.mb(fp)))
                if mbSize >= 5 { t.check(RobustResources.mb(fp) / Double(mbSize) < 15, String(format: "%d MB %@ document: footprint per MB of file %.1f < 15", mbSize, ascii ? "ASCII" : "mixed", RobustResources.mb(fp) / Double(mbSize))) }
                d.updateChangeCount(.changeCleared); d.close()
                await t.spin(50)
                let after = RobustResources.footprint() - base
                t.note(String(format: "         after close: footprint +%.0f MB", RobustResources.mb(after)))
                try? FileManager.default.removeItem(at: f)
            }
        }

        for ascii in [true, false] {
            let pts = fixed.filter { $0.1 == ascii }.sorted { $0.0 < $1.0 }
            if let a = pts.first(where: { $0.0 >= 5 }), let b = pts.last, b.0 > a.0 {
                t.note(String(format: "%@: marginal footprint %.1f MB per MB of file between %d and %d MB (fixed part ~%.0f MB)", ascii ? "ASCII" : "mixed", (b.2 - a.2) / Double(b.0 - a.0), a.0, b.0, a.2 - (b.2 - a.2) / Double(b.0 - a.0) * Double(a.0)))
            }
        }

        // ---- several large documents at once (never more than 3 big documents open together)
        let nBig = isSmoke ? 2 : 3
        t.note("---- \(nBig) x 20 MB at once ----")
        let big = t.url("big20.md")
        try RobustFiles.writeCorpus(big, bytes: 20 << 20, seed: 7)
        var docs: [MarkdownDocument] = []
        let base = RobustResources.footprint()
        wd.label = "resource-policy: several 20 MB documents"
        wd.reset()
        for i in 0..<nBig {
            let f = t.url("big20-\(i).md")
            try FileManager.default.copyItem(at: big, to: f)
            let d = try await doc(f)
            _ = t.renderPNG(d.windowControllers.first!.window!)
            docs.append(d)
        }
        let st = wd.maxStallMs()
        t.note(String(format: "%d x 20 MB open: footprint +%.0f MB (%.0f MB each), longest main-thread stall during the opens %.0f ms", nBig, RobustResources.mb(RobustResources.footprint() - base), RobustResources.mb(RobustResources.footprint() - base) / Double(nBig), st))
        // an external change reaches every one of them
        let t0 = now()
        wd.reset()
        for i in 0..<nBig { await t.sh("printf '\\nexternal\\n' >> \(t.q(t.url("big20-\(i).md")))") }
        let ok = await t.waitFor(15_000) { docs.allSatisfy { $0.stats.silentReloads >= 1 } }
        t.check(ok, String(format: "%d large documents all picked up an external append (%.0f ms, longest stall %.0f ms)", nBig, now() - t0, wd.maxStallMs()))
        for d in docs { t.close(d) }
        await t.spin(100)
        t.note(String(format: "after closing all: footprint +%.0f MB over the baseline", RobustResources.mb(RobustResources.footprint() - base)))
        for i in 0..<nBig { try? FileManager.default.removeItem(at: t.url("big20-\(i).md")) }
        try? FileManager.default.removeItem(at: big)

        // ---- an OPEN 1 MB document whose file is grown (sparse) beyond the limit by another process: refused without reading, text kept
        if !isSmoke {
            let f = t.url("grow-limit.md")
            try RobustFiles.writeCorpus(f, bytes: 1 << 20, seed: 9)
            let d = try await doc(f)
            let r0 = RobustResources.rss()
            await t.sh("/usr/bin/truncate -s \(TextCodec.maxFileBytes + 4096) \(t.q(f))")
            let seen = await t.waitFor(5000) { d.syncState == .unreadable }
            t.check(seen, "an open document whose file grew beyond the limit reports it (state \(d.syncState), banner: \(d.host.map { ($0 as? EditorViewController)?.bannerText ?? "" } ?? ""))")
            t.check(RobustResources.rss() - r0 < 60 << 20, "growing the file beyond the limit did not read it (RSS +\(RobustResources.mbs(RobustResources.rss() - r0)))")
            t.check((d.host?.currentText.length ?? 0) > 900_000, "the text of the document is still there")
            d.updateChangeCount(.changeCleared); d.close()
            try? FileManager.default.removeItem(at: f)
        }

        // ---- the 200 MB limit. A document that size is NEVER opened here (safety rules): the refusal is checked on a SPARSE regular file
        // of limit + 1 bytes (the reader looks at fstat's size before it allocates or reads anything), and the boundary itself on the
        // reader's `maxBytes` parameter with small files.
        if !isSmoke {
            t.note("---- the 200 MB limit ----")
            let limit = TextCodec.maxFileBytes
            let over = t.url("over-limit.md")
            FileManager.default.createFile(atPath: over.path, contents: Data("# sparse\n".utf8))
            let fh = try FileHandle(forWritingTo: over); try fh.truncate(atOffset: UInt64(limit + 1)); try fh.close()
            wd.label = "resource-policy: open limit+1"; wd.reset()
            let r0 = RobustResources.rss()
            let tOver = now()
            var refused = false
            do { _ = try await NSDocumentController.shared.openDocument(withContentsOf: over, display: false) } catch { refused = true }
            t.check(refused, String(format: "a file of limit + 1 byte (%d) is refused (%.0f ms, main-thread stall %.0f ms, RSS +%.0f MB)", limit + 1, now() - tOver, wd.maxStallMs(), RobustResources.mb(RobustResources.rss() - r0)))
            t.check(RobustResources.rss() - r0 < 20 << 20, "the refusal of the over-limit file allocated nothing (RSS +\(RobustResources.mbs(RobustResources.rss() - r0)))")
            try? FileManager.default.removeItem(at: over)
            // boundary on the reader's own parameter, with a small limit
            let edge = t.url("edge.md")
            for n in [0, 1, 4095, 4096, 4097] {
                try Data(repeating: 0x61, count: n).write(to: edge)
                let atLimit = try? DiskReader.readFile(path: edge.path, maxBytes: n)
                t.check(atLimit?.data.count == n, "DiskReader: a file of exactly maxBytes (\(n)) is read in full")
                var over = false
                do { _ = try DiskReader.readFile(path: edge.path, maxBytes: n - 1) } catch LuftigError.tooLarge { over = true } catch {}
                t.check(over || n == 0, "DiskReader: a file of maxBytes + 1 (\(n) vs \(n - 1)) is refused as too large")
            }
            try? FileManager.default.removeItem(at: edge)
            // the ONE big limit test: a single 60 MB document, never more than one at a time
            let sixty = t.url("sixty.md")
            try RobustFiles.writeCorpus(sixty, bytes: 60 << 20, seed: 8, nonASCII: false)
            let b0 = RobustResources.footprint(), rr0 = RobustResources.rss()
            wd.label = "resource-policy: open 60 MB"; wd.reset()
            let tAt = now()
            do {
                let d = try await doc(sixty)
                let openMs = now() - tAt
                let stall = wd.maxStallMs()
                var steps = StepTimes()
                steps.add("draw", time { _ = t.renderPNG(d.windowControllers.first!.window!) })
                let units = (d.host?.currentText.length ?? 0)
                steps.add("key@start", time { t.typeText("x", into: d, at: NSRange(location: 0, length: 0)) })
                steps.add("key@middle", time { t.typeText("x", into: d, at: NSRange(location: units / 2, length: 0)) })
                steps.add("scroll@end", time { t.scrollToTop(t.editor(d)!, character: units - 10); _ = t.renderPNG(d.windowControllers.first!.window!) })
                t.note(String(format: "60 MB document: open+window %.0f ms (stall %.0f ms), footprint +%.0f MB (%.1f per MB of file), RSS +%.0f MB; %@", openMs, stall, RobustResources.mb(RobustResources.footprint() - b0), RobustResources.mb(RobustResources.footprint() - b0) / 60, RobustResources.mb(RobustResources.rss() - rr0), steps.line()))
                await t.sleep(40)          // NSDocument registers the change on the next run-loop turn(s): without this the autosave would find nothing to write
                t.check(d.isDocumentEdited, "the 60 MB document is registered as edited before the autosave")
                wd.label = "resource-policy: autosave of 60 MB"; wd.reset()
                let tSave = now()
                let err = await t.autosave(d)
                t.check(err == nil, String(format: "autosave of the 60 MB document (%.0f ms, longest stall %.0f ms)", now() - tSave, wd.maxStallMs()))
                t.check(steps.worst.1 < 1000, String(format: "no interactive step of the 60 MB document blocks >= 1 s (worst %@ %.0f ms)", steps.worst.0, steps.worst.1))
                t.close(d)
            } catch { t.note("a 60 MB file does not open: \(error)") }
            await t.spin(100)
            t.note(String(format: "after close: footprint +%.0f MB over the baseline", RobustResources.mb(RobustResources.footprint() - b0)))
            try? FileManager.default.removeItem(at: sixty)
        }
    }
}
#endif
