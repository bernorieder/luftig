import AppKit

/// One running luftig, and every file goes to it.
///
/// Launch Services sends a document to the running copy of an app by itself - but it goes by bundle PATH, not by bundle identifier: a second copy of
/// the bundle (a fresh build next to the installed one, a copy on another volume, `open -n`) starts a second instance, and files opened from the
/// Finder then land in whichever copy Launch Services currently prefers. So at launch a luftig that finds another luftig already running (same
/// bundle identifier, another process) YIELDS: the files it was launched with are handed to the running instance, that instance is activated, and
/// this one quits before it shows a window. The instance that was running first always wins (the user's windows are in it).
///
/// The files arrive as the 'odoc' Apple event, which AppKit normally turns into NSDocumentController opens; while yielding, luftig takes that event
/// itself (handler installed in applicationWillFinishLaunching, before AppKit's own) and forwards the URLs. A plain launch ('oapp') while another
/// instance runs just activates it and quits.
enum SingleInstance {

    /// The instance to yield to: the earliest-launched other process of this bundle identifier, nil if this process is the only one (or the first).
    static func instanceToYieldTo(bundleIdentifier: String?, selfPID: pid_t = getpid()) -> NSRunningApplication? {
        guard let id = bundleIdentifier else { return nil }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != selfPID && !$0.isTerminated }
        return choose(others.map { ($0, $0.launchDate ?? .distantPast) })
    }

    /// Of the other instances, the one that has been running longest (the pure decision: tests feed it dates).
    static func choose<T>(_ candidates: [(instance: T, launched: Date)]) -> T? {
        candidates.min { $0.launched < $1.launched }?.instance
    }

    /// The running instance this process yields to (nil: this is the one).
    nonisolated(unsafe) private(set) static var yieldingTo: NSRunningApplication?
    /// Diagnostics: the files forwarded.
    nonisolated(unsafe) private(set) static var forwarded: [URL] = []

    /// Call first thing in `applicationWillFinishLaunching`. Returns true when this process will yield (the caller skips its own setup).
    @MainActor
    static func checkAtLaunch(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        // (a self-test build never yields: its runs start processes of their own on purpose)
        guard let id = bundleIdentifier, !id.hasSuffix(".selftest"), let other = instanceToYieldTo(bundleIdentifier: id) else { return false }
        yieldingTo = other
        // take the open-documents event before AppKit's handler does
        NSAppleEventManager.shared().setEventHandler(Forwarder.shared, andSelector: #selector(Forwarder.handleOpenDocuments(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        return true
    }

    /// Call from `applicationDidFinishLaunching` when `checkAtLaunch` returned true: the running instance comes to the front, this one quits (a moment
    /// later, so that an 'odoc' event that is still on its way is forwarded first).
    @MainActor
    static func finishYielding() {
        guard let other = yieldingTo else { return }
        other.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    /// The URLs in an 'odoc' event's direct object (file URLs, aliases, paths), in order.
    static func urls(in event: NSAppleEventDescriptor) -> [URL] {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }
        var out: [URL] = []
        let n = list.numberOfItems
        if n == 0, let u = list.fileURLValue { return [u] }
        for i in stride(from: 1, through: n, by: 1) {
            guard let item = list.atIndex(i) else { continue }
            if let u = item.fileURLValue { out.append(u) }
            else if let s = item.stringValue, s.hasPrefix("/") { out.append(URL(fileURLWithPath: s)) }
        }
        return out
    }

    /// Hands `urls` to the running instance.
    @MainActor
    static func forward(_ urls: [URL]) {
        guard let other = yieldingTo, let app = other.bundleURL, !urls.isEmpty else { return }
        forwarded += urls
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, _ in }
    }

    final class Forwarder: NSObject {
        static let shared = Forwarder()
        @objc func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
            let urls = SingleInstance.urls(in: event)
            MainActor.assumeIsolated { SingleInstance.forward(urls) }
        }
    }
}
