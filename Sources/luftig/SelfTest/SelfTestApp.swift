#if LUFTIG_SELFTEST
// SelfTestApp.swift - new/untitled documents, encodings through the real document, refusals, lifecycle, menu.

import AppKit

final class ReviewProbe: NSObject {
    var result: Bool?
    @objc func didReviewAll(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) { result = didReviewAll }
}

extension SelfTestScenarios {
    static let appScenarios: [SelfTest.Scenario] = [
        .init(name: "new-untitled", summary: "untitled document: type, default name Untitled.md, Save panel, first save, then external changes work", run: { t in try await newUntitled(t) }),
        .init(name: "formats", summary: "open/edit/autosave documents in CRLF, UTF-16, BOM, Windows-1252: only the edit changes, format preserved", run: { t in try await formats(t) }),
        .init(name: "refusals", summary: "binary, > 200 MB, empty, BOM-only, not-UTF-8 files", run: { t in try await refusals(t) }),
        .init(name: "lifecycle", summary: "NSDocumentController: types, recents, quit review of dirty untitled docs, tabbing, full screen, no visible windows", run: { t in try await lifecycle(t) }),
        .init(name: "menu", summary: "main menu structure, key equivalents, responder-chain routing and validation of every item", run: { t in try await menu(t) }),
    ]

    // MARK: new / untitled

    @MainActor static func newUntitled(_ t: SelfTest.T) async throws {
        let dc = NSDocumentController.shared
        t.note("readableTypes=\(MarkdownDocument.readableTypes) writableTypes=\(MarkdownDocument.writableTypes) defaultType=\(dc.defaultType ?? "nil")")
        let doc = try t.newUntitled()
        t.check(String(reflecting: Swift.type(of: doc)) == "luftig.MarkdownDocument", "untitled document is a luftig.MarkdownDocument")
        t.equal(doc.fileType, "net.daringfireball.markdown", "untitled fileType is Markdown")
        t.equal(doc.displayName, "Untitled", "displayName")
        t.check(doc.fileURL == nil && !doc.isDocumentEdited, "no fileURL, not edited")
        t.check(doc.monitor == nil, "no file watcher before the first save")
        t.equal(doc.fileNameExtension(forType: doc.fileType!, saveOperation: .saveOperation), "md", "default extension for the type is .md")
        t.typeText("# Hello\n\nfirst words\n", into: doc)
        await t.sleep(30)
        t.check(doc.isDocumentEdited, "typed: edited")
        // first Save: what the panel would offer (cancelled: see UITrap note), then the actual save via save(to:)
        UITrap.reset()
        UITrap.panelChooser = { _ in nil }
        doc.save(nil)
        await t.sleep(200)
        t.check(UITrap.panels.count == 1, "first Save shows one Save panel")
        if let p = UITrap.panels.first {
            t.equal(p.nameField, "Untitled.md", "Save panel proposes 'Untitled.md'")
            t.note("Save panel: \(p)")
            t.check(p.allowedTypes.first == "net.daringfireball.markdown", "Save panel offers Markdown first: \(p.allowedTypes)")
            t.check(!p.hasAccessory, "no file-format popup accessory")
        }
        t.check(doc.fileURL == nil && doc.isDocumentEdited, "cancelled panel: nothing written, still untitled + edited")
        let target = t.url("Untitled.md")
        let saved: Error? = await withCheckedContinuation { c in doc.save(to: target, ofType: doc.fileType!, for: .saveOperation) { c.resume(returning: $0) } }
        t.check(saved == nil, "save(to:) of the untitled document: \(String(describing: saved))")
        t.equal(t.read(target), "# Hello\n\nfirst words\n", "file written: UTF-8, LF, exact text")
        await t.sleep(300)
        t.check(!doc.isDocumentEdited && doc.fileURL?.lastPathComponent == "Untitled.md", "after save: clean, fileURL set")
        t.check(doc.monitor != nil && doc.lastDisk != nil, "file watcher armed after the first save")
        t.equal(doc.fileType, "net.daringfireball.markdown", "type after save")
        // external change after the first save is picked up
        await t.sleep(1300)
        let r0 = doc.stats.silentReloads
        await t.sh("printf 'external\\n' >> \(t.q(target))")
        let ok2 = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
        t.check(ok2, "external change after the first save is reloaded")
        t.close(doc)
        t.check(UITrap.violations.isEmpty, "UITrap: no panel URL outside the work dir was requested")

        // a second untitled document does not clash
        let a = try t.newUntitled(), b = try t.newUntitled()
        t.check(a.displayName != b.displayName, "two untitled documents get different names: '\(a.displayName ?? "")' / '\(b.displayName ?? "")'")
        t.close(a); t.close(b)
    }

    // MARK: formats through the real document

    @MainActor static func formats(_ t: SelfTest.T) async throws {
        struct Case { let name: String; let bytes: [UInt8]; let edit: (String) -> (NSRange, String); let expected: [UInt8]; let fmt: String }
        let u8 = { (s: String) in Array(s.utf8) }
        let le16 = { (s: String) in s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
        let cases: [Case] = [
            Case(name: "utf8-crlf", bytes: u8("# T\r\none\r\ntwo\r\n"), edit: { s in ((s as NSString).range(of: "one"), "ONE") }, expected: u8("# T\r\nONE\r\ntwo\r\n"), fmt: "UTF-8, CRLF"),
            Case(name: "utf8-crlf-newline", bytes: u8("a\r\nb\r\n"), edit: { s in (NSRange(location: 1, length: 0), "\nnew") }, expected: u8("a\r\nnew\r\nb\r\n"), fmt: "UTF-8, CRLF"),
            Case(name: "utf8-bom", bytes: [0xEF, 0xBB, 0xBF] + u8("# T\nbody\n"), edit: { s in ((s as NSString).range(of: "body"), "BODY") }, expected: [0xEF, 0xBB, 0xBF] + u8("# T\nBODY\n"), fmt: "UTF-8+BOM, LF"),
            Case(name: "utf16le-bom", bytes: [0xFF, 0xFE] + le16("# T\nbody\n"), edit: { s in ((s as NSString).range(of: "body"), "BODY ü") }, expected: [0xFF, 0xFE] + le16("# T\nBODY ü\n"), fmt: "UTF-16 LE+BOM, LF"),
            Case(name: "cp1252", bytes: [0x43, 0x61, 0x66, 0xE9, 0x0A], edit: { s in ((s as NSString).range(of: "Caf"), "Tea ") }, expected: [0x54, 0x65, 0x61, 0x20, 0xE9, 0x0A], fmt: "Windows-1252, LF"),
            Case(name: "mixed-endings", bytes: u8("a\r\nb\nc\r\n"), edit: { s in ((s as NSString).range(of: "b"), "B") }, expected: u8("a\r\nB\nc\r\n"), fmt: "UTF-8, MIXED"),
            Case(name: "no-trailing-newline", bytes: u8("last line"), edit: { s in (NSRange(location: 4, length: 0), "X") }, expected: u8("lastX line"), fmt: "UTF-8, LF"),
        ]
        for c in cases {
            let file = t.write(data: Data(c.bytes), to: "fmt-\(c.name).md")
            let doc = try await t.open(file)
            t.equal(doc.textFormat.description, c.fmt, "\(c.name): detected \(doc.textFormat)")
            guard let host = doc.host as? EditorViewController else { continue }
            let (range, repl) = c.edit(host.textView.string)
            t.typeText(repl, into: doc, at: range)
            await t.sleep(30)
            let err = await t.autosave(doc)
            t.check(err == nil, "\(c.name): autosave ok \(String(describing: err))")
            t.check(t.readData(file) == Data(c.expected), "\(c.name): file bytes = original with only the edit applied (\(t.readData(file).count) bytes)")
            t.close(doc)
        }
        // a file whose extension belongs to ANOTHER app's Markdown type (.mdown is owned by Ulysses on this machine; the
        // type conforms to net.daringfireball.markdown): opens here, saves in place
        do {
            let file = t.write("# mdown\nbody\n", to: "other-owner.mdown")
            if let doc = try? await t.open(file) {
                t.note("'.mdown' document fileType = \(doc.fileType ?? "nil")")
                t.typeText("X", into: doc, at: NSRange(location: 0, length: 0))
                await t.sleep(30)
                let err = await t.autosave(doc)
                t.check(err == nil && t.read(file) == "X# mdown\nbody\n", ".mdown (foreign Markdown type) opens and autosaves in place (\(String(describing: err)))")
                t.close(doc)
            } else { t.note(".mdown is not openable on this system (no app declares it)") }
        }
        // unrepresentable character typed into a Windows-1252 file: text is kept, file becomes UTF-8
        do {
            let file = t.write(data: Data([0x43, 0x61, 0x66, 0xE9, 0x0A]), to: "fmt-1252-emoji.md")
            let doc = try await t.open(file)
            t.typeText("😀 ", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)
            let err = await t.autosave(doc)
            t.check(err == nil && t.readData(file) == Data("😀 Café\n".utf8), "1252 doc + emoji: saved as UTF-8 instead of failing or losing text (\(t.readData(file).count) bytes)")
            t.equal(doc.textFormat.encoding, .utf8, "format switched to UTF-8")
            t.close(doc)
        }
        // external change that switches the encoding (tool re-saves as UTF-16): reload follows it, save keeps it
        do {
            let file = t.write("hello\n", to: "fmt-switch.md")
            let doc = try await t.open(file)
            await t.sleep(200)
            let tmp = file.appendingPathExtension("tmp")
            try Data([0xFF, 0xFE] + "hello world\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).write(to: tmp)
            let r0 = doc.stats.silentReloads
            await t.sh("mv \(t.q(tmp)) \(t.q(file))")
            _ = await t.waitFor(3000) { doc.stats.silentReloads > r0 }
            t.check(doc.textFormat.encoding == .utf16LE && doc.textFormat.hasBOM, "tool switched the file to UTF-16 LE+BOM: document follows (\(doc.textFormat))")
            t.equal((doc.host?.currentText ?? "") as String, "hello world\n", "text decoded")
            t.close(doc)
        }
    }

    // MARK: refusals

    @MainActor static func refusals(_ t: SelfTest.T) async throws {
        func tryOpen(_ u: URL) async -> (MarkdownDocument?, Error?) {
            do { let (d, _) = try await NSDocumentController.shared.openDocument(withContentsOf: u, display: false); return (d as? MarkdownDocument, nil) }
            catch { return (nil, error) }
        }
        UITrap.reset()
        let bin = t.write(data: Data((0..<4096).map { UInt8($0 & 0xFF) }), to: "binary.md")
        let (d1, e1) = await tryOpen(bin)
        t.check(d1 == nil && e1 != nil, "binary file: open fails gracefully: \(e1.map { ($0 as NSError).localizedDescription } ?? "no error")")
        if let e = e1 as NSError? { t.note("binary error: domain=\(e.domain) code=\(e.code) reason=\(e.localizedFailureReason ?? "nil") suggestion=\(e.localizedRecoverySuggestion ?? "nil") underlying=\((e.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription ?? "nil")") }
        t.check(UITrap.alerts.isEmpty, "(the error is returned to the caller; with display:true NSDocumentController presents it as an alert)")

        let big = t.url("huge.md")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let fd = open(big.path, O_WRONLY); ftruncate(fd, 250 * 1024 * 1024); close(fd)
        let t0 = SelfTest.nowMs()
        let (d2, e2) = await tryOpen(big)
        t.check(d2 == nil && e2 != nil, "250 MB file refused in \(Int(SelfTest.nowMs() - t0)) ms: \(e2.map { ($0 as NSError).localizedDescription } ?? "no error")")

        let empty = t.write("", to: "empty.md")
        let (d3, e3) = await tryOpen(empty)
        t.check(d3 != nil && e3 == nil, "empty file opens")
        if let d3 { t.attachWindow(d3); t.equal((d3.host?.currentText ?? "x") as String, "", "empty text"); t.close(d3) }
        let bomOnly = t.write(data: Data([0xEF, 0xBB, 0xBF]), to: "bomonly.md")
        let (d4, _) = await tryOpen(bomOnly)
        t.check(d4 != nil && d4?.textFormat.hasBOM == true, "BOM-only file opens as an empty UTF-8+BOM document")
        if let d4 { t.close(d4) }
        let latin = t.write(data: Data([0x63, 0x61, 0x66, 0xE9]), to: "latin.md")
        let (d5, _) = await tryOpen(latin)
        t.check(d5 != nil && d5?.textFormat.encoding == .windows1252, "not UTF-8: opens as Windows-1252 instead of failing")
        if let d5 { t.close(d5) }
        // a file that is deleted between choosing it and opening it
        let (d6, e6) = await tryOpen(t.url("does-not-exist.md"))
        t.check(d6 == nil && e6 != nil, "missing file: error, no crash: \(e6.map { ($0 as NSError).localizedDescription } ?? "")")
    }

    // MARK: lifecycle

    @MainActor static func lifecycle(_ t: SelfTest.T) async throws {
        let dc = NSDocumentController.shared
        // app delegate policies
        let ad = AppDelegate()
        t.check(ad.applicationShouldOpenUntitledFile(NSApp), "applicationShouldOpenUntitledFile -> true (launch and Dock click open one untitled document, no Open panel)")
        t.check(ad.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "reopen with no windows -> new untitled document")
        t.check(!ad.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true), "reopen with windows -> just bring them forward")
        t.check(!ad.applicationShouldTerminateAfterLastWindowClosed(NSApp), "closing the last window does not quit")
        t.check(ad.applicationSupportsSecureRestorableState(NSApp), "secure restorable state declared")
        // document types from Info.plist
        t.check(dc.documentClassNames.contains("luftig.MarkdownDocument") || dc.documentClassNames.contains(where: { $0.hasSuffix("MarkdownDocument") }), "Info.plist wiring: documentClassNames=\(dc.documentClassNames)")
        t.equal(dc.defaultType, "net.daringfireball.markdown", "defaultType")
        for ext in ["md", "markdown", "txt"] {
            let u = t.write("# x\n", to: "types/f.\(ext)")
            let type = try? dc.typeForContents(of: u)
            t.note("typeForContents(.\(ext)) = \(type ?? "nil")")
            t.check(type != nil, ".\(ext) is openable")
        }
        // recents
        let a = t.write("a\n", to: "recent-a.md"), b = t.write("b\n", to: "recent-b.md")
        dc.clearRecentDocuments(nil)
        for u in [a, b] { let d = try await t.open(u); dc.noteNewRecentDocumentURL(u); _ = d }
        if let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
           let recentMenu = fileMenu.items.first(where: { $0.title == "Open Recent" })?.submenu {
            recentMenu.update()
            await t.sleep(50)
            t.note("File > Open Recent submenu after two documents were opened: \(recentMenu.items.map { $0.isSeparatorItem ? "-" : $0.title })")
        }
        // (the list is kept by a system daemon: clearRecentDocuments / noteNewRecentDocumentURL take effect asynchronously, so under load it is briefly
        // out of date - wait for it instead of reading it at once; a list that never gets there still fails)
        _ = await t.waitFor(3000) { let r = dc.recentDocumentURLs.map { $0.lastPathComponent }; return r.first == "recent-b.md" && r.contains("recent-a.md") }
        let recents = dc.recentDocumentURLs.map { $0.lastPathComponent }
        t.check(recents.first == "recent-b.md" && recents.contains("recent-a.md"), "Open Recent list (most recent first): \(recents)")
        t.check(dc.maximumRecentDocumentCount >= 5, "maximumRecentDocumentCount = \(dc.maximumRecentDocumentCount)")
        dc.clearRecentDocuments(nil)
        t.check(dc.recentDocumentURLs.isEmpty, "Clear Menu empties the list")
        for d in dc.documents { t.close(d as! MarkdownDocument) }
        // tabbing + full screen on a real document window
        let doc = try t.newUntitled()
        if let w = doc.windowControllers.first?.window {
            t.check(NSWindow.allowsAutomaticWindowTabbing, "allowsAutomaticWindowTabbing")
            t.equal(w.tabbingMode, .automatic, "tabbingMode = .automatic (follows the system 'Prefer tabs' setting; Cmd-N = new window unless the user chose tabs)")
            t.equal(w.tabbingIdentifier, "local.luftig.document", "tabbingIdentifier shared by all document windows")
            t.check(w.collectionBehavior.contains(.fullScreenPrimary), "full-screen capable (fullScreenPrimary)")
            t.check(w.styleMask.contains(.resizable) && w.styleMask.contains(.titled), "titled + resizable (zoom button)")
            t.check(!w.isVisible, "test window was never ordered front")
        }
        // quit with a dirty untitled document
        t.typeText("unsaved thoughts\n", into: doc)
        await t.sleep(30)
        UITrap.reset()
        UITrap.alertChooser = { a in a.buttons.firstIndex(where: { $0.contains("Cancel") }) ?? 0 }
        let probe = ReviewProbe()
        dc.reviewUnsavedDocuments(withAlertTitle: nil, cancellable: true, delegate: probe, didReviewAllSelector: #selector(ReviewProbe.didReviewAll(_:didReviewAll:contextInfo:)), contextInfo: nil)
        _ = await t.waitFor(2000) { probe.result != nil }
        t.note("quit review with a dirty untitled doc (autosavesInPlace): didReviewAll=\(String(describing: probe.result)), alerts=\(UITrap.alerts.map { "\"\($0.message)\" \($0.buttons)" })")
        let err = await t.autosave(doc)
        t.note("autosave of the untitled draft: err=\(String(describing: err)) isDocumentEdited=\(doc.isDocumentEdited) autosavedContentsFileURL=\(doc.autosavedContentsFileURL?.lastPathComponent ?? "nil")")
        UITrap.reset()
        let probe2 = ReviewProbe()
        dc.reviewUnsavedDocuments(withAlertTitle: nil, cancellable: true, delegate: probe2, didReviewAllSelector: #selector(ReviewProbe.didReviewAll(_:didReviewAll:contextInfo:)), contextInfo: nil)
        _ = await t.waitFor(2000) { probe2.result != nil }
        t.note("quit review AFTER the draft was autosaved: didReviewAll=\(String(describing: probe2.result)), alerts=\(UITrap.alerts.map { "\"\($0.message)\" \($0.buttons)" })")
        t.close(doc)
    }

    // MARK: menu

    @MainActor static func menu(_ t: SelfTest.T) async throws {
        guard let main = NSApp.mainMenu else { t.check(false, "no main menu"); return }
        t.equal(main.items.map { $0.title }, ["luftig", "File", "Edit", "View", "Window", "Help"], "top-level menus")
        t.check(NSApp.windowsMenu != nil && NSApp.helpMenu != nil && NSApp.servicesMenu != nil, "windowsMenu / helpMenu / servicesMenu registered")

        func find(_ path: [String]) -> NSMenuItem? {
            var menu: NSMenu? = main
            var item: NSMenuItem?
            for title in path { item = menu?.items.first { $0.title == title }; menu = item?.submenu }
            return item
        }
        func key(_ i: NSMenuItem?) -> String {
            guard let i else { return "-" }
            var s = ""
            let m = i.keyEquivalentModifierMask
            if m.contains(.control) { s += "⌃" }; if m.contains(.option) { s += "⌥" }; if m.contains(.shift) { s += "⇧" }; if m.contains(.command) { s += "⌘" }
            return s + i.keyEquivalent.uppercased()
        }
        let expectedKeys: [([String], String)] = [
            (["File", "New"], "⌘N"), (["File", "Open…"], "⌘O"), (["File", "Close"], "⌘W"), (["File", "Save"], "⌘S"), (["File", "Save As…"], "⇧⌘S"),
            (["File", "Print…"], "⌘P"), (["File", "Page Setup…"], "⇧⌘P"), (["Edit", "Undo"], "⌘Z"), (["Edit", "Redo"], "⇧⌘Z"), (["Edit", "Cut"], "⌘X"),
            (["Edit", "Copy"], "⌘C"), (["Edit", "Paste"], "⌘V"), (["Edit", "Select All"], "⌘A"), (["Edit", "Find", "Find…"], "⌘F"), (["Edit", "Find", "Find Next"], "⌘G"),
            (["Edit", "Find", "Find Previous"], "⇧⌘G"), (["View", "Bigger"], "⌘+"), (["View", "Smaller"], "⌘-"), (["View", "Actual Size"], "⌘0"),
            (["Window", "Minimize"], "⌘M"), (["luftig", "Quit luftig"], "⌘Q"), (["luftig", "Hide luftig"], "⌘H"), (["luftig", "Settings…"], "⌘,"),
        ]
        for (path, k) in expectedKeys { t.equal(key(find(path)), k, "key equivalent of \(path.joined(separator: " > "))") }

        func dump(_ m: NSMenu, _ indent: String) -> [String] {
            m.items.flatMap { i -> [String] in
                let flags = [i.isHidden ? "hidden" : "", i.isAlternate ? "alt" : "", i.isSeparatorItem ? "---" : ""].filter { !$0.isEmpty }.joined(separator: ",")
                return ["\(indent)\(i.isSeparatorItem ? "-----" : i.title) \(i.action.map { NSStringFromSelector($0) } ?? "") \(key(i)) \(flags)"] + (i.submenu.map { dump($0, indent + "    ") } ?? [])
            }
        }
        if CommandLine.arguments.contains("--dump-menu") { dump(main, "").forEach { t.info($0) } }

        // what AppKit did to the menu we installed in applicationWillFinishLaunching
        let flat = dump(main, "").map { $0.trimmingCharacters(in: .whitespaces) }
        t.equal(flat.filter { $0.hasPrefix("Open Recent") }.count, 1, "exactly one Open Recent item (AppKit adds it at launch; adding our own would duplicate it)")
        t.equal(flat.filter { $0.hasPrefix("Enter Full Screen") && !$0.hasSuffix("hidden") }.count, 1, "exactly one visible Enter Full Screen item (added by AppKit)")
        t.check(flat.contains { $0.hasPrefix("Close All") } && flat.contains { $0.hasPrefix("Revert To") } && flat.contains { $0.hasPrefix("Share") }, "AppKit added Close All, Revert To and Share")
        t.note("File menu after launch: \(dump(find(["File"])!.submenu!, "").map { $0.trimmingCharacters(in: .whitespaces) })")

        // responder chain: a document window with an editor
        let doc = try t.newUntitled()
        guard let host = doc.host as? EditorViewController, let window = doc.windowControllers.first?.window else { t.check(false, "no editor"); return }
        t.typeText("some text", into: doc)
        host.textView.setSelectedRange(NSRange(location: 0, length: 4))
        await t.sleep(30)
        window.makeFirstResponder(host.textView)
        t.check(window.firstResponder === host.textView, "text view is first responder")

        func chain(from r: NSResponder) -> [AnyObject] {
            var out: [AnyObject] = []
            var cur: NSResponder? = r
            while let c = cur {
                out.append(c)
                // AppKit routes actions from the window controller to its document (not via nextResponder)
                if let wc = c as? NSWindowController, let d = wc.document { out.append(d as AnyObject) }
                cur = c.nextResponder
            }
            out.append(NSApp)
            if let d = NSApp.delegate { out.append(d as AnyObject) }
            out.append(NSDocumentController.shared)
            return out
        }
        let responders = chain(from: host.textView)
        t.note("responder chain: " + responders.map { String(describing: type(of: $0)) }.joined(separator: " > "))
        var rows: [String] = []
        var unresolved: [String] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            for item in menu.items where !item.isSeparatorItem {
                if let sub = item.submenu { walk(sub, path + [item.title]); continue }
                guard let action = item.action else { continue }
                let name = NSStringFromSelector(action)
                let target = responders.first { $0.responds(to: action) }
                var enabled = "n/a"
                if let target {
                    if let v = target as? NSMenuItemValidation { enabled = v.validateMenuItem(item) ? "enabled" : "disabled" }
                    else if let v = target as? NSUserInterfaceValidations { enabled = v.validateUserInterfaceItem(item) ? "enabled" : "disabled" }
                    else { enabled = "enabled (no validator)" }
                } else { unresolved.append("\((path + [item.title]).joined(separator: " > ")) [\(name)]") }
                rows.append("\((path + [item.title]).joined(separator: " > ").padding(toLength: 44, withPad: " ", startingAt: 0)) \(name.padding(toLength: 40, withPad: " ", startingAt: 0)) -> \(target.map { String(describing: type(of: $0)) } ?? "NOBODY") \(enabled)")
            }
        }
        for item in main.items { if let sub = item.submenu { walk(sub, [item.title]) } }
        rows.forEach { t.info($0) }
        // Items that legitimately have no target while the key window has no such feature: none expected here.
        t.equal(unresolved, [], "every menu action has a responder in the chain")
        func row(_ s: String) -> String { rows.first { $0.hasPrefix(s) } ?? "" }
        t.check(row("File > Save ").contains("MarkdownDocument"), "Save is handled by the document")
        t.check(row("File > New").contains("NSDocumentController"), "New is handled by NSDocumentController")
        t.check(row("Edit > Find > Find…").contains("LuftigEditorTextView") && row("Edit > Find > Find…").contains("enabled"), "Find… handled and enabled by the text view (LuftigEditorTextView, the NSTextView subclass; the spike's plain NSTextView was matched by name)")
        t.check(row("Edit > Cut").contains("enabled"), "Cut enabled with a selection")
        t.check(row("View > Bigger").contains("EditorViewController"), "Bigger/Smaller/Actual Size handled by the editor view controller")
        t.check(row("Window > Minimize").contains("NSWindow") && row("Window > Merge All Windows").contains("NSWindow"), "Window/tab items handled by NSWindow")

        // checkmarks follow state (adapted from the spike's "Wrap Lines": the real editor always wraps; the toggle is now
        // "Wrap to Readable Width", default on)
        let wrapItem = find(["View", "Wrap to Readable Width"])!
        let readable0 = EditorPreferences.readableWidth
        _ = host.validateMenuItem(wrapItem); let on1 = wrapItem.state
        host.luftigToggleReadableWidth(nil)
        _ = host.validateMenuItem(wrapItem); let on2 = wrapItem.state
        t.check(on1 == .on && on2 == .off, "Wrap to Readable Width checkmark follows the state (\(on1.rawValue) -> \(on2.rawValue))")
        host.luftigToggleReadableWidth(nil)
        t.equal(EditorPreferences.readableWidth, readable0, "toggled back")
        let spellItem = find(["View", "Toggle Spell Checking"])!
        _ = host.validateMenuItem(spellItem)
        t.equal(spellItem.state, .off, "Toggle Spell Checking: off by default")
        host.luftigToggleSpellChecking(nil)
        _ = host.validateMenuItem(spellItem)
        t.equal(spellItem.state, .on, "Toggle Spell Checking: on after the first toggle (checkmark follows)")
        host.luftigToggleSpellChecking(nil)
        t.equal(host.textView.isContinuousSpellCheckingEnabled, false, "... and off again")
        let tv = host.textView
        t.check(!tv.isAutomaticQuoteSubstitutionEnabled && !tv.isAutomaticDashSubstitutionEnabled && !tv.isAutomaticTextReplacementEnabled && !tv.isAutomaticLinkDetectionEnabled && !tv.isAutomaticSpellingCorrectionEnabled && !tv.smartInsertDeleteEnabled && !tv.isContinuousSpellCheckingEnabled, "substitutions + spell-check are OFF by default")
        let quotes = find(["Edit", "Substitutions", "Smart Quotes"])!
        _ = tv.validateMenuItem(quotes)
        t.equal(quotes.state, .off, "Smart Quotes menu item shows off")
        let sizeBefore = host.fontSize
        host.luftigIncreaseFontSize(nil)
        t.check(host.fontSize == sizeBefore + 1, "Bigger: \(sizeBefore) -> \(host.fontSize)")
        host.luftigResetFontSize(nil)
        t.equal(host.fontSize, EditorViewController.defaultFontSize, "Actual Size resets")
        let printOp = try? doc.printOperation(withSettings: [:])
        t.check(printOp != nil && printOp?.view is NSTextView, "Print…: printOperation(withSettings:) builds a plain-text print view (the panel itself is not shown)")
        // find bar
        let findItem = find(["Edit", "Find", "Find…"])!
        tv.performTextFinderAction(findItem)
        t.note("performTextFinderAction(showFindInterface) in a never-shown window: findBarVisible=\(host.scrollView.isFindBarVisible)")
        t.close(doc)
    }
}
#endif
