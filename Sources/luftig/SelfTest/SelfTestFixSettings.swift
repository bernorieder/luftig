#if LUFTIG_SELFTEST
// SelfTestFixSettings.swift - the three defects the user found in the Settings window, and the polish for dragging its sliders.
//
//   fix-settings-layout  the grid of controls never moves, nothing resizes the window, whatever a value, a note or a font name says (the user's
//                        configuration: Fira Code, 14 pt, spacing 1.1, GitHub Dark; "the settings jump to the right when the slider goes left")
//   fix-settings-size    the size field shows the size in use whatever has the keyboard focus (stepper arrows with the field being edited left the old number)
//   fix-settings-drag    dragging a slider or holding the stepper: the editors follow at a bounded rate, the last value always arrives, nothing is stale,
//                        invisible windows wait, the window itself never lags
//
// The controls are driven the way the user's hand drives them: through their actions (`sendAction`), through the field editor of the focused size field
// (`makeFirstResponder`, `insertText`, `doCommand(by:)`), through the responder chain (⌘+ ⌘- ⌘0). Nothing is set that a hand could not set.

import AppKit
import MarkdownKit

extension SelfTestScenarios {

    static let fixSettingsScenarios: [SelfTest.Scenario] = [
        .init(name: "fix-settings-layout", summary: "Settings window: no control moves and the window never resizes whatever a value / note / font name says (every slider position, size, scheme, a 40-character font name, note on / off, Automatic, Limit, three window widths)",
              run: { t in try await fixSettingsLayout(t) }),
        .init(name: "fix-settings-size", summary: "Settings window: the size field shows the size in use while it is being edited (stepper, ⌘+ ⌘- ⌘0, Restore Defaults), typing + Return / clicking elsewhere, out-of-range and non-numeric input; every other control follows the preferences whatever has focus",
              run: { t in try await fixSettingsSize(t) }),
        .init(name: "fix-settings-drag", summary: "Settings window: a synthetic slider / stepper drag over a 10 MB document sends a bounded number of broadcasts, restyles at most once per ~40 ms, ends on the final value, hidden windows wait, no main-thread stall",
              run: { t in try await fixSettingsDrag(t) }),
    ]

    @MainActor private static func send(_ control: NSControl) { control.sendAction(control.action, to: control.target) }

    @MainActor @discardableResult private static func choose(_ popup: NSPopUpButton, _ value: String?) -> Bool {
        guard let menu = popup.menu else { return false }
        let index = value == nil ? 0 : (menu.items.firstIndex { ($0.representedObject as? String) == value } ?? -1)
        guard index >= 0 else { return false }
        popup.selectItem(at: index)
        send(popup)
        return true
    }

    /// The configuration of the user's screenshot: GitHub Dark, Fira Code for text and code, 14 pt, line spacing 1.1 (Automatic off).
    @MainActor @discardableResult static func fixUserSettings() -> String {
        let P = EditorPreferences.self
        let fira = FontFactory.resolve("Fira Code") != nil ? "Fira Code" : (anyFamily(monospaced: true) ?? "Menlo")
        P.colorSchemeID = "github-dark"; P.bodyFontFamily = fira; P.codeFontFamily = fira; P.fontSize = 14; P.lineHeightFactor = 1.1
        return fira
    }

    // MARK: layout

    /// Every view of the Settings window that has a place of its own, by name.
    @MainActor private static func fixSettingsViews(_ c: SettingsWindowController) -> [(name: String, view: NSView)] {
        var views: [(String, NSView)] = [
            ("preview", c.preview.scrollView), ("schemePopup", c.schemePopup), ("bodyFontPopup", c.bodyFontPopup), ("codeFontPopup", c.codeFontPopup),
            ("sizeField", c.sizeField), ("sizeStepper", c.sizeStepper), ("codeSizeField", c.codeSizeField), ("codeSizeStepper", c.codeSizeStepper), ("spacingSlider", c.spacingSlider), ("spacingValueLabel", c.spacingValueLabel),
            ("spacingAutomaticCheckbox", c.spacingAutomaticCheckbox), ("spacingNoteLabel", c.spacingNoteLabel), ("limitCheckbox", c.limitCheckbox),
            ("widthSlider", c.widthSlider), ("widthValueLabel", c.widthValueLabel), ("widthNoteLabel", c.widthNoteLabel), ("restoreButton", c.restoreButton),
            ("paneFontPopup", c.paneFontPopup), ("paneSizePopup", c.paneSizePopup), ("paneOpacitySlider", c.paneOpacitySlider), ("paneOpacityValueLabel", c.paneOpacityValueLabel),
            ("outlineWrapCheckbox", c.outlineWrapCheckbox), ("screenControl", c.screenControl), ("openInTabsCheckbox", c.openInTabsCheckbox), ("outlineSpacingSlider", c.outlineSpacingSlider), ("outlineSpacingValueLabel", c.outlineSpacingValueLabel),
            ("showOutlineCheckbox", c.showOutlineCheckbox), ("showWordCountCheckbox", c.showWordCountCheckbox), ("showSyntaxBarCheckbox", c.showSyntaxBarCheckbox), ("showReadingTimeCheckbox", c.showReadingTimeCheckbox),
            ("paddingSlider", c.paddingSlider), ("paddingValueLabel", c.paddingValueLabel), ("paddingNoteLabel", c.paddingNoteLabel),
        ]
        func walk(_ v: NSView) {
            if let g = v as? NSGridView {
                let name = "grid\(views.filter { $0.0.hasPrefix("grid") && !$0.0.contains(".") }.count)"      // grid0: General, grid1: Text, grid2: Layout (the order of the containers)
                views.append((name, g))
                for row in 0..<g.numberOfRows { if let l = g.cell(atColumnIndex: 0, rowIndex: row).contentView { views.append(("\(name).label\(row)", l)) } }
            }
            v.subviews.forEach(walk)
        }
        if let content = c.window?.contentView { walk(content) }
        return views
    }

    @MainActor private static func fixFrames(_ c: SettingsWindowController) -> [String: NSRect] {
        guard let content = c.window?.contentView else { return [:] }
        content.layoutSubtreeIfNeeded()
        var out: [String: NSRect] = [:]
        for (name, v) in fixSettingsViews(c) { out[name] = v.convert(v.bounds, to: content) }
        out["content"] = content.bounds
        if let w = c.window { out["window"] = NSRect(origin: .zero, size: w.frame.size) }
        return out
    }

    /// Does the label's text fit its (fixed) width, i.e. is nothing cut off?
    @MainActor private static func fixTruncated(_ c: SettingsWindowController) -> [String] {
        var cut: [String] = []
        for (name, l) in [("spacingValueLabel", c.spacingValueLabel), ("spacingNoteLabel", c.spacingNoteLabel), ("widthValueLabel", c.widthValueLabel), ("widthNoteLabel", c.widthNoteLabel)] {
            let w = l.attributedStringValue.size().width
            if w > l.frame.width - 4 + 0.5 { cut.append("\(name) '\(l.stringValue)' needs \(Int(w.rounded(.up))) pt, has \(Int(l.frame.width - 4))") }
        }
        return cut
    }

    @MainActor static func fixSettingsLayout(_ t: SelfTest.T) async throws {
        await preservingSettings {
            SettingsWindowController.headless = true
            let P = EditorPreferences.self
            let fira = fixUserSettings()
            let c = SettingsWindowController.shared
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            guard let window = c.window, let content = window.contentView else { t.check(false, "no settings window"); return }
            let userWidth: CGFloat = 679                                    // the width of the user's screenshot (1358 px at 2x)
            window.setContentSize(NSSize(width: userWidth, height: content.frame.height))
            t.note("user's configuration: GitHub Dark, \(fira), 14 pt, spacing 1.1, window \(Int(userWidth)) pt wide; the note is \(c.spacingNoteLabel.stringValue.isEmpty ? "hidden" : "shown: '\(c.spacingNoteLabel.stringValue)'")")
            let reference = fixFrames(c)
            t.check(reference.count > 20, "set-up: \(reference.count) frames recorded (every control, every label of the grid, the grid, the window)")
            var grid: NSGridView?
            @MainActor func findGrid(_ v: NSView) { if let g = v as? NSGridView { grid = g }; v.subviews.forEach(findGrid) }
            findGrid(content)
            t.check(grid != nil && grid!.fittingSize.width == grid!.frame.width, "the grid is as wide as its content (\(grid.map { "\($0.frame.width) pt" } ?? "-")): it is not stretched to the window")
            t.check(grid.map { !$0.hasAmbiguousLayout } ?? false, "the grid's layout is not ambiguous")

            var checked = 0
            var moved: [String] = []
            var cut: [String] = []
            /// Apply a change, then compare EVERY frame with the reference to the pixel.
            @MainActor func probe(_ what: String, _ body: () -> Void) {
                body()
                let now = fixFrames(c)
                checked += 1
                for (name, r) in reference where now[name] != r {
                    if moved.count < 8 { moved.append("\(what): \(name) \(NSStringFromRect(r)) -> \(now[name].map { NSStringFromRect($0) } ?? "gone")") }
                }
                for s in fixTruncated(c) where cut.count < 6 { cut.append("\(what): \(s)") }
            }

            // ---- line spacing: the whole range of the slider, in steps of 0.01 (the note comes and goes at ~1.36 with Fira Code at 14 pt)
            var noteShown = 0, noteHidden = 0
            for i in 0...90 {
                probe("line spacing \(1.1 + Double(i) / 100)") {
                    c.spacingSlider.doubleValue = 1.1 + Double(i) / 100
                    send(c.spacingSlider)
                }
                if c.spacingNoteLabel.stringValue.isEmpty { noteHidden += 1 } else { noteShown += 1 }
            }
            t.check(noteShown > 10 && noteHidden > 10, "... the note was shown at \(noteShown) and absent at \(noteHidden) of the 91 positions (it does come and go)")
            probe("line spacing back to 1.1") { c.spacingSlider.doubleValue = 1.1; send(c.spacingSlider) }

            // ---- column width: the whole range in steps of 10 (the value label and the characters-per-line note change at every step)
            for w in stride(from: 480, through: 1400, by: 10) { probe("column width \(w)") { c.widthSlider.doubleValue = Double(w); send(c.widthSlider) } }
            probe("column width back to 760") { c.widthSlider.doubleValue = 760; send(c.widthSlider) }
            // the two screens: switching hides one container and shows the other; every frame stays where it is (the hidden screen keeps its layout)
            probe("screen: Layout") { c.showScreen(.layout) }
            probe("outline wrap on") { c.outlineWrapCheckbox.state = .on; send(c.outlineWrapCheckbox) }
            probe("outline wrap off") { c.outlineWrapCheckbox.state = .off; send(c.outlineWrapCheckbox) }
            for (i, size) in SettingsWindowController.paneSizes.enumerated() { probe("panes size \(Int(size))") { c.paneSizePopup.selectItem(at: i); send(c.paneSizePopup) } }
            for o in stride(from: 25, through: 100, by: 5) { probe("panes opacity \(o)") { c.paneOpacitySlider.doubleValue = Double(o) / 100; send(c.paneOpacitySlider) } }
            for (box, name) in [(c.showOutlineCheckbox, "outline"), (c.showWordCountCheckbox, "word count"), (c.showSyntaxBarCheckbox, "syntax bar"), (c.showReadingTimeCheckbox, "reading time")] {
                probe("\(name) off") { box.state = .off; send(box) }
                probe("\(name) on") { box.state = .on; send(box) }
            }
            for p in stride(from: 0, through: 50, by: 2) { probe("padding \(p)") { c.paddingSlider.doubleValue = Double(p); send(c.paddingSlider) } }
            probe("padding back to 20") { c.paddingSlider.doubleValue = 20; send(c.paddingSlider) }
            for v in stride(from: 100, through: 250, by: 10) { probe("outline spacing \(v)") { c.outlineSpacingSlider.doubleValue = Double(v) / 100; send(c.outlineSpacingSlider) } }
            probe("outline spacing back to 1.4") { c.outlineSpacingSlider.doubleValue = 1.4; send(c.outlineSpacingSlider) }
            probe("screen: General") { c.showScreen(.general) }
            probe("open in tabs on") { c.openInTabsCheckbox.state = .on; send(c.openInTabsCheckbox) }
            probe("open in tabs off") { c.openInTabsCheckbox.state = .off; send(c.openInTabsCheckbox) }
            probe("screen: Text") { c.showScreen(.text) }

            // ---- size: every size from 9 to 40 (the note and the value label follow the floor of the fonts)
            for s in 9...40 { probe("size \(s)") { c.sizeStepper.doubleValue = Double(s); send(c.sizeStepper) } }
            probe("size back to 14") { c.sizeStepper.doubleValue = 14; send(c.sizeStepper) }

            // ---- every colour scheme
            for s in ColorSchemes.all { probe("scheme \(s.id)") { choose(c.schemePopup, s.id) } }
            probe("scheme back to GitHub Dark") { choose(c.schemePopup, "github-dark") }

            // ---- font names: a very long one (40 and 118 characters), for the text font and for the code font (they are shown as "... (not installed)")
            let long40 = String(repeating: "Wide Font Name ", count: 3).prefix(40).description
            let long118 = String(repeating: "A Family Name That Goes On ", count: 5).prefix(118).description
            t.equal(long40.count, 40, "set-up: a font name of 40 characters")
            for name in [long40, long118] {
                probe("text font '\(name.prefix(12))...' (\(name.count) characters)") { P.bodyFontFamily = name; c.syncFromPreferences() }
                probe("code font '\(name.prefix(12))...' (\(name.count) characters)") { P.codeFontFamily = name; c.syncFromPreferences() }
            }
            t.check(c.bodyFontPopup.selectedItem?.title.contains("not installed") == true, "... the popup shows the long name, marked as not installed (\(c.bodyFontPopup.selectedItem?.title.count ?? 0) characters)")
            P.bodyFontFamily = fira; P.codeFontFamily = fira
            probe("fonts back") { c.syncFromPreferences() }
            // the longest title of the installed families
            if let longest = FontFactory.installedFamilies().max(by: { $0.count < $1.count }) {
                probe("text font '\(longest)'") { choose(c.bodyFontPopup, longest) }
                probe("code font: an installed proportional family '\(longest)'") { P.codeFontFamily = longest; c.syncFromPreferences() }
                P.bodyFontFamily = fira; P.codeFontFamily = fira; c.syncFromPreferences()
            }

            // ---- a tall family at a big size: the largest note ("Raised to ... pt") and the largest value label
            if let tall = installedFamilies(["Zapfino"]).first {
                probe("Zapfino, 40 pt, spacing 1.1") { P.bodyFontFamily = tall; P.fontSize = 40; P.lineHeightFactor = 1.1; c.syncFromPreferences() }
                t.check(!c.spacingNoteLabel.stringValue.isEmpty, "... the note says '\(c.spacingNoteLabel.stringValue)', value '\(c.spacingValueLabel.stringValue)'")
                probe("Zapfino, 40 pt, spacing 2.0") { P.lineHeightFactor = 2.0; c.syncFromPreferences() }
                P.bodyFontFamily = fira; P.fontSize = 14; P.lineHeightFactor = 1.1; c.syncFromPreferences()
            }

            // ---- the checkboxes and Restore Defaults
            probe("Automatic on") { c.spacingAutomaticCheckbox.performClick(nil) }
            probe("Automatic off") { c.spacingAutomaticCheckbox.performClick(nil) }
            probe("Limit off (the slider is disabled, its label says 'window width')") { c.limitCheckbox.performClick(nil) }
            t.check(!c.widthSlider.isEnabled && c.widthValueLabel.stringValue == "window width", "... the enabled state and the label text changed (that is all that may change): '\(c.widthValueLabel.stringValue)'")
            probe("Limit on") { c.limitCheckbox.performClick(nil) }
            probe("Restore Defaults") { c.restoreButton.performClick(nil) }
            probe("Restore Defaults: the note is gone") { c.syncFromPreferences() }
            fixUserSettings()
            probe("user's configuration again") { c.syncFromPreferences() }

            t.equal(moved.count, 0, "NO frame moved, in \(checked) states (every control, every grid label, the grid, the content, the window, to the pixel) \(moved)")
            t.equal(cut.count, 0, "no value label or note is cut off in any of them \(cut)")
            t.check(abs(window.frame.width - (reference["window"]?.width ?? 0)) < 0.5 && abs(window.frame.height - (reference["window"]?.height ?? 0)) < 0.5, "the window kept its size (\(Int(window.frame.width)) x \(Int(window.frame.height)) pt)")

            // ---- three window widths: the grid stays centred, as wide as its content, and keeps its inner layout; nothing runs out of the window
            let gridWidth = reference["grid0"]?.width ?? 0
            let innerNames = ["schemePopup", "bodyFontPopup", "codeFontPopup", "sizeField", "sizeStepper", "codeSizeField", "codeSizeStepper", "spacingSlider", "spacingValueLabel", "spacingAutomaticCheckbox", "spacingNoteLabel", "limitCheckbox", "widthSlider", "widthValueLabel", "widthNoteLabel"]
            for width in [window.contentMinSize.width, 700, 1100, 2000] {
                window.setContentSize(NSSize(width: width, height: window.contentView!.frame.height))
                let f = fixFrames(c)
                var bad: [String] = []
                if let g = f["grid0"] {
                    if abs(g.width - gridWidth) > 0.01 { bad.append("grid width \(g.width) != \(gridWidth)") }
                    if abs(g.midX - width / 2) > 0.5 { bad.append("grid not centred: midX \(g.midX) of \(width / 2)") }
                    if g.minX < 19.5 { bad.append("grid starts at \(g.minX)") }
                    for n in innerNames { if let r = f[n], let r0 = reference[n], let g0 = reference["grid0"], abs((r.minX - g.minX) - (r0.minX - g0.minX)) > 0.01 || abs(r.width - r0.width) > 0.01 || abs(r.minY - r0.minY) > 0.01 { bad.append("\(n) moved inside the grid") } }
                } else { bad.append("no grid") }
                for (n, r) in f where n != "content" && n != "window" && (r.minX < -0.5 || r.maxX > width + 0.5) { bad.append("\(n) outside the window") }
                t.check(bad.isEmpty, "window \(Int(width)) pt wide: the grid is centred, \(Int(gridWidth)) pt wide, laid out as at 679 pt, every control inside \(bad.prefix(3))")
            }
            window.setContentSize(NSSize(width: userWidth, height: window.contentView!.frame.height))

            // ---- the pictures (when asked for): the user's configuration with the note hidden and shown
            if let prefix = SelfTest.argument("png-prefix") {
                for (label, factor) in [("note-hidden", 1.5), ("note-shown", 1.1)] {
                    P.lineHeightFactor = CGFloat(factor); c.syncFromPreferences()
                    await t.sleep(80)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let tv = c.preview.textView
                    _ = tv.layoutManager?.ensureLayout(forBoundingRect: tv.visibleRect, in: tv.textContainer!)
                    if let png = t.renderPNG(window) { try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(label).png")); t.note("wrote \(prefix)-\(label).png (spacing \(factor))") }
                }
            }
        }
    }

    // MARK: the size field

    /// What the user SEES in the size field: the field editor's text while it is being edited, else the field's value.
    @MainActor private static func visibleSize(_ c: SettingsWindowController) -> String { c.sizeField.currentEditor()?.string ?? c.sizeField.stringValue }

    @MainActor static func fixSettingsSize(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            SettingsWindowController.headless = true
            let P = EditorPreferences.self
            P.fontSize = 14
            let (docA, a, _) = try await openEditor(t, text: settingsDocument(times: 1), name: "fs-a.md", size: NSSize(width: 900, height: 600))
            _ = docA
            let c = SettingsWindowController.shared
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            guard let window = c.window else { t.check(false, "no settings window"); return }
            window.contentView?.layoutSubtreeIfNeeded()
            let field = c.sizeField

            /// The field, the stepper, the preference and the editor all say `n`.
            @MainActor func expectSize(_ n: Int, _ label: String) {
                let editing = field.currentEditor() != nil
                t.check(P.fontSize == CGFloat(n) && a.fontSize == CGFloat(n), "\(label): the preference and the editor are at \(n) pt (\(P.fontSize) / \(a.fontSize))")
                t.equal(visibleSize(c), "\(n)", "\(label): the number the user SEES in the field is \(n) (\(editing ? "field editor" : "field"))")
                t.equal(field.stringValue, "\(n)", "\(label): ... and the field's value too")
                t.equal(c.sizeStepper.doubleValue, Double(n), "\(label): ... and the stepper")
            }
            @MainActor func focusField() {
                t.check(window.makeFirstResponder(field), "the size field takes the keyboard focus")
                field.currentEditor()?.selectAll(nil)
                t.check(field.currentEditor() != nil, "... its field editor is active: the text is being edited")
            }
            /// Key presses in the field editor (it is an NSTextView): they replace the selection, as typing does.
            @MainActor func typeKeys(_ s: String) { (field.currentEditor() as? NSTextView)?.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            @MainActor func stepperClick(_ delta: Double) { c.sizeStepper.doubleValue += delta; send(c.sizeStepper) }       // what a click on an arrow does: the value moves, the action is sent

            // ---- the AppKit fact behind the defect (reported, not asserted): what does a field that is being edited show after `doubleValue =`?
            focusField()
            field.doubleValue = 33
            t.note("AppKit: after `doubleValue = 33` on the size field while it is being edited, its field editor shows '\(field.currentEditor()?.string ?? "-")', `stringValue` is '\(field.stringValue)', still editing: \(field.currentEditor() != nil)")
            field.abortEditing(); field.doubleValue = 14; c.syncFromPreferences()

            // ---- the bug, exactly: the field is first responder with its text selected, then the stepper arrows
            focusField()
            t.equal(visibleSize(c), "14", "the field shows 14")
            stepperClick(+1); expectSize(15, "stepper up")
            t.check(field.currentEditor() != nil && window.firstResponder === field.currentEditor(), "... the field still has the focus, still being edited")
            t.equal(field.currentEditor()?.selectedRange, NSRange(location: 0, length: 2), "... its text is selected (the next digit replaces it)")
            stepperClick(+1); stepperClick(+1); expectSize(17, "stepper up twice more")
            stepperClick(-1); expectSize(16, "stepper down")
            // (A synthesized click on an arrow cannot drive the stepper in a headless process: a mouse-down with the mouse-up queued, through `window.sendEvent` or
            // `mouseDown(with:)`, runs the cell's tracking loop and changes nothing, and `accessibilityPerformIncrement()` answers false. What a click does - the cell's
            // value moves, the action is sent - is `stepperClick` above; `performClick` below is AppKit's own click.)
            c.sizeStepper.performClick(nil)                                      // AppKit's own click
            t.check(P.fontSize != 16 && visibleSize(c) == "\(Int(P.fontSize))", "performClick on the stepper: the preference is \(P.fontSize) and the field shows \(visibleSize(c))")
            P.fontSize = 16
            for _ in 0..<25 { stepperClick(+1) }                                  // 41 would be past the end: the stepper stops at 40
            t.check(visibleSize(c) == "\(Int(P.fontSize))" && P.fontSize == 40, "at the top of the range the field shows \(visibleSize(c)) (preference \(P.fontSize))")
            P.fontSize = 14; c.syncFromPreferences()

            // ---- ⌘+ ⌘- ⌘0 with the field focused: the responder chain of the Settings window (field editor -> field -> window -> its controller)
            focusField()
            @MainActor func shortcut(_ sel: Selector) -> Bool { window.firstResponder?.tryToPerform(sel, with: nil) ?? false }
            t.check(shortcut(#selector(LuftigEditorActions.luftigIncreaseFontSize(_:))), "⌘+ reaches the Settings window from the focused field")
            expectSize(15, "⌘+")
            t.check(shortcut(#selector(LuftigEditorActions.luftigDecreaseFontSize(_:))) && shortcut(#selector(LuftigEditorActions.luftigDecreaseFontSize(_:))), "⌘- twice")
            expectSize(13, "⌘- twice")
            t.check(shortcut(#selector(LuftigEditorActions.luftigResetFontSize(_:))), "⌘0")
            expectSize(16, "⌘0")
            // the same from the editor window (View > Bigger in a document window while the Settings field is focused)
            a.luftigIncreaseFontSize(nil); expectSize(17, "⌘+ in the document window")
            a.luftigDecreaseFontSize(nil); a.luftigDecreaseFontSize(nil); expectSize(15, "⌘- twice in the document window")
            P.fontSize = 22; expectSize(22, "the preference set from elsewhere")

            // ---- typing a number + Return
            focusField()
            typeKeys("2")      // replaces the selection, as a key press does
            typeKeys("4")
            t.equal(visibleSize(c), "24", "typed 2, 4: the field shows 24")
            t.equal(P.fontSize, 22, "... nothing is applied before Return")
            field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            expectSize(24, "typed 24 + Return")

            // ---- typing, then clicking elsewhere (the field loses the focus: the number is taken)
            focusField()
            typeKeys("30")
            t.check(window.makeFirstResponder(nil), "clicking elsewhere takes the focus away")
            expectSize(30, "typed 30, then focus left")

            // ---- text the user is typing is not thrown away when another setting changes
            focusField()
            typeKeys("2")
            P.columnWidth = 900; P.lineHeightFactor = 1.6
            t.equal(visibleSize(c), "2", "typing '2' while the column width and the line spacing change: the typed text stays")
            P.lineHeightFactor = nil; P.columnWidth = 760
            typeKeys("0")
            field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            expectSize(20, "... then the 0 and Return")

            // ---- out of range: clamped, and the field shows what was used
            for (typed, expected) in [("100", 40), ("5", 9), ("0", 9), ("40", 40), ("9", 9), ("41", 40), ("999", 40)] as [(String, Int)] {
                focusField()
                typeKeys(typed)
                field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                t.equal(visibleSize(c), "\(expected)", "typed \(typed) + Return: the field shows \(expected) (the size in use: \(P.fontSize))")
                t.check(P.fontSize == CGFloat(expected) && c.sizeStepper.doubleValue == Double(expected), "... preference \(P.fontSize), stepper \(c.sizeStepper.doubleValue)")
            }
            // a fraction, written the way this machine's locale writes it (the formatter takes the locale's decimal separator)
            let sep = (field.formatter as? NumberFormatter)?.decimalSeparator ?? "."
            focusField()
            typeKeys("12\(sep)5")
            field.currentEditor()?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            t.check(P.fontSize == 12.5 && visibleSize(c) == "12\(sep)5", "typed 12\(sep)5 + Return: \(P.fontSize) pt, the field shows '\(visibleSize(c))'")
            P.fontSize = 18; c.syncFromPreferences()
            // not a number (a field set from code; a paste the formatter would refuse; an empty field): nothing changes, the field shows the size in use
            for junk in ["abc", "", ".", "--", "1e", "  "] {
                focusField()
                field.currentEditor()?.string = junk
                _ = window.makeFirstResponder(nil)
                if field.currentEditor() != nil { _ = c.control(field, didFailToFormatString: junk, errorDescription: nil); _ = window.makeFirstResponder(nil) }
                t.check(P.fontSize == 18 && visibleSize(c) == "18" && field.currentEditor() == nil, "'\(junk)' is not a size: still 18 pt, the field shows '\(visibleSize(c))', not stuck in editing")
            }
            field.stringValue = "abc"; send(field)
            t.check(P.fontSize == 18 && visibleSize(c) == "18", "'abc' sent to the action from code: still 18 pt, the field shows '\(visibleSize(c))'")

            // ---- arrow keys in the field: they move the caret, nothing else
            focusField()
            for (key, code) in [("\u{F700}", 126), ("\u{F701}", 125), ("\u{F702}", 123), ("\u{F703}", 124)] as [(String, UInt16)] {
                if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                             characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) { window.sendEvent(ev) }
            }
            for sel in [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:))] { field.currentEditor()?.doCommand(by: sel) }
            t.check(P.fontSize == 18 && visibleSize(c) == "18" && c.sizeStepper.doubleValue == 18, "arrow keys in the field change nothing: 18 pt, the field shows '\(visibleSize(c))'")
            stepperClick(+1); expectSize(19, "the stepper still works after the arrow keys")
            _ = window.makeFirstResponder(nil)
            expectSize(19, "focus left")

            // ---- Restore Defaults while the field is being edited
            focusField()
            c.restoreButton.performClick(nil)
            expectSize(16, "Restore Defaults while the size field is being edited")
            _ = window.makeFirstResponder(nil)

            // ---- the other controls follow the preferences whatever has the focus: field editor, a slider, a pop-up, a check box
            let other = ColorSchemes.all.first { $0.id != ColorSchemes.defaultID }?.id ?? ColorSchemes.defaultID
            let body = installedFamilies(["Georgia", "Times", "Helvetica Neue"]).first ?? anyFamily() ?? "Helvetica"
            let code = installedFamilies(["Menlo", "Courier New", "Monaco"]).first ?? anyFamily(monospaced: true) ?? "Courier"
            let focusTargets: [(String, () -> Void)] = [
                ("the size field (being edited)", { focusField() }),
                ("the line spacing slider", { _ = window.makeFirstResponder(c.spacingSlider) }),
                ("the column width slider", { _ = window.makeFirstResponder(c.widthSlider) }),
                ("the text font pop-up", { _ = window.makeFirstResponder(c.bodyFontPopup) }),
                ("the Automatic check box", { _ = window.makeFirstResponder(c.spacingAutomaticCheckbox) }),
                ("the stepper", { _ = window.makeFirstResponder(c.sizeStepper) }),
            ]
            for (name, focus) in focusTargets {
                P.restoreDefaults(); c.syncFromPreferences()
                focus()
                P.fontSize = 21; P.colorSchemeID = other; P.bodyFontFamily = body; P.codeFontFamily = code; P.lineHeightFactor = 1.7; P.columnWidth = 900; P.readableWidth = false
                var bad: [String] = []
                if visibleSize(c) != "21" || c.sizeStepper.doubleValue != 21 { bad.append("size '\(visibleSize(c))' / stepper \(c.sizeStepper.doubleValue)") }
                if (c.schemePopup.selectedItem?.representedObject as? String) != other { bad.append("scheme popup") }
                if (c.bodyFontPopup.selectedItem?.representedObject as? String) != body || (c.codeFontPopup.selectedItem?.representedObject as? String) != code { bad.append("font popups") }
                if c.spacingAutomaticCheckbox.state != .off || abs(c.spacingSlider.doubleValue - 1.7) > 0.001 || !c.spacingValueLabel.stringValue.hasPrefix("1.70") { bad.append("line spacing: \(c.spacingValueLabel.stringValue), slider \(c.spacingSlider.doubleValue), Automatic \(c.spacingAutomaticCheckbox.state.rawValue)") }
                if c.limitCheckbox.state != .off || c.widthSlider.isEnabled || c.widthValueLabel.stringValue != "window width" || abs(c.widthSlider.doubleValue - 900) > 0.001 { bad.append("column: \(c.widthValueLabel.stringValue), slider \(c.widthSlider.doubleValue), Limit \(c.limitCheckbox.state.rawValue)") }
                P.readableWidth = true
                if c.limitCheckbox.state != .on || !c.widthSlider.isEnabled || c.widthValueLabel.stringValue != "900 pt" { bad.append("column limited again: \(c.widthValueLabel.stringValue)") }
                P.restoreDefaults()
                if visibleSize(c) != "16" || c.spacingAutomaticCheckbox.state != .on || c.widthValueLabel.stringValue != "760 pt" || c.schemePopup.selectedItem?.representedObject as? String != ColorSchemes.defaultID { bad.append("Restore Defaults: size '\(visibleSize(c))', \(c.widthValueLabel.stringValue)") }
                t.check(bad.isEmpty, "focus on \(name): every control follows a change of every preference (size, scheme, both fonts, spacing, column, Limit, Restore Defaults) \(bad)")
                _ = window.makeFirstResponder(nil)
            }
            P.restoreDefaults()
        }
    }

    // MARK: dragging a slider

    /// Counts what a drag does to one editor and to the machine.
    private struct DragResult {
        var rebuilds = 0, broadcasts = 0
        var seen: [CGFloat] = []              // the line-height factor each broadcast carried, in order
        var durationMs = 0.0, maxGapMs = 0.0
        var previewStale = 0                  // events after which the Settings preview did not show the slider's value
    }

    @MainActor static func fixSettingsDrag(_ t: SelfTest.T) async throws {
        try await preservingSettings {
            SettingsWindowController.headless = true
            let P = EditorPreferences.self
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let loaded = PerfLab.loadAverage() > cores / 2
            let big = t.corpusFile(bytes: 10_000_000)
            let (docA, a, _) = try await openEditor(t, text: try String(contentsOf: big, encoding: .utf8), name: "drag-a.md", size: NSSize(width: 1100, height: 800))
            let (docB, b, _) = try await openEditor(t, text: settingsDocument(times: 40), name: "drag-b.md", size: NSSize(width: 900, height: 700))
            _ = (docA, docB)
            let c = SettingsWindowController.shared
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            let fira = fixUserSettings()
            await t.sleep(50)
            _ = fira
            P.lineHeightFactor = 1.2
            for h in [a, b] { h.styler.styleVisible(); perfLayoutVisible(h) }
            defer { EditorViewController.visibilityOverride = nil }

            /// One synthetic drag: `events` slider actions `pace` ms apart (120 Hz) from 1.2 to 2.0, the mouse down at the start and up at the end.
            @MainActor func drag(_ label: String, events: Int, pace: Double, visible: Bool?) async -> DragResult {
                EditorViewController.visibilityOverride = visible
                let slider = c.spacingSlider
                var r = DragResult()
                let rebuilds0 = a.themeRebuildCount
                let broadcasts0 = EditorPreferences.broadcastCount
                var last: CGFloat = -1
                let token = NotificationCenter.default.addObserver(forName: P.didChange, object: nil, queue: nil) { _ in
                    let f = P.lineHeightFactor ?? 0
                    r.seen.append(f); last = f
                }
                defer { NotificationCenter.default.removeObserver(token) }
                var prev = SelfTest.nowMs()
                let t0 = prev
                @MainActor func gap() { let n = SelfTest.nowMs(); r.maxGapMs = max(r.maxGapMs, n - prev); prev = n }
                c.tracking(slider, began: true)
                for i in 0..<events {
                    let v = 1.2 + 0.8 * Double(i) / Double(events - 1)
                    slider.doubleValue = v
                    send(slider)
                    // the Settings window itself must follow the hand at once: its preview is built from the slider's value
                    if abs((c.preview.theme.settings.lineHeightFactor ?? 0) - CGFloat((v * 100).rounded() / 100)) > 0.0001 { r.previewStale += 1 }
                    let due = t0 + Double(i + 1) * pace
                    while SelfTest.nowMs() < due { try? await Task.sleep(nanoseconds: 1_000_000); gap() }
                    gap()
                }
                c.tracking(slider, began: false)
                gap()
                r.durationMs = SelfTest.nowMs() - t0
                r.rebuilds = a.themeRebuildCount - rebuilds0
                r.broadcasts = EditorPreferences.broadcastCount - broadcasts0
                _ = last
                t.note("\(label): \(events) slider actions over \(Int(r.durationMs)) ms -> \(r.broadcasts) broadcasts, \(r.rebuilds) restyles of the 10 MB editor; longest main-thread gap \(Int(r.maxGapMs)) ms; \(r.previewStale) preview mismatches")
                return r
            }

            // ---- 1. the baseline of this machine: how long ONE restyle of the 10 MB document takes (so the bound below is the bound for THIS machine)
            P.lineHeightFactor = 1.3
            let one0 = SelfTest.nowMs()
            P.lineHeightFactor = 1.31
            let oneRestyle = SelfTest.nowMs() - one0
            t.note("one restyle of the 10 MB editor + the 1 MB-class window + the preview: \(Int(oneRestyle)) ms")
            P.lineHeightFactor = 1.2

            // ---- 2. a drag with the windows visible
            let r1 = await drag("visible windows", events: 150, pace: 1000.0 / 120, visible: true)
            let interval = max(EditorPreferences.minimumAdjustingInterval * 1000, oneRestyle)
            let bound = Int((r1.durationMs / interval).rounded(.up)) + 3
            t.check(r1.rebuilds <= bound, "visible windows: \(r1.rebuilds) restyles of the 10 MB document for 150 slider events (the bound for \(Int(r1.durationMs)) ms at one per \(Int(interval)) ms is \(bound)); an un-coalesced drag does 150")
            t.check(r1.rebuilds >= 2, "... but it did follow the drag: the first value at once and the last at the end (\(r1.rebuilds) restyles)")
            t.check(r1.broadcasts == r1.seen.count && r1.broadcasts <= bound, "... \(r1.broadcasts) broadcasts of the preferences")
            t.check(zip(r1.seen, r1.seen.dropFirst()).allSatisfy { $0 <= $1 }, "no stale value after a newer one: the broadcasts carried a non-decreasing line spacing \(r1.seen.prefix(6).map { String(format: "%.2f", Double($0)) }.joined(separator: " ")) ...")
            t.equal(P.lineHeightFactor, 2.0, "the final value is the one the hand stopped at (2.00)")
            t.equal(r1.seen.last, 2.0, "... and the LAST broadcast carried it")
            for (name, h) in [("the 10 MB editor", a), ("the second editor", b)] {
                t.check(h.theme.settings == P.themeSettings, "\(name) ended on the final settings (line spacing \(h.theme.settings.lineHeightFactor.map { String(format: "%.2f", Double($0)) } ?? "nil"))")
            }
            t.equal(c.preview.theme.settings, P.themeSettings, "the Settings preview ended on the final settings")
            t.equal(r1.previewStale, 0, "the preview showed the slider's value after EVERY one of the 150 events (the window itself is not coalesced)")
            t.check(abs(c.spacingSlider.doubleValue - 2.0) < 0.001 && c.spacingValueLabel.stringValue.hasPrefix("2.00"), "the slider and its label show 2.00 ('\(c.spacingValueLabel.stringValue)')")
            assertMatchesFreshLex(t, a, range: visibleRange(a), "10 MB editor, visible part after the drag")
            assertMatchesFreshLex(t, b, range: visibleRange(b), "second editor, visible part after the drag")
            if !loaded { t.check(r1.maxGapMs < 100, "no main-thread stall: the longest gap between two turns of the run loop was \(Int(r1.maxGapMs)) ms (< 100 ms)") }
            else { t.note("machine busy (load \(String(format: "%.1f", PerfLab.loadAverage()))): the stall check (\(Int(r1.maxGapMs)) ms) is reported, not asserted") }

            // ---- 3. the same drag with the windows hidden (the real headless windows are not visible: nobody can see them): they wait, the end catches them up
            P.lineHeightFactor = 1.2
            let r2 = await drag("hidden windows", events: 150, pace: 1000.0 / 120, visible: false)
            t.equal(r2.rebuilds, 1, "hidden windows: the 10 MB editor restyled ONCE for the whole drag (at its end), not \(150) times")
            for (name, h) in [("the 10 MB editor", a), ("the second editor", b)] {
                t.check(h.theme.settings == P.themeSettings && P.lineHeightFactor == 2.0, "hidden windows: \(name) is on the final settings after the drag (\(h.theme.settings.lineHeightFactor.map { String(format: "%.2f", Double($0)) } ?? "nil"))")
            }
            assertMatchesFreshLex(t, a, range: visibleRange(a), "hidden windows: 10 MB editor, visible part after the drag")
            if !loaded { t.check(r2.maxGapMs < 100, "hidden windows: longest gap \(Int(r2.maxGapMs)) ms (< 100 ms)") }

            // ---- 4. the window of a real (headless) editor asked the way the app asks (no override): hidden
            EditorViewController.visibilityOverride = nil
            let before = a.themeRebuildCount
            c.tracking(c.widthSlider, began: true)
            P.lineHeightFactor = 1.5
            t.equal(a.themeRebuildCount, before, "a window that is not visible is not restyled while a drag is in progress (the real `isVisible` of a headless window is \(a.view.window?.isVisible ?? false))")
            c.tracking(c.widthSlider, began: false)
            t.equal(a.themeRebuildCount, before + 1, "... and is brought up to date when the drag ends")

            // ---- 5. holding the stepper: ~30 actions per second for a second
            EditorViewController.visibilityOverride = true
            P.fontSize = 12
            let rebuilds0 = a.themeRebuildCount
            c.tracking(c.sizeStepper, began: true)
            let s0 = SelfTest.nowMs()
            for _ in 0..<30 {
                c.sizeStepper.doubleValue += 1
                send(c.sizeStepper)
                let due = SelfTest.nowMs() + 33
                while SelfTest.nowMs() < due { try? await Task.sleep(nanoseconds: 1_000_000) }
            }
            c.tracking(c.sizeStepper, began: false)
            let stepMs = SelfTest.nowMs() - s0
            t.equal(P.fontSize, 40, "holding the stepper up: the size ends at the top of the range, 40 pt")
            let boundStepper = Int((stepMs / interval).rounded(.up)) + 3
            t.check(a.themeRebuildCount - rebuilds0 <= boundStepper, "holding the stepper: \(a.themeRebuildCount - rebuilds0) restyles for 30 repeats in \(Int(stepMs)) ms (bound \(boundStepper))")
            t.check(a.theme.settings == P.themeSettings && b.theme.settings == P.themeSettings && visibleSize(c) == "40", "... both editors are at 40 pt and the field shows '\(visibleSize(c))'")

            // ---- 5b. a mouse-down on the knob through the slider's own `mouseDown` (40 drags and the mouse-up are queued first). What this shows: the override
            // opens the drag, AppKit's tracking runs and sends the action, the override closes the drag with the final flush. What it cannot show: a headless
            // process has no mouse button really pressed, so AppKit's tracking loop returns at once and leaves the queued events where they are (measured in the
            // classic and in the new look: all 41 still queued afterwards; they are taken out below). Whether the loop BLOCKS for a real drag - which the
            // coalescing relies on - is seen only with a real mouse.
            EditorViewController.visibilityOverride = true
            P.lineHeightFactor = 1.2; c.syncFromPreferences()
            c.present(); c.showScreen(.text)                 // (the Text screen, whatever an earlier scenario left showing)
            if let win = c.window, let content = win.contentView {
                content.layoutSubtreeIfNeeded()
                let slider = c.spacingSlider
                let knob = slider.cell.map { ($0 as! NSSliderCell).knobRect(flipped: slider.isFlipped) } ?? .zero
                let y = knob.midY
                @MainActor func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
                    let p = slider.convert(NSPoint(x: x, y: y), to: nil)
                    return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                }
                let rebuilds = a.themeRebuildCount, broadcasts = EditorPreferences.broadcastCount
                var posted = 0
                let endX = slider.bounds.width - 12
                for i in 1...40 { if let e = event(.leftMouseDragged, x: knob.midX + (endX - knob.midX) * CGFloat(i) / 40) { NSApp.postEvent(e, atStart: false); posted += 1 } }
                if let up = event(.leftMouseUp, x: endX) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown, x: knob.midX) {
                    let t0 = SelfTest.nowMs()
                    slider.mouseDown(with: down)
                    t.check(true, "the slider's mouseDown returned after \(Int(SelfTest.nowMs() - t0)) ms (\(posted) drags posted)")
                }
                var leftInQueue = 0
                while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date.distantPast, inMode: .default, dequeue: true) != nil { leftInQueue += 1 }
                t.note("\(leftInQueue) of the \(posted + 1) queued mouse events were still queued afterwards (headless: no button is really down, the tracking loop does not take them)")
                t.check(c.trackedControl == nil && !EditorPreferences.isAdjusting, "after the mouse-up no drag is left open")
                // (a headless process gives the tracking loop no mouse position of its own, so where the knob ends up is the loop's business, not the test's: what is checked
                // is that `mouseDown` wraps the loop - begin, end, the final flush - and that everything agrees at the end)
                t.note("the real drag left the line spacing at \(P.lineHeightFactor.map { String(format: "%.2f", Double($0)) } ?? "nil") (started at 1.20)")
                t.equal(c.spacingSlider.doubleValue, Double(P.lineHeightFactor ?? 0), "... the slider and the preference agree")
                t.check(a.theme.settings == P.themeSettings && b.theme.settings == P.themeSettings, "... both editors ended on it")
                t.check(a.themeRebuildCount - rebuilds <= 3 && EditorPreferences.broadcastCount - broadcasts <= 3, "... with \(a.themeRebuildCount - rebuilds) restyles and \(EditorPreferences.broadcastCount - broadcasts) broadcasts for \(posted) mouse events that arrived at once")
            }

            // ---- 6. outside a drag nothing is coalesced: every change is broadcast at once, once (what every test and the menu rely on)
            EditorViewController.visibilityOverride = nil
            P.lineHeightFactor = 1.4
            let n = NoteCounter()
            P.lineHeightFactor = 1.5; P.lineHeightFactor = 1.6; P.lineHeightFactor = 1.7
            t.equal(n.count, 3, "outside a drag every change is broadcast at once (3 changes, \(n.count) broadcasts)")
            t.check(!EditorPreferences.isAdjusting && c.trackedControl == nil, "no drag is left open")
        }
    }
}
#endif
