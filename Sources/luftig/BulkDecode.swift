// BulkDecode.swift - bytes -> NSString for big non-ASCII texts, without `NSString(bytes:length:encoding:)`.
//
// Why: on macOS 27.0.1 (26A434) every `NSString(bytes:length:encoding:)` of a NON-ASCII text above ~1-2 MB leaves ~2 bytes per character of freed memory
// resident for ever ("Malloc Large (empty)" in vmmap, nothing in `leaks`; +430 MB after 45 decodes of a 5 MB file in a 30-line standalone program; none for
// ASCII-only texts or texts <= 1 MB). Every open and every auto-reload of such a file leaked 2 bytes per character (a 20 MB document: ~40 MB per open).
//
//   * <= 1 MB or pure ASCII: Foundation as before (an ASCII text stays an 8-bit string: half the memory, 0.1 ms per MB).
//   * well-formed UTF-8: a validating transcoder with an ASCII fast path into ONE malloc'ed UTF-16 buffer that the result adopts (`freeWhenDone`):
//     20 MB of real Markdown 6.4 ms instead of 33-50 ms, identical result (differential-tested), no leak.
//   * anything else (invalid UTF-8 so that the caller can try the next encoding, windows-1252, MacRoman): Foundation in 256 KB slices
//     (far below the size where it misbehaves) into the same kind of buffer. A slice never starts with EF BB BF (Foundation drops a BOM at the
//     start of ITS input), so the pieces concatenate to exactly what one call would have produced; invalid input is nil, as before.
import Foundation

enum BulkDecode {
    static let sliceBytes = 256 * 1024
    static let threshold = 1 << 20

    /// 32 bytes at a time; true when no byte is >= 0x80.
    static func isASCII(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        var acc: UInt64 = 0
        while i + 32 <= n {
            let q = UnsafeRawPointer(p + i)
            acc |= q.loadUnaligned(as: UInt64.self) | q.loadUnaligned(fromByteOffset: 8, as: UInt64.self) | q.loadUnaligned(fromByteOffset: 16, as: UInt64.self) | q.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            if acc & 0x8080_8080_8080_8080 != 0 { return false }
            i += 32
        }
        while i < n { if p[i] >= 0x80 { return false }; i += 1 }
        return true
    }

    static func nsString(_ base: UnsafeRawPointer, _ n: Int, encoding: UInt, utf8: Bool) -> NSString? {
        let b = base.assumingMemoryBound(to: UInt8.self)
        if n <= threshold || isASCII(b, n) { return NSString(bytes: base, length: n, encoding: encoding) }
        guard let raw = malloc(n * 2 + 16) else { return NSString(bytes: base, length: n, encoding: encoding) }
        let out = raw.bindMemory(to: unichar.self, capacity: n + 8)
        var o = 0
        if utf8, let units = transcodeUTF8(b, n, out) {
            o = units
        } else {
            // Foundation in slices
            var i = 0
            o = 0
            while i < n {
                var end = min(n, i + sliceBytes)
                if end < n, utf8 {
                    // cut BEFORE a newline when there is one in the last 16 KB (a line start is never a continuation byte and the next slice then starts with
                    // "\n", never with a BOM); otherwise at a character boundary that is not followed by EF BB BF.
                    var e = end
                    let floor = max(i + 1, end - 16 * 1024)
                    while e > floor && b[e] != 0x0A { e -= 1 }
                    if b[e] == 0x0A && e > i { end = e }
                    else {
                        while end > i + 1 && ((b[end] & 0xC0) == 0x80 || (b[end] == 0xEF && end + 2 < n && b[end + 1] == 0xBB && b[end + 2] == 0xBF)) { end -= 1 }
                        if end <= i { free(raw); return NSString(bytes: base, length: n, encoding: encoding) }   // only continuation bytes: let Foundation decide
                    }
                }
                guard let s = NSString(bytes: base + i, length: end - i, encoding: encoding) else { free(raw); return nil }
                let len = s.length
                s.getCharacters(out + o, range: NSRange(location: 0, length: len))
                o += len; i = end
            }
        }
        if o < n - n / 4, let r = realloc(raw, max(o, 1) * 2) { return NSString(charactersNoCopy: r.bindMemory(to: unichar.self, capacity: o), length: o, freeWhenDone: true) }
        return NSString(charactersNoCopy: out, length: o, freeWhenDone: true)
    }

    /// Strict (Unicode Table 3-7) UTF-8 -> UTF-16. Returns the number of units written, or nil for anything that is not well-formed (overlong forms,
    /// surrogates, > U+10FFFF, truncated sequences): the caller then lets Foundation decide. A leading EF BB BF is dropped like Foundation does.
    static func transcodeUTF8(_ b: UnsafePointer<UInt8>, _ n: Int, _ out: UnsafeMutablePointer<unichar>) -> Int? {
        var i = 0, o = 0
        if n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { i = 3 }
        while i < n {
            while i + 8 <= n {                                           // ASCII run, 8 bytes at a time
                let w = UnsafeRawPointer(b + i).loadUnaligned(as: UInt64.self)
                if w & 0x8080_8080_8080_8080 != 0 { break }
                out[o] = unichar(w & 0xFF); out[o + 1] = unichar((w >> 8) & 0xFF); out[o + 2] = unichar((w >> 16) & 0xFF); out[o + 3] = unichar((w >> 24) & 0xFF)
                out[o + 4] = unichar((w >> 32) & 0xFF); out[o + 5] = unichar((w >> 40) & 0xFF); out[o + 6] = unichar((w >> 48) & 0xFF); out[o + 7] = unichar(w >> 56)
                i += 8; o += 8
            }
            if i >= n { break }
            let c = b[i]
            if c < 0x80 { out[o] = unichar(c); i += 1; o += 1; continue }
            if c < 0xC2 { return nil }                                   // continuation byte, or overlong 2-byte lead (C0, C1)
            if c < 0xE0 {
                if i + 1 >= n { return nil }
                let c1 = b[i + 1]; if c1 & 0xC0 != 0x80 { return nil }
                out[o] = (unichar(c & 0x1F) << 6) | unichar(c1 & 0x3F); i += 2; o += 1
            } else if c < 0xF0 {
                if i + 2 >= n { return nil }
                let c1 = b[i + 1], c2 = b[i + 2]
                if c1 & 0xC0 != 0x80 || c2 & 0xC0 != 0x80 { return nil }
                if c == 0xE0 && c1 < 0xA0 { return nil }                 // overlong
                if c == 0xED && c1 >= 0xA0 { return nil }                // surrogate
                out[o] = (unichar(c & 0x0F) << 12) | (unichar(c1 & 0x3F) << 6) | unichar(c2 & 0x3F); i += 3; o += 1
            } else if c < 0xF5 {
                if i + 3 >= n { return nil }
                let c1 = b[i + 1], c2 = b[i + 2], c3 = b[i + 3]
                if c1 & 0xC0 != 0x80 || c2 & 0xC0 != 0x80 || c3 & 0xC0 != 0x80 { return nil }
                if c == 0xF0 && c1 < 0x90 { return nil }                 // overlong
                if c == 0xF4 && c1 >= 0x90 { return nil }                // > U+10FFFF
                let v = ((UInt32(c & 0x07) << 18) | (UInt32(c1 & 0x3F) << 12) | (UInt32(c2 & 0x3F) << 6) | UInt32(c3 & 0x3F)) - 0x10000
                out[o] = unichar(0xD800 + (v >> 10)); out[o + 1] = unichar(0xDC00 + (v & 0x3FF)); i += 4; o += 2
            } else { return nil }
        }
        return o
    }
}
