// DiskFile.swift
//
// Low-level, Foundation-only helpers for "what is on disk right now":
//   * FileSignature   - identity + cheap change fingerprint of a file (dev, inode, size, mtime, ctime)
//   * FastHash        - 64-bit non-cryptographic content hash, ~10 GB/s
//   * DiskReader      - race-aware whole-file read (plain read(2), NOT mmap: see note)
//
// Why ctime is in the signature: the "nasty" external writer that rewrites a file in place with the same size and
// then restores the old mtime (`touch -r`, rsync -t, some build tools, cp -p) cannot restore ctime - the kernel sets it
// on every write/chmod/rename/link. (dev, inode, size, mtime, ctime) therefore catches every content change that
// `stat` can possibly see; the content hash then decides whether the *content* really changed (chmod/touch only
// change the signature).
//
// Why read(2) and not mmap: a mapped file that gets truncated by another process while we are decoding it kills the
// process with SIGBUS. Measured cost of read(2) into a malloc buffer for 10 MB from the page cache: ~0.3 ms.
// mmap saves ~0.25 ms and costs a crash when an editor/build tool truncates the file. Not worth it.

import Foundation

struct FileSignature: Equatable, CustomStringConvertible {
    var device: Int32
    var inode: UInt64
    var size: Int64
    var mtimeSec: Int64, mtimeNsec: Int64
    var ctimeSec: Int64, ctimeNsec: Int64

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        size = Int64(st.st_size)
        mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNsec = Int64(st.st_mtimespec.tv_nsec)
        ctimeSec = Int64(st.st_ctimespec.tv_sec); ctimeNsec = Int64(st.st_ctimespec.tv_nsec)
    }

    /// stat(2) (follows a symlink at the last component). nil if the path does not exist / is not accessible.
    static func of(path: String) -> FileSignature? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileSignature(st)
    }
    static func of(fd: Int32) -> FileSignature? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return FileSignature(st)
    }

    var modificationDate: Date { Date(timeIntervalSince1970: Double(mtimeSec) + Double(mtimeNsec) / 1e9) }
    var description: String { "dev=\(device) ino=\(inode) size=\(size) mtime=\(mtimeSec).\(String(format: "%09ld", mtimeNsec)) ctime=\(ctimeSec).\(String(format: "%09ld", ctimeNsec))" }
}

enum FastHash {
    /// 4-lane multiply/rotate hash over 32-byte blocks + a mixed tail. Non-cryptographic; collisions in a
    /// "did the file change" test are ~2^-64 per comparison.
    static func hash64(_ p: UnsafeRawBufferPointer) -> UInt64 {
        let n = p.count
        let k1: UInt64 = 0x9E37_79B1_85EB_CA87, k2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
        let k3: UInt64 = 0x1656_67B1_9E37_79F9, k4: UInt64 = 0x85EB_CA77_C2B2_AE63
        var a = UInt64(n) &* k1, b = k2, c = k3, d = k4
        var i = 0
        @inline(__always) func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
        if let base = p.baseAddress {
            while i + 32 <= n {
                let w0 = base.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                let w1 = base.loadUnaligned(fromByteOffset: i + 8, as: UInt64.self)
                let w2 = base.loadUnaligned(fromByteOffset: i + 16, as: UInt64.self)
                let w3 = base.loadUnaligned(fromByteOffset: i + 24, as: UInt64.self)
                a = rotl(a ^ (w0 &* k2), 31) &* k1
                b = rotl(b ^ (w1 &* k2), 31) &* k1
                c = rotl(c ^ (w2 &* k2), 31) &* k1
                d = rotl(d ^ (w3 &* k2), 31) &* k1
                i += 32
            }
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while i < n {
                tail |= UInt64(base.load(fromByteOffset: i, as: UInt8.self)) << shift
                shift += 8
                if shift == 64 { a = rotl(a ^ (tail &* k2), 31) &* k1; tail = 0; shift = 0 }
                i += 1
            }
            if shift > 0 { b = rotl(b ^ (tail &* k2), 31) &* k1 }
        }
        var h = rotl(a, 1) &+ rotl(b, 7) &+ rotl(c, 12) &+ rotl(d, 18)
        h ^= h >> 33; h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33; h = h &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return h
    }
}

/// What we believe is on disk: fingerprint + content hash of the bytes we last read or wrote.
struct DiskState: Equatable {
    var signature: FileSignature
    var hash: UInt64
    var byteCount: Int
}

enum DiskReader {
    /// Reads the whole file with read(2). The returned signature is the one *after* the read, taken from the same
    /// descriptor, and the read is retried (<= `attempts`) while the file changes underneath us (a writer in progress).
    static func readFile(path: String, maxBytes: Int = TextCodec.maxFileBytes, attempts: Int = 4) throws -> (data: Data, signature: FileSignature) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw ScribeError.ioError(path: path, errno: errno) }
        defer { close(fd) }
        var last: (Data, FileSignature)? = nil
        for attempt in 0..<max(1, attempts) {
            guard let before = FileSignature.of(fd: fd) else { throw ScribeError.ioError(path: path, errno: errno) }
            if before.size > Int64(maxBytes) { throw ScribeError.tooLarge(bytes: Int(before.size), limit: maxBytes) }
            let want = Int(before.size)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(want, 1), alignment: 16)
            var got = 0
            while got < want {
                let r = pread(fd, buf + got, want - got, off_t(got))
                if r < 0 { if errno == EINTR { continue }; let e = errno; buf.deallocate(); throw ScribeError.ioError(path: path, errno: e) }
                if r == 0 { break }                       // file shrank while reading
                got += r
            }
            let data = Data(bytesNoCopy: buf, count: got, deallocator: .custom { p, _ in p.deallocate() })
            guard let after = FileSignature.of(fd: fd) else { throw ScribeError.ioError(path: path, errno: errno) }
            last = (data, after)
            if after == before && got == want { return (data, after) }
            if attempt + 1 < attempts { usleep(15_000) }   // somebody is writing: let them finish
        }
        return (last!.0, last!.1)
    }

    static func state(of data: Data, signature: FileSignature) -> DiskState {
        let h = data.withUnsafeBytes { FastHash.hash64($0) }
        return DiskState(signature: signature, hash: h, byteCount: data.count)
    }
}
