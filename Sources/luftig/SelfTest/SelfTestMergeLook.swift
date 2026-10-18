#if LUFTIG_SELFTEST
// SelfTestMergeLook.swift - the fixed Settings window (fix-settings-*) under the current system look (look-*): what neither of the two could check alone.
// Registered through `mergeLookScenarios`.
//
//   look-settings-fixed  the fixed layout under the new control metrics, in four appearances (light and dark system with the default scheme, a dark scheme on a
//                        light system, a light scheme on a dark system), at the user's configuration (Fira Code, 14 pt, spacing 1.1): every control through
//                        its whole range, every frame identical to the pixel in every state AND in every appearance, the window keeps its size; the focused
//                        size field follows the stepper and ⌘+ in each appearance; a click on the sliders and the stepper (drawn by a hosted SwiftUI view
//                        under the new look) still reaches the controls' own `mouseDown`, which is what the drag coalescing relies on.

import AppKit

extension SelfTestScenarios {
    static let mergeLookScenarios: [SelfTest.Scenario] = [
        .init(name: "look-settings-fixed", summary: "fixed Settings layout under the new look: every control through its range in 4 appearances (light, dark, dark scheme on light system, light scheme on dark system), frames identical everywhere; focused size field follows the stepper; clicks on the sliders / stepper reach their mouseDown (drag coalescing)",
              run: { t in try await lookSettingsFixed(t) }),
    ]

    /// Every view of the Settings window that has a place of its own (the controls, the labels of the grid, the grid, the preview), in content coordinates.
    @MainActor private static func mergeFrames(_ c: SettingsWindowController) -> [String: NSRect] {
        guard let content = c.window?.contentView else { return [:] }
        content.layoutSubtreeIfNeeded()
        var views: [(String, NSView)] = [
            ("preview", c.preview.scrollView), ("schemePopup", c.schemePopup), ("bodyFontPopup", c.bodyFontPopup), ("codeFontPopup", c.codeFontPopup),
            ("sizeField", c.sizeField), ("sizeStepper", c.sizeStepper), ("spacingSlider", c.spacingSlider), ("spacingValueLabel", c.spacingValueLabel),
            ("spacingAutomaticCheckbox", c.spacingAutomaticCheckbox), ("spacingNoteLabel", c.spacingNoteLabel), ("limitCheckbox", c.limitCheckbox),
            ("widthSlider", c.widthSlider), ("widthValueLabel", c.widthValueLabel), ("widthNoteLabel", c.widthNoteLabel), ("restoreButton", c.restoreButton),
        ]
        @MainActor func walk(_ v: NSView) {
            if let g = v as? NSGridView {
                let name = "grid\(views.filter { $0.0.hasPrefix("grid") && !$0.0.contains(".") }.count)"      // grid0: General, grid1: Text, grid2: Layout (the order of the containers)
                views.append((name, g))
                for row in 0..<g.numberOfRows { if let l = g.cell(atColumnIndex: 0, rowIndex: row).contentView { views.append(("\(name).label\(row)", l)) } }
            }
            v.subviews.forEach(walk)
        }
        walk(content)
        var out: [String: NSRect] = [:]
        for (name, v) in views { out[name] = v.convert(v.bounds, to: content) }
        out["content"] = content.bounds
        if let w = c.window { out["window"] = NSRect(origin: .zero, size: w.frame.size) }
        return out
    }

    @MainActor static func lookSettingsFixed(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            SettingsWindowController.headless = true
            let P = EditorPreferences.self
            @MainActor func send(_ control: NSControl) { control.sendAction(control.action, to: control.target) }
            let fira = fixUserSettings()
            let (doc, a, _) = try await openEditor(t, text: settingsDocument(times: 40), name: "merge-look.md", size: NSSize(width: 900, height: 700))
            _ = doc
            let c = SettingsWindowController.shared
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            guard let window = c.window, let content = window.contentView else { t.check(false, "no settings window"); return }
            defer { window.appearance = nil }
            window.setContentSize(NSSize(width: 679, height: content.frame.height))       // the width of the user's screenshot
            t.note("the user's configuration: \(fira), 14 pt, spacing 1.1; Settings window \(Int(content.frame.width)) x \(Int(content.frame.height)) pt")

            // The four appearances. A fixed scheme forces the app's appearance (Palette.apply) and the window inherits it, as in the app; the default scheme
            // follows the system, which the window's own appearance stands in for here.
            let cases: [(label: String, scheme: String, system: NSAppearance.Name, dark: Bool)] = [
                ("light system, default scheme", ColorSchemes.defaultID, .aqua, false),
                ("dark system, default scheme", ColorSchemes.defaultID, .darkAqua, true),
                ("dark scheme (GitHub Dark) on a light system", "github-dark", .aqua, true),
                ("light scheme (Solarized Light) on a dark system", "solarized-light", .darkAqua, false),
            ]
            @MainActor func enter(_ k: (label: String, scheme: String, system: NSAppearance.Name, dark: Bool)) {
                P.colorSchemeID = k.scheme
                window.appearance = Palette.isSystemScheme ? NSAppearance(named: k.system) : nil
                P.bodyFontFamily = fira; P.codeFontFamily = fira; P.fontSize = 14; P.lineHeightFactor = 1.1; P.readableWidth = true; P.columnWidth = 760
                c.syncFromPreferences()
            }

            enter(cases[0])
            let reference = mergeFrames(c)
            t.check(reference.count > 20, "set-up: \(reference.count) frames recorded")
            var states = 0
            for k in cases {
                enter(k)
                // a changed NSApp.appearance reaches the window's effectiveAppearance one run-loop turn later (measured: right after the switch it is still the
                // old one), and on a busy machine later still: wait for it, up to a second
                var isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                var waited = 0.0
                while isDark != k.dark && waited < 1000 { await t.sleep(30); waited += 30; isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
                t.equal(isDark, k.dark, "\(k.label): the window is drawn \(k.dark ? "dark" : "light")")
                var moved: [String] = []
                var noteSeen = Set<Bool>()
                @MainActor func probe(_ what: String, _ body: () -> Void) {
                    body()
                    states += 1
                    let now = mergeFrames(c)
                    for (name, r) in reference where now[name] != r && moved.count < 6 { moved.append("\(what): \(name) \(NSStringFromRect(r)) -> \(now[name].map { NSStringFromRect($0) } ?? "gone")") }
                }
                probe("start") {}
                for i in 0...90 {
                    probe("line spacing \(1.1 + Double(i) / 100)") { c.spacingSlider.doubleValue = 1.1 + Double(i) / 100; send(c.spacingSlider) }
                    noteSeen.insert(c.spacingNoteLabel.stringValue.isEmpty)
                }
                probe("line spacing 1.1") { c.spacingSlider.doubleValue = 1.1; send(c.spacingSlider) }
                for w in stride(from: 480, through: 1400, by: 20) { probe("column width \(w)") { c.widthSlider.doubleValue = Double(w); send(c.widthSlider) } }
                for s in 9...40 { probe("size \(s)") { c.sizeStepper.doubleValue = Double(s); send(c.sizeStepper) } }
                probe("size 14") { c.sizeStepper.doubleValue = 14; send(c.sizeStepper) }
                probe("Automatic on") { c.spacingAutomaticCheckbox.performClick(nil) }
                probe("Automatic off") { c.spacingAutomaticCheckbox.performClick(nil) }
                probe("Limit off") { c.limitCheckbox.performClick(nil) }
                probe("Limit on") { c.limitCheckbox.performClick(nil) }
                probe("Restore Defaults") { c.restoreButton.performClick(nil) }
                enter(k)
                probe("the user's configuration again") {}
                t.check(noteSeen.count == 2, "\(k.label): the line-spacing note came and went while the slider crossed its range")
                t.equal(moved.count, 0, "\(k.label): NO frame moved and none differs from the light-system reference, to the pixel \(moved)")

                // the size field, focused, follows the stepper and ⌘+ (what the user reported), in this appearance
                t.check(window.makeFirstResponder(c.sizeField), "\(k.label): the size field takes the focus")
                c.sizeField.currentEditor()?.selectAll(nil)
                c.sizeStepper.doubleValue += 1; send(c.sizeStepper)
                t.check(P.fontSize == 15 && c.sizeField.currentEditor()?.string == "15" && a.fontSize == 15, "\(k.label): stepper up with the field focused: preference \(P.fontSize), the field shows '\(c.sizeField.currentEditor()?.string ?? c.sizeField.stringValue)', editor \(a.fontSize)")
                _ = window.firstResponder?.tryToPerform(#selector(LuftigEditorActions.luftigIncreaseFontSize(_:)), with: nil)
                t.check(P.fontSize == 16 && c.sizeField.currentEditor()?.string == "16", "\(k.label): ⌘+ with the field focused: the field shows '\(c.sizeField.currentEditor()?.string ?? c.sizeField.stringValue)'")
                window.makeFirstResponder(nil)
            }
            t.note("\(states) states checked in \(cases.count) appearances")

            // ---- the drag coalescing under the new controls. It relies on the slider's (and the stepper's) `mouseDown` override: `SettingsSlider` marks the drag
            // open, calls super (AppKit's tracking loop) and closes it. Under the new look the control draws through a hosted SwiftUI view INSIDE it; if that
            // view took the clicks itself, the override would never run and the drags would silently stop being coalesced. Hit testing decides who gets the click.
            enter(cases[2])
            await t.sleep(30)
            content.layoutSubtreeIfNeeded()
            for (name, control) in [("line spacing slider", c.spacingSlider as NSControl), ("column width slider", c.widthSlider), ("size stepper", c.sizeStepper)] {
                let r = control.bounds
                var hits: [String] = []
                for (fx, fy) in [(0.1, 0.5), (0.5, 0.5), (0.9, 0.5), (0.5, 0.35), (0.5, 0.65)] as [(CGFloat, CGFloat)] {     // inside the alignment rect (a classic slider's frame overhangs it)
                    let p = control.convert(NSPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy), to: content.superview)
                    let hit = content.superview?.hitTest(p)
                    if hit !== control { hits.append("(\(fx), \(fy)) -> \(hit.map { "\(type(of: $0))" } ?? "nil")") }
                }
                t.check(hits.isEmpty, "\(name): a click anywhere on it reaches the control itself (\(type(of: control))), not the hosted view inside it \(hits)")
            }
            // The override then wraps the tracking: a mouse-down opens the drag and the end closes it, with one final broadcast. (Whether AppKit's tracking loop
            // BLOCKS inside `mouseDown` for a real drag cannot be seen here: in a headless process no mouse button is really pressed and the loop returns at once,
            // leaving queued drag events untouched - in the classic look as well. Those events are taken out of the queue below.)
            final class Flags: @unchecked Sendable { var duringDrag = 0, total = 0 }      // written on the main thread only (the notification is posted there)
            let flags = Flags()
            let token = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { _ in
                flags.total += 1
                if EditorPreferences.isAdjusting { flags.duringDrag += 1 }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            P.lineHeightFactor = 1.6; c.syncFromPreferences()
            let slider = c.spacingSlider
            let knob = (slider.cell as? NSSliderCell)?.knobRect(flipped: slider.isFlipped) ?? .zero
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                slider.mouseDown(with: down)              // what the window does with a click the hit test gave the slider (`window.sendEvent` of a synthetic click does nothing headless)
            }
            while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date.distantPast, inMode: .default, dequeue: true) != nil {}
            t.check(flags.duringDrag >= 1, "the slider's mouseDown opened a drag around its action (\(flags.duringDrag) of \(flags.total) broadcasts inside it)")
            t.check(c.trackedControl == nil && !EditorPreferences.isAdjusting, "after the mouse-down returned no drag is left open")
            t.check(a.theme.settings == P.themeSettings && c.preview.theme.settings == P.themeSettings, "the editor and the preview ended on the final value (\(P.lineHeightFactor.map { String(format: "%.2f", Double($0)) } ?? "nil"))")
        }
    }
}
#endif
