#if LUFTIG_SELFTEST
// SelfTestSettingsWindow.swift - the Settings WINDOW: settings-window, settings-defaults.
//
// The window is never put on the screen (SettingsWindowController.headless); its controls are driven programmatically (sendAction / performClick), the
// way a click would, never with a real mouse.

import AppKit
import MarkdownKit

extension SelfTestScenarios {

    // MARK: helpers

    @MainActor private static func send(_ control: NSControl) { control.sendAction(control.action, to: control.target) }

    /// Choose a popup item by its represented object (a family name / a scheme id; nil = the first item) and send the action, like a click on the menu.
    @MainActor @discardableResult private static func choose(_ popup: NSPopUpButton, _ value: String?) -> Bool {
        guard let menu = popup.menu else { return false }
        let index = value == nil ? 0 : (menu.items.firstIndex { ($0.representedObject as? String) == value } ?? -1)
        guard index >= 0 else { return false }
        popup.selectItem(at: index)
        send(popup)
        return true
    }

    @MainActor private static func selectedValue(_ popup: NSPopUpButton) -> String? { popup.selectedItem?.representedObject as? String }

    @MainActor private static func menuItem(_ path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var item: NSMenuItem?
        for title in path { item = menu?.items.first { $0.title == title }; menu = item?.submenu }
        return item
    }

    // MARK: settings-window

    @MainActor static func settingsWindow(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            SettingsWindowController.headless = true
            let text = settingsDocument(times: 2)
            let (docA, a, _) = try await openEditor(t, text: text, name: "sw-a.md", size: NSSize(width: 1400, height: 700))
            let (docB, b, _) = try await openEditor(t, text: text, name: "sw-b.md", size: NSSize(width: 1400, height: 700))

            // ---- the menu item and the singleton
            let item = menuItem(["luftig", "Settings…"])
            t.check(item != nil && item?.keyEquivalent == "," && item?.keyEquivalentModifierMask == [.command], "luftig > Settings… exists and is bound to ⌘,")
            if let appMenu = NSApp.mainMenu?.items.first?.submenu {
                let titles = appMenu.items.map { $0.isSeparatorItem ? "-" : $0.title }
                t.check(titles.starts(with: ["About luftig", "-", "Settings…", "-", "Services"]), "... in the standard place: after About, before Services (\(titles.prefix(6)))")
            }
            let c = SettingsWindowController.shared
            let count0 = c.presentCount
            t.check(NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil), "the Settings… action is answered (application delegate), with no document window key")
            t.equal(c.presentCount, count0 + 1, "choosing Settings… presents the window")
            t.check(NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil), "... again")
            t.equal(c.presentCount, count0 + 2, "... a second time presents it again")
            t.check(SettingsWindowController.shared === c && NSApp.windows.filter { $0.title == "Settings" }.count <= 1, "ONE Settings window: the same controller, \(NSApp.windows.filter { $0.title == "Settings" }.count) window titled Settings")
            guard let window = c.window else { t.check(false, "no window"); return }
            t.equal(window.title, "Settings", "the window's title is Settings")
            t.check(window.styleMask.contains(.closable) && window.styleMask.contains(.titled), "it is a titled window with a close button (⌘W closes it)")
            if let close = menuItem(["File", "Close"]) { t.check(close.action == #selector(NSWindow.performClose(_:)) && close.keyEquivalent == "w" && window.validateMenuItem(close), "File > Close (⌘W) is enabled for it") }
            t.check(!window.isReleasedWhenClosed && window.tabbingMode == .disallowed && !window.isRestorable, "closing only hides it (the next ⌘, shows the same window); it never becomes a tab; it is not restored at launch")
            t.check(window.contentMinSize.width >= 560 && window.contentMinSize.height == window.contentMaxSize.height, "minimum width \(Int(window.contentMinSize.width)) pt; the height is fixed to the content (\(Int(window.contentMinSize.height)) pt)")
            t.equal(window.frameAutosaveName, SettingsWindowController.frameAutosaveName, "its position is remembered (frame autosave name \(window.frameAutosaveName))")
            window.setFrameOrigin(NSPoint(x: 321, y: 234))
            window.saveFrame(usingName: SettingsWindowController.frameAutosaveName)
            t.check((UserDefaults.standard.string(forKey: "NSWindow Frame " + SettingsWindowController.frameAutosaveName) ?? "").hasPrefix("321 234"), "... saved in the preferences: \(UserDefaults.standard.string(forKey: "NSWindow Frame " + SettingsWindowController.frameAutosaveName) ?? "nothing")")
            window.performClose(nil)
            c.present()
            t.check(SettingsWindowController.shared === c && c.window === window, "closed and presented again: the same window")

            // ---- the layout: every control lies inside the window at the minimum width, at the default width and at a wide one
            let panelView = window.contentView!
            let allControls: [NSView] = [c.preview.scrollView, c.schemePopup, c.bodyFontPopup, c.codeFontPopup, c.sizeField, c.sizeStepper, c.spacingSlider, c.spacingValueLabel, c.spacingAutomaticCheckbox,
                                         c.limitCheckbox, c.widthSlider, c.widthValueLabel, c.widthNoteLabel, c.restoreButton]
            let height0 = panelView.frame.height
            for width in [window.contentMinSize.width, 700, 1100] {
                window.setContentSize(NSSize(width: width, height: height0))
                panelView.layoutSubtreeIfNeeded()
                let outside = allControls.filter { v in let r = v.convert(v.bounds, to: panelView); return r.minX < -0.5 || r.maxX > panelView.bounds.width + 0.5 || r.minY < -0.5 || r.maxY > panelView.bounds.height + 0.5 }
                t.check(outside.isEmpty && abs(panelView.frame.width - width) < 1, "layout at \(Int(width)) pt wide: every control lies inside the window (\(Int(panelView.frame.width)) pt) \(outside.map { String(describing: type(of: $0)) })")
            }
            window.setContentSize(NSSize(width: 700, height: height0))
            panelView.layoutSubtreeIfNeeded()
            t.check(window.contentMinSize.width <= 580, "the minimum width is about 560 pt (\(Int(window.contentMinSize.width)))")

            // ---- the pop-up menus
            let schemeItems = c.schemePopup.menu!.items
            t.equal(schemeItems.first?.title, "luftig (follows system appearance)", "colour scheme menu: the luftig default comes first, labelled \"luftig (follows system appearance)\"")
            t.equal(schemeItems.first?.representedObject as? String, ColorSchemes.defaultID, "... and is the default scheme")
            t.equal(schemeItems.compactMap { $0.representedObject as? String }.sorted(), ColorSchemes.all.map { $0.id }.sorted(), "colour scheme menu: every scheme exactly once (\(ColorSchemes.all.count))")
            t.check(schemeItems.filter { $0.representedObject != nil }.allSatisfy { ($0.image?.size.width ?? 0) > 10 }, "colour scheme menu: every item has a colour swatch")
            var header = "", misgrouped: [String] = []
            for i in schemeItems {
                if i.isSectionHeader { header = i.title }
                else if let id = i.representedObject as? String, id != ColorSchemes.defaultID, ColorSchemes.scheme(withID: id).family != header { misgrouped.append("\(id) under \(header)") }
            }
            t.check(misgrouped.isEmpty, "colour scheme menu: grouped by family under section headers \(misgrouped)")

            let textItems = c.bodyFontPopup.menu!.items, codeItems = c.codeFontPopup.menu!.items
            t.equal(textItems.first?.title, "System (SF Pro)", "text font menu: \"System (SF Pro)\" first")
            t.equal(codeItems.first?.title, "System Mono (SF Mono)", "code font menu: \"System Mono (SF Mono)\" first")
            let installed = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            t.equal(textItems.compactMap { $0.representedObject as? String }, installed, "text font menu: every installed family, sorted (\(installed.count))")
            let codeFamilies = codeItems.compactMap { $0.representedObject as? String }
            var fixed = Set<String>()
            for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] { if let f = NSFont(name: name, size: 12)?.familyName { fixed.insert(f) } }
            t.check(!codeFamilies.isEmpty && codeFamilies.allSatisfy { fam in NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: fam]), size: 12)?.isFixedPitch == true }, "code font menu: only monospaced families (\(codeFamilies.count): \(codeFamilies.prefix(8).joined(separator: ", "))\(codeFamilies.count > 8 ? ", ..." : ""))")
            t.equal(Set(codeFamilies), fixed.intersection(Set(installed)), "code font menu: every installed family with a fixed-pitch face (NSFontManager's own list: \(fixed.count))")
            t.check(Set(codeFamilies).isDisjoint(with: ["Georgia", "Times", "Helvetica Neue"]), "code font menu: no proportional family")
            c.menuNeedsUpdate(c.bodyFontPopup.menu!)
            var plainButCould: [String] = [], titledButCannot: [String] = [], titledCount = 0
            for i in c.bodyFontPopup.menu!.items {
                guard let family = i.representedObject as? String, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { continue }
                let covers = family.unicodeScalars.filter { $0 != " " }.prefix(3).allSatisfy { font.coveredCharacterSet.contains($0) }
                if i.attributedTitle != nil { titledCount += 1; if !covers { titledButCannot.append(family) } } else if covers { plainButCould.append(family) }
            }
            t.check(plainButCould.isEmpty && titledButCannot.isEmpty, "text font menu: each name is shown in its own font once the menu is opened, except for families that cannot spell their own name (\(titledCount) of \(installed.count) titled) \(plainButCould.prefix(4)) \(titledButCannot.prefix(4))")
            if let g = c.bodyFontPopup.menu!.items.first(where: { $0.title == "Georgia" }) { t.equal((g.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.familyName, "Georgia", "... Georgia is set in Georgia") }

            // ---- the preview: the real Theme + lexer, read-only
            @MainActor func checkPreview(_ label: String) {
                let tv = c.preview.textView, ts = tv.textStorage!
                t.check(!tv.isEditable && !tv.isSelectable, "\(label): the preview is read-only")
                t.equal(ts.string, SettingsPreview.sampleText, "\(label): the preview shows the sample text")
                t.equal(c.preview.theme.settings, P.themeSettings, "\(label): the preview's theme is built from the preferences")
                let r = StyleOracle.compare(storage: ts, settings: P.themeSettings)
                t.check(r.mismatches == 0, "\(label): the preview == a fresh restyle (\(r.checkedRuns) runs compared, \(r.mismatches) mismatches) \(r.first.map { "\($0.range): \($0.expected) / \($0.actual)" }.prefix(2))")
            }
            checkPreview("start")
            do {
                let ts = c.preview.textView.textStorage!, s = ts.string as NSString, th = c.preview.theme
                @MainActor func at(_ needle: String, _ off: Int = 0) -> [NSAttributedString.Key: Any] { ts.attributes(at: s.range(of: needle).location + off, effectiveRange: nil) }
                t.equal((at("A quiet page", 2)[.font] as? NSFont)?.pointSize, th.headingSize(1), "the preview has a first-level heading (\(th.headingSize(1)) pt)")
                t.equal((at("Set the way", 2)[.font] as? NSFont)?.pointSize, th.headingSize(2), "... a second-level heading")
                t.check(at("link", 0)[.underlineStyle] != nil && at("struck", 0)[.strikethroughStyle] != nil && ((at("italic", 0)[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false), "... a link, struck text, italic and bold")
                t.check(at("inline code", 0)[.luftigInline] != nil && (at("inline code", 0)[.font] as? NSFont)?.isFixedPitch == true, "... inline code")
                t.check(s.range(of: "A list item that is long enough to wrap").location != NSNotFound && s.range(of: "A nested item").location != NSNotFound, "... a nested list with a long item (wraps at 700 pt: the line is \(s.range(of: "A list item that is long enough to wrap onto a second line, so you can see where the continuation lines start").length) characters)")
                t.check(BlockMark.decode(at("A quote is set apart", 0)[.luftigBlock])?.kind == .quote, "... a quote (bar)")
                t.check(BlockMark.decode(at("let answer", 0)[.luftigBlock])?.kind == .code && (at("let answer", 0)[.font] as? NSFont)?.isFixedPitch == true, "... a fenced code block")
                t.check(at("| size", 0)[.luftigPanel] != nil && (at("| size", 0)[.font] as? NSFont)?.isFixedPitch == true, "... a table")
            }

            // ---- the controls drive the preferences, every editor and the preview
            // colour scheme
            if let other = ColorSchemes.all.first(where: { $0.id != ColorSchemes.defaultID }) {
                t.check(choose(c.schemePopup, other.id), "scheme: choose \(other.id)")
                t.equal(P.colorSchemeID, other.id, "scheme: the preference follows the pop-up")
                t.equal(Palette.scheme.id, other.id, "scheme: the palette follows")
                t.equal(a.theme !== b.theme, true, "scheme: both editors rebuilt their own theme")
                t.equal(selectedValue(c.schemePopup), other.id, "scheme: the pop-up shows it")
                checkPreview("scheme \(other.id)")
                choose(c.schemePopup, ColorSchemes.defaultID)
                t.equal(P.colorSchemeID, ColorSchemes.defaultID, "scheme: back to the default")
            }
            // text font and code font
            let body = installedFamilies(["Georgia", "Times", "Helvetica Neue"]).first ?? anyFamily() ?? "Helvetica"
            let code = installedFamilies(["Menlo", "Courier New", "Monaco"]).first ?? anyFamily(monospaced: true) ?? "Courier"
            t.check(choose(c.bodyFontPopup, body), "text font: choose \(body)")
            t.equal(P.bodyFontFamily, body, "text font: the preference follows")
            t.check(a.theme.bodyFamily == body && b.theme.bodyFamily == body && c.preview.theme.bodyFamily == body, "text font: both editors and the preview use it")
            t.equal(selectedValue(c.bodyFontPopup), body, "text font: the pop-up shows it")
            checkPreview("text font")
            t.check(choose(c.codeFontPopup, code), "code font: choose \(code)")
            t.check(P.codeFontFamily == code && a.theme.codeFamily == code && b.theme.codeFamily == code && c.preview.theme.codeFamily == code, "code font: the preference, both editors and the preview follow")
            checkPreview("code font")
            // size: stepper, field, the keyboard shortcuts
            c.sizeStepper.doubleValue = 21
            send(c.sizeStepper)
            t.check(P.fontSize == 21 && a.fontSize == 21 && b.fontSize == 21 && c.preview.theme.baseSize == 21, "size: the stepper sets 21 pt everywhere")
            t.equal(c.sizeField.doubleValue, 21, "size: ... and the field shows it")
            c.sizeField.stringValue = "18"
            send(c.sizeField)
            t.check(P.fontSize == 18 && c.sizeStepper.doubleValue == 18 && a.fontSize == 18, "size: typing 18 in the field sets 18 pt (stepper \(c.sizeStepper.doubleValue))")
            c.sizeField.stringValue = "100"
            send(c.sizeField)
            // (a number outside 9 ... 40 used to be refused: the formatter had a minimum and a maximum, and a real field then kept the keyboard focus with a beep. It is clamped now
            // and the field shows the size that is in use: fix-settings-size drives this through the field editor)
            t.check(P.fontSize == 40 && c.sizeField.doubleValue == 40 && c.sizeStepper.doubleValue == 40, "size: 100 is clamped to 40 and the field shows it (\(c.sizeField.doubleValue))")
            c.sizeField.stringValue = "18"
            send(c.sizeField)
            c.sizeField.stringValue = "abc"
            send(c.sizeField)
            t.check(P.fontSize == 18 && c.sizeField.doubleValue == 18, "size: 'abc' changes nothing")
            a.luftigIncreaseFontSize(nil)
            t.check(c.sizeField.doubleValue == 19 && c.sizeStepper.doubleValue == 19, "size: ⌘+ in an editor window: the Settings window follows (\(c.sizeField.doubleValue))")
            b.luftigDecreaseFontSize(nil); b.luftigDecreaseFontSize(nil)
            t.check(c.sizeField.doubleValue == 17, "size: ⌘- twice in the other window: the Settings window shows \(c.sizeField.doubleValue)")
            a.luftigResetFontSize(nil)
            t.check(c.sizeField.doubleValue == 16 && P.fontSize == 16, "size: ⌘0: 16 pt")
            c.luftigIncreaseFontSize(nil); c.luftigIncreaseFontSize(nil)
            t.check(P.fontSize == 18 && a.fontSize == 18, "size: ⌘+ while the Settings window is key works too (\(P.fontSize))")
            c.luftigDecreaseFontSize(nil); c.luftigResetFontSize(nil)
            t.equal(P.fontSize, 16, "size: ⌘- and ⌘0 as well")
            let mi = NSMenuItem(title: "Bigger", action: #selector(LuftigEditorActions.luftigIncreaseFontSize(_:)), keyEquivalent: "+")
            P.fontSize = 40
            t.check(!c.validateMenuItem(mi), "size: View > Bigger is disabled at 40 pt, for the Settings window as for the editors")
            P.fontSize = 16
            checkPreview("size")
            // line spacing
            c.spacingSlider.doubleValue = 1.8
            send(c.spacingSlider)
            t.equal(P.lineHeightFactor, 1.8, "line spacing: the slider sets 1.8")
            t.equal(c.spacingAutomaticCheckbox.state, .off, "line spacing: ... and 'Automatic' goes off")
            t.check(a.theme.bodyLineHeight == (16 * 1.8 as CGFloat).rounded() && b.theme.bodyLineHeight == a.theme.bodyLineHeight && c.preview.theme.bodyLineHeight == a.theme.bodyLineHeight, "line spacing: both editors and the preview have a \(a.theme.bodyLineHeight) pt box")
            t.check(c.spacingValueLabel.stringValue.contains("1.80") && c.spacingValueLabel.stringValue.contains("\(Int(a.theme.bodyLineHeight)) pt"), "line spacing: the label says '\(c.spacingValueLabel.stringValue)'")
            checkPreview("line spacing")
            c.spacingAutomaticCheckbox.performClick(nil)
            t.check(P.lineHeightFactor == nil && c.spacingAutomaticCheckbox.state == .on, "line spacing: ticking Automatic removes the choice")
            t.check(abs(c.spacingSlider.doubleValue - Double(Theme.lineHeightRatio(baseSize: 16))) < 0.001 && a.theme.bodyLineHeight == (16 * Theme.lineHeightRatio(baseSize: 16)).rounded(), "line spacing: ... the slider shows the automatic curve (\(c.spacingSlider.doubleValue)) and the editors have its box (\(a.theme.bodyLineHeight) pt)")
            let boxBefore = a.theme.bodyLineHeight
            c.spacingAutomaticCheckbox.performClick(nil)
            t.check(c.spacingAutomaticCheckbox.state == .off && a.theme.bodyLineHeight == boxBefore, "line spacing: unticking it keeps today's box (\(boxBefore) pt -> \(a.theme.bodyLineHeight) pt): nothing moves")
            c.spacingAutomaticCheckbox.performClick(nil)
            // the floor and what the window says about it
            if let tall = installedFamilies(["Zapfino"]).first {
                let heightBefore = window.frame.height
                P.lineHeightFactor = 1.1
                choose(c.bodyFontPopup, tall)
                t.check(c.preview.theme.bodyLineHeight > c.preview.theme.requestedLineHeight, "line spacing: \(tall) at 1.1 needs a taller box than the factor gives (\(c.preview.theme.bodyLineHeight) pt > \(c.preview.theme.requestedLineHeight) pt)")
                t.check(c.spacingNoteLabel.stringValue.hasPrefix("Raised to \(Int(c.preview.theme.bodyLineHeight)) pt"), "line spacing: the window says so: '\(c.spacingNoteLabel.stringValue)'")
                // (the window used to grow to show the note and shrink again; the note has a place of its own now, next to the "Automatic" box, and nothing in the window
                // changes size or moves when it comes and goes: fix-settings-layout)
                t.check(abs(window.frame.height - heightBefore) < 0.5 && window.contentMinSize.height == window.contentMaxSize.height, "line spacing: the window did not change size to show the note (\(Int(heightBefore)) -> \(Int(window.frame.height)) pt) and stays exactly as tall as its content")
                checkPreview("tall font")
                choose(c.bodyFontPopup, body)
                P.lineHeightFactor = nil
                t.check(c.spacingNoteLabel.stringValue.isEmpty && abs(window.frame.height - heightBefore) < 1, "line spacing: no note, the window is its old height again (\(Int(window.frame.height)) pt)")
            }
            // column width
            let panel = window.contentView!
            c.limitCheckbox.performClick(nil)
            t.check(!P.readableWidth && !c.widthSlider.isEnabled, "column: unticking 'Limit line length' turns the preference off and disables the slider")
            for (name, host) in [("A", a), ("B", b)] { t.check(host.textView.textContainerInset.width == 28, "column: unlimited, window \(name) uses the whole width (inset \(Int(host.textView.textContainerInset.width)) pt)") }
            a.luftigToggleReadableWidth(nil)
            t.check(P.readableWidth && c.limitCheckbox.state == .on && c.widthSlider.isEnabled, "column: View > Wrap to Readable Width and the checkbox are one switch")
            c.widthSlider.doubleValue = 900
            send(c.widthSlider)
            t.equal(P.columnWidth, 900, "column: the slider sets 900 pt")
            for (name, host) in [("A", a), ("B", b)] { t.check(abs(host.textView.textContainer!.size.width - 900) < 1.5, "column: window \(name)'s text is \(Int(host.textView.textContainer!.size.width)) pt wide") }
            t.check(c.widthValueLabel.stringValue == "900 pt" && c.widthNoteLabel.stringValue.contains("characters per line"), "column: the labels say '\(c.widthValueLabel.stringValue)' / '\(c.widthNoteLabel.stringValue)'")
            c.widthSlider.doubleValue = 520
            send(c.widthSlider)
            panel.layoutSubtreeIfNeeded()
            t.check(abs(c.preview.textView.textContainer!.size.width - 520) < 1.5, "column: the preview's column is \(Int(c.preview.textView.textContainer!.size.width)) pt (520 expected)")
            checkPreview("column")

            // ---- Restore Defaults
            P.lineHeightFactor = 1.4
            P.bodyFontFamily = body
            P.fontSize = 24
            if let other = ColorSchemes.all.first(where: { $0.id != ColorSchemes.defaultID }) { P.colorSchemeID = other.id }
            c.restoreButton.performClick(nil)
            t.equal(P.themeSettings, ThemeSettings(baseSize: 16), "Restore Defaults: fonts, size and spacing are the defaults")
            t.check(P.columnWidth == 760 && P.readableWidth && P.colorSchemeID == ColorSchemes.defaultID, "Restore Defaults: column 760 pt, limited, default scheme")
            t.check(selectedValue(c.bodyFontPopup) == nil && selectedValue(c.codeFontPopup) == nil && selectedValue(c.schemePopup) == ColorSchemes.defaultID, "Restore Defaults: the pop-ups show the defaults")
            t.check(c.sizeField.doubleValue == 16 && c.spacingAutomaticCheckbox.state == .on && c.widthSlider.doubleValue == 760 && c.limitCheckbox.state == .on, "Restore Defaults: the other controls show them")
            t.check(a.theme.settings == ThemeSettings(baseSize: 16) && b.theme.settings == ThemeSettings(baseSize: 16), "Restore Defaults: both editors are at the defaults")
            checkPreview("defaults")

            // ---- a family that is gone: the pop-up shows it, honestly, and leaves the saved name alone
            let ghost = "Ghost Family 4711"
            P.bodyFontFamily = ghost
            t.equal(c.bodyFontPopup.selectedItem?.title, "\(ghost) (not installed)", "text font: a family that is not installed is shown as such: '\(c.bodyFontPopup.selectedItem?.title ?? "")'")
            t.check(UserDefaults.standard.string(forKey: P.bodyFontFamilyKey) == ghost && c.preview.theme.bodyFamily == nil, "... the saved name is still there and the preview uses the system font")
            P.bodyFontFamily = nil
            t.check(selectedValue(c.bodyFontPopup) == nil && !c.bodyFontPopup.menu!.items.contains { $0.title.contains("not installed") }, "... and the extra item is gone again")

            // ---- looks right in light and dark, with every colour scheme
            var renders = 0
            for (appearanceName, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearanceName)
                for scheme in ColorSchemes.all {
                    P.colorSchemeID = scheme.id
                    panel.layoutSubtreeIfNeeded()
                    let tv = c.preview.textView
                    _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                    guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { t.check(false, "\(label) / \(scheme.id): no bitmap"); continue }
                    panel.cacheDisplay(in: panel.bounds, to: rep)
                    renders += 1
                    let scale = CGFloat(rep.pixelsWide) / panel.bounds.width
                    @MainActor func pixel(_ p: NSPoint) -> (r: Double, g: Double, b: Double) {      // p in the panel's (unflipped) coordinates
                        let x = Int(p.x * scale), y = Int((panel.bounds.height - p.y) * scale)
                        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0) }
                        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                    }
                    func lum(_ p: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b }
                    let previewFrame = c.preview.scrollView.convert(c.preview.scrollView.bounds, to: panel)
                    // the page is dark for a dark scheme (or the system scheme in a dark window), light otherwise: judged by luminance (a window that was never key
                    // draws the inactive variants of the catalog colours, a little off the active ones: no exact RGB match)
                    let page = pixel(NSPoint(x: previewFrame.minX + 14, y: previewFrame.maxY - 14))
                    let wantDark = scheme.appearance == .dark || (scheme.appearance == .system && appearanceName == .darkAqua)
                    t.check(wantDark ? lum(page) < 0.45 : lum(page) > 0.55, "\(label) / \(scheme.id): the preview's page is \(wantDark ? "dark" : "light") (luminance \(String(format: "%.2f", lum(page))))")
                    let chrome = pixel(NSPoint(x: 6, y: 6))
                    t.check(appearanceName == .darkAqua ? lum(chrome) < 0.45 : lum(chrome) > 0.8, "\(label) / \(scheme.id): the window background is the system's \(label) grey (luminance \(String(format: "%.2f", lum(chrome))))")
                    // the page has text on it: at least some pixels in the preview differ from the page colour
                    var ink = 0
                    var y = previewFrame.minY + 4
                    while y < previewFrame.maxY - 4 { var x = previewFrame.minX + 4; while x < previewFrame.maxX - 4 { let px = pixel(NSPoint(x: x, y: y)); if abs(px.r - page.r) + abs(px.g - page.g) + abs(px.b - page.b) > 0.3 { ink += 1 }; x += 4 }; y += 4 }
                    t.check(ink > 150, "\(label) / \(scheme.id): the preview shows text (\(ink) ink samples)")
                    // the controls are readable: the label colour contrasts with the window background
                    let label0 = Contrast.rgba(NSColor.labelColor, appearance: NSAppearance(named: appearanceName)!)
                    t.check(abs((0.2126 * label0.r + 0.7152 * label0.g + 0.0722 * label0.b) - lum(chrome)) > 0.5, "\(label) / \(scheme.id): the labels contrast with the window")
                }
            }
            t.note("\(renders) renderings of the window (light / dark x \(ColorSchemes.all.count) schemes)")
            window.appearance = nil
            P.colorSchemeID = ColorSchemes.defaultID

            // ---- a window that is closed keeps following the preferences (it is just hidden)
            window.performClose(nil)
            P.fontSize = 22
            t.check(c.sizeField.doubleValue == 22, "a hidden Settings window still follows the preferences (field \(c.sizeField.doubleValue))")
            c.present()
            t.equal(c.sizeField.doubleValue, 22, "... so it shows the right values when it comes back")
            for d in [docA, docB] { t.close(d) }
        }
    }

    // MARK: settings-defaults

    /// The look the baseline Theme gave: copied from the code before the Settings existed, so that "the default look is unchanged" is a comparison with
    /// something that does not move when Theme.swift does.
    private enum BaselineLook {
        static let scales: [CGFloat] = [1, 1.6, 1.35, 1.18, 1.05, 1.0, 1.0]
        static func ratio(_ s: CGFloat) -> CGFloat { min(1.5, max(1.3, 1.56 - 0.009 * s)) }
        static func body(_ s: CGFloat) -> CGFloat { (s * ratio(s)).rounded() }
        static func headingSize(_ s: CGFloat, _ level: Int) -> CGFloat { level <= 0 ? s : (s * scales[min(6, level)]).rounded() }
        static func lineHeight(_ s: CGFloat, level: Int) -> CGFloat { level <= 0 ? body(s) : max(body(s), (headingSize(s, level) * 1.3).rounded()) }

        static func make(mono: Bool, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
            var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
            if italic {
                let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
                f = NSFont(descriptor: d, size: size) ?? f
            }
            return f
        }
        static func font(for s: MDStyle, base: CGFloat) -> NSFont {
            let mono = (base * 0.9 * 2).rounded() / 2
            let level = s.headingLevel
            if s.contains(.codeBlock) || s.contains(.codeFence) { return make(mono: true, size: mono, weight: s.contains(.codeLanguage) ? .semibold : .regular, italic: false) }
            if s.contains(.inlineCode) {
                return make(mono: true, size: level > 0 ? (headingSize(base, level) * 0.9 * 2).rounded() / 2 : mono, weight: (level > 0 || s.contains(.bold)) ? .semibold : .regular, italic: s.contains(.italic))
            }
            if s.contains(.table) || s.contains(.frontMatter) {
                let heavy = (s.contains(.tableHeader) || s.contains(.bold)) && !s.contains(.tableDelimiter)
                return make(mono: true, size: mono, weight: heavy ? .bold : .regular, italic: false)
            }
            if level > 0 {
                if s.facets == [.marker] || s.facets == [.marker, .blockquote] { return make(mono: false, size: base, weight: .regular, italic: false) }
                return make(mono: false, size: headingSize(base, level), weight: level <= 2 ? .bold : .semibold, italic: s.contains(.italic))
            }
            var weight: NSFont.Weight = .regular
            if s.contains(.bold) { weight = .bold } else if s.contains(.listMarker) || s.contains(.taskChecked) { weight = .semibold }
            return make(mono: false, size: base, weight: weight, italic: s.contains(.italic))
        }
    }

    /// Colours are compared by what they resolve to (light and dark): a scheme change and back may hand out new objects for the same colour.
    private static func resolved(_ c: NSColor) -> [Double] {
        [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!].flatMap { a -> [Double] in let v = Contrast.rgba(c, appearance: a); return [v.r, v.g, v.b, v.a] }
    }
    private static func sameAttributes(_ a: TextAttributes, _ b: TextAttributes) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in a {
            guard let w = b[k] else { return false }
            if let c1 = v as? NSColor, let c2 = w as? NSColor { if resolved(c1) != resolved(c2) { return false } }
            else if !(v as AnyObject).isEqual(w as AnyObject) { return false }
        }
        return true
    }
    private static func dump(_ ts: NSTextStorage) -> [(NSRange, TextAttributes)] {
        var out: [(NSRange, TextAttributes)] = []
        ts.enumerateAttributes(in: NSRange(location: 0, length: ts.length), options: []) { a, r, _ in out.append((r, a)) }
        return out
    }

    @MainActor static func settingsDefaults(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            let P = EditorPreferences.self
            SettingsWindowController.headless = true
            let text = settingsDocument(times: 3) + "\nNon-ASCII: café 日本語 😀 and `日本語`.\n\n> مرحبا بكم\n\n# Überschrift ***fett***\n"
            let (doc, host, _) = try await openEditor(t, text: text, name: "defaults.md", size: NSSize(width: 1400, height: 900))
            let tv = host.textView, ts = tv.textStorage!
            host.styler.styleEverything()

            // ---- 1. the default look IS the baseline look: every font and line box, for sizes 9...40 (Theme level) and for the document (editor level)
            let md = MarkdownStyler().lexAll(text as NSString)
            var styles = Set<UInt32>()
            for run in md { styles.insert(run.style.rawValue) }
            var fontMismatch: [String] = [], heightMismatch: [String] = [], extraKeys: [String] = []
            for size in [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 40] as [CGFloat] {
                let theme = Theme(baseSize: size)
                if theme.bodyLineHeight != BaselineLook.body(size) { heightMismatch.append("\(size) pt body \(theme.bodyLineHeight) vs \(BaselineLook.body(size))") }
                for level in 1...6 where theme.lineHeight(headingLevel: level) != BaselineLook.lineHeight(size, level: level) { heightMismatch.append("\(size) pt H\(level) \(theme.lineHeight(headingLevel: level)) vs \(BaselineLook.lineHeight(size, level: level))") }
                for raw in styles {
                    let s = MDStyle(rawValue: raw)
                    let f = theme.font(for: s), e = BaselineLook.font(for: s, base: size)
                    if !f.isEqual(e) { fontMismatch.append("\(size) pt \(s): \(f.fontName)@\(f.pointSize) vs \(e.fontName)@\(e.pointSize)") }
                    let attrs = theme.attributes(for: s)
                    if attrs[.obliqueness] != nil || attrs[.strokeWidth] != nil { extraKeys.append("\(size) pt \(s)") }
                }
            }
            t.check(fontMismatch.isEmpty, "default look: the font of every style (\(styles.count) of them) at 13 sizes == the baseline rules \(fontMismatch.prefix(3))")
            t.check(heightMismatch.isEmpty, "default look: every line box at 13 sizes == the baseline rules \(heightMismatch.prefix(3))")
            t.check(extraKeys.isEmpty, "default look: no synthetic slant / stroke anywhere \(extraKeys.prefix(3))")
            @MainActor func checkDocument(_ label: String) {
                var bad: [String] = []
                let base = host.theme.baseSize
                for run in md {
                    let loc = run.range.location
                    var ascii = true
                    for i in run.range.location..<NSMaxRange(run.range) where (text as NSString).character(at: i) > 0x7F { ascii = false; break }
                    guard let f = ts.attribute(.font, at: loc, effectiveRange: nil) as? NSFont else { bad.append("no font at \(loc)"); continue }
                    let e = BaselineLook.font(for: run.style, base: base)
                    if ascii ? !f.isEqual(e) : f.pointSize != e.pointSize { bad.append("\(NSStringFromRange(run.range)) \(run.style): \(f.fontName)@\(f.pointSize) vs \(e.fontName)@\(e.pointSize)") }
                    if run.style.headingLevel == 0 && run.style.quoteDepth == 0 && !run.style.contains(.codeBlock) && !run.style.contains(.codeFence) && !run.style.contains(.table) && !run.style.contains(.frontMatter) && !run.style.contains(.horizontalRule),
                       let p = ts.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle, p.minimumLineHeight != BaselineLook.body(base) || p.maximumLineHeight != BaselineLook.body(base) {
                        bad.append("\(NSStringFromRange(run.range)) line box \(p.minimumLineHeight)/\(p.maximumLineHeight) vs \(BaselineLook.body(base))")
                    }
                    if ts.attribute(.obliqueness, at: loc, effectiveRange: nil) != nil || ts.attribute(.strokeWidth, at: loc, effectiveRange: nil) != nil { bad.append("\(NSStringFromRange(run.range)): synthetic attribute") }
                }
                t.check(bad.isEmpty, "\(label): all \(md.count) lexer runs of the document have the baseline font and (plain text) line box, no synthetic attribute \(bad.prefix(3))")
            }
            checkDocument("default look in the editor")
            let reference = dump(ts)
            t.check(reference.count > 100, "set-up: \(reference.count) attribute runs captured")
            // the column
            host.view.window?.contentView?.layoutSubtreeIfNeeded()
            let insetDefault = tv.textContainerInset.width
            t.check(abs(tv.textContainer!.size.width - 760) < 1.5, "default look: the column is 760 pt (\(Int(tv.textContainer!.size.width)))")

            // ---- 2. change everything, then Restore Defaults in the Settings window: the same attributes, run for run
            let body = installedFamilies(["Georgia", "Times"]).first ?? anyFamily() ?? "Helvetica"
            let code = installedFamilies(["Menlo", "Courier New"]).first ?? anyFamily(monospaced: true) ?? "Courier"
            P.bodyFontFamily = body; P.codeFontFamily = code; P.fontSize = 23; P.lineHeightFactor = 1.9; P.columnWidth = 540
            if let other = ColorSchemes.all.first(where: { $0.id != ColorSchemes.defaultID }) { P.colorSchemeID = other.id }
            host.styler.styleEverything()
            let changed = dump(ts)
            t.check(changed.count != reference.count || !zip(changed, reference).allSatisfy { $0.0 == $1.0 && sameAttributes($0.1, $1.1) }, "set-up: the look really changed (fonts \(body) / \(code), 23 pt, 1.9, column 540)")
            t.check(abs(tv.textContainer!.size.width - 540) < 1.5, "set-up: the column changed to \(Int(tv.textContainer!.size.width)) pt")
            let c = SettingsWindowController.shared
            c.restoreButton.performClick(nil)
            await t.spin(20)
            host.styler.styleEverything()
            let after = dump(ts)
            var firstDiff = ""
            if after.count == reference.count {
                for (x, y) in zip(after, reference) where x.0 != y.0 || !sameAttributes(x.1, y.1) { firstDiff = "at \(NSStringFromRange(y.0)): \(StyleOracle.describe(x.1)) vs \(StyleOracle.describe(y.1))"; break }
            } else { firstDiff = "\(after.count) runs vs \(reference.count)" }
            t.check(after.count == reference.count && firstDiff.isEmpty, "Restore Defaults: the attributes of all \(reference.count) runs are what they were before the changes (fonts, colours, paragraph styles, marks) \(firstDiff)")
            checkDocument("after Restore Defaults")
            host.view.window?.contentView?.layoutSubtreeIfNeeded()
            t.check(abs(tv.textContainerInset.width - insetDefault) < 0.5 && abs(tv.textContainer!.size.width - 760) < 1.5, "Restore Defaults: the column is 760 pt again (inset \(tv.textContainerInset.width))")
            t.check(host.theme.settings == ThemeSettings(baseSize: 16) && host.view.window?.appearance == nil, "Restore Defaults: the theme settings are the default ones and the window follows the system appearance")
            assertMatchesFreshLex(t, host, "Restore Defaults: whole document == fresh Theme + lex")
            // not-yet-styled text changes with it, too: a second document, far from the viewport
            t.close(doc)
        }
    }
}
#endif
