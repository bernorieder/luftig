#if LUFTIG_SELFTEST
// SelfTestRobust.swift - robustness scenarios (adversarial review): registry + shared infrastructure.
//
//   monkey           seeded random-action driver over several documents / windows (SelfTestRobustMonkey.swift)
//   leaks            open/close documents in bulk: instances, file descriptors, threads, memory must return to baseline (SelfTestRobustLeaks.swift)
//   leaks-bisect     which user action leaves a closed document's objects alive? (SelfTestRobustLeaks.swift, by name only)
//   hostile          binary / enormous / pathological files through the real open path, main-thread stall per step (SelfTestRobustHostile.swift)
//   resource-policy  memory per MB of text, the 200 MB limit (never opened: refused from fstat), 3 x 20 MB, one 60 MB document (SelfTestRobustHostile.swift)
//   storm            thousands of external-change events: touch / append / atomic replace / whole-file swap (SelfTestRobustHostile.swift)
//   reader-race      DiskReader.readFile against a writer that shrinks and regrows the file (SelfTestRobustHostile.swift)
//   robust-regress   one check group per DEFECT found (each FAILS on the baseline, passes with the suggested fix; --known adds the unfixed ones)
//   robust-probe     throw-away experiments behind the findings (--probe symlink|keepunreadable|bigcycles|quickclose|coldmiddle|symdir|wcclose|inflight)
//
// `--selftest all` runs only a short smoke subset of each (3 seeds x 300 steps, 12 x 1 MB, small hostile cases, ...). Everything heavy is explicit:
//   --selftest monkey --seed 7 --steps 2000 --docs 3 [--seeds 30] [--script actions.jsonl] [--log out.jsonl] [--trace] [--watch-slot N --watch-from STEP]
//                     [--nul] [--symlinks] [--no-exotic] [--autosave-delay 3]
//   --selftest leaks --docs 300 --big 30 [--close-modes 1,2] [--leaks-tool]
//   --selftest hostile --cases name1,name2 | all | list [--strict]
//   --selftest resource-policy --full
//   --selftest storm --events 5000 --size 1,20 --kinds touch,append,atomic,swap [--vmmap]
//   --selftest reader-race --reads 1500
//   --selftest robust-regress [--known] [--only textkit-leak,nul-save,utf16-odd,close-missing,symlink-save,undo-merge]
// Scripts/robust-soak.sh drives many seeds / cases, one process each, so that a crash or hang is attributed to its seed / case.
//
// SAFETY (this suite once wedged filecoordinationd machine-wide with a named pipe swapped in for an open document's file): REGULAR FILES ONLY
// (and symlinks to regular files). No FIFOs, devices, sockets, mounts, network or File Provider locations anywhere in these files; documents
// are <= 20 MB (one 60 MB document in resource-policy, a 200 MB limit test that never opens or reads the file); no line > 5 MB.
//
// The main thread is watched by RobustWatchdog: a hang (no run-loop tick for `hangLimitMs`) is turned into a report with a `sample` of the process
// and exit status 3; a crash (signal) prints the label of the step in flight and a backtrace (exit 134).

import AppKit
import Darwin
import MarkdownKit
import os

extension SelfTestScenarios {
    static let robustScenarios: [SelfTest.Scenario] = [
        .init(name: "monkey", summary: "seeded random actions over several documents (type, undo, paste, scroll, resize, save, close, external writers, conflicts); invariants after every step. --seed N --steps M --docs K [--seeds S] [--script f]",
              run: Robust.scoped { t in try await Robust.monkey(t) }),
        .init(name: "leaks", summary: "open/close documents in bulk: live instances, file descriptors, threads, memory back to baseline. --docs N --big M",
              run: Robust.scoped { t in try await Robust.leaks(t) }),
        .init(name: "leaks-bisect", summary: "which user action makes a closed document stay alive? one open/act/close round per action, weak references afterwards",
              run: Robust.scoped { t in try await Robust.leaksBisect(t) }, inAll: false),
        .init(name: "hostile", summary: "binary / enormous / pathological regular files through the open path with main-thread stall measurement. --cases a,b | all | list",
              run: Robust.scoped { t in try await Robust.hostile(t) }),
        .init(name: "resource-policy", summary: "RSS per MB of text, the 200 MB limit (refused from fstat, never opened), 3 x 20 MB open at once, one 60 MB document (--full for the heavy part)",
              run: Robust.scoped { t in try await Robust.resourcePolicy(t) }),
        .init(name: "storm", summary: "thousands of external-change events (touch / append / atomic replace / whole-file swap) against open documents: stall, check rate, final consistency. --events N --size 1,20 --kinds ...",
              run: Robust.scoped { t in try await Robust.storm(t) }),
        .init(name: "reader-race", summary: "DiskReader.readFile in a loop while another process truncates and regrows the file. --reads N",
              run: Robust.scoped { t in try await Robust.readerRace(t) }),
        .init(name: "robust-probe", summary: "throw-away experiments (--probe name)", run: Robust.scoped { t in try await Robust.probe(t) }, inAll: false),
        // one group per defect the robustness review found (each failed before its fix); --known adds the defects that are reported but not fixed (they fail on purpose)
        .init(name: "robust-regress", summary: "one check group per defect found by the robustness review and fixed since; --known adds the reported-only ones (they fail on purpose)",
              run: Robust.scoped { t in try await Robust.regress(t) }),
    ]
}

enum Robust {

    /// A robust scenario leaves nothing running behind it: the watchdog's 1 ms heartbeat would otherwise cost a few percent of a core for the rest of
    /// the process, and fail the idle-CPU measurements of every scenario that runs after it in `--selftest all`.
    static func scoped(_ body: @escaping @MainActor (SelfTest.T) async throws -> Void) -> @MainActor (SelfTest.T) async throws -> Void {
        { t in defer { RobustWatchdog.shared.stop() }; try await body(t) }
    }

    /// True when the scenario runs as part of `--selftest all` (short smoke subset) rather than by name.
    static var isSmoke: Bool {
        if SelfTest.argument("selftest") == "all" { return true }
        return false
    }

    static func intArg(_ name: String, smoke: Int, full: Int) -> Int {
        if let v = SelfTest.argument(name).flatMap({ Int($0) }) { return v }
        return isSmoke ? smoke : full
    }

    static func now() -> Double { SelfTest.nowMs() }

    /// A check for a defect that the review REPORTED (robust-regress proves it and verifies its fix). Inside `--selftest all` (the smoke run) a failure is
    /// only a note, so that the suite stays green on the baseline; by name (`--selftest leaks ...`) or with `--strict` it is a hard check.
    @MainActor static func checkKnown(_ t: SelfTest.T, _ cond: @autoclosure () -> Bool, _ msg: @autoclosure () -> String, defect: String, line: Int = #line) {
        if isSmoke && !SelfTest.flag("strict") {
            let ok = cond()
            if ok { t.check(true, msg(), line: line) } else { t.note("KNOWN DEFECT '\(defect)' (reproduced and fixed in robust-regress): \(msg())") }
        } else {
            t.check(cond(), msg(), line: line)
        }
    }

    /// Wall time (ms) of a synchronous block.
    @discardableResult
    static func time(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
    }
}

// MARK: - process resources

enum RobustResources {
    /// Open file descriptors of this process (proc_pidinfo), total and by kind.
    struct FDs { var total = 0; var vnode = 0; var kqueue = 0; var pipe = 0; var socket = 0; var other = 0 }

    static func fds() -> FDs {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return FDs() }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride + 16
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buf, Int32(count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return FDs() }
        var r = FDs()
        for i in 0..<(Int(got) / MemoryLayout<proc_fdinfo>.stride) {
            r.total += 1
            switch Int32(buf[i].proc_fdtype) {
            case PROX_FDTYPE_VNODE: r.vnode += 1
            case PROX_FDTYPE_KQUEUE: r.kqueue += 1
            case PROX_FDTYPE_PIPE: r.pipe += 1
            case PROX_FDTYPE_SOCKET: r.socket += 1
            default: r.other += 1
            }
        }
        return r
    }

    /// One line per open descriptor: "fd:kind[:path]" (path for vnodes), for diffs between two moments.
    static func fdList() -> [String] {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride + 16
        var buf = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &buf, Int32(count * MemoryLayout<proc_fdinfo>.stride))
        guard got > 0 else { return [] }
        var lines: [String] = []
        for i in 0..<(Int(got) / MemoryLayout<proc_fdinfo>.stride) {
            let fd = buf[i].proc_fd
            switch Int32(buf[i].proc_fdtype) {
            case PROX_FDTYPE_VNODE:
                var vi = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &vi, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                let path = r > 0 ? withUnsafePointer(to: &vi.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } } : "?"
                lines.append("\(fd):vnode:\(path)")
            case PROX_FDTYPE_KQUEUE: lines.append("\(fd):kqueue")
            case PROX_FDTYPE_PIPE: lines.append("\(fd):pipe")
            case PROX_FDTYPE_SOCKET:
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                if r > 0 {
                    let fam = si.psi.soi_family, kind = si.psi.soi_kind
                    var detail = "family \(fam) kind \(kind)"
                    if fam == 1 {          // family 1: a local (unix-domain) socket - only DESCRIBED here, this suite never creates one
                        detail += " unix path '" + withUnsafePointer(to: &si.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { String(cString: $0) } } + "'"
                        detail += " peer '" + withUnsafePointer(to: &si.psi.soi_proto.pri_un.unsi_caddr.ua_sun.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { String(cString: $0) } } + "'"
                    }
                    lines.append("\(fd):socket[\(detail)]")
                } else { lines.append("\(fd):socket") }
            default: lines.append("\(fd):other(\(buf[i].proc_fdtype))")
            }
        }
        return lines
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let l = list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: l)), vm_size_t(Int(n) * MemoryLayout<thread_act_t>.stride))
        return Int(n)
    }

    static func machPortCount() -> Int {
        var names: mach_port_name_array_t?
        var nc: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var tc: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &nc, &types, &tc) == KERN_SUCCESS else { return 0 }
        if let n = names { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: n)), vm_size_t(Int(nc) * MemoryLayout<mach_port_name_t>.stride)) }
        if let ty = types { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ty)), vm_size_t(Int(tc) * MemoryLayout<mach_port_type_t>.stride)) }
        return Int(nc)
    }

    /// Physical footprint (what Activity Monitor calls "Memory"): resident + compressed dirty pages.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func rss() -> Int { ProcessMetrics.residentBytes() }

    /// Bytes the malloc zones report as IN USE (live blocks), summed over all zones. Footprint minus this is what the allocator holds on to
    /// (free lists, dirty pages not yet returned) or what is not malloc at all (VM allocations, IOSurfaces, fonts...).
    static func heapInUse() -> Int {
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS, let zones else { return 0 }
        var total = 0
        for i in 0..<Int(count) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[i])) else { continue }
            var st = malloc_statistics_t()
            malloc_zone_statistics(zone, &st)
            total += Int(st.size_in_use)
        }
        return total
    }

    /// The "Malloc Large (empty)" row of `vmmap -summary` for this process: freed large blocks libmalloc keeps mapped (and, as it turns out, dirty).
    /// Returns "virtual / resident / dirty" text, or nil when vmmap is not allowed to look at the process.
    static func vmmapLargeEmpty() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap"); p.arguments = ["-summary", "\(getpid())"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("Malloc Large (empty)") }) else { return nil }
        return line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(3).joined(separator: " ")
    }

    /// Asks every malloc zone to give free pages back to the OS; returns the bytes released (best effort).
    @discardableResult static func pressureRelief() -> Int { Int(malloc_zone_pressure_relief(nil, 0)) }

    static func mb(_ b: Int) -> Double { Double(b) / 1_048_576 }
    static func mbs(_ b: Int) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

    /// Snapshot used by the leak / policy scenarios.
    struct Snapshot {
        var rss = 0, footprint = 0, heap = 0, fds = FDs(), threads = 0, ports = 0, presenters = 0, documents = 0, windows = 0
        var description: String {
            "rss \(mbs(rss)) footprint \(mbs(footprint)) malloc-in-use \(mbs(heap)) fds \(fds.total) (vnode \(fds.vnode) kqueue \(fds.kqueue) pipe \(fds.pipe)) threads \(threads) ports \(ports) presenters \(presenters) docs \(documents) windows \(windows)"
        }
    }
    @MainActor static func snapshot() -> Snapshot {
        var s = Snapshot()
        s.rss = rss(); s.footprint = footprint(); s.heap = heapInUse(); s.fds = fds(); s.threads = threadCount(); s.ports = machPortCount()
        s.presenters = NSFileCoordinator.filePresenters.count
        s.documents = NSDocumentController.shared.documents.count
        s.windows = NSApp.windows.count
        return s
    }
}

// MARK: - preferences of the self-test domain

enum RobustPrefs {
    /// Removes the keys the robustness scenarios change (they are the factory defaults when absent). Safe to call from any thread.
    static func reset() {
        let d = UserDefaults.standard
        d.removeObject(forKey: EditorPreferences.fontSizeKey)
        d.removeObject(forKey: EditorPreferences.readableWidthKey)
        d.synchronize()
    }
}

// MARK: - watchdog

/// Samples the main run loop: a 1 ms timer on the main queue stamps `lastBeat`; a thread of its own compares the stamp with the
/// clock. The longest gap since `reset()` is the longest main-thread stall (a synchronous block of the test counts too: it is the
/// main thread). A gap above `hangLimitMs` is a HANG: the thread runs /usr/bin/sample on this process, prints the label of what was
/// in flight and the main thread's stack, and ends the process with status 3.
final class RobustWatchdog: @unchecked Sendable {
    static let shared = RobustWatchdog()

    private var lock = os_unfair_lock()
    private var lastBeat = DispatchTime.now().uptimeNanoseconds
    private var maxGap: UInt64 = 0
    private var maxGapLabel = "-"
    private var _label = "-"
    private var started = false
    private var timer: DispatchSourceTimer?
    var hangLimitMs: Double = 60_000
    /// Set to false by a scenario that deliberately blocks (none do).
    var enabled = true

    var label: String {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _label }
        set { os_unfair_lock_lock(&lock); _label = newValue; os_unfair_lock_unlock(&lock); RobustCrash.setLabel(newValue) }
    }

    private var generation = 0

    func start() {
        guard !started else { return }
        started = true
        os_unfair_lock_lock(&lock); generation += 1; let gen = generation; lastBeat = DispatchTime.now().uptimeNanoseconds; os_unfair_lock_unlock(&lock)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
        t.setEventHandler { [self] in
            let n = DispatchTime.now().uptimeNanoseconds
            os_unfair_lock_lock(&lock)
            let gap = n &- lastBeat
            if gap > maxGap { maxGap = gap; maxGapLabel = _label }
            lastBeat = n
            os_unfair_lock_unlock(&lock)
        }
        timer = t
        t.resume()
        let th = Thread { [self] in watchLoop(gen) }
        th.name = "robust-watchdog"
        th.qualityOfService = .userInteractive
        th.start()
    }

    /// Ends the heartbeat and the watching thread (a later `start()` begins afresh).
    func stop() {
        guard started else { return }
        if let t = timer { if paused { t.resume() }; t.cancel() }
        timer = nil; paused = false; hangSuspended = false; started = false
        os_unfair_lock_lock(&lock); generation += 1; os_unfair_lock_unlock(&lock)
    }

    private var paused = false
    /// The 1 ms heartbeat timer keeps the process busy (a few percent of a core): idle measurements switch it off. `resume()` restarts it.
    func pause() { guard !paused, let t = timer else { return }; t.suspend(); paused = true; os_unfair_lock_lock(&lock); lastBeat = DispatchTime.now().uptimeNanoseconds; os_unfair_lock_unlock(&lock); hangSuspended = true }
    func resume() { guard paused, let t = timer else { return }; os_unfair_lock_lock(&lock); lastBeat = DispatchTime.now().uptimeNanoseconds; os_unfair_lock_unlock(&lock); t.resume(); paused = false; hangSuspended = false }
    private var hangSuspended = false

    /// Longest stall (ms) since the last reset, including a stall that is still going on.
    func maxStallMs() -> Double {
        os_unfair_lock_lock(&lock)
        let now = DispatchTime.now().uptimeNanoseconds
        let cur = now &- lastBeat
        let m = max(maxGap, cur)
        os_unfair_lock_unlock(&lock)
        return Double(m) / 1e6
    }
    func reset() {
        os_unfair_lock_lock(&lock)
        maxGap = 0
        lastBeat = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_unlock(&lock)
    }

    private func watchLoop(_ gen: Int) {
        while true {
            usleep(hangSuspended ? 250_000 : 5_000)         // (while the heartbeat is paused for an idle measurement the thread hardly wakes up)
            os_unfair_lock_lock(&lock); let current = generation; os_unfair_lock_unlock(&lock)
            guard current == gen else { return }            // stopped (or restarted: the new thread watches)
            guard enabled, !hangSuspended else { continue }
            os_unfair_lock_lock(&lock)
            let now = DispatchTime.now().uptimeNanoseconds
            let gap = now &- lastBeat
            let lbl = _label
            os_unfair_lock_unlock(&lock)
            if Double(gap) / 1e6 > hangLimitMs { reportHang(gapMs: Double(gap) / 1e6, label: lbl) }
        }
    }

    private func reportHang(gapMs: Double, label: String) -> Never {
        let pid = getpid()
        RobustPrefs.reset()          // (the process ends below: a scenario's `defer` will not run)
        print("ROBUST-HANG: the main thread has not returned to its run loop for \(Int(gapMs)) ms while: \(label)")
        fflush(stdout)
        let file = NSTemporaryDirectory() + "luftig-hang-sample-\(pid).txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(pid)", "2", "-file", file]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { p.waitUntilExit() }
        if let text = try? String(contentsOfFile: file, encoding: .utf8) {
            // the main thread's call graph (first block after "Call graph:")
            let lines = text.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.contains("Call graph:") }) {
                print("ROBUST-HANG sample (main thread), full file: \(file)")
                for l in lines[(i + 1)..<min(lines.count, i + 70)] { print("  " + l) }
            }
        } else {
            print("ROBUST-HANG: /usr/bin/sample produced no output")
        }
        fflush(stdout)
        _exit(3)
    }
}

// MARK: - process sampling

enum RobustSample {
    nonisolated(unsafe) static var taken = 0
    /// `/usr/bin/sample` on this very process (2 s) for a stuck asynchronous operation (the main thread is idle, something waits for a daemon / a lock).
    /// Prints the lines of every thread's call graph that mention coordination / presenter / document / luftig frames. At most 3 per process.
    @MainActor static func ofSelf(_ why: String, t: SelfTest.T) async {
        guard taken < 3 else { return }
        taken += 1
        let file = NSTemporaryDirectory() + "luftig-sample-\(getpid())-\(taken).txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "2", "-file", file]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
            do { try p.run() } catch { c.resume() }
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { t.note("sample (\(why)): no output"); return }
        t.note("sample of this process (\(why)): \(file)")
        let lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("Call graph:") }) else { return }
        var shown = 0
        for l in lines[(i + 1)...] {
            if l.hasPrefix("Total number in stack") { break }
            if l.contains("Coordinat") || l.contains("Presenter") || l.contains("NSDocument") || l.contains("luftig") || l.contains("semaphore") || l.contains("_dispatch_sync") || l.contains("Thread_") {
                out("    | " + l.prefix(220)); shown += 1
                if shown > 80 { break }
            }
        }
    }
}

// MARK: - crash reporter

/// SIGSEGV / SIGILL / SIGTRAP / SIGABRT / SIGBUS / SIGFPE: print the label of the step that was running and a backtrace, exit 134.
/// (An Objective-C exception ends in abort(): the runner's uncaught-exception handler has already printed it.)
enum RobustCrash {
    nonisolated(unsafe) static let labelBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
    nonisolated(unsafe) static var installed = false

    static func setLabel(_ s: String) {
        _ = s.withCString { strlcpy(labelBuffer, $0, 1024) }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        labelBuffer.initialize(repeating: 0, count: 1024)
        let altSize = 256 * 1024
        var ss = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: altSize, alignment: 16), ss_size: altSize, ss_flags: 0)
        sigaltstack(&ss, nil)
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = { sig in
            var msg = Array("\nROBUST-CRASH: signal \(sig) while: ".utf8)
            msg.append(contentsOf: Array(String(cString: RobustCrash.labelBuffer).utf8))
            msg.append(10)
            _ = msg.withUnsafeBufferPointer { write(1, $0.baseAddress, $0.count) }
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
            let n = backtrace(&frames, 48)
            backtrace_symbols_fd(&frames, n, 1)
            _exit(134)
        }
        sa.sa_flags = SA_ONSTACK
        sigemptyset(&sa.sa_mask)
        for s in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] { sigaction(s, &sa, nil) }
    }
}

// MARK: - files

enum RobustFiles {
    /// Writes `prefix + unit x count + suffix` in 1 MB chunks (no giant buffer in memory).
    static func writeRepeating(_ url: URL, unit: [UInt8], count: Int, prefix: [UInt8] = [], suffix: [UInt8] = []) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        if !prefix.isEmpty { try h.write(contentsOf: Data(prefix)) }
        let perChunk = max(1, (1 << 20) / max(1, unit.count))
        var chunk = [UInt8](); chunk.reserveCapacity(perChunk * unit.count)
        for _ in 0..<min(perChunk, count) { chunk.append(contentsOf: unit) }
        var left = count
        while left > 0 {
            let n = min(perChunk, left)
            if n == chunk.count / max(1, unit.count) { try h.write(contentsOf: Data(chunk)) }
            else { try h.write(contentsOf: Data(chunk[0..<(n * unit.count)])) }
            left -= n
        }
        if !suffix.isEmpty { try h.write(contentsOf: Data(suffix)) }
    }

    /// Pseudo-random bytes from the suite's own seeded generator (never from a device).
    static func writeRandom(_ url: URL, bytes: Int, seed: UInt64 = 0xB1A5ED) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        var rng = TestRNG(seed)
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var left = bytes
        while left > 0 {
            var i = 0
            while i < buf.count { var w = rng.next(); for _ in 0..<8 where i < buf.count { buf[i] = UInt8(truncatingIfNeeded: w); w >>= 8; i += 1 } }
            let n = min(left, buf.count)
            try h.write(contentsOf: Data(buf[0..<n]))
            left -= n
        }
    }

    /// Markdown of about `bytes` bytes written to `url` by repeating one 200 KB corpus block (fast, no giant String).
    static func writeCorpus(_ url: URL, bytes: Int, seed: UInt64 = 3, nonASCII: Bool = true) throws {
        let block = Array(SelfTestCorpus.markdown(bytes: min(bytes, 200_000), seed: seed, nonASCII: nonASCII).utf8)
        let reps = max(1, bytes / max(1, block.count))
        try writeRepeating(url, unit: block, count: reps)
    }
}

// MARK: - the stall budget

enum StallBudget {
    /// DESIGN.md: typing < 8 ms, open < 100 ms; the task of this review: > 100 ms blocked UI is a finding, > 1 s is high.
    static let finding: Double = 100
    static let high: Double = 1000
    static func grade(_ ms: Double) -> String { ms > high ? "HIGH(>1s)" : (ms > finding ? "slow(>100ms)" : "ok") }
}
#endif
