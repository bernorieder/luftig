#if LUFTIG_SELFTEST
// SelfTestAuditShell.swift - scenarios added by the adversarial review of the app shell (menus, bundle, lifecycle, launch).
// Registered in SelfTestScenarios.all through `auditShellScenarios`.

import AppKit
import UniformTypeIdentifiers

extension SelfTestScenarios {
    static let auditShellScenarios: [SelfTest.Scenario] = [
        .init(name: "audit-shell-menu", summary: "live main menu: dead items, key-equivalent duplicates, title conventions, validation matrix in 0 / untitled / saved / dirty / conflicted / deleted states", run: { t in try await auditShellMenu(t) }),
        .init(name: "audit-shell-bundle", summary: "Info.plist of the running bundle: identity, versions, minimum OS vs the binary, icon sizes, document types / UTIs, no privacy keys", run: { t in try await auditShellBundle(t) }),
        .init(name: "audit-shell-prefs", summary: "EditorPreferences: hostile UserDefaults values never crash or escape the allowed range", run: { t in try await auditShellPrefs(t) }),
        .init(name: "audit-shell-runner", summary: "the self-test runner itself: --workdir never deletes a real folder, a killed run's preferences do not leak into the next run", run: { t in try await auditShellRunner(t) }),
        .init(name: "audit-shell-child", summary: "(internal) starts from default preferences: run by audit-shell-runner in a child process", run: { t in try await auditShellPrefsChild(t) }, inAll: false),
    ]

    // MARK: bundle

    /// `minos` of the executable's LC_BUILD_VERSION (or LC_VERSION_MIN_MACOSX) as "major.minor", read from the Mach-O header.
    private static func machOMinimumOS(_ url: URL) -> (minos: String, sdk: String)? {
        guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: 64 * 1024), data.count > 32 else { return nil }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func ver(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF)" }
        guard u32(0) == 0xFEEDFACF else { return nil }        // 64-bit little endian (fat / big endian binaries are not built here)
        var off = 32
        for _ in 0..<Int(u32(16)) {
            guard off + 8 <= data.count else { return nil }
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == 0x32, off + 24 <= data.count { return (ver(u32(off + 12)), ver(u32(off + 16))) }       // LC_BUILD_VERSION: platform, minos, sdk
            if cmd == 0x24, off + 16 <= data.count { return (ver(u32(off + 8)), ver(u32(off + 12))) }        // LC_VERSION_MIN_MACOSX: version, sdk
            off += max(8, size)
        }
        return nil
    }

    @MainActor static func auditShellBundle(_ t: SelfTest.T) async throws {
        let info = Bundle.main.infoDictionary ?? [:]
        func str(_ k: String) -> String { info[k] as? String ?? "" }
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

        // identity and versions
        t.check(matches(str("CFBundleIdentifier"), "^[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+$"), "CFBundleIdentifier is a reverse-DNS name: \(str("CFBundleIdentifier"))")
        t.equal(str("CFBundlePackageType"), "APPL", "CFBundlePackageType")
        t.check(matches(str("CFBundleShortVersionString"), "^[0-9]+(\\.[0-9]+){1,2}$"), "CFBundleShortVersionString is a plain version: \(str("CFBundleShortVersionString"))")
        t.check(matches(str("CFBundleVersion"), "^[0-9]+(\\.[0-9]+){0,2}$"), "CFBundleVersion is numeric: \(str("CFBundleVersion"))")
        t.check(!str("CFBundleName").isEmpty && !str("CFBundleDisplayName").isEmpty && !str("CFBundleDevelopmentRegion").isEmpty, "name, display name, development region are set")
        t.check(str("CFBundleName").count <= 15, "CFBundleName fits the menu bar title limit (15): \(str("CFBundleName"))")
        t.equal(str("NSPrincipalClass"), "NSApplication", "NSPrincipalClass")
        t.check(NSClassFromString(str("NSPrincipalClass")) != nil, "NSPrincipalClass resolves")
        t.check(info["NSHighResolutionCapable"] as? Bool == true, "NSHighResolutionCapable")
        t.check(!str("LSApplicationCategoryType").isEmpty, "LSApplicationCategoryType: \(str("LSApplicationCategoryType"))")
        t.check(!str("NSHumanReadableCopyright").isEmpty, "copyright line for the About panel")
        t.check(info.keys.filter { $0.hasSuffix("UsageDescription") }.isEmpty && info["NSAppTransportSecurity"] == nil, "no privacy usage descriptions, no ATS exceptions (nothing in the app can need them)")
        t.check(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") == nil && Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") == nil, "a regular Dock application (not an agent)")

        // minimum system version vs what the linker recorded
        if let exe = Bundle.main.executableURL, let mo = machOMinimumOS(exe) {
            let plistMin = str("LSMinimumSystemVersion")
            t.note("executable: minos \(mo.minos), linked against SDK \(mo.sdk); Info.plist LSMinimumSystemVersion \(plistMin)")
            t.check(plistMin == mo.minos || plistMin == mo.minos + ".0", "LSMinimumSystemVersion (\(plistMin)) equals the executable's deployment target (\(mo.minos))")
            t.check(ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: Int(mo.minos.split(separator: ".")[0]) ?? 14, minorVersion: 0, patchVersion: 0)), "this OS satisfies the declared minimum")
        } else { t.check(false, "cannot read the Mach-O header of the executable") }

        // icon: the file the plist names exists and carries every size macOS asks for
        let iconName = str("CFBundleIconFile")
        if let iconURL = Bundle.main.url(forResource: (iconName as NSString).deletingPathExtension, withExtension: (iconName as NSString).pathExtension.isEmpty ? "icns" : (iconName as NSString).pathExtension),
           let img = NSImage(contentsOf: iconURL) {
            var px = Set<Int>()
            for r in img.representations { px.insert(r.pixelsWide) }
            t.note("icon \(iconURL.lastPathComponent): pixel widths \(px.sorted())")
            t.check([16, 32, 64, 128, 256, 512, 1024].allSatisfy { px.contains($0) }, "the icon carries 16 / 32 / 64 / 128 / 256 / 512 / 1024 px images (10 iconset entries)")
        } else { t.check(false, "CFBundleIconFile '\(iconName)' does not resolve to a loadable image in Contents/Resources") }

        // document types
        let types = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        t.check(!types.isEmpty, "CFBundleDocumentTypes present (\(types.count))")
        for ty in types {
            let name = ty["CFBundleTypeName"] as? String ?? "?"
            t.check(ty["CFBundleTypeRole"] as? String == "Editor", "\(name): role Editor")
            t.check((ty["NSDocumentClass"] as? String).flatMap { NSClassFromString($0) } != nil, "\(name): NSDocumentClass \(ty["NSDocumentClass"] ?? "nil") resolves to a class")
            t.check(["Default", "Alternate", "Owner", "None"].contains(ty["LSHandlerRank"] as? String ?? ""), "\(name): LSHandlerRank is valid: \(ty["LSHandlerRank"] ?? "nil")")
            t.check(!((ty["LSItemContentTypes"] as? [String]) ?? []).isEmpty || !((ty["CFBundleTypeExtensions"] as? [String]) ?? []).isEmpty, "\(name): declares content types or extensions (no OSType keys)")
            // This bundle is the self-test variant (id ends in .selftest): never a candidate handler for anything. The shipping plist's
            // Alternate ranks are asserted by Scripts/test-build-app.sh.
            if (Bundle.main.bundleIdentifier ?? "").hasSuffix(".selftest") {
                t.equal(ty["LSHandlerRank"] as? String, "None", "\(name): the self-test build is never offered as a handler (rank None)")
            }
        }
        let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
        // An exported type for the rarer extensions once made luftig - and its self-test build - the default app for .mkd and took it from the
        // user's own editor: an exported type changes how EVERY app sees those files. Never again.
        t.check(exported.isEmpty, "no UTExportedTypeDeclarations (an exported type for .mkd & co. hijacks the extension system-wide)")
        let imported = (info["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? []
        let declaredIDs = Set((exported + imported).compactMap { $0["UTTypeIdentifier"] as? String })
        for ty in types { for id in (ty["LSItemContentTypes"] as? [String]) ?? [] {
            t.check(UTType(id) != nil || declaredIDs.contains(id), "content type \(id) is a system type or declared in this plist")
        } }
        for decl in exported {
            let id = decl["UTTypeIdentifier"] as? String ?? "?"
            t.check((decl["UTTypeConformsTo"] as? [String])?.contains("net.daringfireball.markdown") == true, "exported \(id) conforms to net.daringfireball.markdown")
            let exts = ((decl["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? []
            t.check(!exts.isEmpty && Set(exts).count == exts.count, "exported \(id): extensions \(exts), no duplicates")
        }
        let dc = NSDocumentController.shared
        // every extension the exported types claim really opens (".mkd" used to stay an anonymous type that luftig could not open,
        // and the launch blocked on an invisible error alert): a file of each kind goes through the document controller
        for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt"] {
            let u = t.write("# x\n", to: "types/claimed.\(ext)")
            var opened: NSDocument?
            var failure = ""
            do { opened = try await dc.openDocument(withContentsOf: u, display: false).0 } catch { failure = " (\(error.localizedDescription))" }
            t.check(opened is MarkdownDocument, "a .\(ext) file opens as a MarkdownDocument\(failure)")
            opened?.close()
        }
        t.check(dc.documentClassNames.contains { $0.hasSuffix("MarkdownDocument") }, "NSDocumentController sees the document class: \(dc.documentClassNames)")
        t.equal(dc.defaultType, "net.daringfireball.markdown", "new documents are Markdown")
        t.check(info["NSSupportsAutomaticTermination"] as? Bool == true && info["NSSupportsSuddenTermination"] as? Bool == true, "automatic / sudden termination are declared (NSDocument switches them off while there are unsaved edits)")
        t.check(Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") == nil, "no help book in the bundle (the Help menu must not offer one: see audit-shell-menu)")
    }

    // MARK: the runner

    /// Runs this very executable as a child process (`luftig-SelfTest --selftest ...`), without blocking the main run loop.
    @MainActor private static func auditShellChild(_ t: SelfTest.T, _ args: [String]) async -> (status: Int32, output: String) {
        guard let exe = Bundle.main.executableURL else { return (-1, "no executable") }
        return await withCheckedContinuation { (c: CheckedContinuation<(status: Int32, output: String), Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe(), box = DataBox()
            p.standardOutput = pipe; p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }
            p.terminationHandler = { pr in
                pipe.fileHandleForReading.readabilityHandler = nil
                box.append(pipe.fileHandleForReading.readDataToEndOfFile())
                c.resume(returning: (pr.terminationStatus, String(decoding: box.data, as: UTF8.self)))
            }
            do { try p.run() } catch { c.resume(returning: (-1, "\(error)")) }
        }
    }

    @MainActor static func auditShellRunner(_ t: SelfTest.T) async throws {
        let fm = FileManager.default
        // 1. --workdir: the runner deletes its work directory, so it must refuse a folder that holds somebody's files
        let precious = t.url("precious")
        try fm.createDirectory(at: precious.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let keep = precious.appendingPathComponent("Documents/keep.txt")
        try "do not delete".write(to: keep, atomically: false, encoding: .utf8)
        let r1 = await auditShellChild(t, ["--selftest", "codec", "--workdir=\(precious.path)"])
        t.check(fm.fileExists(atPath: keep.path), "--workdir pointing at a folder with files: the files are still there afterwards")
        t.check(r1.status == 2, "... and the runner refuses (exit status \(r1.status), 2 expected)")
        t.check(r1.output.contains("refusing --workdir"), "... with a message that says why: \(r1.output.split(separator: "\n").first.map(String.init) ?? "(no output)")")
        let fresh = t.url("fresh-workdir")
        let r2 = await auditShellChild(t, ["--selftest", "codec", "--workdir=\(fresh.path)"])
        t.check(r2.status == 0 && r2.output.contains("SELFTEST RESULT: PASS"), "--workdir that does not exist yet is used (exit status \(r2.status))")
        t.check(!fm.fileExists(atPath: fresh.path), "... and removed again at the end")
        let empty = t.url("empty-workdir")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let r3 = await auditShellChild(t, ["--selftest", "codec", "--workdir=\(empty.path)"])
        t.check(r3.status == 0 && r3.output.contains("SELFTEST RESULT: PASS"), "--workdir that is an empty directory is used (exit status \(r3.status))")
        let file = t.write("x", to: "a-file")
        let r4 = await auditShellChild(t, ["--selftest", "codec", "--workdir=\(file.path)"])
        t.check(r4.status == 2 && fm.fileExists(atPath: file.path), "--workdir that is a regular file: refused, the file survives (exit status \(r4.status))")

        // 2. a killed run leaves its preferences behind: the next run must start from the defaults
        let ud = UserDefaults.standard
        let saved = EditorPreferences.allKeys.map { ($0, ud.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { ud.set(v, forKey: k) } else { ud.removeObject(forKey: k) } } }
        ud.set(23.0, forKey: EditorPreferences.fontSizeKey)
        ud.set(false, forKey: EditorPreferences.readableWidthKey)
        // ... and what the Settings window leaves behind: fonts, spacing, column width, colour scheme
        ud.set("Georgia", forKey: EditorPreferences.bodyFontFamilyKey)
        ud.set("Menlo", forKey: EditorPreferences.codeFontFamilyKey)
        ud.set(1.9, forKey: EditorPreferences.lineHeightFactorKey)
        ud.set(520.0, forKey: EditorPreferences.columnWidthKey)
        if let other = ColorSchemes.all.first(where: { $0.id != ColorSchemes.defaultID }) { ud.set(other.id, forKey: EditorPreferences.colorSchemeKey) }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let r5 = await auditShellChild(t, ["--selftest", "audit-shell-child"])
        t.check(r5.status == 0 && r5.output.contains("SELFTEST RESULT: PASS"), "a run that starts with font size 23 / narrow column / other fonts / spacing / scheme left over by an earlier run still sees the defaults (exit status \(r5.status))")
        if r5.status != 0 { r5.output.split(separator: "\n").filter { $0.contains("FAIL") }.forEach { t.info(String($0)) } }
    }

    @MainActor static func auditShellPrefsChild(_ t: SelfTest.T) async throws {
        t.equal(EditorPreferences.fontSize, EditorPreferences.defaultFontSize, "font size at the start of a run is the default")
        t.check(EditorPreferences.readableWidth, "readable width at the start of a run is the default (on)")
        t.equal(EditorPreferences.themeSettings, ThemeSettings(baseSize: 16), "fonts, spacing and size at the start of a run are the defaults")
        t.equal(EditorPreferences.columnWidth, EditorPreferences.defaultColumnWidth, "column width at the start of a run is the default")
        t.equal(EditorPreferences.colorSchemeID, ColorSchemes.defaultID, "colour scheme at the start of a run is the default")
    }

    // MARK: preferences

    @MainActor static func auditShellPrefs(_ t: SelfTest.T) async throws {
        let ud = UserDefaults.standard
        let savedSize = ud.object(forKey: EditorPreferences.fontSizeKey), savedWidth = ud.object(forKey: EditorPreferences.readableWidthKey)
        defer {
            if let savedSize { ud.set(savedSize, forKey: EditorPreferences.fontSizeKey) } else { ud.removeObject(forKey: EditorPreferences.fontSizeKey) }
            if let savedWidth { ud.set(savedWidth, forKey: EditorPreferences.readableWidthKey) } else { ud.removeObject(forKey: EditorPreferences.readableWidthKey) }
        }
        let range = EditorPreferences.fontSizeRange
        let hostile: [(String, Any?)] = [("unset", nil), ("string", "abc"), ("numeric string", "22"), ("zero", 0.0), ("negative", -5.0), ("below range", 3.0), ("above range", 1e9),
                                         ("+inf", Double.infinity), ("-inf", -Double.infinity), ("NaN", Double.nan), ("array", [1, 2]), ("bool", true), ("in range", 21.5)]
        for (label, value) in hostile {
            if let value { ud.set(value, forKey: EditorPreferences.fontSizeKey) } else { ud.removeObject(forKey: EditorPreferences.fontSizeKey) }
            let v = EditorPreferences.fontSize
            t.check(v.isFinite && range.contains(v), "font size default '\(label)' -> \(v) stays inside \(range)")
            let theme = Theme(baseSize: v)
            t.check(theme.baseAttributes[.font] != nil, "a Theme can be built from it")
        }
        for (label, value) in [("string", "yes" as Any), ("number 0", 0), ("number 7", 7), ("array", [true]), ("NSNull-ish", [String: Int]())] {
            ud.set(value, forKey: EditorPreferences.readableWidthKey)
            _ = EditorPreferences.readableWidth
            t.check(true, "readable-width default '\(label)' reads without crashing (\(EditorPreferences.readableWidth))")
        }
        ud.set(10.0, forKey: EditorPreferences.fontSizeKey)
        EditorPreferences.fontSize = 3
        t.equal(EditorPreferences.fontSize, range.lowerBound, "setting 3 pt clamps to \(range.lowerBound)")
        EditorPreferences.fontSize = .nan
        t.check(EditorPreferences.fontSize.isFinite && range.contains(EditorPreferences.fontSize), "setting NaN leaves a valid size: \(EditorPreferences.fontSize)")
        EditorPreferences.fontSize = 500
        t.equal(EditorPreferences.fontSize, range.upperBound, "setting 500 pt clamps to \(range.upperBound)")
    }

    // MARK: menu

    private typealias MenuLeaf = (path: String, item: NSMenuItem)
    private static func menuLeaves(_ m: NSMenu, _ prefix: String) -> [MenuLeaf] {
        m.items.flatMap { i -> [MenuLeaf] in
            if i.isSeparatorItem { return [] }
            let p = (prefix.isEmpty ? i.title : prefix + " > " + i.title) + (i.isHidden && i.submenu == nil ? " (hidden)" : "")
            if let s = i.submenu { return menuLeaves(s, p) }
            return [(p, i)]
        }
    }
    private static func keyString(_ i: NSMenuItem) -> String {
        guard !i.keyEquivalent.isEmpty else { return "" }
        let m = i.keyEquivalentModifierMask
        return (m.contains(.control) ? "^" : "") + (m.contains(.option) ? "~" : "") + (m.contains(.shift) ? "$" : "") + (m.contains(.command) ? "@" : "") + i.keyEquivalent.lowercased()
    }
    /// The responders an action travels through for a key window holding `from` (the window controller reaches its document, the
    /// application reaches its delegate and the document controller) - the same walk the `menu` scenario does.
    private static func responderChain(from r: NSResponder?) -> [AnyObject] {
        var out: [AnyObject] = []
        var cur = r
        while let c = cur {
            out.append(c)
            if let wc = c as? NSWindowController, let d = wc.document { out.append(d as AnyObject) }
            cur = c.nextResponder
        }
        out.append(NSApp)
        if let d = NSApp.delegate { out.append(d as AnyObject) }
        out.append(NSDocumentController.shared)
        return out
    }
    /// target class name + enabled flag of one item for a given chain ("-" when nobody responds: AppKit disables the item)
    private static func resolve(_ item: NSMenuItem, in chain: [AnyObject]) -> (target: String, enabled: Bool) {
        guard let action = item.action, let target = chain.first(where: { $0.responds(to: action) }) else { return ("-", false) }
        let name = String(describing: type(of: target))
        if let v = target as? NSMenuItemValidation { return (name, v.validateMenuItem(item)) }
        if let v = target as? NSUserInterfaceValidations { return (name, v.validateUserInterfaceItem(item)) }
        return (name, true)
    }

    @MainActor static func auditShellMenu(_ t: SelfTest.T) async throws {
        guard let main = NSApp.mainMenu else { t.check(false, "no main menu"); return }
        let all = menuLeaves(main, "")

        // -- the live structure, one line per top-level menu (hidden items and alternates marked), for the report
        func dump(_ m: NSMenu) -> String {
            m.items.map { i -> String in
                if i.isSeparatorItem { return "-" }
                var s = i.title + (keyString(i).isEmpty ? "" : " [" + keyString(i) + "]") + (i.isHidden ? " (hidden)" : "") + (i.isAlternate ? " (alt)" : "")
                if let sub = i.submenu { s += " {" + dump(sub) + "}" }
                return s
            }.joined(separator: " | ")
        }
        for top in main.items { if let sub = top.submenu { t.note("menu \(top.title): \(dump(sub))") } }

        // -- dead items and conventions
        let hasHelpBook = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookFolder") != nil
        let helpItems = all.filter { $0.item.action == #selector(NSApplication.showHelp(_:)) }
        t.check(hasHelpBook || helpItems.isEmpty, "no 'Help' menu item that can only show \"Help isn't available\" (the bundle has no help book): \(helpItems.map { $0.path })")
        t.check(main.items.contains { $0.title == "Help" } && NSApp.helpMenu != nil, "the Help menu itself stays registered (AppKit adds its search field to it)")
        // luftig > Settings… (⌘,) opens the Settings window (SettingsWindowController): the ONE item of its kind, in the standard place, no legacy "Preferences" item
        let settingsItems = all.filter { $0.path.lowercased().contains("preferences") || $0.path.lowercased().contains("settings") }
        t.equal(settingsItems.map { $0.path }, ["luftig > Settings…"], "exactly one Settings item (luftig > Settings…) and no 'Preferences' item")
        if let s = settingsItems.first?.item {
            t.check(s.keyEquivalent == "," && s.keyEquivalentModifierMask == [.command] && s.action == #selector(AppDelegate.showSettings(_:)) && s.target == nil, "Settings… is ⌘, and goes through the responder chain to the application delegate (target nil, action showSettings:)")
        }
        if let appMenu = main.items.first?.submenu {
            let titles = appMenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            t.check(titles.starts(with: ["About luftig", "-", "Settings…", "-", "Services"]), "Settings… sits after About and before Services, as on every Mac app: \(titles.prefix(6))")
        }
        func allItems(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map { allItems($0) } ?? []) } }
        t.equal(allItems(main).filter { $0.title == "Open Recent" }.count, 1, "exactly one Open Recent menu")
        var keys: [String: String] = [:]
        var dups: [String] = []
        for l in all where !l.item.isHidden && !l.item.isAlternate && !keyString(l.item).isEmpty {
            let k = keyString(l.item)
            if let prev = keys[k] { dups.append("\(k): \(prev) / \(l.path)") } else { keys[k] = l.path }
        }
        t.equal(dups, [], "no key equivalent is bound twice among the visible, non-alternate items (\(keys.count) bound)")
        let needEllipsis = ["luftig > Settings…", "File > Open…", "File > Save As…", "File > Rename…", "File > Move To…", "File > Page Setup…", "File > Print…", "Edit > Find > Find…", "Edit > Find > Find and Replace…"]
        for p in needEllipsis { t.check(all.contains { $0.path == p }, "'\(p)' exists and its title ends with the ellipsis character") }
        t.check(all.filter { $0.item.title.hasSuffix("...") }.isEmpty, "no title ends with three ASCII dots instead of the ellipsis character")
        // items that look like toggles must be state-bearing or plain actions; nothing may carry a keyEquivalent without an action
        t.check(all.filter { !keyString($0.item).isEmpty && $0.item.action == nil }.isEmpty, "no key equivalent on an item without an action")

        // -- validation matrix
        let dir = t.work
        let saved = t.write("# Saved\n\nparagraph one\n\nparagraph two\n\nparagraph three\n", to: "menu-saved.md")
        typealias Row = (state: String, rows: [String: (String, Bool)])
        var matrix: [Row] = []
        func snapshot(_ state: String, _ chain: [AnyObject]) {
            var r: [String: (String, Bool)] = [:]
            for l in all { r[l.path] = resolve(l.item, in: chain) }
            matrix.append((state, r))
        }
        t.info("step: no window")
        snapshot("no window", responderChain(from: nil))
        t.info("step: untitled")
        let untitled = try t.newUntitled()
        snapshot("untitled", responderChain(from: t.editor(untitled)?.textView))
        t.info("step: open saved")
        let clean = try await t.open(saved)
        snapshot("saved, clean", responderChain(from: t.editor(clean)?.textView))
        t.typeText("EDIT ", into: clean, at: NSRange(location: 2, length: 0))
        snapshot("saved, dirty", responderChain(from: t.editor(clean)?.textView))
        t.close(untitled); t.close(clean)
        // conflicted: overlapping external edit of a dirty document
        let cfile = t.write("alpha\nbeta\ngamma\n", to: "menu-conflict.md")
        let conf = try await t.open(cfile)
        await t.sleep(1300)
        t.typeText("MINE ", into: conf, at: NSRange(location: 6, length: 0))
        await t.sh("printf 'alpha\\nTHEIRS beta\\ngamma\\n' > \(t.q(cfile))")
        let gotConflict = await t.waitFor(4000) { conf.syncState == .conflict }
        t.check(gotConflict, "set-up: overlapping edit puts the document into the conflict state")
        snapshot("conflicted", responderChain(from: t.editor(conf)?.textView))
        t.close(conf)
        // deleted on disk
        let dfile = t.write("to be deleted\n", to: "menu-deleted.md")
        let del = try await t.open(dfile)
        await t.sleep(1300)
        await t.sh("rm \(t.q(dfile))")
        let gotDeleted = await t.waitFor(5000) { del.syncState == .deletedOnDisk }
        t.check(gotDeleted, "set-up: rm puts the document into the deleted state")
        snapshot("deleted", responderChain(from: t.editor(del)?.textView))
        UITrap.reset()
        t.note("Reload from Disk on a document whose file was deleted: validate=\(resolve(all.first { $0.path == "File > Reload from Disk" }!.item, in: responderChain(from: t.editor(del)?.textView)))")
        del.luftigReloadFromDisk(nil)
        await t.sleep(400)
        t.note("... after choosing it: alerts=\(UITrap.alerts.map { $0.message }) banner=\(t.editor(del)?.bannerVisible == true ? (t.editor(del)?.bannerText ?? "") : "none") state=\(del.syncState)")
        t.close(del)
        _ = dir

        func cell(_ state: String, _ path: String) -> (String, Bool) { matrix.first { $0.state == state }?.rows[path] ?? ("?", false) }
        for row in matrix {
            let on = all.filter { row.rows[$0.path]?.1 == true }.map { $0.path }
            t.note("[\(row.state)] \(on.count) of \(all.count) items enabled; disabled: \(all.filter { row.rows[$0.path]?.1 != true }.map { $0.path }.joined(separator: " | "))")
        }
        // with no window: only application-level items work; nothing may be enabled that needs a document or an editor
        for p in ["File > New", "File > Open…", "luftig > Quit luftig", "luftig > About luftig", "luftig > Settings…"] { t.check(cell("no window", p).1, "no window: '\(p)' is enabled (\(cell("no window", p).0))") }
        for p in ["File > Close", "File > Save", "File > Save As…", "File > Print…", "File > Reload from Disk", "Edit > Cut", "Edit > Paste", "Edit > Find > Find…", "View > Bigger", "View > Wrap to Readable Width", "Window > Minimize"] {
            t.check(!cell("no window", p).1, "no window: '\(p)' is disabled (\(cell("no window", p).0))")
        }
        for st in ["untitled", "saved, clean", "saved, dirty", "conflicted", "deleted"] {
            for p in ["File > New", "File > Open…", "File > Close", "File > Save", "File > Save As…", "File > Print…", "Edit > Select All", "Edit > Find > Find…", "View > Wrap to Readable Width", "luftig > Settings…"] {
                t.check(cell(st, p).1, "\(st): '\(p)' is enabled (\(cell(st, p).0))")
            }
        }
        t.check(!cell("untitled", "File > Reload from Disk").1, "untitled: Reload from Disk is disabled (there is no file)")
        t.check(cell("saved, clean", "File > Reload from Disk").1 && cell("saved, dirty", "File > Reload from Disk").1, "saved documents: Reload from Disk is enabled")
        t.check(UITrap.violations.isEmpty, "UITrap: nothing outside the work directory was touched")

        // -- ⌘+ is ⇧⌘= on a US keyboard: the View menu must answer BOTH ⌘= and ⇧⌘= (it used to answer only ⇧⌘=, so ⌘= did nothing)
        let growers = all.filter { $0.item.action == #selector(LuftigEditorActions.luftigIncreaseFontSize(_:)) }
        t.check(growers.contains { $0.item.keyEquivalent == "=" && $0.item.keyEquivalentModifierMask == [.command] } && growers.contains { $0.item.keyEquivalent == "+" }, "View > Bigger is bound to ⌘+ and to ⌘= (\(growers.map { keyString($0.item) }))")
        let editorDoc = try t.newUntitled()
        if let editor = t.editor(editorDoc) {
            let savedSize = EditorPreferences.fontSize
            defer { EditorPreferences.fontSize = savedSize }
            EditorPreferences.fontSize = 16
            let probe = NSMenu(title: "probe")
            for g in growers { let c = g.item.copy() as! NSMenuItem; c.target = editor; c.isHidden = false; probe.addItem(c) }
            func event(_ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 24)!
            }
            let handledEquals = probe.performKeyEquivalent(with: event("=", [.command]))
            t.check(handledEquals && EditorPreferences.fontSize == 17, "⌘= (US keyboard, no shift) makes the text bigger: handled \(handledEquals), size \(EditorPreferences.fontSize) (17 expected)")
            let handledPlus = probe.performKeyEquivalent(with: event("+", [.command, .shift]))
            t.check(handledPlus && EditorPreferences.fontSize == 18, "⇧⌘= (typing ⌘+) makes the text bigger: handled \(handledPlus), size \(EditorPreferences.fontSize) (18 expected)")
        } else { t.check(false, "no editor for the untitled document") }
        t.close(editorDoc)
    }
}
#endif
