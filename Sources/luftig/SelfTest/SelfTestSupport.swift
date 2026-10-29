#if LUFTIG_SELFTEST
// SelfTestSupport.swift - shared helpers of the integration scenarios: a deterministic Markdown corpus generator, process
// metrics (RSS, CPU time), contrast maths, attribute comparison against a fresh Theme + MarkdownStyler.lexAll.

import AppKit
import MarkdownKit
import Darwin

/// Deterministic pseudo random numbers (SplitMix64): the same seed gives the same corpus and the same edit sequence.
struct TestRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

enum SelfTestCorpus {
    private static let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike",
                                "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee",
                                "zulu", "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "markdown", "editor", "native", "text", "view",
                                "styled", "lazily", "around", "viewport", "block", "state", "checkpoint", "layout", "attribute", "run", "heading"]
    private static let exotic = ["Größenänderung", "café", "naïve", "Zoë", "日本語", "中文", "한국어", "😀", "🎉", "👩‍💻", "مرحبا", "שלום", "Ångström", "–", "…"]

    private static func word(_ r: inout TestRNG, nonASCII: Bool) -> String {
        nonASCII && r.chance(2) ? r.pick(exotic) : r.pick(words)
    }

    private static func sentence(_ r: inout TestRNG, nonASCII: Bool, inline: Bool = true) -> String {
        var parts: [String] = []
        for _ in 0..<(6 + r.int(12)) {
            var w = word(&r, nonASCII: nonASCII)
            if inline && r.chance(14) {
                switch r.int(8) {
                case 0: w = "**\(w)**"
                case 1: w = "*\(w)*"
                case 2: w = "`\(w)`"
                case 3: w = "[\(w)](https://example.com/\(w))"
                case 4: w = "~~\(w)~~"
                case 5: w = "<https://example.com/\(w)>"
                case 6: w = "\\*\(w)"
                default: w = "_\(w)_"
                }
            }
            parts.append(w)
        }
        return parts.joined(separator: " ")
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for w in text.split(separator: " ") {
            if !cur.isEmpty && cur.count + 1 + w.count > width { lines.append(cur); cur = String(w) } else { cur += (cur.isEmpty ? "" : " ") + w }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// Markdown of roughly `bytes` UTF-8 bytes: front matter, headings, hard-wrapped paragraphs with inline markup, lists (nested,
    /// tasks), quotes (nested), fenced and indented code, tables, rules, comments; ~2 % non-ASCII words.
    static func markdown(bytes target: Int, seed: UInt64 = 1, nonASCII: Bool = true) -> String {
        var r = TestRNG(seed)
        var out = "---\ntitle: Corpus \(seed)\ntags: [a, b]\n---\n\n"
        out.reserveCapacity(target + 4000)
        var n = 0
        while out.utf8.count < target {
            n += 1
            switch r.int(100) {
            case 0..<9:
                out += String(repeating: "#", count: 1 + r.int(4)) + " " + sentence(&r, nonASCII: nonASCII, inline: r.chance(20)).prefix(60) + "\n\n"
            case 9..<45:
                out += wrap(sentence(&r, nonASCII: nonASCII) + " " + sentence(&r, nonASCII: nonASCII) + (r.chance(50) ? " " + sentence(&r, nonASCII: nonASCII) : ""), width: 78).joined(separator: "\n") + "\n\n"
            case 45..<58:
                for i in 0..<(3 + r.int(4)) {
                    let marker = r.chance(25) ? "\(i + 1). " : (r.chance(20) ? "- [\(r.chance(50) ? "x" : " ")] " : "- ")
                    out += marker + sentence(&r, nonASCII: nonASCII).prefix(70) + "\n"
                    if r.chance(25) { out += "  - " + sentence(&r, nonASCII: nonASCII).prefix(50) + "\n" }
                }
                out += "\n"
            case 58..<68:
                for _ in 0..<(2 + r.int(3)) { out += "> " + sentence(&r, nonASCII: nonASCII).prefix(70) + "\n" }
                if r.chance(30) { out += "> > " + sentence(&r, nonASCII: nonASCII).prefix(50) + "\n" }
                out += "\n"
            case 68..<82:
                out += "```" + r.pick(["swift", "json", "sh", "", "python"]) + "\n"
                for _ in 0..<(4 + r.int(16)) { out += (r.chance(30) ? "    " : "") + "let \(r.pick(words)) = \(r.int(1000)) // \(r.pick(words))\n" }
                out += "```\n\n"
            case 82..<88:
                out += "| a | b | c |\n|---|:-:|--:|\n"
                for _ in 0..<(2 + r.int(3)) { out += "| \(r.pick(words)) | \(r.int(100)) | `\(r.pick(words))` |\n" }
                out += "\n"
            case 88..<91: out += r.pick(["---", "***", "___"]) + "\n\n"
            case 91..<94: out += "<!-- \(sentence(&r, nonASCII: false, inline: false)) -->\n\n"
            case 94..<97: out += "    " + sentence(&r, nonASCII: nonASCII, inline: false).prefix(60) + "\n    indented code\n\n"
            default: out += "Setext \(n)\n" + (r.chance(50) ? "======" : "------") + "\n\n"
            }
        }
        return out
    }
}

// MARK: process metrics

enum ProcessMetrics {
    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
    /// User + system CPU seconds of this process so far.
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }
    static func mb(_ bytes: Int) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
}

// MARK: colour maths (WCAG 2 contrast)

enum Contrast {
    /// sRGB components (r, g, b, a) of a dynamic colour as resolved for the given appearance.
    static func rgba(_ c: NSColor, appearance: NSAppearance) -> (r: Double, g: Double, b: Double, a: Double) {
        var out: (Double, Double, Double, Double) = (0, 0, 0, 1)
        appearance.performAsCurrentDrawingAppearance {
            let s = c.usingColorSpace(.sRGB) ?? c
            out = (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent))
        }
        return out
    }
    static func over(_ top: (r: Double, g: Double, b: Double, a: Double), _ bottom: (r: Double, g: Double, b: Double, a: Double)) -> (r: Double, g: Double, b: Double, a: Double) {
        let a = top.a + bottom.a * (1 - top.a)
        func mix(_ t: Double, _ b: Double) -> Double { a == 0 ? 0 : (t * top.a + b * bottom.a * (1 - top.a)) / a }
        return (mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b), a)
    }
    static func luminance(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    static func ratio(_ fg: (r: Double, g: Double, b: Double, a: Double), on bg: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        let f = over(fg, bg)       // a translucent foreground is composited over its background first
        let l1 = luminance(f), l2 = luminance(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

// MARK: comparing the text storage with a fresh lex

enum StyleOracle {
    /// `allowFontFallback`: NSTextStorage's attribute fixing (`fixFontAttributeInRange`) replaces the `.font` of runs that contain
    /// characters the font cannot render (emoji, CJK, Hebrew, ...) by a fallback font. That is AppKit's doing, not ours: such a font
    /// is accepted when the point size is the same (the text is non-ASCII, checked by the caller).
    static func attributesEqual(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any], allowFontFallback: Bool = false) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in a {
            guard let w = b[k] else { return false }
            if !(v as AnyObject).isEqual(w as AnyObject) {
                if allowFontFallback, k == .font, let f = v as? NSFont, let g = w as? NSFont, f.pointSize == g.pointSize { continue }
                return false
            }
        }
        return true
    }

    static func describe(_ a: [NSAttributedString.Key: Any]) -> String {
        var parts: [String] = []
        if let f = a[.font] as? NSFont { parts.append("font=\(f.fontName)@\(f.pointSize)") }
        if let p = a[.paragraphStyle] as? NSParagraphStyle { parts.append("para(h=\(p.minimumLineHeight)/\(p.maximumLineHeight) indent=\(p.firstLineHeadIndent) before=\(p.paragraphSpacingBefore))") }
        if let c = a[.foregroundColor] as? NSColor { parts.append("fg=\(c.description.prefix(40))") }
        if let b = a[.luftigBlock] { parts.append("block=\(b)") }
        if a[.luftigInline] != nil { parts.append("inline") }
        if a[.strikethroughStyle] != nil { parts.append("strike") }
        if let k = a[.kern] { parts.append("kern=\(k)") }
        if a[.underlineStyle] != nil { parts.append("underline") }
        return parts.joined(separator: " ")
    }

    /// What the storage should look like: a FRESH Theme (same base size) + a fresh `MarkdownStyler.lexAll` of the current text.
    /// Tables are aligned as in the editor (TableAlignment.swift), for a text container `tableWidthLimit` wide.
    /// `tables`: the editor's aligner, whose width limit, grid switch and selection the oracle uses (TableRender.swift); nil: tables aligned only.
    static func expectedRuns(text: NSString, baseSize: CGFloat, tableWidthLimit: CGFloat = .greatestFiniteMagnitude, tables: TableAligner? = nil) -> (runs: [StyledRun], mdRuns: [MDRun]) {
        let theme = Theme(baseSize: baseSize)
        let md = MarkdownStyler().lexAll(text)
        return (aligned(theme.styledRuns(md, text: text), md, text, tableWidthLimit, like: tables, theme: theme), md)
    }

    /// The whole text's tables aligned, or drawn as grids like the editor's (the oracle sees the whole text, so no table is cut).
    static func aligned(_ styled: [StyledRun], _ md: [MDRun], _ text: NSString, _ limit: CGFloat, like editor: TableAligner? = nil, theme: Theme? = nil) -> [StyledRun] {
        let aligner = TableAligner()
        _ = aligner.setWidthLimit(editor?.widthLimit ?? limit)
        if let editor { aligner.renderTables = editor.renderTables; aligner.revealed = editor.revealed }
        return aligner.align(styled, lexRuns: md, text: text, region: NSRange(location: 0, length: text.length), cutAtStart: false, cutAtEnd: false, theme: theme)
    }

    struct Mismatch { var range: NSRange; var expected: String; var actual: String }

    /// Compares every character of `range` (default: all) with the oracle. Returns the number of mismatching runs and the first few.
    static func compare(storage: NSTextStorage, baseSize: CGFloat, range: NSRange? = nil, maxReport: Int = 5, tableWidthLimit: CGFloat = .greatestFiniteMagnitude, tables: TableAligner? = nil) -> (checkedRuns: Int, mismatches: Int, first: [Mismatch]) {
        let text = storage.string as NSString
        let (expected, md) = expectedRuns(text: text, baseSize: baseSize, tableWidthLimit: tableWidthLimit, tables: tables)
        let window = range ?? NSRange(location: 0, length: storage.length)
        var checked = 0, bad = 0
        var first: [Mismatch] = []
        // `expected` may have MORE entries than the lexer runs (runs are split at line breaks): look the lexer style up by position
        func lexStyle(at loc: Int) -> MDStyle {
            var lo = 0, hi = md.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if md[mid].range.location <= loc { lo = mid } else { hi = mid - 1 } }
            return md.isEmpty ? MDStyle() : md[lo].style
        }
        for run in expected {
            let r = NSIntersectionRange(run.range, window)
            if r.length == 0 { continue }
            checked += 1
            var pos = r.location
            var ok = true
            var badActual = [NSAttributedString.Key: Any]()
            while pos < NSMaxRange(r) {
                var eff = NSRange(location: 0, length: 0)
                let a = storage.attributes(at: pos, longestEffectiveRange: &eff, in: NSRange(location: pos, length: NSMaxRange(r) - pos))
                var nonASCII = false
                for i in eff.location..<NSMaxRange(eff) where text.character(at: i) > 0x7F { nonASCII = true; break }
                if !attributesEqual(a, run.attributes, allowFontFallback: nonASCII) { ok = false; badActual = a; break }
                pos = NSMaxRange(eff)
                if eff.length == 0 { break }
            }
            if !ok {
                bad += 1
                if first.count < maxReport {
                    let sample = text.substring(with: NSRange(location: r.location, length: min(24, r.length))).debugDescription
                    first.append(Mismatch(range: r, expected: "\(lexStyle(at: r.location)) \(describe(run.attributes))", actual: "\(describe(badActual)) text=\(sample)"))
                }
            }
        }
        return (checked, bad, first)
    }
}

extension SelfTest.T {
    /// A shared, cached corpus file (generated once per run): `markdown(bytes:)` of the given size.
    func corpusFile(bytes: Int, seed: UInt64 = 1, nonASCII: Bool = true) -> URL {
        let dir = work.deletingLastPathComponent().appendingPathComponent("corpus")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("corpus-\(bytes)-\(seed)-\(nonASCII ? "u" : "a").md")
        if !FileManager.default.fileExists(atPath: url.path) {
            let text = SelfTestCorpus.markdown(bytes: bytes, seed: seed, nonASCII: nonASCII)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Run the main run loop for a moment (timers, async blocks, notifications).
    func spin(_ ms: Double = 20) async { await sleep(ms) }

    func fontOf(_ tv: NSTextView, at loc: Int) -> NSFont? { tv.textStorage?.attribute(.font, at: loc, effectiveRange: nil) as? NSFont }
}
#endif
