#if LUFTIG_SELFTEST
// SelfTestLook.swift - the look of the app on macOS 26 and later (the executable is re-stamped SDK 27.0 / minos 14.0 by Package.swift, so AppKit gives
// it the current system design: 32 pt title bar, new scrollers, flat translucent buttons, scroll pockets, ...). Registered through `lookScenarios`.
//
//   look-stamp     the Mach-O says minos 14.0 / SDK >= 26 and the OS really draws the new chrome (title bar, scroller width): FAILS on a classic-stamped build
//   look-editor    what the new chrome must not do to the editor: still TextKit 1 with our layout manager; the text container starts below the title bar,
//                  the first line is fully visible at scroll position 0 and nothing paints over it (a scroll-edge effect / pocket), the last line is
//                  reachable, a legacy scroller takes its width from the content and the column stays centred, the find bar does not cover text
//   look-banner    the conflict banner under the new (flat, translucent) buttons: geometry, no overlap, every title legible on its fill (pixels), both
//                  styles, both appearances, three widths
//   look-settings  the Settings window under the new control metrics: nothing overlaps, every pop-up shows its selected title in full (numbers only for the rest)
//   look-render    (internal) PNGs for review: --out-dir DIR   (banner, find bar, legacy scroller, alerts, app icon)
//   look-cost      (internal) cost of the first use of each screen in a fresh process (A/B between builds)
//   look-defaults  (internal) the values of the public primitive properties of the views we use and of freshly made controls: diff two builds

import AppKit

extension SelfTestScenarios {
    static let lookScenarios: [SelfTest.Scenario] = [
        .init(name: "look-stamp", summary: "the executable is stamped minos 14.0 / SDK >= 26 and macOS draws the current chrome (title bar 32 pt, 17 pt scrollers)", run: { t in try await lookStamp(t) }),
        .init(name: "look-editor", summary: "new chrome vs the editor: TextKit 1 kept, first line fully visible and not painted over, last line reachable, legacy scroller, find bar", run: { t in try await lookEditor(t) }),
        .init(name: "look-banner", summary: "conflict banner with the flat translucent buttons: geometry, legibility on pixels, 2 styles x 2 appearances x 3 widths", run: { t in try await lookBanner(t) }),
        .init(name: "look-settings", summary: "Settings window under the new control metrics: no overlaps, pop-up titles fit, light + dark", run: { t in try await lookSettings(t) }),
        .init(name: "look-render", summary: "(internal) PNGs for review: --out-dir DIR (banner, find bar, legacy scroller, alerts, app icon)", run: { t in try await lookRender(t) }, inAll: false),
        .init(name: "look-cost", summary: "(internal) one fresh process: time, footprint and loaded libraries of the first editor window, banner, find bar, Settings window and alert (the new controls are hosted views: what do they cost?)", run: { t in try await lookCost(t) }, inAll: false),
        .init(name: "look-defaults", summary: "(internal) values of the public primitive properties of our views and of fresh controls, one per line: diff two builds", run: { t in try await lookDefaults(t) }, inAll: false),
    ]

    // MARK: helpers

    /// `minos` and `sdk` of the executable's LC_BUILD_VERSION, as (major, minor).
    static func lookMachO(_ url: URL) -> (minos: (Int, Int), sdk: (Int, Int))? {
        guard let h = try? FileHandle(forReadingFrom: url), let data = try? h.read(upToCount: 64 * 1024), data.count > 32 else { return nil }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func ver(_ v: UInt32) -> (Int, Int) { (Int(v >> 16), Int((v >> 8) & 0xFF)) }
        guard u32(0) == 0xFEEDFACF else { return nil }
        var off = 32
        for _ in 0..<Int(u32(16)) {
            guard off + 8 <= data.count else { return nil }
            let cmd = u32(off), size = Int(u32(off + 4))
            if cmd == 0x32, off + 24 <= data.count { return (ver(u32(off + 12)), ver(u32(off + 16))) }
            off += max(8, size)
        }
        return nil
    }

    /// The SDK version the OS believes the running program was linked against (`dyld_get_program_sdk_version`), as (major, minor).
    static func lookProgramSDK() -> (Int, Int)? {
        typealias Fn = @convention(c) () -> UInt32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_get_program_sdk_version") else { return nil }       // RTLD_DEFAULT
        let v = unsafeBitCast(sym, to: Fn.self)()
        return (Int(v >> 16), Int((v >> 8) & 0xFF))
    }

    static func lookRect(_ r: NSRect) -> String { String(format: "(%.1f, %.1f, %.1f x %.1f)", r.minX, r.minY, r.width, r.height) }
    static func lookInsets(_ i: NSEdgeInsets) -> String { String(format: "t%.1f l%.1f b%.1f r%.1f", i.top, i.left, i.bottom, i.right) }
    static func lookZero(_ i: NSEdgeInsets) -> Bool { i.top == 0 && i.left == 0 && i.bottom == 0 && i.right == 0 }

    /// The height of the title bar of a window = frame - content rect.
    @MainActor static func lookTitleBarHeight(_ w: NSWindow) -> CGFloat { w.frame.height - w.contentRect(forFrameRect: w.frame).height }

    /// A bitmap of the window's content view, top-left origin: `pixel(x, y)` in POINTS of the view, (r, g, b) in 0...1 (sRGB).
    @MainActor final class LookShot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: NSSize
        init?(_ view: NSView) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            self.rep = rep; size = view.bounds.size; scale = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        }
        func rgb(px x: Int, py y: Int) -> (Double, Double, Double) {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        /// Relative luminance (WCAG) of every pixel in `r` (view points, top-left origin).
        func luminances(in r: NSRect) -> [Double] {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            var out: [Double] = []
            let x0 = Int((r.minX * scale).rounded(.down)), x1 = Int((r.maxX * scale).rounded(.up)), y0 = Int((r.minY * scale).rounded(.down)), y1 = Int((r.maxY * scale).rounded(.up))
            guard x1 > x0, y1 > y0 else { return out }
            for y in y0..<y1 { for x in x0..<x1 { let c = rgb(px: x, py: y); out.append(0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)) } }
            return out
        }
        /// Contrast of the "ink" against the "fill" inside `r`: the fill is the median luminance, the ink the 2nd percentile at the far side from it.
        func inkContrast(in r: NSRect) -> Double {
            let l = luminances(in: r).sorted()
            guard l.count > 20 else { return 0 }
            let fill = l[l.count / 2]
            let lo = l[l.count / 50], hi = l[l.count - 1 - l.count / 50]
            let ink = abs(fill - lo) >= abs(hi - fill) ? lo : hi
            return (max(fill, ink) + 0.05) / (min(fill, ink) + 0.05)
        }
        /// Pixels that differ between this shot and another view's bitmap over the same top-left rectangle (points); `tolerance` per channel in 0...255.
        func differingPixels(_ other: NSBitmapImageRep, in r: NSRect, otherOrigin: NSPoint = .zero, tolerance: Int = 0) -> Int {
            var n = 0
            let x0 = Int((r.minX * scale).rounded(.down)), x1 = Int((r.maxX * scale).rounded(.up)), y0 = Int((r.minY * scale).rounded(.down)), y1 = Int((r.maxY * scale).rounded(.up))
            let ox = Int((otherOrigin.x * scale).rounded()), oy = Int((otherOrigin.y * scale).rounded())
            for y in y0..<y1 { for x in x0..<x1 {
                guard let a = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = other.colorAt(x: x - x0 + ox, y: y - y0 + oy)?.usingColorSpace(.sRGB) else { continue }
                if abs(Int((a.redComponent - b.redComponent) * 255)) > tolerance || abs(Int((a.greenComponent - b.greenComponent) * 255)) > tolerance || abs(Int((a.blueComponent - b.blueComponent) * 255)) > tolerance { n += 1 }
            } }
            return n
        }
    }

    /// The frame of `v` in `root`'s coordinates, converted to a top-left origin (what a bitmap uses).
    @MainActor static func lookTopLeft(_ v: NSView, in root: NSView) -> NSRect {
        let r = root.convert(v.bounds, from: v)
        return root.isFlipped ? r : NSRect(x: r.minX, y: root.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    // MARK: look-stamp

    @MainActor static func lookStamp(_ t: SelfTest.T) async throws {
        guard let exe = Bundle.main.executableURL, let mo = lookMachO(exe) else { t.check(false, "cannot read LC_BUILD_VERSION of the executable"); return }
        t.note("executable: minos \(mo.minos.0).\(mo.minos.1), SDK \(mo.sdk.0).\(mo.sdk.1); the OS reads the SDK as \(lookProgramSDK().map { "\($0.0).\($0.1)" } ?? "?"); running on \(ProcessInfo.processInfo.operatingSystemVersionString)")
        t.check(mo.minos == (14, 0), "the deployment target is still macOS 14.0 (minos \(mo.minos.0).\(mo.minos.1)): the app still runs on macOS 14")
        t.equal(Bundle.main.infoDictionary?["LSMinimumSystemVersion"] as? String, "14.0", "Info.plist LSMinimumSystemVersion is 14.0 as well")
        t.check(mo.sdk.0 >= 26, "the executable is stamped with an SDK >= 26 (is \(mo.sdk.0).\(mo.sdk.1)): the newest systems then draw it with the current design (Package.swift, linkerSettings)")
        if let p = lookProgramSDK() { t.check(p.0 >= 26, "dyld_get_program_sdk_version() = \(p.0).\(p.1): what AppKit decides the look by") } else { t.check(false, "dyld_get_program_sdk_version not found") }

        // what the OS makes of it (only on a system that has the new design): the title bar and the scrollers are the visible part
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
            let (doc, _, _) = try await openEditor(t, text: "# x\n", name: "look-stamp.md")
            if let w = doc.windowControllers.first?.window {
                t.check(lookTitleBarHeight(w) >= 32, "macOS 26+: the title bar is 32 pt (new chrome), not the classic 28 pt (is \(lookTitleBarHeight(w)) pt)")
            }
            t.check(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) >= 17, "macOS 26+: a legacy scroller is 17 pt wide (new design), not the classic 15 pt (is \(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) pt)")
            t.close(doc)
        } else { t.note("this system is older than macOS 26: only the stamp is checked") }
    }

    // MARK: look-editor

    @MainActor static func lookEditor(_ t: SelfTest.T) async throws {
        let text = "# A title on the first line\n\nThe first paragraph. " + String(repeating: "Words that fill a line and wrap in the column. ", count: 30) + "\n\n" + SelfTestCorpus.markdown(bytes: 60_000, seed: 7)
        let (doc, host, _) = try await openEditor(t, text: text, name: "look-editor.md", size: NSSize(width: 860, height: 700))
        guard let w = doc.windowControllers.first?.window, let content = w.contentView else { t.check(false, "no window"); return }
        let tv = host.textView, sv = host.scrollView, clip = sv.contentView
        defer { t.close(doc) }
        // this scenario is about the system's chrome around the TEXT VIEW: the three elements around the text (outline, word count, syntax bar) are hidden for it
        let chromeSaved = (EditorPreferences.showOutline, EditorPreferences.showWordCount, EditorPreferences.showSyntaxBar)
        EditorPreferences.showOutline = false; EditorPreferences.showWordCount = false; EditorPreferences.showSyntaxBar = false
        defer { EditorPreferences.showOutline = chromeSaved.0; EditorPreferences.showWordCount = chromeSaved.1; EditorPreferences.showSyntaxBar = chromeSaved.2 }
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
            w.appearance = NSAppearance(named: appearance)
            w.setContentSize(NSSize(width: 860, height: 700))
            content.layoutSubtreeIfNeeded()
            tv.scroll(.zero); sv.reflectScrolledClipView(clip)
            host.styler.styleVisible()
            _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
            let label = "\(name)"

            // 1. the text engine is ours
            t.check(tv.layoutManager is LuftigLayoutManager && tv.textLayoutManager == nil && tv.textContainer?.textLayoutManager == nil, "\(label): TextKit 1 with LuftigLayoutManager (layoutManager non-nil, textLayoutManager nil)")
            t.check(tv.layoutManager?.allowsNonContiguousLayout == true, "\(label): non-contiguous layout is still on")

            // 2. the chrome: the content starts below the title bar, nothing is inset or overlapped
            t.note("\(label): title bar \(lookTitleBarHeight(w)) pt; contentLayoutRect \(lookRect(w.contentLayoutRect)); scroll view \(lookRect(sv.frame)); clip \(lookRect(clip.frame)) insets \(lookInsets(clip.contentInsets)); text view \(lookRect(tv.frame)); scroller \(sv.verticalScroller.map { lookRect($0.frame) } ?? "-")")
            t.check(!w.styleMask.contains(.fullSizeContentView), "\(label): the content does not extend under the title bar (no fullSizeContentView)")
            t.check(abs(w.contentLayoutRect.minY - content.bounds.minY) < 0.5 && abs(w.contentLayoutRect.height - content.bounds.height) < 0.5, "\(label): contentLayoutRect == the content view (\(lookRect(w.contentLayoutRect)) vs \(lookRect(content.bounds)))")
            t.check(lookZero(content.safeAreaInsets) && lookZero(sv.safeAreaInsets) && lookZero(clip.safeAreaInsets), "\(label): no safe-area inset on the content, scroll or clip view")
            t.check(lookZero(sv.contentInsets) && clip.contentInsets.top == 0 && clip.contentInsets.left == 0 && clip.contentInsets.right == 0, "\(label): no content inset at the top, left or right (clip \(lookInsets(clip.contentInsets)))")
            t.check(clip.contentInsets.bottom <= 8, "\(label): the bottom inset AppKit adds is small (\(clip.contentInsets.bottom) pt)")
            t.check(abs(sv.frame.minY - content.bounds.minY) < 0.5 && abs(sv.frame.maxY - content.bounds.maxY) < 0.5 && abs(sv.frame.width - content.bounds.width) < 0.5, "\(label): the scroll view fills the content view when the banner is hidden")
            t.check(clip.bounds.origin.y == 0, "\(label): scroll position 0 is clip bounds y = 0")

            // 3. the first line: below the container inset, fully visible
            let lm = tv.layoutManager!
            let first = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            t.check(tv.textContainerOrigin.y == 20, "\(label): the text container starts 20 pt below the top of the text view (\(tv.textContainerOrigin.y))")
            t.check(tv.visibleRect.contains(first) && first.minY >= 20 - 0.5, "\(label): the first line \(lookRect(first)) lies inside the visible rect \(lookRect(tv.visibleRect)), 20 pt below the top edge")
            // nothing paints over it: the window's pixels over the first lines == the text view's own drawing of the same area (a scroll-edge effect, a pocket or a
            // translucent bar over the top would differ)
            if let shot = LookShot(content) {
                let area = NSRect(x: 0, y: 0, width: content.bounds.width, height: min(200, content.bounds.height))
                if let rep = tv.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: tv.bounds.width, height: area.height)) {
                    tv.cacheDisplay(in: NSRect(x: 0, y: 0, width: tv.bounds.width, height: area.height), to: rep)
                    let inkRows = shot.luminances(in: NSRect(x: first.minX, y: first.minY, width: min(300, first.width), height: first.height))
                    let n = shot.differingPixels(rep, in: area, tolerance: 2)
                    t.check(n == 0 && Set(inkRows.map { ($0 * 50).rounded() }).count > 2, "\(label): the top \(Int(area.height)) pt of the window are exactly the text view's own drawing: \(n) pixels differ, the first line has ink")
                }
            }

            // 4. the last line is reachable and fully visible
            tv.moveToEndOfDocument(nil)
            host.styler.styleVisible()
            lm.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
            tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
            let last = lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            t.check(tv.visibleRect.contains(last) && tv.visibleRect.maxY - last.maxY >= 10, "\(label): after Cmd-Down the last line \(lookRect(last)) is fully visible with room below (visible \(lookRect(tv.visibleRect)), clip bottom inset \(clip.contentInsets.bottom))")
            tv.scroll(.zero); sv.reflectScrolledClipView(clip)
        }
        w.appearance = NSAppearance(named: .aqua)

        // 4b. the narrowest window: nothing that is drawn comes near the side edges, where the window's corners are rounder in the new design, and the overlay scroller
        // (17 pt) has room beside the text. (A band / quote bar reaches `bandOutset` into the inset; the corner radius of a window without a toolbar is about 16 pt.)
        w.setContentSize(NSSize(width: 360, height: 400))
        content.layoutSubtreeIfNeeded()
        let narrowInset = tv.textContainerInset.width, overlayScroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        t.check(narrowInset - DecorationMetrics.bandOutset >= 16, "narrowest window (\(Int(content.bounds.width)) pt): bands and quote bars start \(narrowInset - DecorationMetrics.bandOutset) pt from the side edges (>= 16 pt, the window's corner radius)")
        t.check(narrowInset >= overlayScroller + 4, "narrowest window: the \(overlayScroller) pt overlay scroller has room beside the text (inset \(narrowInset) pt)")
        w.setContentSize(NSSize(width: 860, height: 700))
        content.layoutSubtreeIfNeeded()

        // 5. a LEGACY scroller (System Settings > Show scroll bars: Always, or a mouse) takes its width from the content: the column stays centred in what is left
        w.setContentSize(NSSize(width: 1100, height: 700))
        content.layoutSubtreeIfNeeded()
        host.luftigToggleReadableWidth(nil); host.luftigToggleReadableWidth(nil)            // (on -> off -> on: a no-op for the state, makes the column controller measure again)
        let overlayWidth = clip.frame.width
        sv.scrollerStyle = .legacy
        content.layoutSubtreeIfNeeded()
        let sw = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        t.check(abs((sv.frame.width - clip.frame.width) - sw) < 0.5, "legacy scroller: the clip view is \(sw) pt narrower than the scroll view (\(clip.frame.width) of \(sv.frame.width); overlay style: \(overlayWidth))")
        if let sc = sv.verticalScroller {
            t.check(!sc.isHidden && sc.isEnabled && abs(sc.frame.width - sw) < 0.5 && sc.knobProportion > 0 && sc.knobProportion < 1, "legacy scroller: it is shown (frame \(lookRect(sc.frame)), knob \(String(format: "%.3f", sc.knobProportion)) of the track, \(sw) pt wide)")
        } else { t.check(false, "no vertical scroller") }
        let cw = tv.textContainer!.size.width, inset = tv.textContainerInset.width, extra = host.padding.textTrailingExtra
        t.check(abs(inset - ((clip.frame.width - extra - 760) / 2).rounded(.down)) <= 1 && abs(inset + cw + inset + extra - clip.frame.width) <= 1.5, "legacy scroller: the 760 pt column is centred in the clip view minus the right-hand extra (inset \(inset) + \(cw) + \(inset) + extra \(extra) = \(2 * inset + cw + extra) of \(clip.frame.width))")
        sv.scrollerStyle = NSScroller.preferredScrollerStyle
        content.layoutSubtreeIfNeeded()

        // 6. the find bar sits above the text and does not cover the first line
        w.setContentSize(NSSize(width: 860, height: 700))
        content.layoutSubtreeIfNeeded()
        tv.scroll(.zero); sv.reflectScrolledClipView(clip)
        let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.performTextFinderAction(item)
        content.layoutSubtreeIfNeeded()
        // AppKit moves the text down by the height of the bar (an animated scroll to -inset): give it time
        let scrolled = await t.waitFor(1500) { content.layoutSubtreeIfNeeded(); return clip.bounds.origin.y <= -clip.contentInsets.top + 0.5 }
        t.note("find bar: the clip view's bounds origin is \(clip.bounds.origin.y) \(scrolled ? "(scrolled below the bar by AppKit)" : "after 1.5 s (AppKit did not scroll: it animates only a window that is displayed)"), top inset \(clip.contentInsets.top)")
        if let bar = sv.findBarView {
            let barRect = lookTopLeft(bar, in: content), clipRect = lookTopLeft(clip, in: content)
            let first = tv.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            let firstInWindow = NSRect(x: first.minX, y: clipRect.minY + first.minY - clip.bounds.minY, width: first.width, height: first.height)
            t.note("find bar \(lookRect(barRect)), clip view \(lookRect(clipRect)) bounds \(lookRect(clip.bounds)) insets \(lookInsets(clip.contentInsets)), first line in the window \(lookRect(firstInWindow))")
            t.check(sv.isFindBarVisible && barRect.height > 10, "the find bar is shown (\(Int(barRect.height)) pt high)")
            t.check(clip.contentInsets.top >= barRect.height - 0.5, "the clip view's top inset (\(clip.contentInsets.top) pt) is the find bar's height (\(barRect.height) pt): the text is scrolled below the bar, not under it")
            if scrolled { t.check(barRect.maxY <= firstInWindow.minY + 0.5, "the find bar ends (y \(barRect.maxY)) above the first line (y \(firstInWindow.minY)): it covers no text") }
            else { t.note("NOT VERIFIED here (same under the classic stamp): that the first line ends up below the bar - AppKit scrolls the text down only in a window that is displayed") }
        } else { t.check(false, "no find bar view") }
        item.tag = NSTextFinder.Action.hideFindInterface.rawValue
        tv.performTextFinderAction(item)
        content.layoutSubtreeIfNeeded()
        t.check(!sv.isFindBarVisible, "the find bar can be hidden again")
    }

    // MARK: look-banner

    @MainActor static func lookBanner(_ t: SelfTest.T) async throws {
        let (doc, host, _) = try await openEditor(t, text: "# Title\n\nThe first paragraph of the document, so that there is a first line under the banner.\n", name: "look-banner.md", size: NSSize(width: 860, height: 500))
        guard let w = doc.windowControllers.first?.window, let content = w.contentView else { t.check(false, "no window"); return }
        defer { t.close(doc) }
        let short = "“look-banner.md” was changed on disk, and you have unsaved changes."
        let long = "“a-document-with-a-rather-long-name-that-needs-room.md” was changed on disk by another application, and you have unsaved changes in this window. Reload it to see the other version."
        var worst = Double.infinity, worstLabel = ""
        for style in [EditorBanner.Style.warning, .info] {
            for (appearance, aname) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
                for width in [860.0, 420.0, 360.0] {
                    let label = "\(style == .warning ? "warning" : "info") / \(aname) / \(Int(width)) pt"
                    w.appearance = NSAppearance(named: appearance)
                    w.setContentSize(NSSize(width: width, height: 500))
                    host.showBanner(EditorBanner(message: width > 400 ? short : long, style: style, buttons: [("Reload from Disk", {}), ("Keep My Version", {})]))
                    content.layoutSubtreeIfNeeded()
                    await t.sleep(5)
                    let banner = host.banner
                    guard !banner.isHidden, banner.window === w else { t.check(false, "no banner"); continue }
                    let bounds = banner.bounds
                    let buttons = banner.buttonStack.arrangedSubviews.compactMap { $0 as? NSButton }
                    let stack = banner.buttonStack.frame, message = banner.messageField.frame
                    t.check(buttons.count == 2 && !banner.isHidden, "\(label): two buttons")
                    var inside = true, centred = true
                    for b in buttons {
                        let r = banner.convert(b.bounds, from: b)
                        if r.minX < -0.5 || r.maxX > bounds.width + 0.5 || r.minY < -0.5 || r.maxY > bounds.height + 0.5 { inside = false }
                        if abs(r.midY - bounds.midY) > 1.5 { centred = false }
                    }
                    t.check(inside, "\(label): both buttons lie inside the banner \(lookRect(bounds)) (\(buttons.map { lookRect(banner.convert($0.bounds, from: $0)) }.joined(separator: ", ")))")
                    t.check(centred, "\(label): the buttons are centred vertically in the banner")
                    t.check((buttons.first.map { $0.alignmentRect(forFrame: $0.frame).height } ?? 99) + 8 <= bounds.height, "\(label): the banner (\(Int(bounds.height)) pt) is at least 8 pt taller than its buttons")
                    t.check(message.maxX <= stack.minX - 8 && message.minX >= 0 && stack.maxX <= bounds.width + 0.5, "\(label): the message (to x \(Int(message.maxX))) and the buttons (from x \(Int(stack.minX))) do not overlap, the buttons end inside the banner (x \(Int(stack.maxX)) of \(Int(bounds.width)))")
                    // the editor starts exactly where the banner ends: no text is covered
                    // (in the content view's coordinates: the scroll view sits in a nested stack; the word count row, when shown, lies between the banner and the text)
                    let sv = host.scrollView
                    let svFrame = content.convert(sv.bounds, from: sv), bannerFrame = content.convert(banner.bounds, from: banner)
                    let between = host.wordCount.isHidden ? 0 : WordCountView.height
                    t.check(abs(svFrame.maxY + between - bannerFrame.minY) < 0.5 && svFrame.minY >= -0.5, "\(label): the scroll view starts below the banner (scroll view top y \(svFrame.maxY), banner bottom y \(bannerFrame.minY), \(Int(between)) pt word count row between)")
                    // legibility on pixels: every button title on its own fill, and the message on the banner's tint
                    if let shot = LookShot(content) {
                        for b in buttons {
                            let r = lookTopLeft(b, in: content).insetBy(dx: 3, dy: 3)
                            let c = shot.inkContrast(in: r)
                            if c < worst { worst = c; worstLabel = "\(label) \"\(b.title)\"" }
                            t.check(c >= 3, "\(label): the title \"\(b.title)\" is legible on the button (contrast \(String(format: "%.1f", c)):1)")
                        }
                        let mc = shot.inkContrast(in: lookTopLeft(banner.messageField, in: content))
                        t.check(mc >= 4.5, "\(label): the message is legible on the banner tint (contrast \(String(format: "%.1f", mc)):1)")
                    }
                    host.hideBanner()
                }
            }
        }
        t.note("worst button title contrast: \(String(format: "%.1f", worst)):1 (\(worstLabel))")
        w.appearance = NSAppearance(named: .aqua)
    }

    // MARK: look-settings

    @MainActor static func lookSettings(_ t: SelfTest.T) async throws {
        await preservingSettings {
            SettingsWindowController.headless = true
            let c = SettingsWindowController.shared
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            guard let w = c.window, let content = w.contentView else { t.check(false, "no settings window"); return }
            t.note("Settings window: title bar \(lookTitleBarHeight(w)) pt, content \(lookRect(content.frame))")
            let controls: [(String, NSView)] = [("scheme pop-up", c.schemePopup), ("text font pop-up", c.bodyFontPopup), ("code font pop-up", c.codeFontPopup), ("size field", c.sizeField), ("size stepper", c.sizeStepper),
                                                ("spacing slider", c.spacingSlider), ("spacing value", c.spacingValueLabel), ("automatic checkbox", c.spacingAutomaticCheckbox), ("limit checkbox", c.limitCheckbox),
                                                ("width slider", c.widthSlider), ("width value", c.widthValueLabel), ("width note", c.widthNoteLabel), ("restore button", c.restoreButton)]
            for (appearance, aname) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
                w.appearance = NSAppearance(named: appearance)
                for scheme in [ColorSchemes.defaultID, "dracula"] {
                    EditorPreferences.colorSchemeID = scheme
                    if scheme != ColorSchemes.defaultID { w.appearance = nil }
                    c.syncFromPreferences()
                    content.layoutSubtreeIfNeeded()
                    let label = "\(scheme == ColorSchemes.defaultID ? aname : "scheme " + scheme)"
                    let frames = controls.map { ($0.0, content.convert($0.1.bounds, from: $0.1)) }
                    var overlaps: [String] = []
                    for i in 0..<frames.count { for j in (i + 1)..<frames.count where frames[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(frames[j].1.insetBy(dx: 0.5, dy: 0.5)) { overlaps.append("\(frames[i].0) x \(frames[j].0)") } }
                    t.check(overlaps.isEmpty, "\(label): no two controls overlap \(overlaps)")
                    let outside = frames.filter { $0.1.minX < -0.5 || $0.1.maxX > content.bounds.width + 0.5 || $0.1.minY < -0.5 || $0.1.maxY > content.bounds.height + 0.5 }.map { $0.0 }
                    t.check(outside.isEmpty, "\(label): every control lies inside the window \(outside)")
                    // a pop-up shows its selected title in full: title + image + the arrows' room must fit the fixed width
                    for (name, popup) in [("scheme pop-up", c.schemePopup), ("text font pop-up", c.bodyFontPopup), ("code font pop-up", c.codeFontPopup)] {
                        guard let item = popup.selectedItem else { continue }
                        let font = popup.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                        let title = (item.attributedTitle?.string ?? item.title) as NSString
                        let need = title.size(withAttributes: [.font: font]).width + (item.image.map { $0.size.width + 6 } ?? 0) + 34
                        t.check(need <= popup.frame.width, "\(label): \(name) \"\(title)\" needs about \(Int(need)) pt of its \(Int(popup.frame.width)) pt (intrinsic \(String(format: "%.1f", popup.intrinsicContentSize.width)) pt)")
                    }
                    if scheme == ColorSchemes.defaultID { t.note("\(label): " + frames.map { "\($0.0) \(lookRect($0.1))" }.joined(separator: "; ")) }
                }
                EditorPreferences.colorSchemeID = ColorSchemes.defaultID
                c.syncFromPreferences()
            }
            // the three font pop-ups, the slider and the stepper drive the preferences with the new controls too (the controls are the same objects, only drawn differently)
            c.sizeStepper.doubleValue = 20; _ = c.sizeStepper.sendAction(c.sizeStepper.action, to: c.sizeStepper.target)
            t.equal(EditorPreferences.fontSize, 20, "the stepper still drives the font size")
            c.spacingSlider.doubleValue = 1.7; _ = c.spacingSlider.sendAction(c.spacingSlider.action, to: c.spacingSlider.target)
            t.equal(EditorPreferences.lineHeightFactor, 1.7, "the line spacing slider still drives the preference")
            c.restoreButton.performClick(nil)
            t.equal(EditorPreferences.fontSize, EditorPreferences.defaultFontSize, "Restore Defaults still works")
            w.appearance = nil
        }
    }
}
#endif
