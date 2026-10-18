#if LUFTIG_SELFTEST
// SelfTestFixWindows.swift - fix-fullscreen-open (ON SCREEN): a file opened while another one fills the screen.
import AppKit

extension SelfTestScenarios {
    static let fixWindowsScenarios: [SelfTest.Scenario] = [
        .init(name: "fix-single-instance", summary: "one running luftig: the choice of the instance to yield to, the files of an open-documents event, a self-test build never yields",
              run: { t in try await fixSingleInstance(t) }),
        .init(name: "fix-fullscreen-open", summary: "(ON SCREEN, ~8 s) a document in full screen; a second file is opened: every window leaves full screen, the new one is a window of its own on the desktop",
              run: { t in try await fixFullScreenOpen(t) }, inAll: false),
    ]

    @MainActor static func fixSingleInstance(_ t: SelfTest.T) async throws {
        let d0 = Date(timeIntervalSince1970: 1000), d1 = Date(timeIntervalSince1970: 2000), d2 = Date(timeIntervalSince1970: 3000)
        t.equal(SingleInstance.choose([(instance: "b", launched: d1), (instance: "a", launched: d0), (instance: "c", launched: d2)]), "a", "the instance running longest wins")
        t.check(SingleInstance.choose([(instance: String, launched: Date)]()) == nil, "no other instance: nothing to yield to")
        t.check(SingleInstance.instanceToYieldTo(bundleIdentifier: Bundle.main.bundleIdentifier) == nil, "this self-test process is the only one of its bundle id")
        t.check(SingleInstance.instanceToYieldTo(bundleIdentifier: nil) == nil, "no bundle id: nothing to yield to")
        t.check(!SingleInstance.checkAtLaunch(bundleIdentifier: Bundle.main.bundleIdentifier), "a self-test build never yields (.selftest)")
        t.check(SingleInstance.yieldingTo == nil, "... and remembers no instance")
        // the files of an 'odoc' event: a list of file URLs, a single URL, paths
        let a = URL(fileURLWithPath: "/tmp/a.md"), b = URL(fileURLWithPath: "/tmp/b.md")
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: a), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: b), at: 2)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        t.equal(SingleInstance.urls(in: event).map { $0.path }, [a.path, b.path], "two file URLs in order")
        let single = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        single.setParam(NSAppleEventDescriptor(fileURL: a), forKeyword: AEKeyword(keyDirectObject))
        t.equal(SingleInstance.urls(in: single).map { $0.path }, [a.path], "a single URL, not a list")
        let empty = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        t.equal(SingleInstance.urls(in: empty).count, 0, "no direct object: no files")
        t.equal(SingleInstance.forwarded.count, 0, "nothing was forwarded in this process")
    }

    @MainActor static func fixFullScreenOpen(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let a = t.write("# A\n\nfirst\n", to: "fs-a.md"), b = t.write("# B\n\nsecond\n", to: "fs-b.md")
            let docA = try await t.open(a, size: NSSize(width: 900, height: 600))
            guard let wA = docA.windowControllers.first?.window else { t.check(false, "no window"); return }
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            wA.makeKeyAndOrderFront(nil)
            await t.sleep(300)
            wA.toggleFullScreen(nil)
            var waited = 0.0
            while !wA.styleMask.contains(.fullScreen) && waited < 4000 { await t.sleep(50); waited += 50 }
            await t.sleep(1200)
            t.check(wA.styleMask.contains(.fullScreen), "A is in full screen")
            // the second file, as the Finder would open it: NSDocumentController makes the window controllers and calls showWindows (the hook)
            let docB = try await t.open(b, size: NSSize(width: 900, height: 600))
            guard let wB = docB.windowControllers.first?.window else { t.check(false, "no window for B"); return }
            docB.showWindows()
            waited = 0
            while wA.styleMask.contains(.fullScreen) && waited < 4000 { await t.sleep(50); waited += 50 }
            await t.sleep(1500)
            t.check(!wA.styleMask.contains(.fullScreen), "opening B took A out of full screen (\(Int(waited)) ms)")
            t.check(!wB.styleMask.contains(.fullScreen), "B is not in full screen")
            t.check(wB.isVisible && (wB.tabbedWindows?.count ?? 1) <= 1 && (wA.tabbedWindows?.count ?? 1) <= 1, "B is a window of its own (tabs of A: \(wA.tabbedWindows?.count ?? 0), of B: \(wB.tabbedWindows?.count ?? 0))")
            t.close(docB); t.close(docA)
            await t.sleep(300)
        }
    }
}
#endif
