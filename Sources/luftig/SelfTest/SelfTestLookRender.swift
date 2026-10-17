#if LUFTIG_SELFTEST
// SelfTestLookRender.swift - the internal scenarios of SelfTestLook.swift: `look-render` (PNGs of the screens that the ordinary `render` does not show: the banner in both
// styles, the find bar, a legacy scroller, the alerts, the app icon) and `look-defaults` (a dump of property values to diff between two builds).
//
//   luftig-SelfTest --selftest look-render --out-dir DIR [--input f.md] --workdir=...
//   luftig-SelfTest --selftest look-defaults --workdir=... > values.txt
//
// Nothing is ever put on screen: the windows are never ordered front, alerts are trapped by UITrap (this file takes a second look at them on their way) and drawn
// offscreen. NOT visible here (the title bar and window frame are drawn by the window server, not by the content view): title bar, tab bar, full-screen chrome.

import AppKit
import MachO
import ObjectiveC

/// Remembers the NSAlerts that the app code presented (UITrap answers them at once; this keeps a reference so that they can be drawn). Installed once, AFTER UITrap.
enum LookAlertCapture {
    nonisolated(unsafe) static var captured: [NSAlert] = []
    nonisolated(unsafe) static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        for (a, b) in [(#selector(NSAlert.runModal), #selector(NSAlert.look_runModal)),
                       (#selector(NSAlert.beginSheetModal(for:completionHandler:)), #selector(NSAlert.look_beginSheetModal(for:completionHandler:)))] {
            if let m1 = class_getInstanceMethod(NSAlert.self, a), let m2 = class_getInstanceMethod(NSAlert.self, b) { method_exchangeImplementations(m1, m2) }
        }
    }
}

extension NSAlert {
    @objc fileprivate func look_runModal() -> NSApplication.ModalResponse {
        LookAlertCapture.captured.append(self)
        return look_runModal()           // (swapped: the implementation that was there before, UITrap's)
    }
    @objc fileprivate func look_beginSheetModal(for window: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)?) {
        LookAlertCapture.captured.append(self)
        look_beginSheetModal(for: window, completionHandler: handler)
    }
}

extension SelfTestScenarios {

    @MainActor static func lookPNG(_ view: NSView, background: NSColor? = nil) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bg = background?.usingColorSpace(.sRGB) else { return rep.representation(using: .png, properties: [:]) }
        // composite on an opaque surface colour (CoreGraphics, so that no appearance or drawing context decides): a sheet's own background is drawn by its window frame,
        // which a snapshot of the content view does not include
        guard let cg = rep.cgImage, let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.setFillColor(red: bg.redComponent, green: bg.greenComponent, blue: bg.blueComponent, alpha: 1)
        ctx.fill(full)
        ctx.draw(cg, in: full)
        guard let merged = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: merged).representation(using: .png, properties: [:])
    }

    @MainActor static func lookRender(_ t: SelfTest.T) async throws {
        guard let dir = SelfTest.argument("out-dir") else { t.check(false, "usage: --selftest look-render --out-dir DIR [--input f.md]"); return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func save(_ data: Data?, _ name: String) {
            guard let data else { t.check(false, "could not render \(name)"); return }
            do { try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)); t.check(true, "rendered \(name) (\(data.count / 1024) KB)") } catch { t.check(false, "could not write \(name): \(error)") }
        }
        let text = (SelfTest.argument("input").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }) ?? SelfTestCorpus.markdown(bytes: 40_000, seed: 3)
        LookAlertCapture.install()

        for (appearance, aname) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
            let (doc, host, file) = try await openEditor(t, text: text, name: "look-render-\(aname).md", size: NSSize(width: 860, height: 520))
            guard let w = doc.windowControllers.first?.window, let content = w.contentView else { continue }
            w.appearance = NSAppearance(named: appearance)
            w.setContentSize(NSSize(width: 860, height: 520))
            content.layoutSubtreeIfNeeded()
            host.styler.styleVisible()
            let tv = host.textView, sv = host.scrollView

            // banner: both styles, a long message in a narrow window
            host.showBanner(EditorBanner(message: "“\(file.lastPathComponent)” was changed on disk, and you have unsaved changes.", style: .warning, buttons: [("Reload from Disk", {}), ("Keep My Version", {})]))
            save(lookPNG(content), "banner-warning-\(aname).png")
            host.showBanner(EditorBanner(message: "“\(file.lastPathComponent)” was changed on disk. Your changes and the other changes were merged.", style: .info, buttons: [("Show Changes", {}), ("OK", {})]))
            save(lookPNG(content), "banner-info-\(aname).png")
            w.setContentSize(NSSize(width: 420, height: 520))
            host.showBanner(EditorBanner(message: "“a-document-with-a-rather-long-name-that-needs-room.md” was changed on disk by another application, and you have unsaved changes.", style: .warning, buttons: [("Reload from Disk", {}), ("Keep My Version", {})]))
            save(lookPNG(content), "banner-narrow-\(aname).png")
            host.hideBanner()
            w.setContentSize(NSSize(width: 860, height: 520))
            content.layoutSubtreeIfNeeded()

            // find bar (the native one, shown through the text finder action: ⌘F)
            let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performTextFinderAction(item)
            content.layoutSubtreeIfNeeded()
            save(lookPNG(content), "find-\(aname).png")
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            tv.performTextFinderAction(item)

            // a legacy scroller (always visible), at the top and at the end
            sv.scrollerStyle = .legacy
            sv.hasVerticalScroller = true
            content.layoutSubtreeIfNeeded()
            tv.scroll(.zero); sv.reflectScrolledClipView(sv.contentView)
            host.styler.styleVisible()
            save(lookPNG(content), "legacy-scroller-top-\(aname).png")
            tv.moveToEndOfDocument(nil)
            host.styler.styleVisible()
            _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
            content.layoutSubtreeIfNeeded()
            save(lookPNG(content), "legacy-scroller-end-\(aname).png")
            sv.scrollerStyle = NSScroller.preferredScrollerStyle
            tv.scroll(.zero); sv.reflectScrolledClipView(sv.contentView)

            // the alerts the document code presents (trapped by UITrap, drawn from the captured NSAlert)
            LookAlertCapture.captured.removeAll()
            doc.presentOverwriteSheet { _ in }
            doc.syncState = .conflict
            doc.presentCloseSheet { _ in }
            doc.syncState = .deletedOnDisk
            doc.presentCloseSheet { _ in }
            doc.syncState = .inSync
            t.typeText("edit", into: doc, at: NSRange(location: 0, length: 0))
            await t.sleep(30)                                  // (the edited state is set a moment after typing)
            doc.luftigReloadFromDisk(nil)
            let names = ["alert-overwrite", "alert-close-conflict", "alert-close-deleted", "alert-reload"]
            t.check(LookAlertCapture.captured.count == names.count, "the four alerts were presented and captured (\(LookAlertCapture.captured.count))")
            for (alert, name) in zip(LookAlertCapture.captured, names) {
                alert.window.appearance = NSAppearance(named: appearance)
                alert.layout()
                await t.sleep(250)                              // (the icon is made lazily)
                if let cv = alert.window.contentView {
                    t.note("\(name)-\(aname): content \(lookRect(cv.frame)), buttons \(alert.buttons.map { "\($0.title) \(lookRect(cv.convert($0.bounds, from: $0)))" })")
                    save(lookPNG(cv, background: appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)), "\(name)-\(aname).png")          // (an opaque stand-in for the sheet's own background)
                }
            }
            t.close(doc)
        }

        // the app icon the alerts and the About panel use (NSApp.applicationIconImage) and the one Finder and the Dock get (NSWorkspace; only the self-test bundle is looked at)
        let appIcon = NSApp.applicationIconImage
        t.note("NSApp.applicationIconImage: \(appIcon.map { "\($0.size) \($0.representations.count) representations" } ?? "nil")")
        if let appIcon {
            let big = NSImage(size: NSSize(width: 256, height: 256))
            big.lockFocus(); appIcon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256)); big.unlockFocus()
            if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { save(rep.representation(using: .png, properties: [:]), "app-icon-nsapp.png") }
        }
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let img = NSImage(size: NSSize(width: 256, height: 256))
        img.lockFocus(); icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256)); img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { save(rep.representation(using: .png, properties: [:]), "app-icon.png") }
    }


    // MARK: look-cost

    /// The names of all images (dylibs) loaded into this process.
    static func lookImages() -> Set<String> {
        var s = Set<String>()
        for i in 0..<_dyld_image_count() { if let n = _dyld_get_image_name(i) { s.insert(String(cString: n)) } }
        return s
    }

    /// COST lines for a fresh process: `COST <step> <ms> <footprint MB> <images loaded by this step>` and the new images that are not in the dyld shared cache's usual set.
    @MainActor static func lookCost(_ t: SelfTest.T) async throws {
        var known = lookImages()
        var lastFootprint = ProcessMetrics.residentBytes()
        func step(_ name: String, _ body: () async throws -> Void) async rethrows {
            let t0 = SelfTest.nowMs()
            try await body()
            let ms = SelfTest.nowMs() - t0
            let now = lookImages(), added = now.subtracting(known)
            known = now
            let fp = ProcessMetrics.residentBytes()
            out("COST \(name) \(String(format: "%.2f", ms)) \(String(format: "%.1f", Double(fp - lastFootprint) / 1_048_576)) \(added.count) \(added.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ","))")
            lastFootprint = fp
        }
        out("COST start 0 \(String(format: "%.1f", Double(lastFootprint) / 1_048_576)) \(known.count) -")
        let text = (try? String(contentsOfFile: SelfTest.argument("input") ?? "", encoding: .utf8)) ?? SelfTestCorpus.markdown(bytes: 40_000, seed: 3)
        let url = t.write(text, to: "look-cost.md")
        var doc: MarkdownDocument?
        var host: EditorViewController?
        await step("open-window") {
            let r = try? await openOnce(url, width: 860, height: 700)
            doc = r?.doc
            host = doc?.host as? EditorViewController
        }
        guard let doc, let host, let w = doc.windowControllers.first?.window, let content = w.contentView else { t.check(false, "no window"); return }
        await step("banner") {
            host.showBanner(EditorBanner(message: "“look-cost.md” was changed on disk, and you have unsaved changes.", style: .warning, buttons: [("Reload from Disk", {}), ("Keep My Version", {})]))
            content.layoutSubtreeIfNeeded()
            _ = LookShot(content)
            host.hideBanner()
        }
        await step("find-bar") {
            let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            host.textView.performTextFinderAction(item)
            content.layoutSubtreeIfNeeded()
            _ = LookShot(content)
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            host.textView.performTextFinderAction(item)
        }
        await step("settings-window") {
            SettingsWindowController.headless = true
            let c = SettingsWindowController.shared
            c.present()
            c.window?.contentView?.layoutSubtreeIfNeeded()
            if let v = c.window?.contentView { _ = LookShot(v) }
        }
        await step("alert") {
            let a = NSAlert()
            a.messageText = "“look-cost.md” has unsaved changes."
            a.informativeText = "Overwrite the file with your version, or discard your changes."
            a.addButton(withTitle: "Overwrite File"); a.addButton(withTitle: "Discard My Changes"); a.addButton(withTitle: "Cancel")
            a.layout()
            if let v = a.window.contentView { _ = LookShot(v) }
        }
        t.close(doc)
        t.check(true, "measured")
    }

    // MARK: look-defaults

    nonisolated(unsafe) static var lookDumpSkip: Set<String> = Set((SelfTest.argument("skip") ?? "").split(separator: ",").map(String.init))

    /// `class.property = value` for the public primitive properties (BOOL, numbers, geometry structs, strings, colours) of `obj` and its superclasses up to NSObject.
    @MainActor static func lookDump(_ obj: NSObject, as label: String) {
        var cls: AnyClass? = type(of: obj)
        var seen = Set<String>()
        let skip: Set<String> = ["hash", "superclass", "description", "debugDescription", "isProxy", "retainCount", "isFlipped"]
        while let c = cls, c != NSObject.self {
            var n: UInt32 = 0
            if let list = class_copyPropertyList(c, &n) {
                for i in 0..<Int(n) {
                    let name = String(cString: property_getName(list[i]))
                    guard !name.hasPrefix("_"), !name.hasPrefix("accessibility"), !skip.contains(name), seen.insert(name).inserted, let raw = property_getAttributes(list[i]) else { continue }
                    let attrs = String(cString: raw)
                    let type = attrs.split(separator: ",").first.map(String.init) ?? ""
                    let simple = type.hasPrefix("Tc") || type.hasPrefix("TB") || type.hasPrefix("Tq") || type.hasPrefix("TQ") || type.hasPrefix("Ti") || type.hasPrefix("TI") || type.hasPrefix("Td") || type.hasPrefix("Tf") || type.hasPrefix("Tl") || type.hasPrefix("TL") || type.hasPrefix("T{") || type.hasPrefix("T@\"NSString\"") || type.hasPrefix("T@\"NSColor\"")
                    guard simple, !lookDumpSkip.contains("\(c).\(name)") else { continue }
                    FileHandle.standardError.write(Data("READING \(c).\(name)\n".utf8))           // the last one before a crash is the culprit: --skip=Class.name,... leaves it out
                    out("  \(label) \(c).\(name) = \(String(describing: obj.value(forKey: name) ?? "nil"))")
                }
                free(list)
            }
            cls = class_getSuperclass(c)
        }
    }

    @MainActor static func lookDefaults(_ t: SelfTest.T) async throws {
        out("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // the objects of the real editor window
        let (doc, host, _) = try await openEditor(t, text: "# Title\n\nSome text\n", name: "look-defaults.md", size: NSSize(width: 860, height: 600))
        guard let w = doc.windowControllers.first?.window else { return }
        w.appearance = NSAppearance(named: .aqua)
        host.styler.styleVisible()
        host.showBanner(EditorBanner(message: "banner", style: .warning, buttons: [("Reload from Disk", {}), ("Keep My Version", {})]))
        w.contentView?.layoutSubtreeIfNeeded()
        lookDump(w, as: "editor-window")
        lookDump(host.scrollView, as: "editor-scrollview")
        lookDump(host.scrollView.contentView, as: "editor-clipview")
        if let s = host.scrollView.verticalScroller { lookDump(s, as: "editor-vertical-scroller") }
        lookDump(host.textView, as: "editor-textview")
        if let b = (host.view.subviews.first as? BannerView)?.buttonStack.arrangedSubviews.first as? NSButton { lookDump(b, as: "banner-button") }
        if let b = host.view.subviews.first as? BannerView { lookDump(b.messageField, as: "banner-message") }
        t.close(doc)
        // freshly made controls (what an unset property gets from the SDK the program was linked with)
        let fresh: [(String, NSObject)] = [
            ("button", NSButton(title: "Title", target: nil, action: nil)), ("checkbox", NSButton(checkboxWithTitle: "Title", target: nil, action: nil)),
            ("slider", NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)), ("stepper", NSStepper()), ("popup", NSPopUpButton(frame: .zero, pullsDown: false)),
            ("label", NSTextField(labelWithString: "x")), ("field", NSTextField(string: "x")), ("scrollview", NSScrollView()), ("box", NSBox()), ("gridview", NSGridView()),
            ("stackview", NSStackView()), ("window", NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)),
            ("panel", NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: true)),
            ("alert", NSAlert()),
        ]
        for (name, obj) in fresh { lookDump(obj, as: "fresh-\(name)") }
        out("metrics: legacy scroller \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)), overlay \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)), preferred style \(NSScroller.preferredScrollerStyle.rawValue)")
        for cs in [NSControl.ControlSize.regular, .small, .mini] { out("metrics: control size \(cs.rawValue): button \(NSButton(title: "Title", target: nil, action: nil).also { $0.controlSize = cs }.intrinsicContentSize), popup \(NSPopUpButton(frame: .zero, pullsDown: false).also { $0.controlSize = cs; $0.addItem(withTitle: "Title") }.intrinsicContentSize), slider \(NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil).also { $0.controlSize = cs }.intrinsicContentSize), field \(NSTextField(string: "x").also { $0.controlSize = cs }.intrinsicContentSize)") }
        t.check(true, "dumped")
    }
}

private extension NSObject {
    func also(_ f: (Self) -> Void) -> Self { f(self); return self }
}
#endif
