// DocumentText.swift
//
// Bytes <-> text for luftig documents. Foundation only (no AppKit), no document/editor dependencies.
//
//  * `TextCodec.decode` detects BOM / UTF-8 / UTF-16 / UTF-32 / legacy 8-bit and remembers BOM + line-ending style
//  * `TextCodec.encode` writes the text back in exactly the remembered format
//  * line endings: files that are *uniformly* CRLF (or CR) are normalised to LF in memory (so the editor and the
//    Markdown lexer only ever see "\n") and expanded again on save; files with mixed endings are kept literally
//    (LineEnding.mixed) and written back byte-for-byte. An unmodified round trip is always byte-identical.
//
// Measured (release, Apple M5 Pro, see docs/spike-document.md): UTF-8 -> NSString 10 MB ASCII 0.3 ms,
// 10 MB mixed (German/CJK/emoji) 15 ms; NSString -> UTF-8 10 MB 0.1 ms (ASCII, immutable string) .. 12 ms (mixed).

import Foundation

enum LineEnding: String {
    case lf, crlf, cr, mixed

    /// True when the in-memory text is normalised to "\n" (everything except `.mixed`).
    var isNormalised: Bool { self != .mixed }
}

enum TextEncodingKind: String {
    case utf8, utf16LE, utf16BE, utf32LE, utf32BE, windows1252, macRoman

    var foundation: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        case .windows1252: return .windowsCP1252
        case .macRoman: return .macOSRoman
        }
    }
    var isAsciiCompatible8Bit: Bool { self == .utf8 || self == .windows1252 || self == .macRoman }
    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .utf32LE: return "UTF-32 LE"
        case .utf32BE: return "UTF-32 BE"
        case .windows1252: return "Windows-1252"
        case .macRoman: return "Mac OS Roman"
        }
    }
}

struct TextFormat: Equatable, CustomStringConvertible {
    var encoding: TextEncodingKind = .utf8
    var hasBOM: Bool = false
    var lineEnding: LineEnding = .lf
    var description: String { "\(encoding.displayName)\(hasBOM ? "+BOM" : ""), \(lineEnding.rawValue.uppercased())" }
}

struct DecodedText {
    var text: NSString          // line endings normalised unless format.lineEnding == .mixed
    var format: TextFormat
    var byteCount: Int
}

enum LuftigError: LocalizedError, CustomNSError {
    case binaryFile
    case tooLarge(bytes: Int, limit: Int)
    case cannotDecode
    case notRepresentable(encoding: String)
    case ioError(path: String, errno: Int32)
    case notRegularFile(path: String)
    case damagedUTF8(firstInvalidByte: Int)

    static var errorDomain: String { "local.luftig.document" }
    var errorCode: Int {
        switch self {
        case .binaryFile: return 1
        case .tooLarge: return 2
        case .cannotDecode: return 3
        case .notRepresentable: return 4
        case .ioError: return 5
        case .notRegularFile: return 6
        case .damagedUTF8: return 7
        }
    }
    var errorDescription: String? {
        switch self {
        case .binaryFile: return "This file does not look like a text file."
        case .tooLarge(let b, let l):
            let f = ByteCountFormatter()
            return "This file is too large to edit (\(f.string(fromByteCount: Int64(b))); the limit is \(f.string(fromByteCount: Int64(l))))."
        case .cannotDecode: return "The file's text encoding could not be determined."
        case .notRepresentable(let e): return "The text contains characters that cannot be saved in \(e)."
        case .ioError(let p, let e): return "Could not read \((p as NSString).lastPathComponent): \(String(cString: strerror(e)))."
        case .notRegularFile(let p): return "“\((p as NSString).lastPathComponent)” is not a regular file (it is a folder, a pipe or a device)."
        case .damagedUTF8(let at): return "This file is mostly UTF-8 but contains invalid bytes (the first one at byte \(at))."
        }
    }
    /// NSDocument wraps read errors as "The document “x” could not be opened." and shows the underlying error's
    /// *failure reason* as the second line (the localizedDescription of the underlying error is not shown).
    var failureReason: String? { errorDescription }
    var recoverySuggestion: String? {
        switch self {
        case .binaryFile: return "luftig only opens plain-text and Markdown files."
        case .tooLarge: return "Open it in a tool made for very large files."
        case .notRepresentable: return "The document will be saved as UTF-8 instead."
        case .damagedUTF8: return "luftig does not open it, because showing it in another encoding would garble the text and saving would change it for good. Repair the file with another tool first."
        default: return nil
        }
    }
}

enum TextCodec {
    /// Hard limit; above this a file is refused (see LuftigError.tooLarge).
    static let maxFileBytes = 200 * 1024 * 1024
    /// How much of the file is searched for NUL bytes when deciding "binary".
    static let binarySniffBytes = 64 * 1024

    // MARK: decode

    static func decode(_ data: Data) throws -> DecodedText {
        try data.withUnsafeBytes { try decode(bytes: $0) }
    }

    static func decode(bytes: UnsafeRawBufferPointer) throws -> DecodedText {
        let n = bytes.count
        if n > maxFileBytes { throw LuftigError.tooLarge(bytes: n, limit: maxFileBytes) }
        if n == 0 { return DecodedText(text: "", format: TextFormat(), byteCount: 0) }
        let b = bytes.bindMemory(to: UInt8.self)

        // 1. BOM
        var enc: TextEncodingKind? = nil
        var bomLength = 0
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { enc = .utf8; bomLength = 3 }
        else if n >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { enc = .utf32LE; bomLength = 4 }
        else if n >= 4, b[0] == 0, b[1] == 0, b[2] == 0xFE, b[3] == 0xFF { enc = .utf32BE; bomLength = 4 }
        else if n >= 2, b[0] == 0xFF, b[1] == 0xFE { enc = .utf16LE; bomLength = 2 }
        else if n >= 2, b[0] == 0xFE, b[1] == 0xFF { enc = .utf16BE; bomLength = 2 }

        // 2. no BOM: binary / BOM-less UTF-16 detection (NUL bytes)
        if enc == nil {
            let sniff = min(n, binarySniffBytes)
            if memchr(bytes.baseAddress!, 0, sniff) != nil {
                if let guess = guessBOMlessUTF16(b, sniff) { enc = guess }
                else if !nulIsIncidental(bytes, sniff) { throw LuftigError.binaryFile }
            }
        }
        let hasBOM = bomLength > 0
        let body = UnsafeRawBufferPointer(rebasing: bytes[bomLength...])

        // 3. decode
        switch enc {
        case .utf16LE, .utf16BE, .utf32LE, .utf32BE:
            guard let s = NSString(bytes: body.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, length: body.count,
                                   encoding: enc!.foundation.rawValue) else { throw LuftigError.cannotDecode }
            let (text, le) = normaliseWideText(s)
            let decoded = DecodedText(text: text, format: TextFormat(encoding: enc!, hasBOM: hasBOM, lineEnding: le), byteCount: n)
            // Bytes in, bytes out: NSString silently drops a dangling odd byte (a truncated file) and may drop or repair other things.
            // These formats are rare, so the byte-exact round trip is simply VERIFIED; a file that would not survive it is refused
            // (nothing is lost: it stays on disk untouched) instead of being rewritten differently by the first save.
            guard (try? encode(text, format: decoded.format)).map({ $0.count == n && $0.withUnsafeBytes { memcmp($0.baseAddress!, bytes.baseAddress!, n) == 0 } }) == true
            else { throw LuftigError.cannotDecode }
            return decoded

        default:
            // 8-bit family: classify line endings on the bytes, normalise (rare) into a copy, then decode.
            let kind = classifyLineEndings(body)
            var work = body
            var owned: UnsafeMutableRawBufferPointer? = nil
            if kind == .crlf || kind == .cr {
                let out = UnsafeMutableRawBufferPointer.allocate(byteCount: max(body.count, 1), alignment: 1)
                let m = normaliseBytes(body, into: out, kind: kind)
                owned = out
                work = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(out)[0..<m])
            }
            defer { owned?.deallocate() }
            let base = work.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
            let candidates: [TextEncodingKind] = (enc == .utf8) ? [.utf8] : [.utf8, .windows1252, .macRoman]
            for cand in candidates {
                // NSString(bytes:encoding: UTF-8) is NOT a validator on this macOS: a lone 0xA9 (Latin-1 / Windows-1252 "©") decodes to U+FFFD
                // instead of failing, and the first save would write EF BF BD over it. Validate strictly first.
                if cand == .utf8, !isValidUTF8(work) {
                    // Not valid UTF-8. Either a legacy 8-bit text (Latin-1 / Windows-1252 / Mac Roman: every high byte is a lone byte) or UTF-8 that has
                    // been damaged (a stray byte pasted in, a truncated sequence). The second must NOT fall back to Windows-1252: the file would show as
                    // mojibake ("GrÃ¶ÃŸe") and the first typed character that 1252 cannot hold (an emoji, an arrow) would make the document switch to
                    // UTF-8 and write the mojibake as UTF-8: every umlaut of the file garbled for good (found by the audit). Valid multi-byte UTF-8
                    // sequences next to invalid bytes are the tell-tale; such a file is refused untouched.
                    if let bad = utf8Diagnose(body), enc == .utf8 || bad.validMultibyteSequences > 0 { throw LuftigError.damagedUTF8(firstInvalidByte: bomLength + bad.firstInvalid) }
                    continue
                }
                // (BulkDecode: Foundation's NSString(bytes:length:encoding:) leaves ~2 bytes per character of freed memory resident on macOS 27 for non-ASCII
                // texts above ~1 MB - every open and every auto-reload of such a file paid it. Small and ASCII texts still go through Foundation.)
                guard var s = BulkDecode.nsString(base, work.count, encoding: cand.foundation.rawValue, utf8: cand == .utf8) else { continue }
                // NSString also drops a leading U+FEFF of the (BOM-stripped) body: a file that starts with TWO byte order marks lost one.
                if cand == .utf8, work.count >= 3, work[0] == 0xEF, work[1] == 0xBB, work[2] == 0xBF { s = ("\u{FEFF}" + (s as String)) as NSString }
                let decoded = DecodedText(text: s, format: TextFormat(encoding: cand, hasBOM: hasBOM, lineEnding: kind), byteCount: n)
                if cand != .utf8 {
                    // legacy 8-bit: verify the round trip (cheap, small files) so that the fallback chain can never rewrite a byte
                    guard let back = try? encode(s, format: decoded.format), back.count == n,
                          back.withUnsafeBytes({ memcmp($0.baseAddress!, bytes.baseAddress!, n) == 0 }) else { continue }
                }
                return decoded
            }
            throw LuftigError.cannotDecode
        }
    }

    /// Strict UTF-8 validity (the Swift standard library's validator: 0.8 ms per 10 MB of ASCII, ~4 ms of mixed text).
    static func isValidUTF8(_ p: UnsafeRawBufferPointer) -> Bool {
        guard let base = p.baseAddress, p.count > 0 else { return true }
        var s = String(decoding: UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: p.count), as: UTF8.self)   // repairs invalid input
        return s.withUTF8 { $0.count == p.count && memcmp($0.baseAddress!, base, p.count) == 0 }                                       // ... which changes the bytes
    }

    /// For text that is NOT valid UTF-8: offset of the first byte that does not belong to a well-formed sequence and how many well-formed multi-byte
    /// sequences the buffer holds. nil when it is valid. Only called on the (rare) failure path.
    static func utf8Diagnose(_ p: UnsafeRawBufferPointer) -> (firstInvalid: Int, validMultibyteSequences: Int)? {
        let b = p.bindMemory(to: UInt8.self)
        let n = b.count
        var i = 0, multi = 0
        var firstInvalid = -1
        @inline(__always) func cont(_ k: Int, _ lo: UInt8 = 0x80, _ hi: UInt8 = 0xBF) -> Bool { k < n && b[k] >= lo && b[k] <= hi }
        while i < n {
            let c = b[i]
            if c < 0x80 { i += 1; continue }
            var len = 0
            switch c {
            case 0xC2...0xDF: if cont(i + 1) { len = 2 }
            case 0xE0: if cont(i + 1, 0xA0, 0xBF) && cont(i + 2) { len = 3 }
            case 0xE1...0xEC, 0xEE...0xEF: if cont(i + 1) && cont(i + 2) { len = 3 }
            case 0xED: if cont(i + 1, 0x80, 0x9F) && cont(i + 2) { len = 3 }
            case 0xF0: if cont(i + 1, 0x90, 0xBF) && cont(i + 2) && cont(i + 3) { len = 4 }
            case 0xF1...0xF3: if cont(i + 1) && cont(i + 2) && cont(i + 3) { len = 4 }
            case 0xF4: if cont(i + 1, 0x80, 0x8F) && cont(i + 2) && cont(i + 3) { len = 4 }
            default: break
            }
            if len == 0 { if firstInvalid < 0 { firstInvalid = i }; i += 1 } else { multi += 1; i += len }
        }
        return firstInvalid < 0 ? nil : (firstInvalid, multi)
    }

    /// True when the NULs in the sniffed region are incidental: a handful (<= 4) or at most 1 % of the bytes, and the region is otherwise valid UTF-8
    /// (a stray U+0000 that was typed or pasted - luftig itself writes it back as a NUL byte, so it must be able to read such a file again).
    /// Binary data (images, archives, executables, random bytes) is not valid UTF-8 or is full of NULs.
    private static func nulIsIncidental(_ bytes: UnsafeRawBufferPointer, _ sniff: Int) -> Bool {
        let b = bytes.bindMemory(to: UInt8.self)
        var nuls = 0
        for i in 0..<sniff where b[i] == 0 { nuls += 1 }
        guard nuls <= 4 || nuls * 100 <= sniff else { return false }
        var end = sniff
        if end < b.count {                      // the region is only a prefix of the file: do not judge a multi-byte sequence it cuts in two
            var k = end
            while k > 0, end - k < 3, (b[k - 1] & 0xC0) == 0x80 { k -= 1 }      // trailing continuation bytes ...
            if k > 0, b[k - 1] >= 0xC0 { end = k - 1 }                            // ... and their lead byte
        }
        return isValidUTF8(UnsafeRawBufferPointer(rebasing: bytes[0..<end]))
    }

    /// Heuristic for UTF-16 without BOM: lots of NULs, strongly on one parity.
    private static func guessBOMlessUTF16(_ b: UnsafeBufferPointer<UInt8>, _ sniff: Int) -> TextEncodingKind? {
        guard sniff >= 4 else { return nil }
        var even = 0, odd = 0
        for i in 0..<sniff where b[i] == 0 { if i & 1 == 0 { even += 1 } else { odd += 1 } }
        let pairs = sniff / 2
        if odd * 10 > pairs * 3 && even * 50 < pairs { return .utf16LE }   // "A\0B\0": NUL on odd offsets
        if even * 10 > pairs * 3 && odd * 50 < pairs { return .utf16BE }
        return nil
    }

    /// Scans for CR. No CR at all (the overwhelmingly common case) costs one memchr.
    static func classifyLineEndings(_ p: UnsafeRawBufferPointer) -> LineEnding {
        guard let base = p.baseAddress, p.count > 0, memchr(base, 13, p.count) != nil else { return .lf }
        let b = p.bindMemory(to: UInt8.self)
        var crlf = 0, loneCR = 0, loneLF = 0
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c == 13 {
                if i + 1 < n, b[i + 1] == 10 { crlf += 1; i += 2; continue }
                loneCR += 1
            } else if c == 10 { loneLF += 1 }
            i += 1
        }
        if crlf > 0 && loneCR == 0 && loneLF == 0 { return .crlf }
        if loneCR > 0 && crlf == 0 && loneLF == 0 { return .cr }
        if crlf == 0 && loneCR == 0 { return .lf }
        return .mixed
    }

    /// CRLF -> LF or CR -> LF into `out` (capacity >= input). Returns the number of bytes written.
    private static func normaliseBytes(_ p: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer, kind: LineEnding) -> Int {
        let src = p.bindMemory(to: UInt8.self)
        let dst = out.bindMemory(to: UInt8.self)
        var o = 0
        if kind == .cr {
            for i in 0..<src.count { dst[i] = src[i] == 13 ? 10 : src[i] }
            return src.count
        }
        var i = 0
        let n = src.count
        while i < n {
            // copy up to the next CR in one memcpy
            let rest = n - i
            if let hit = memchr(src.baseAddress! + i, 13, rest) {
                let run = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - (src.baseAddress! + i)
                if run > 0 { memcpy(dst.baseAddress! + o, src.baseAddress! + i, run); o += run; i += run }
                i += 1   // skip the CR (it is always followed by LF in a pure-CRLF file)
            } else {
                memcpy(dst.baseAddress! + o, src.baseAddress! + i, rest); o += rest; i = n
            }
        }
        return o
    }

    /// Line endings of a UTF-16/32 text that has already been decoded (rare formats: simple + slower path).
    private static func normaliseWideText(_ s: NSString) -> (NSString, LineEnding) {
        let n = s.length
        if s.range(of: "\r").location == NSNotFound { return (s, .lf) }
        var units = [unichar](repeating: 0, count: n)
        s.getCharacters(&units, range: NSRange(location: 0, length: n))
        var crlf = 0, loneCR = 0, loneLF = 0, i = 0
        while i < n {
            if units[i] == 13 { if i + 1 < n, units[i + 1] == 10 { crlf += 1; i += 2; continue }; loneCR += 1 }
            else if units[i] == 10 { loneLF += 1 }
            i += 1
        }
        let kind: LineEnding
        if crlf > 0 && loneCR == 0 && loneLF == 0 { kind = .crlf }
        else if loneCR > 0 && crlf == 0 && loneLF == 0 { kind = .cr }
        else if crlf == 0 && loneCR == 0 { kind = .lf }
        else { kind = .mixed }
        switch kind {
        case .crlf:
            var out = [unichar](); out.reserveCapacity(n)
            i = 0
            while i < n { if units[i] == 13, i + 1 < n, units[i + 1] == 10 { i += 1; continue }; out.append(units[i]); i += 1 }
            return (NSString(characters: out, length: out.count), kind)
        case .cr:
            for j in 0..<n where units[j] == 13 { units[j] = 10 }
            return (NSString(characters: units, length: n), kind)
        default:
            return (s, kind)
        }
    }

    // MARK: encode

    /// `text` is the editor's text (LF only unless format.lineEnding == .mixed). Returns the exact bytes to write.
    /// Throws LuftigError.notRepresentable if a legacy encoding cannot hold the characters (caller: fall back to UTF-8).
    static func encode(_ text: NSString, format: TextFormat) throws -> Data {
        var body: Data
        switch format.encoding {
        case .utf8:
            guard var d = utf8Bytes(text) else { throw LuftigError.notRepresentable(encoding: "UTF-8") }
            // Stray CRs in a normalised document (pasted CRLF text) would double up when expanding: fold them to LF.
            // Checked on the BYTES (memchr, ~0 ms): NSString.range(of:"\r") on a 10 MB text storage costs 40 ms.
            if format.lineEnding.isNormalised, d.withUnsafeBytes({ $0.count > 0 && memchr($0.baseAddress!, 13, $0.count) != nil }) {
                d = foldCRtoLF(d)
            }
            if format.lineEnding == .crlf { d = expandLFtoCRLF(d) } else if format.lineEnding == .cr { d = replaceLFwithCR(d) }
            body = d
        default:
            var t = text
            if format.lineEnding.isNormalised, text.range(of: "\r").location != NSNotFound {
                t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") as NSString
            }
            var s: NSString = t
            if format.lineEnding == .crlf { s = t.replacingOccurrences(of: "\n", with: "\r\n") as NSString }
            else if format.lineEnding == .cr { s = t.replacingOccurrences(of: "\n", with: "\r") as NSString }
            guard let d = s.data(using: format.encoding.foundation.rawValue) else {
                throw LuftigError.notRepresentable(encoding: format.encoding.displayName)
            }
            body = d
        }
        guard format.hasBOM else { return body }
        var out = Data(capacity: body.count + 4)
        switch format.encoding {
        case .utf8: out.append(contentsOf: [0xEF, 0xBB, 0xBF])
        case .utf16LE: out.append(contentsOf: [0xFF, 0xFE])
        case .utf16BE: out.append(contentsOf: [0xFE, 0xFF])
        case .utf32LE: out.append(contentsOf: [0xFF, 0xFE, 0, 0])
        case .utf32BE: out.append(contentsOf: [0, 0, 0xFE, 0xFF])
        default: break
        }
        out.append(body)
        return out
    }

    /// UTF-8 bytes of an NSString. Chunked CFStringGetBytes: 2.4x faster than `data(using:)` on an NSTextStorage's
    /// string (10 MB: 6-8 ms vs 14-18 ms). nil if the text contains a lone surrogate (not representable).
    static func utf8Bytes(_ s: NSString) -> Data? {
        let n = s.length
        if n == 0 { return Data() }
        let chunk = 1 << 20
        let cap = chunk * 3 + 16
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { buf.deallocate() }
        var out = Data()
        out.reserveCapacity(n + n / 8)
        var loc = 0
        while loc < n {
            var len = min(chunk, n - loc)
            if len < n - loc, UTF16.isLeadSurrogate(s.character(at: loc + len - 1)) { len -= 1 }     // never split a pair
            var used = 0
            let ok = s.getBytes(buf, maxLength: cap, usedLength: &used, encoding: String.Encoding.utf8.rawValue,
                                options: [], range: NSRange(location: loc, length: len), remaining: nil)
            if !ok { return s.data(using: String.Encoding.utf8.rawValue) }     // nil for lone surrogates
            out.append(buf, count: used)
            loc += len
        }
        return out
    }

    /// CRLF and lone CR -> LF on UTF-8 bytes.
    static func foldCRtoLF(_ d: Data) -> Data {
        var out = Data(capacity: d.count)
        d.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                if b[i] == 13 { out.append(10); if i + 1 < b.count, b[i + 1] == 10 { i += 1 } }
                else { out.append(b[i]) }
                i += 1
            }
        }
        return out
    }

    static func expandLFtoCRLF(_ d: Data) -> Data {
        let n = d.count
        if n == 0 { return d }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let sb = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // pass 1: count LFs (memchr hops)
            var lfs = 0
            var p = 0
            while p < n {
                guard let hit = memchr(sb + p, 10, n - p) else { break }
                lfs += 1
                p = UnsafeRawPointer(sb).distance(to: UnsafeRawPointer(hit)) + 1
            }
            if lfs == 0 { return d }
            // pass 2: copy runs, inserting CR before each LF
            let out = UnsafeMutablePointer<UInt8>.allocate(capacity: n + lfs)
            var i = 0, w = 0
            while i < n {
                if let hit = memchr(sb + i, 10, n - i) {
                    let run = UnsafeRawPointer(sb + i).distance(to: UnsafeRawPointer(hit))
                    memcpy(out + w, sb + i, run); w += run; i += run
                    out[w] = 13; out[w + 1] = 10; w += 2; i += 1
                } else {
                    memcpy(out + w, sb + i, n - i); w += n - i; i = n
                }
            }
            return Data(bytesNoCopy: out, count: w, deallocator: .custom { ptr, _ in ptr.deallocate() })
        }
    }

    static func replaceLFwithCR(_ d: Data) -> Data {
        var out = d
        out.withUnsafeMutableBytes { o in
            let b = o.bindMemory(to: UInt8.self)
            for i in 0..<b.count where b[i] == 10 { b[i] = 13 }
        }
        return out
    }
}
