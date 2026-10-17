// ExternalChangeMonitor.swift
//
// Event source for "the file under this document may have changed". Foundation only.
//
//   * DispatchSource (kqueue EVFILT_VNODE) on the FILE descriptor   -> in-place writes, truncation, chmod/touch, unlink, rename
//   * DispatchSource on the PARENT DIRECTORY descriptor              -> atomic replace (rename over), delete+recreate,
//                                                                       rename away and back (new directory entries)
//   * events are coalesced: fire `settleDelay` after the last event, but never later than `maxDelay` after the first
//     one of a burst (a build tool that writes 20x in 1 s produces ~3 callbacks, not 20, and we do not read a
//     half-written file)
//   * after every burst the file descriptor is re-bound if the path now points to a different inode (atomic replace
//     leaves our descriptor on the unlinked old inode: this is the classic "watcher dies after the first reload" bug)
//   * on non-local file systems (SMB/NFS/AFP/WebDAV/FUSE: kqueue sees only local changes) a 2 s stat-poll timer is added
//   * idle cost: zero (no timers, no threads; kqueue wakes the process only on events)
//
// The monitor never reads or decides anything. It only calls `onChange` (on the MAIN queue) and the owner compares
// FileSignature / content hash. A spurious call costs one stat(2).

import Foundation

final class ExternalChangeMonitor {
    private let queue = DispatchQueue(label: "local.scribe.filewatch", qos: .utility)
    private var path: String
    private let onChange: () -> Void

    // all of the following are only touched on `queue`
    private var fileFD: Int32 = -1
    private var dirFD: Int32 = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var burstStart: UInt64 = 0
    private var deliveryTimes: [UInt64] = []        // uptime ns of the most recent callbacks
    private var stopped = false

    /// Quiet period after the last event before `onChange` fires.
    var settleDelay: TimeInterval = 0.05
    /// Upper bound from the first event of a burst to the callback, however long the burst lasts.
    var maxDelay: TimeInterval = 0.4
    /// Burst throttle: once there have been `burstThreshold` callbacks within the last second, further callbacks are never
    /// closer than this (a writer that touches the file every 50 ms is answered ~3-4x per second, not 20x). A single change
    /// - also right after another single one (e.g. the xattr write NSDocument does at open) - still arrives after `settleDelay`.
    var minInterval: TimeInterval = 0.3
    var burstThreshold = 2
    /// Poll interval used on non-local file systems only.
    var pollInterval: TimeInterval = 2.0
    /// Test hooks: poll even on a local file system / run without kqueue sources (set before start()).
    var forcePolling = false
    var vnodeEnabled = true

    /// Counters for tests/diagnostics.
    private(set) var eventCount = 0
    private(set) var deliveryCount = 0
    private(set) var rebindCount = 0
    private(set) var isPolling = false

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { disarm() }

    func start() { queue.async { [self] in stopped = false; arm() } }

    func retarget(path newPath: String) {
        queue.async { [self] in
            guard newPath != path else { return }
            path = newPath
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel(); pending = nil
            disarm()
        }
    }

    /// Feed an event from another source (NSFilePresenter callback, app activation, ...). Coalesced like a vnode event.
    func nudge() { queue.async { [self] in schedule() } }

    // MARK: queue-confined

    private func disarm() {
        fileSource?.cancel(); fileSource = nil          // cancel handlers close the descriptors
        dirSource?.cancel(); dirSource = nil
        pollTimer?.cancel(); pollTimer = nil
        isPolling = false
        fileFD = -1; dirFD = -1
    }

    private func arm() {
        disarm()
        if stopped { return }
        // O_EVTONLY: event notifications only; does not keep the volume busy (can be ejected) and needs no read permission
        let ffd = vnodeEnabled ? open(path, O_EVTONLY | O_CLOEXEC) : -1
        if ffd >= 0 {
            fileFD = ffd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: ffd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link], queue: queue)
            src.setEventHandler { [weak self] in self?.eventCount += 1; self?.schedule() }
            src.setCancelHandler { close(ffd) }
            fileSource = src
            src.resume()
        }
        let dirPath = (path as NSString).deletingLastPathComponent
        let dfd = vnodeEnabled ? open(dirPath, O_EVTONLY | O_CLOEXEC) : -1
        if dfd >= 0 {
            dirFD = dfd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dfd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
            src.setEventHandler { [weak self] in self?.eventCount += 1; self?.schedule() }
            src.setCancelHandler { close(dfd) }
            dirSource = src
            src.resume()
        }
        var fs = statfs()
        if forcePolling || (statfs(dirPath, &fs) == 0 && (fs.f_flags & UInt32(MNT_LOCAL)) == 0) {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.deliver(rebind: false) }
            pollTimer = t
            isPolling = true
            t.resume()
        }
    }

    private func schedule() {
        if stopped { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if pending == nil { burstStart = now }
        pending?.cancel()
        let elapsed = Double(now &- burstStart) / 1e9
        var delay = max(0, min(settleDelay, maxDelay - elapsed))
        let recent = deliveryTimes.filter { Double(now &- $0) / 1e9 < 1.0 }
        if recent.count >= burstThreshold, let last = recent.last {
            let sinceLast = Double(now &- last) / 1e9
            if sinceLast < minInterval { delay = max(delay, minInterval - sinceLast) }
        }
        let item = DispatchWorkItem { [weak self] in self?.deliver(rebind: true) }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func deliver(rebind: Bool) {
        pending = nil
        if stopped { return }
        deliveryTimes.append(DispatchTime.now().uptimeNanoseconds)
        if deliveryTimes.count > 8 { deliveryTimes.removeFirst(deliveryTimes.count - 8) }
        if rebind { rebindIfNeeded() }
        deliveryCount += 1
        DispatchQueue.main.async { [onChange] in onChange() }
    }

    /// If the path now refers to another inode than our descriptor (atomic replace, delete+recreate), re-arm.
    private func rebindIfNeeded() {
        var sp = stat()
        let pathExists = stat(path, &sp) == 0
        var sf = stat()
        let haveFD = fileFD >= 0 && fstat(fileFD, &sf) == 0
        let dirPath = (path as NSString).deletingLastPathComponent
        var sdPath = stat(), sdFD = stat()
        let dirOK = dirFD >= 0 && fstat(dirFD, &sdFD) == 0 && stat(dirPath, &sdPath) == 0 && sdFD.st_ino == sdPath.st_ino
        if !dirOK && stat(dirPath, &sdPath) == 0 { rebindCount += 1; arm(); return }     // directory itself replaced/moved
        if pathExists && (!haveFD || sf.st_ino != sp.st_ino || sf.st_dev != sp.st_dev) { rebindCount += 1; arm() }
        // path missing: keep the directory source - its next event is the file coming back
    }
}
