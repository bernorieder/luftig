// SettingsWindowController.swift - luftig > Settings… (⌘,)
//
// ONE window (a singleton: opening it again raises it), plain AppKit (NSGridView + Auto Layout, no nib, no SwiftUI). Every control applies at once to
// every open editor window and is saved in UserDefaults (EditorPreferences); there are no OK / Apply buttons. The window never holds state of its
// own: it reads the preferences, shows them, and writes them back when a control is used; it follows changes made elsewhere (⌘+ ⌘- ⌘0, the
// View menu) because it observes `EditorPreferences.didChange` like an editor does.
//
//   [ live preview: the real Theme + lexer + decorations, read-only ]   <- on every screen
//   ( General | Text | Layout )                        <- three screens, a segmented control under the preview; the chosen one is remembered
//   General:
//   Files           [ ] Open files in tabs
//   File changes    [Reload automatically v]
//                   Changes made by other programs appear at once (merged with yours when both edited).
//   Editing         [x] Continue lists on Return
//                   Tab and Shift-Tab nest and un-nest list items.
//   Tables          [x] Draw tables as grids
//                   While the caret is elsewhere. Click into a table to edit its Markdown.
//   Images          [Images on this Mac  v]                            (never / this Mac / this Mac and the web)
//                   (a note on what the choice means: the web one says luftig then connects to the sites)
//   Text:
//   Color scheme   [swatch luftig (follows system appearance)  v]
//   Text font       [System (SF Pro)  v]  [ 16 ] (stepper) pt
//   Code font       [System Mono (SF Mono)  v]  [ 14.5 ] (stepper) pt  (a share of the text size: ⌘+ ⌘- scale both)
//   Line spacing    ----o------   1.42 ×  (23 pt)
//                   [x] Automatic   (a note here when the fonts raised the line box)
//   Column width    [x] Limit line length (centered column)
//                   ----o------   760 pt
//                   about 85 characters per line
//   Layout:
//   Show            [x] Outline  [x] Syntax bar                       (the View menu's switches, the other way to reach them)
//                   [x] Word count  [ ] Reading time                  (both in one row at the top right)
//   Padding         ----o------   20 pt                                 (ONE number for every gap: the window's frame, between the panels, around the text)
//   Panes font      [Same as text font  v]
//   Panes size      [12 pt v]
//   Panes opacity   ----o------   100 %
//   Outline         [x] Wrap long headings
//   Outline spacing ----o------   1.40 ×                                (the row height as a multiple of the outline font's height: not padding)
//                                                               [Restore Defaults]
//
// The window's height is that of the taller screen, computed once; switching screens hides one container and shows the other, nothing moves.
// The preview stays on both screens: a pane setting has no preview of its own, and the text one keeps the window familiar.
//
// LAYOUT IS FIXED. The controls grid has fixed column widths (labels: the widest label; controls: slider + value label) and is centred in the window
// by plain constraints; every label that shows a value has a fixed width (monospaced digits, truncating, never compressing the grid); the note under
// "Line spacing" has a place of its own next to the "Automatic" box (it is empty most of the time). Nothing a value, a note or a font name says can move a
// control or resize the window: the window's height is the content's, computed once, and its width is the user's (560 ... 2000 pt).
// (It used to be an NSStackView of a grid that was only pinned between two margins: the grid then stretched to the window's width, NSGridView handed the
// spare width to its first or its second column depending on whether the note row was shown, and the whole grid jumped 180 pt to the right when the
// line-spacing slider went below the point where the note appears: `fix-settings-layout`.)

import AppKit
import UniformTypeIdentifiers

/// The window's content: draws the standard window background itself, so a snapshot of the content view (the self-test renders one) is the whole picture.
private final class SettingsContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A slider that says when a drag begins and ends: `mouseDown` returns when the mouse is released (the cell tracks the drag in its own loop and sends the
/// action on every move). While the drag lasts the Settings window lets the editors follow at a bounded rate (`EditorPreferences.beginAdjusting`).
final class SettingsSlider: NSSlider {
    var onTracking: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onTracking?(true)
        defer { onTracking?(false) }
        super.mouseDown(with: event)
    }
}

/// The same for the stepper: holding an arrow repeats the action while the mouse is down.
final class SettingsStepper: NSStepper {
    var onTracking: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onTracking?(true)
        defer { onTracking?(false) }
        super.mouseDown(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation, NSTextFieldDelegate {

    // MARK: fixed geometry (points)
    static let margin: CGFloat = 20
    static let previewHeight: CGFloat = 340
    static let popupWidth: CGFloat = 300
    /// A font popup and its size (field, stepper, "pt") fill the control column.
    static let sizeFieldWidth: CGFloat = 52
    static let sizeGap: CGFloat = 8
    static var fontPopupWidth: CGFloat {
        let pt = ceil(("pt" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 4
        return floor(controlColumnWidth - sizeGap - sizeFieldWidth - 4 - ceil(NSStepper().fittingSize.width) - 4 - pt)
    }
    static let sliderWidth: CGFloat = 250
    static let sliderGap: CGFloat = 10
    static let colorWellWidth: CGFloat = 44
    static let minContentWidth: CGFloat = 560
    static let defaultContentWidth: CGFloat = 700
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Wide enough for the longest thing a value label can say ("8.88 ×  (888 pt)", "window width"): digits are the same width in this font.
    static let valueLabelWidth: CGFloat = {
        let widest = ["8.88 ×  (888 pt)", "1400 pt", "window width"].map { ($0 as NSString).size(withAttributes: [.font: valueFont]).width }.max() ?? 100
        return ceil(widest) + 4
    }()
    /// The column of controls: the slider, a gap and its value label. Everything in it is at most this wide.
    static var controlColumnWidth: CGFloat { sliderWidth + sliderGap + valueLabelWidth }

    static let title = "Settings"
    static let frameAutosaveName = "LuftigSettingsWindow"
    static let systemTextFontTitle = "System (SF Pro)"
    static let systemCodeFontTitle = "System Mono (SF Mono)"

    /// The one Settings window. Created on first use (building it takes a few milliseconds and the lists of installed fonts).
    static let shared = SettingsWindowController()

    /// luftig > Settings…: open the window, or raise it when it is already open.
    static func present() { shared.present() }

    #if LUFTIG_SELFTEST
    /// The self-test never puts a window on the screen: with this set, `present()` builds the window and counts the call, nothing more.
    nonisolated(unsafe) static var headless = false
    private(set) var presentCount = 0
    #endif

    // MARK: controls (internal: the self-test drives them with sendAction / performClick)

    let preview = SettingsPreview()
    let schemePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let bodyFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let codeFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeField = NSTextField(string: "")
    let sizeStepper = SettingsStepper()
    let codeSizeField = NSTextField(string: "")
    let codeSizeStepper = SettingsStepper()
    let spacingSlider = SettingsSlider(value: 1.4, minValue: Double(EditorPreferences.lineHeightFactorRange.lowerBound), maxValue: Double(EditorPreferences.lineHeightFactorRange.upperBound), target: nil, action: nil)
    let spacingValueLabel = NSTextField(labelWithString: "")
    let spacingAutomaticCheckbox = NSButton(checkboxWithTitle: "Automatic", target: nil, action: nil)
    /// Next to the "Automatic" box; empty unless the chosen fonts raised the line box. Fixed size: it never moves anything.
    let spacingNoteLabel = NSTextField(labelWithString: "")
    let limitCheckbox = NSButton(checkboxWithTitle: "Limit line length (centered column)", target: nil, action: nil)
    let widthSlider = SettingsSlider(value: 760, minValue: Double(EditorPreferences.columnWidthRange.lowerBound), maxValue: Double(EditorPreferences.columnWidthRange.upperBound), target: nil, action: nil)
    let widthValueLabel = NSTextField(labelWithString: "")
    let widthNoteLabel = NSTextField(labelWithString: "")
    // the panes (outline, word count, syntax bar): font, size, opacity
    let paneFontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let paneSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let paneOpacitySlider = SettingsSlider(value: 1, minValue: Double(EditorPreferences.paneOpacityRange.lowerBound), maxValue: Double(EditorPreferences.paneOpacityRange.upperBound), target: nil, action: nil)
    let paneOpacityValueLabel = NSTextField(labelWithString: "")
    static let paneSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 15, 16, 18, 20]
    static let paneFontDefaultTitle = "Same as text font"
    let outlineWrapCheckbox = NSButton(checkboxWithTitle: "Wrap long headings", target: nil, action: nil)
    let outlineSpacingSlider = SettingsSlider(value: Double(EditorPreferences.defaultOutlineLineHeight), minValue: Double(EditorPreferences.outlineLineHeightRange.lowerBound), maxValue: Double(EditorPreferences.outlineLineHeightRange.upperBound), target: nil, action: nil)
    let outlineSpacingValueLabel = NSTextField(labelWithString: "")
    let restoreButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
    // the three panes (the View menu's switches too) and the padding factor
    let showOutlineCheckbox = NSButton(checkboxWithTitle: "Outline", target: nil, action: nil)
    let showWordCountCheckbox = NSButton(checkboxWithTitle: "Word count", target: nil, action: nil)
    let showSyntaxBarCheckbox = NSButton(checkboxWithTitle: "Syntax bar", target: nil, action: nil)
    let showReadingTimeCheckbox = NSButton(checkboxWithTitle: "Reading time", target: nil, action: nil)
    let paddingSlider = SettingsSlider(value: Double(EditorPreferences.defaultPadding), minValue: Double(EditorPreferences.paddingRange.lowerBound), maxValue: Double(EditorPreferences.paddingRange.upperBound), target: nil, action: nil)
    let paddingValueLabel = NSTextField(labelWithString: "")
    let paddingNoteLabel = NSTextField(labelWithString: "")
    // the General screen
    let openInTabsCheckbox = NSButton(checkboxWithTitle: "Open files in tabs", target: nil, action: nil)
    let continueListsCheckbox = NSButton(checkboxWithTitle: "Continue lists on Return", target: nil, action: nil)
    let continueListsNoteLabel = NSTextField(labelWithString: "")
    let reloadPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let reloadNoteLabel = NSTextField(labelWithString: "")
    let tablesCheckbox = NSButton(checkboxWithTitle: "Draw tables as grids", target: nil, action: nil)
    let tablesNoteLabel = NSTextField(labelWithString: "")
    let imagesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let imagesNoteLabel = NSTextField(labelWithString: "")
    // the Colors screen: the scheme popup and a custom scheme from seven colours (ColorSchemesCustom.swift), edited as a draft the editors show live
    let colorWells: [NSColorWell] = CustomScheme.Role.allCases.map { _ in NSColorWell(style: .minimal) }
    let saveSchemeButton = NSButton(title: "Save", target: nil, action: nil)
    let saveAsNewSchemeButton = NSButton(title: "Save as New…", target: nil, action: nil)
    let revertSchemeButton = NSButton(title: "Revert", target: nil, action: nil)
    let deleteSchemeButton = NSButton(title: "Delete…", target: nil, action: nil)
    /// The draft: what the wells show. Loaded from the chosen scheme (`draftLoadedFrom`); `draftSource` is the custom scheme Save overwrites (nil: not a custom
    /// scheme, Save is disabled, Save as New makes one); `draftDirty` once a colour was changed (the editors then show the draft, `ColorSchemes.draft`).
    private(set) var draft = CustomScheme.luftigLight
    private(set) var draftLoadedFrom: String?
    private(set) var draftSource: String?
    private(set) var draftDirty = false
    /// The screens: General, Text, Layout and Colors; the segmented control under the preview switches, the choice is remembered.
    enum Screen: Int, CaseIterable { case general = 0, text = 1, layout = 2, colors = 3
        var title: String { self == .general ? "General" : self == .text ? "Text" : self == .layout ? "Layout" : "Colors" }
    }
    static let screenKey = "LuftigSettingsScreen"
    let screenControl = NSSegmentedControl(labels: Screen.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    let generalScreen = NSView()
    let textScreen = NSView()
    let layoutScreen = NSView()
    let colorsScreen = NSView()
    private(set) var screen: Screen = .general

    /// The families the two font popups offer (the code font: monospaced ones only).
    private(set) var textFamilies: [String] = []
    private(set) var codeFamilies: [String] = []
    private var fontTitlesApplied = Set<ObjectIdentifier>()
    private var observer: NSObjectProtocol?
    private var syncing = false
    /// The size the size field was last made to show (what a change of the preference is compared with while the field is being edited).
    private var shownSize: CGFloat = 0
    private var shownCodeSize: CGFloat = 0
    /// The slider or stepper whose drag is in progress (nil: none). Its own value is the user's hand, not the preference, until the drag ends.
    private(set) var trackedControl: NSControl?

    // MARK: lifecycle

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = SettingsWindowController.title
        window.isReleasedWhenClosed = false                    // closing hides it; the next ⌘, shows the same window again
        window.tabbingMode = .disallowed                       // never a tab of a document window
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        textFamilies = FontFactory.installedFamilies()
        codeFamilies = FontFactory.monospacedFamilies(among: textFamilies)
        buildContent()
        observer = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { [weak self] _ in self?.syncFromPreferences() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    func present() {
        #if LUFTIG_SELFTEST
        presentCount += 1
        #endif
        // scheme files may have been added or removed by hand since the window was built (the scheme in use among them: applied afresh, or the default)
        ColorSchemes.reloadImported()
        populateSchemePopup()
        EditorPreferences.colorSchemesReloaded()
        syncFromPreferences()
        #if LUFTIG_SELFTEST
        if SettingsWindowController.headless { _ = window; return }
        #endif
        showWindow(nil)
    }

    // MARK: building the window

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func secondary(_ field: NSTextField) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
    }

    private func buildContent() {
        guard let window else { return }
        typealias W = SettingsWindowController
        // -- controls
        for (popup, action, name) in [(schemePopup, #selector(schemeChanged(_:)), "Color scheme"), (bodyFontPopup, #selector(textFontChanged(_:)), "Text font"), (codeFontPopup, #selector(codeFontChanged(_:)), "Code font")] {
            popup.target = self; popup.action = action
            popup.setAccessibilityLabel(name)
            popup.widthAnchor.constraint(equalToConstant: popup === schemePopup ? W.popupWidth : W.fontPopupWidth).isActive = true
            popup.lineBreakMode = .byTruncatingMiddle                                  // a long family name never widens the popup (nor the grid)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        populateSchemePopup()
        populateFontPopup(bodyFontPopup, defaultTitle: SettingsWindowController.systemTextFontTitle, families: textFamilies)
        populateFontPopup(codeFontPopup, defaultTitle: SettingsWindowController.systemCodeFontTitle, families: codeFamilies)
        bodyFontPopup.menu?.delegate = self
        codeFontPopup.menu?.delegate = self

        // The size field accepts any number the formatter can read (fractions to 0.1; no minimum and maximum here: a number outside 9 ... 40 is not an error
        // the field refuses with a beep and keeps the keyboard focus for, it is clamped by `EditorPreferences.fontSize` and the field shows what was used).
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        for (field, stepper, action, stepAction, name) in [(sizeField, sizeStepper, #selector(sizeFieldChanged(_:)), #selector(sizeStepperChanged(_:)), "Font size"),
                                                           (codeSizeField, codeSizeStepper, #selector(codeSizeFieldChanged(_:)), #selector(codeSizeStepperChanged(_:)), "Code font size")] {
            field.formatter = formatter
            field.alignment = .right
            field.delegate = self
            field.target = self; field.action = action
            field.widthAnchor.constraint(equalToConstant: W.sizeFieldWidth).isActive = true
            field.setAccessibilityLabel(name)
            stepper.valueWraps = false
            stepper.target = self; stepper.action = stepAction
            stepper.onTracking = { [weak self, weak stepper] began in if let stepper { self?.tracking(stepper, began: began) } }
            stepper.setAccessibilityLabel(name + " stepper")
        }
        sizeStepper.minValue = Double(EditorPreferences.fontSizeRange.lowerBound)
        sizeStepper.maxValue = Double(EditorPreferences.fontSizeRange.upperBound)
        sizeStepper.increment = 1
        codeSizeStepper.increment = 0.5                                                // (its range follows the text size: syncFromPreferences)

        spacingSlider.target = self; spacingSlider.action = #selector(spacingSliderChanged(_:))
        spacingSlider.isContinuous = true
        spacingSlider.setAccessibilityLabel("Line spacing")
        spacingSlider.widthAnchor.constraint(equalToConstant: W.sliderWidth).isActive = true
        spacingSlider.onTracking = { [weak self, weak spacingSlider] began in if let spacingSlider { self?.tracking(spacingSlider, began: began) } }
        spacingAutomaticCheckbox.target = self; spacingAutomaticCheckbox.action = #selector(spacingAutomaticChanged(_:))
        fixedLabel(spacingValueLabel, width: W.valueLabelWidth, font: W.valueFont)

        let checkboxWidth = ceil(spacingAutomaticCheckbox.intrinsicContentSize.width)
        secondary(spacingNoteLabel)
        fixedLabel(spacingNoteLabel, width: W.controlColumnWidth - checkboxWidth - 12, font: spacingNoteLabel.font)

        limitCheckbox.target = self; limitCheckbox.action = #selector(limitChanged(_:))
        widthSlider.target = self; widthSlider.action = #selector(widthSliderChanged(_:))
        widthSlider.isContinuous = true
        widthSlider.setAccessibilityLabel("Column width")
        widthSlider.widthAnchor.constraint(equalToConstant: W.sliderWidth).isActive = true
        widthSlider.onTracking = { [weak self, weak widthSlider] began in if let widthSlider { self?.tracking(widthSlider, began: began) } }
        fixedLabel(widthValueLabel, width: W.valueLabelWidth, font: W.valueFont)
        secondary(widthNoteLabel)
        fixedLabel(widthNoteLabel, width: W.controlColumnWidth, font: widthNoteLabel.font)

        // -- the panes
        paneFontPopup.target = self; paneFontPopup.action = #selector(paneFontChanged(_:))
        paneFontPopup.setAccessibilityLabel("Panes font")
        paneFontPopup.widthAnchor.constraint(equalToConstant: W.popupWidth).isActive = true
        paneFontPopup.lineBreakMode = .byTruncatingMiddle
        paneFontPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        populateFontPopup(paneFontPopup, defaultTitle: W.paneFontDefaultTitle, families: textFamilies)
        paneFontPopup.menu?.delegate = self
        paneSizePopup.target = self; paneSizePopup.action = #selector(paneSizeChanged(_:))
        paneSizePopup.setAccessibilityLabel("Panes size")
        for s in W.paneSizes {
            let item = NSMenuItem(title: "\(Int(s)) pt", action: nil, keyEquivalent: "")
            item.representedObject = Double(s)
            paneSizePopup.menu?.addItem(item)
        }
        paneSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        paneOpacitySlider.target = self; paneOpacitySlider.action = #selector(paneOpacityChanged(_:))
        paneOpacitySlider.isContinuous = true
        paneOpacitySlider.setAccessibilityLabel("Panes opacity")
        paneOpacitySlider.widthAnchor.constraint(equalToConstant: W.sliderWidth).isActive = true
        paneOpacitySlider.onTracking = { [weak self, weak paneOpacitySlider] began in if let paneOpacitySlider { self?.tracking(paneOpacitySlider, began: began) } }
        fixedLabel(paneOpacityValueLabel, width: W.valueLabelWidth, font: W.valueFont)
        outlineSpacingSlider.target = self; outlineSpacingSlider.action = #selector(outlineSpacingChanged(_:))
        outlineSpacingSlider.isContinuous = true
        outlineSpacingSlider.setAccessibilityLabel("Outline spacing")
        outlineSpacingSlider.widthAnchor.constraint(equalToConstant: W.sliderWidth).isActive = true
        outlineSpacingSlider.onTracking = { [weak self, weak outlineSpacingSlider] began in if let outlineSpacingSlider { self?.tracking(outlineSpacingSlider, began: began) } }
        fixedLabel(outlineSpacingValueLabel, width: W.valueLabelWidth, font: W.valueFont)
        outlineWrapCheckbox.target = self; outlineWrapCheckbox.action = #selector(outlineWrapChanged(_:))
        outlineWrapCheckbox.setAccessibilityLabel("Wrap long headings in the outline")

        for (box, action, name) in [(showOutlineCheckbox, #selector(showOutlineChanged(_:)), "Show the outline"), (showWordCountCheckbox, #selector(showWordCountChanged(_:)), "Show the word count"), (showSyntaxBarCheckbox, #selector(showSyntaxBarChanged(_:)), "Show the syntax bar"), (showReadingTimeCheckbox, #selector(showReadingTimeChanged(_:)), "Show the reading time")] {
            box.target = self; box.action = action; box.setAccessibilityLabel(name)
        }
        paddingSlider.target = self; paddingSlider.action = #selector(paddingSliderChanged(_:))
        paddingSlider.isContinuous = true
        paddingSlider.setAccessibilityLabel("Padding")
        paddingSlider.widthAnchor.constraint(equalToConstant: W.sliderWidth).isActive = true
        paddingSlider.onTracking = { [weak self, weak paddingSlider] began in if let paddingSlider { self?.tracking(paddingSlider, began: began) } }
        fixedLabel(paddingValueLabel, width: W.valueLabelWidth, font: W.valueFont)
        secondary(paddingNoteLabel)
        fixedLabel(paddingNoteLabel, width: W.controlColumnWidth, font: paddingNoteLabel.font)
        paddingNoteLabel.stringValue = "Every gap: the window's frame, between the panels, around the text."

        openInTabsCheckbox.target = self; openInTabsCheckbox.action = #selector(openInTabsChanged(_:))
        openInTabsCheckbox.setAccessibilityLabel("Open files in tabs")
        continueListsCheckbox.target = self; continueListsCheckbox.action = #selector(continueListsChanged(_:))
        continueListsCheckbox.setAccessibilityLabel("Continue lists on Return")
        secondary(continueListsNoteLabel)
        fixedLabel(continueListsNoteLabel, width: W.controlColumnWidth, font: continueListsNoteLabel.font)
        continueListsNoteLabel.stringValue = "Tab and Shift-Tab nest and un-nest list items."
        reloadPopup.target = self; reloadPopup.action = #selector(reloadBehaviorChanged(_:))
        reloadPopup.setAccessibilityLabel("When the file changes on disk")
        for b in EditorPreferences.ReloadBehavior.allCases {
            let item = NSMenuItem(title: b.title, action: nil, keyEquivalent: "")
            item.representedObject = b.rawValue
            reloadPopup.menu?.addItem(item)
        }
        reloadPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        secondary(reloadNoteLabel)
        wrappingLabel(reloadNoteLabel, width: W.controlColumnWidth, lines: 2)             // (the longest of its three texts needs two lines)
        tablesCheckbox.target = self; tablesCheckbox.action = #selector(tablesChanged(_:))
        tablesCheckbox.setAccessibilityLabel("Draw tables as grids")
        secondary(tablesNoteLabel)
        wrappingLabel(tablesNoteLabel, width: W.controlColumnWidth, lines: 1)
        tablesNoteLabel.stringValue = "While the caret is elsewhere. Click into a table to edit its Markdown."
        imagesPopup.target = self; imagesPopup.action = #selector(imagesChanged(_:))
        imagesPopup.setAccessibilityLabel("Show images")
        for m in EditorPreferences.ImageMode.allCases {
            let item = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            item.representedObject = m.rawValue
            imagesPopup.menu?.addItem(item)
        }
        imagesPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        secondary(imagesNoteLabel)
        wrappingLabel(imagesNoteLabel, width: W.controlColumnWidth, lines: 3)             // (the longest of its three texts needs three lines)

        // -- the Colors screen
        let noteLabels: [NSTextField] = CustomScheme.Role.allCases.map { NSTextField(labelWithString: $0.note) }
        var colorRows: [NSStackView] = []
        for (i, well) in colorWells.enumerated() {
            let role = CustomScheme.Role.allCases[i]
            well.target = self; well.action = #selector(colorWellChanged(_:))
            well.isContinuous = true
            well.tag = i
            well.setAccessibilityLabel("\(role.title) colour")
            secondary(noteLabels[i])
            fixedLabel(noteLabels[i], width: W.controlColumnWidth - W.colorWellWidth - 10, font: noteLabels[i].font)
            well.widthAnchor.constraint(equalToConstant: W.colorWellWidth).isActive = true
            let row = NSStackView(views: [well, noteLabels[i]])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
            colorRows.append(row)
        }
        for (button, action, name) in [(saveSchemeButton, #selector(saveScheme(_:)), "Save the scheme"), (saveAsNewSchemeButton, #selector(saveSchemeAsNew(_:)), "Save the scheme as a new one"),
                                       (revertSchemeButton, #selector(revertScheme(_:)), "Revert the scheme"), (deleteSchemeButton, #selector(deleteScheme(_:)), "Delete the scheme")] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.setAccessibilityLabel(name)
        }
        let schemeButtonsRow = NSStackView(views: [saveSchemeButton, saveAsNewSchemeButton, revertSchemeButton, deleteSchemeButton])
        schemeButtonsRow.orientation = .horizontal; schemeButtonsRow.spacing = 6

        screenControl.target = self; screenControl.action = #selector(screenChanged(_:))
        screenControl.segmentStyle = .automatic
        screenControl.setAccessibilityLabel("Settings screen")
        screenControl.translatesAutoresizingMaskIntoConstraints = false
        for (i, sc) in Screen.allCases.enumerated() { screenControl.setWidth(90, forSegment: i); screenControl.setLabel(sc.title, forSegment: i) }

        restoreButton.target = self; restoreButton.action = #selector(restoreDefaults(_:))
        restoreButton.bezelStyle = .rounded
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        // -- rows
        // a font and its size, in one row
        func fontRow(_ popup: NSPopUpButton, _ field: NSTextField, _ stepper: NSStepper) -> NSStackView {
            let size = NSStackView(views: [field, stepper, NSTextField(labelWithString: "pt")])
            size.orientation = .horizontal; size.spacing = 4
            let row = NSStackView(views: [popup, size])
            row.orientation = .horizontal; row.spacing = W.sizeGap
            return row
        }
        let textFontRow = fontRow(bodyFontPopup, sizeField, sizeStepper)
        let codeFontRow = fontRow(codeFontPopup, codeSizeField, codeSizeStepper)
        let spacingSliderRow = NSStackView(views: [spacingSlider, spacingValueLabel])
        spacingSliderRow.orientation = .horizontal; spacingSliderRow.spacing = W.sliderGap
        let automaticRow = NSStackView(views: [spacingAutomaticCheckbox, spacingNoteLabel])
        automaticRow.orientation = .horizontal; automaticRow.alignment = .firstBaseline; automaticRow.spacing = 12
        let spacingRow = NSStackView(views: [spacingSliderRow, automaticRow])
        spacingRow.orientation = .vertical; spacingRow.alignment = .leading; spacingRow.spacing = 6
        let widthRow = NSStackView(views: [widthSlider, widthValueLabel])
        widthRow.orientation = .horizontal; widthRow.spacing = W.sliderGap
        let widthColumn = NSStackView(views: [limitCheckbox, widthRow, widthNoteLabel])
        widthColumn.orientation = .vertical; widthColumn.alignment = .leading; widthColumn.spacing = 6

        let opacityRow = NSStackView(views: [paneOpacitySlider, paneOpacityValueLabel])
        opacityRow.orientation = .horizontal; opacityRow.spacing = W.sliderGap
        let outlineSpacingRow = NSStackView(views: [outlineSpacingSlider, outlineSpacingValueLabel])
        outlineSpacingRow.orientation = .horizontal; outlineSpacingRow.spacing = W.sliderGap
        // the four switches, two by two (one row would be wider than the control column): outline and bar, then the word count row's two
        let showRow1 = NSStackView(views: [showOutlineCheckbox, showSyntaxBarCheckbox])
        showRow1.orientation = .horizontal; showRow1.spacing = 14
        let showRow2 = NSStackView(views: [showWordCountCheckbox, showReadingTimeCheckbox])
        showRow2.orientation = .horizontal; showRow2.spacing = 14
        let showRow = NSStackView(views: [showRow1, showRow2])
        showRow.orientation = .vertical; showRow.alignment = .leading; showRow.spacing = 6
        let paddingSliderRow = NSStackView(views: [paddingSlider, paddingValueLabel])
        paddingSliderRow.orientation = .horizontal; paddingSliderRow.spacing = W.sliderGap
        let paddingColumn = NSStackView(views: [paddingSliderRow, paddingNoteLabel])
        paddingColumn.orientation = .vertical; paddingColumn.alignment = .leading; paddingColumn.spacing = 6

        let continueListsColumn = NSStackView(views: [continueListsCheckbox, continueListsNoteLabel])
        continueListsColumn.orientation = .vertical; continueListsColumn.alignment = .leading; continueListsColumn.spacing = 6
        let reloadColumn = NSStackView(views: [reloadPopup, reloadNoteLabel])
        reloadColumn.orientation = .vertical; reloadColumn.alignment = .leading; reloadColumn.spacing = 6
        let tablesColumn = NSStackView(views: [tablesCheckbox, tablesNoteLabel])
        tablesColumn.orientation = .vertical; tablesColumn.alignment = .leading; tablesColumn.spacing = 6
        let imagesColumn = NSStackView(views: [imagesPopup, imagesNoteLabel])
        imagesColumn.orientation = .vertical; imagesColumn.alignment = .leading; imagesColumn.spacing = 6

        // the grids share the label column width, so the controls of every screen start at the same x
        let generalLabels = ["Files:", "File changes:", "Editing:", "Tables:", "Images:"].map { label($0) }
        let textLabels = ["Text font:", "Code font:", "Line spacing:", "Column width:"].map { label($0) }
        let panesLabels = ["Show:", "Padding:", "Panes font:", "Panes size:", "Panes opacity:", "Outline:", "Outline spacing:"].map { label($0) }
        let colorsLabels = (["Color scheme:"] + CustomScheme.Role.allCases.map { $0.title + ":" } + [""]).map { label($0) }
        let labelWidth = ceil((generalLabels + textLabels + panesLabels + colorsLabels).map { $0.intrinsicContentSize.width }.max() ?? 90)
        func makeGrid(_ rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = 12
            grid.columnSpacing = 10
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
            grid.column(at: 0).width = labelWidth                                                            // FIXED widths: the grid never stretches to the window,
            grid.column(at: 1).width = W.controlColumnWidth                                                  // so no column can be handed spare width
            grid.rowAlignment = .firstBaseline
            return grid
        }
        let generalGrid = makeGrid([
            [generalLabels[0], openInTabsCheckbox],
            [generalLabels[1], reloadColumn],
            [generalLabels[2], continueListsColumn],
            [generalLabels[3], tablesColumn],
            [generalLabels[4], imagesColumn],
        ])
        let grid = makeGrid([
            [textLabels[0], textFontRow],
            [textLabels[1], codeFontRow],
            [textLabels[2], spacingRow],
            [textLabels[3], widthColumn],
        ])
        let panesGrid = makeGrid([
            [panesLabels[0], showRow],
            [panesLabels[1], paddingColumn],
            [panesLabels[2], paneFontPopup],
            [panesLabels[3], paneSizePopup],
            [panesLabels[4], opacityRow],
            [panesLabels[5], outlineWrapCheckbox],
            [panesLabels[6], outlineSpacingRow],
        ])
        let colorsGrid = makeGrid([[colorsLabels[0], schemePopup]] + colorRows.enumerated().map { [colorsLabels[$0.offset + 1], $0.element] }
                                  + [[colorsLabels[8], schemeButtonsRow]])
        colorsGrid.rowSpacing = 8                                                                              // ten rows: tighter than the other screens
        colorsGrid.rowAlignment = .none
        for i in 0..<colorsGrid.numberOfRows { colorsGrid.row(at: i).yPlacement = .center }

        let previewView = preview.scrollView
        previewView.translatesAutoresizingMaskIntoConstraints = false

        let content = SettingsContentView(frame: NSRect(x: 0, y: 0, width: W.defaultContentWidth, height: 700))
        for screenView in [generalScreen, textScreen, layoutScreen, colorsScreen] { screenView.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(screenView) }
        content.addSubview(previewView)
        content.addSubview(screenControl)
        generalScreen.addSubview(generalGrid)
        textScreen.addSubview(grid)
        layoutScreen.addSubview(panesGrid)
        colorsScreen.addSubview(colorsGrid)
        content.addSubview(restoreButton)
        let m = W.margin
        NSLayoutConstraint.activate([
            // the preview on top, on both screens; the switch under it
            previewView.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            previewView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            previewView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            previewView.heightAnchor.constraint(equalToConstant: W.previewHeight),
            screenControl.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 14),
            screenControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            // both screens fill the same place under the switch; the hidden one keeps its layout (so nothing moves when it comes back)
            textScreen.topAnchor.constraint(equalTo: screenControl.bottomAnchor, constant: 14),
            textScreen.leadingAnchor.constraint(equalTo: content.leadingAnchor), textScreen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            layoutScreen.topAnchor.constraint(equalTo: screenControl.bottomAnchor, constant: 14),
            layoutScreen.leadingAnchor.constraint(equalTo: content.leadingAnchor), layoutScreen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            generalScreen.topAnchor.constraint(equalTo: screenControl.bottomAnchor, constant: 14),
            generalScreen.leadingAnchor.constraint(equalTo: content.leadingAnchor), generalScreen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            colorsScreen.topAnchor.constraint(equalTo: screenControl.bottomAnchor, constant: 14),
            colorsScreen.leadingAnchor.constraint(equalTo: content.leadingAnchor), colorsScreen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            colorsGrid.topAnchor.constraint(equalTo: colorsScreen.topAnchor),
            colorsGrid.centerXAnchor.constraint(equalTo: colorsScreen.centerXAnchor),
            colorsGrid.leadingAnchor.constraint(greaterThanOrEqualTo: colorsScreen.leadingAnchor, constant: m),
            colorsGrid.trailingAnchor.constraint(lessThanOrEqualTo: colorsScreen.trailingAnchor, constant: -m),
            colorsGrid.bottomAnchor.constraint(equalTo: colorsScreen.bottomAnchor),
            generalGrid.topAnchor.constraint(equalTo: generalScreen.topAnchor),
            generalGrid.centerXAnchor.constraint(equalTo: generalScreen.centerXAnchor),
            generalGrid.leadingAnchor.constraint(greaterThanOrEqualTo: generalScreen.leadingAnchor, constant: m),
            generalGrid.trailingAnchor.constraint(lessThanOrEqualTo: generalScreen.trailingAnchor, constant: -m),
            generalGrid.bottomAnchor.constraint(equalTo: generalScreen.bottomAnchor),
            // Text: its grid
            grid.topAnchor.constraint(equalTo: textScreen.topAnchor),
            grid.centerXAnchor.constraint(equalTo: textScreen.centerXAnchor),                       // centred, at its own fixed width: nothing is left to stretch or to guess
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: textScreen.leadingAnchor, constant: m),    // (the minimum window width keeps these two satisfied)
            grid.trailingAnchor.constraint(lessThanOrEqualTo: textScreen.trailingAnchor, constant: -m),
            grid.bottomAnchor.constraint(equalTo: textScreen.bottomAnchor),
            // Panes: its grid, at the top of the screen
            panesGrid.topAnchor.constraint(equalTo: layoutScreen.topAnchor),
            panesGrid.centerXAnchor.constraint(equalTo: layoutScreen.centerXAnchor),
            panesGrid.leadingAnchor.constraint(greaterThanOrEqualTo: layoutScreen.leadingAnchor, constant: m),
            panesGrid.trailingAnchor.constraint(lessThanOrEqualTo: layoutScreen.trailingAnchor, constant: -m),
            panesGrid.bottomAnchor.constraint(equalTo: layoutScreen.bottomAnchor),
            // the button under the taller screen, on both screens
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: textScreen.bottomAnchor, constant: 18),
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: generalScreen.bottomAnchor, constant: 18),
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: layoutScreen.bottomAnchor, constant: 18),
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: colorsScreen.bottomAnchor, constant: 18),
            restoreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        window.contentView = content
        showScreen(Screen(rawValue: UserDefaults.standard.integer(forKey: W.screenKey)) ?? .general)

        // -- size: the height is the content's (computed ONCE: nothing in the window changes size), the width is the user's from the minimum up; the position is remembered
        syncFromPreferences()
        content.layoutSubtreeIfNeeded()
        // (the button's FRAME is taller than the rectangle the constraints place - its alignment rect - by the room of its shadow and focus ring)
        let restoreHeight = restoreButton.alignmentRect(forFrame: NSRect(origin: .zero, size: restoreButton.fittingSize)).height
        let switchHeight = ceil(screenControl.fittingSize.height)
        let tallest = max(grid.fittingSize.height, panesGrid.fittingSize.height, generalGrid.fittingSize.height, colorsGrid.fittingSize.height)
        let height = ceil(m + W.previewHeight + 14 + switchHeight + 14 + tallest + 18 + restoreHeight + 18)
        window.setContentSize(NSSize(width: W.defaultContentWidth, height: height))
        window.contentMinSize = NSSize(width: W.minContentWidth, height: height)
        window.contentMaxSize = NSSize(width: 2000, height: height)
        let hadFrame = UserDefaults.standard.object(forKey: "NSWindow Frame " + SettingsWindowController.frameAutosaveName) != nil
        window.setFrameAutosaveName(SettingsWindowController.frameAutosaveName)
        if !hadFrame { window.center() }
    }

    /// Show one screen (the segmented control follows; the choice is remembered).
    func showScreen(_ sc: Screen) {
        screen = sc
        generalScreen.isHidden = sc != .general
        textScreen.isHidden = sc != .text
        layoutScreen.isHidden = sc != .layout
        colorsScreen.isHidden = sc != .colors
        screenControl.selectedSegment = sc.rawValue
        UserDefaults.standard.set(sc.rawValue, forKey: SettingsWindowController.screenKey)
    }
    @objc func screenChanged(_ sender: NSSegmentedControl) { showScreen(Screen(rawValue: sender.selectedSegment) ?? .general) }

    /// A note that wraps onto `lines` lines: a fixed width AND a fixed height (the room of `lines` lines, whatever the text uses), so that a longer text wraps
    /// instead of being cut off and a shorter one moves nothing.
    private func wrappingLabel(_ l: NSTextField, width: CGFloat, lines: Int) {
        l.lineBreakMode = .byWordWrapping
        l.usesSingleLineMode = false
        l.maximumNumberOfLines = lines
        l.preferredMaxLayoutWidth = width
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // the height the field itself asks for `lines` lines (a formula from the font's metrics was 1 pt short per line: a third line was dropped)
        let saved = l.stringValue
        l.stringValue = Array(repeating: "Xg", count: lines).joined(separator: "\n")
        let height = ceil(l.intrinsicContentSize.height)
        l.stringValue = saved
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        l.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    /// A label that shows values: a fixed width whatever it says (it truncates, it never asks the layout for more), so the text can change without moving anything.
    private func fixedLabel(_ l: NSTextField, width: CGFloat, font: NSFont?) {
        if let font { l.font = font }
        l.lineBreakMode = .byTruncatingTail
        l.usesSingleLineMode = true
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    // MARK: popups

    /// The swatch of a scheme: its colours side by side in a small rounded tile.
    static func swatchImage(for scheme: ColorScheme) -> NSImage {
        let colors = scheme.swatch
        let image = NSImage(size: NSSize(width: 38, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let w = rect.width / CGFloat(max(1, colors.count))
            for (i, c) in colors.enumerated() { c.setFill(); NSRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: rect.height).fill() }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func schemeTitle(_ scheme: ColorScheme) -> String { scheme.id == ColorSchemes.defaultID ? "luftig (follows system appearance)" : scheme.name }

    /// The default scheme first, then the others grouped by family (in the order the families first occur in `ColorSchemes.all`).
    private func populateSchemePopup() {
        let menu = schemePopup.menu ?? NSMenu()
        menu.removeAllItems()
        func add(_ s: ColorScheme) {
            let item = NSMenuItem(title: SettingsWindowController.schemeTitle(s), action: nil, keyEquivalent: "")
            item.representedObject = s.id
            item.image = SettingsWindowController.swatchImage(for: s)
            menu.addItem(item)
        }
        let all = ColorSchemes.all
        if let d = all.first(where: { $0.id == ColorSchemes.defaultID }) { add(d) }
        var families: [String] = []
        for s in all where s.id != ColorSchemes.defaultID && !families.contains(s.family) { families.append(s.family) }
        for family in families {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: family))
            for s in all where s.id != ColorSchemes.defaultID && s.family == family { add(s) }
        }
        // schemes from files (SchemeImport): Base16 YAML, hundreds of editor themes come in it
        menu.addItem(.separator())
        let importItem = NSMenuItem(title: "Import Scheme…", action: nil, keyEquivalent: "")
        importItem.tag = SettingsWindowController.importSchemeTag
        menu.addItem(importItem)
        if !ColorSchemes.imported.isEmpty {
            let show = NSMenuItem(title: "Show Imported Schemes in Finder", action: nil, keyEquivalent: "")
            show.tag = SettingsWindowController.showImportedTag
            menu.addItem(show)
        }
        schemePopup.menu = menu
    }
    static let importSchemeTag = 4712
    static let showImportedTag = 4713

    /// Color scheme > Import Scheme…: a Base16 YAML file; the scheme is copied into Application Support, listed under "Imported" and chosen.
    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Color Scheme"
        panel.message = "A Base16 colour scheme (a YAML file with base00 … base0F)."
        panel.allowedContentTypes = SchemeImport.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            if r == .OK, let url = panel.url { self.importScheme(from: url) } else { self.syncFromPreferences() }
        }
        if let w = window, w.isVisible { panel.beginSheetModal(for: w, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Imports the file (the same as choosing it in the panel); an error is shown as an alert, the popup goes back to the scheme in use.
    @discardableResult
    func importScheme(from url: URL) -> Bool {
        do {
            let id = try SchemeImport.importFile(url)
            populateSchemePopup()
            EditorPreferences.colorSchemeID = id
            EditorPreferences.colorSchemesReloaded()           // (the scheme in use imported again with other colours: the id is the same, the colours are not)
            syncFromPreferences()
            return true
        } catch {
            populateSchemePopup()
            syncFromPreferences()
            let alert = NSAlert(error: error)
            #if LUFTIG_SELFTEST
            lastImportError = error
            if SettingsWindowController.headless { return false }
            #endif
            if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
            return false
        }
    }
    #if LUFTIG_SELFTEST
    private(set) var lastImportError: Error?
    #endif

    private func populateFontPopup(_ popup: NSPopUpButton, defaultTitle: String, families: [String]) {
        let menu = popup.menu ?? NSMenu()
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: defaultTitle, action: nil, keyEquivalent: ""))        // representedObject nil = the system font
        menu.addItem(.separator())
        for f in families {
            let item = NSMenuItem(title: f, action: nil, keyEquivalent: "")
            item.representedObject = f
            menu.addItem(item)
        }
        popup.menu = menu
    }

    /// Each family name in its own typeface - built when a font menu is first opened (a few hundred fonts are not worth building for every ⌘,).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard fontTitlesApplied.insert(ObjectIdentifier(menu)).inserted else { return }
        applyFontTitles(menu)
    }

    func applyFontTitles(_ menu: NSMenu) {
        fontTitlesApplied.insert(ObjectIdentifier(menu))
        for item in menu.items {
            guard let family = item.representedObject as? String,
                  let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: NSFont.systemFontSize) else { continue }
            // a family of symbols, ornaments or one script (Wingdings, Apple Braille, Devanagari MT) cannot spell its own name: keep the plain title
            guard family.unicodeScalars.filter({ $0 != " " }).prefix(3).allSatisfy({ font.coveredCharacterSet.contains($0) }) else { continue }
            item.attributedTitle = NSAttributedString(string: family, attributes: [.font: font])
        }
    }

    /// Select the item of `family` (nil = the first item). A family that is not in the list (uninstalled, or not monospaced for the code font)
    /// gets an item of its own so that the popup never shows a font that is not the one in use.
    private func select(_ family: String?, in popup: NSPopUpButton) {
        guard let menu = popup.menu else { return }
        for item in menu.items where item.tag == SettingsWindowController.unavailableItemTag { menu.removeItem(item) }       // left by an earlier sync
        guard let family else { popup.selectItem(at: 0); return }
        if let item = menu.items.first(where: { ($0.representedObject as? String) == family }) { popup.select(item); return }
        let item = NSMenuItem(title: "\(family) (\(FontFactory.resolve(family) == nil ? "not installed" : "not monospaced"))", action: nil, keyEquivalent: "")
        item.representedObject = family
        item.tag = SettingsWindowController.unavailableItemTag
        menu.insertItem(item, at: 1)
        popup.select(item)
    }
    private static let unavailableItemTag = 4711

    // MARK: preferences -> controls

    /// Make every control show the preferences, and the preview show the settings. Called when a preference changes (by this window or not).
    /// Idempotent and cheap; never changes the size or the position of anything (the layout is fixed, see the header).
    func syncFromPreferences() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let s = EditorPreferences.themeSettings

        if let item = schemePopup.menu?.items.first(where: { ($0.representedObject as? String) == EditorPreferences.colorSchemeID }) { schemePopup.select(item) }
        select(s.bodyFamily, in: bodyFontPopup)
        select(s.codeFamily, in: codeFontPopup)

        showSize(s.baseSize, in: sizeField, sizeStepper, shown: &shownSize)
        codeSizeStepper.minValue = Double(Theme.codeSize(baseSize: s.baseSize, scale: EditorPreferences.codeFontScaleRange.lowerBound))
        codeSizeStepper.maxValue = Double(Theme.codeSize(baseSize: s.baseSize, scale: EditorPreferences.codeFontScaleRange.upperBound))
        showSize(Theme.codeSize(baseSize: s.baseSize, scale: s.codeScale), in: codeSizeField, codeSizeStepper, shown: &shownCodeSize)

        preview.refresh()
        let theme = preview.theme
        let automatic = s.lineHeightFactor == nil
        let shown = s.lineHeightFactor ?? Theme.lineHeightRatio(baseSize: s.baseSize)
        spacingAutomaticCheckbox.state = automatic ? .on : .off
        if trackedControl !== spacingSlider { spacingSlider.doubleValue = Double(shown) }       // while the hand drags it, the slider is the hand's
        spacingValueLabel.stringValue = String(format: "%.2f ×  (%d pt)", Double(shown), Int(theme.bodyLineHeight))
        if theme.bodyLineHeight > theme.requestedLineHeight {
            spacingNoteLabel.stringValue = String(format: "Raised to %d pt (%.2f ×) to fit the fonts.", Int(theme.bodyLineHeight), Double(theme.bodyLineHeight / theme.baseSize))
            spacingNoteLabel.toolTip = "The line box is never smaller than the tallest letters of the chosen fonts (ascent + descent), so the lines do not run into each other."
        } else {
            spacingNoteLabel.stringValue = ""
            spacingNoteLabel.toolTip = nil
        }

        let limited = EditorPreferences.readableWidth, width = EditorPreferences.columnWidth
        limitCheckbox.state = limited ? .on : .off
        if trackedControl !== widthSlider { widthSlider.doubleValue = Double(width) }
        widthSlider.isEnabled = limited
        widthValueLabel.stringValue = limited ? "\(Int(width)) pt" : "window width"
        widthValueLabel.textColor = limited ? .labelColor : .disabledControlTextColor
        widthNoteLabel.stringValue = limited ? "about \(SettingsPreview.charactersPerLine(width: width, font: theme.bodyFont)) characters per line" : "The text uses the full width of the window."

        // the panes
        select(EditorPreferences.paneFontFamily, in: paneFontPopup)
        let paneSize = EditorPreferences.paneFontSize
        if let item = paneSizePopup.menu?.items.first(where: { ($0.representedObject as? Double).map { abs($0 - Double(paneSize)) < 0.01 } ?? false }) { paneSizePopup.select(item) }
        else {
            for item in paneSizePopup.menu?.items ?? [] where item.tag == SettingsWindowController.unavailableItemTag { paneSizePopup.menu?.removeItem(item) }
            let item = NSMenuItem(title: String(format: "%g pt", Double(paneSize)), action: nil, keyEquivalent: "")
            item.representedObject = Double(paneSize); item.tag = SettingsWindowController.unavailableItemTag
            paneSizePopup.menu?.insertItem(item, at: 0); paneSizePopup.select(item)
        }
        let opacity = EditorPreferences.paneOpacity
        if trackedControl !== paneOpacitySlider { paneOpacitySlider.doubleValue = Double(opacity) }
        paneOpacityValueLabel.stringValue = "\(Int((opacity * 100).rounded())) %"
        outlineWrapCheckbox.state = EditorPreferences.outlineWraps ? .on : .off
        let spacing = EditorPreferences.outlineLineHeight
        if trackedControl !== outlineSpacingSlider { outlineSpacingSlider.doubleValue = Double(spacing) }
        outlineSpacingValueLabel.stringValue = String(format: "%.2f ×", Double(spacing))

        openInTabsCheckbox.state = EditorPreferences.openInTabs ? .on : .off
        continueListsCheckbox.state = EditorPreferences.continueLists ? .on : .off
        let behavior = EditorPreferences.reloadBehavior
        if let item = reloadPopup.menu?.items.first(where: { ($0.representedObject as? String) == behavior.rawValue }) { reloadPopup.select(item) }
        reloadNoteLabel.stringValue = behavior.note
        tablesCheckbox.state = EditorPreferences.renderTables ? .on : .off
        let images = EditorPreferences.renderImages
        if let item = imagesPopup.menu?.items.first(where: { ($0.representedObject as? String) == images.rawValue }) { imagesPopup.select(item) }
        imagesNoteLabel.stringValue = images.note
        showOutlineCheckbox.state = EditorPreferences.showOutline ? .on : .off
        showWordCountCheckbox.state = EditorPreferences.showWordCount ? .on : .off
        showSyntaxBarCheckbox.state = EditorPreferences.showSyntaxBar ? .on : .off
        showReadingTimeCheckbox.state = EditorPreferences.showReadingTime ? .on : .off
        let padding = EditorPreferences.padding
        if trackedControl !== paddingSlider { paddingSlider.doubleValue = Double(padding) }
        paddingValueLabel.stringValue = "\(Int(padding)) pt"

        syncColorsScreen()
    }

    // MARK: the Colors screen (the draft)

    /// The draft follows the chosen scheme: a new choice drops the draft (the wells show the new scheme's colours); otherwise the draft stays, and stays what
    /// the editors show (something may have applied the chosen scheme over it: Restore Defaults, the window opening again).
    private func syncColorsScreen() {
        let current = EditorPreferences.colorSchemeID
        if draftLoadedFrom != current { loadDraft(from: current) }
        else if ColorSchemes.draft != nil, Palette.scheme.id != CustomScheme.draftID { EditorPreferences.schemeDraftChanged() }
        showDraft()
    }

    /// The draft from the scheme `id`: its colours and name, nothing changed yet. An applied draft is dropped: the editors show `id` again.
    private func loadDraft(from id: String) {
        draft = CustomScheme.from(schemeID: id)
        draftLoadedFrom = id
        draftSource = CustomScheme.isCustom(id) ? id : nil
        draftDirty = false
        if ColorSchemes.draft != nil {
            ColorSchemes.draft = nil
            if Palette.scheme.id == CustomScheme.draftID { EditorPreferences.schemeDraftChanged() }
        }
    }

    /// The wells and the buttons show the draft.
    private func showDraft() {
        for (i, well) in colorWells.enumerated() where CustomScheme.hex(well.color) != draft.colors[i] { well.color = CustomScheme.color(draft.colors[i]) }
        revertSchemeButton.isEnabled = draftDirty
        saveSchemeButton.isEnabled = draftSource != nil                       // only a custom scheme is overwritten; a built-in or imported one is saved as a new one
        deleteSchemeButton.isEnabled = draftSource != nil
    }

    @objc func colorWellChanged(_ sender: NSColorWell) {
        guard let role = CustomScheme.Role(rawValue: sender.tag) else { return }
        let v = CustomScheme.hex(sender.color)
        guard v != draft[role] else { return }
        draft[role] = v
        draftDirty = true
        // coalesced: the colour panel sends a change for every pixel of a drag, and applying a draft rebuilds every window
        #if LUFTIG_SELFTEST
        if SettingsWindowController.headless { applyDraft(); return }
        #endif
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyDraft), object: nil)
        perform(#selector(applyDraft), with: nil, afterDelay: 0.02, inModes: [.common])
    }
    /// The editors show the draft.
    @objc func applyDraft() {
        ColorSchemes.draft = draft.spec(id: CustomScheme.draftID)
        EditorPreferences.schemeDraftChanged()
        showDraft()
    }

    @objc func saveScheme(_ sender: Any?) { saveDraft() }
    @objc func revertScheme(_ sender: Any?) {
        loadDraft(from: EditorPreferences.colorSchemeID)
        showDraft()
    }

    /// Save as New…: asks for a name (proposed: the draft's, made free), then saves a new custom scheme under it.
    @objc func saveSchemeAsNew(_ sender: Any?) {
        #if LUFTIG_SELFTEST
        if SettingsWindowController.headless { saveDraftAsNew(named: draft.name); return }
        #endif
        let alert = NSAlert()
        alert.messageText = "Save as New Scheme"
        alert.informativeText = "The name of the new colour scheme:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = CustomScheme.uniqueName(draft.name)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self else { return }
            if r == .alertFirstButtonReturn { self.saveDraftAsNew(named: field.stringValue) }
        }
        if let w = window, w.isVisible { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// Save: the draft overwrites the custom scheme it came from (only then: the button is disabled for a built-in or imported scheme). False (with an
    /// alert) when the file cannot be written.
    @discardableResult
    func saveDraft() -> Bool {
        guard let source = draftSource else { return false }
        return write(draft, replacing: source)
    }

    /// Save as New: a new custom scheme with the draft's colours under `name` (made free: "Name 2" when the name is taken), chosen afterwards.
    @discardableResult
    func saveDraftAsNew(named name: String) -> Bool {
        var s = draft
        s.name = CustomScheme.uniqueName(name)
        return write(s, replacing: nil)
    }

    private func write(_ s: CustomScheme, replacing: String?) -> Bool {
        do {
            let id = try s.save(replacing: replacing)
            ColorSchemes.draft = nil
            draftDirty = false
            draftLoadedFrom = nil                                                   // the sync loads the draft afresh, from the file
            populateSchemePopup()
            EditorPreferences.colorSchemeID = id
            EditorPreferences.colorSchemesReloaded()                                // (the same id saved with other colours: the colours in use are the file's now)
            syncFromPreferences()
            return true
        } catch {
            let alert = NSAlert(error: error)
            #if LUFTIG_SELFTEST
            lastImportError = error
            if SettingsWindowController.headless { return false }
            #endif
            if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
            return false
        }
    }

    /// Delete…: the custom scheme the draft came from, after a confirmation; the default scheme is used afterwards.
    @objc func deleteScheme(_ sender: Any?) {
        guard let id = draftSource else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the colour scheme “\(draft.name)”?"
        alert.informativeText = "Its file is removed from the schemes folder. The default scheme is used afterwards."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in if r == .alertFirstButtonReturn { self?.deleteScheme(id: id) } }
        #if LUFTIG_SELFTEST
        if SettingsWindowController.headless { finish(.alertFirstButtonReturn); return }
        #endif
        if let w = window, w.isVisible { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }
    func deleteScheme(id: String) {
        try? CustomScheme.delete(id: id)
        ColorSchemes.draft = nil
        draftDirty = false
        draftLoadedFrom = nil
        populateSchemePopup()
        EditorPreferences.colorSchemeID = ColorSchemes.defaultID
        EditorPreferences.colorSchemesReloaded()
        syncFromPreferences()
    }

    /// Closing the window drops a draft that was not saved: the editors show the chosen scheme again.
    func windowWillClose(_ notification: Notification) {
        guard ColorSchemes.draft != nil else { return }
        loadDraft(from: EditorPreferences.colorSchemeID)
        showDraft()
    }

    /// A size field and its stepper show `size`, whatever has the keyboard focus. `shown`: what the field was last made to show.
    ///
    /// The field used to be skipped while it was being edited (`if sizeField.currentEditor() == nil`, so that a sync never overwrote what the user was typing):
    /// after a click in the field it stays first responder, so the stepper arrows and ⌘+ ⌘- ⌘0 changed the size and the number beside them stayed (the user
    /// saw the old number with its text selected). Now a CHANGE of the size goes into the field editor - selected, as if it had been typed: the next digit
    /// replaces it - and text the user is typing while the size does NOT change is left alone.
    private func showSize(_ size: CGFloat, in field: NSTextField, _ stepper: NSStepper, shown: inout CGFloat) {
        stepper.doubleValue = Double(size)
        let number = NSNumber(value: Double(size))
        if let editor = field.currentEditor() {
            if size != shown {
                let text = (field.formatter as? NumberFormatter)?.string(from: number) ?? String(Double(size))
                editor.string = text
                editor.selectAll(nil)
            }
        } else {
            field.objectValue = number
        }
        shown = size
    }

    // MARK: drags (slider, stepper): the editors follow at a bounded rate, the last value always arrives

    /// A slider or stepper drag began / ended (the controls call this from `mouseDown`, which returns when the mouse is released; the self-test calls it
    /// around synthetic drags). While it lasts `EditorPreferences` broadcasts at most every ~40 ms (and invisible windows wait); the window itself follows the
    /// controls at once (labels, preview: a millisecond). The end flushes: the final value is applied to every window, always.
    func tracking(_ control: NSControl, began: Bool) {
        if began {
            guard trackedControl == nil else { return }
            trackedControl = control
            EditorPreferences.beginAdjusting()
        } else {
            guard trackedControl === control else { return }
            trackedControl = nil
            EditorPreferences.endAdjusting()
            syncFromPreferences()
        }
    }

    // MARK: NSTextFieldDelegate (the size field)

    /// A string the formatter cannot read (an empty field, a lone "." ...): the number it showed comes back and the field keeps working.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        guard control === sizeField || control === codeSizeField else { return true }
        (control as? NSTextField)?.abortEditing()
        shownSize = 0; shownCodeSize = 0
        syncFromPreferences()
        return false
    }

    // MARK: controls -> preferences

    @objc func schemeChanged(_ sender: NSPopUpButton) {
        switch sender.selectedItem?.tag {
        case SettingsWindowController.importSchemeTag: presentImportPanel(); return
        case SettingsWindowController.showImportedTag:
            try? FileManager.default.createDirectory(at: SchemeImport.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([SchemeImport.directory])
            syncFromPreferences(); return
        default: break
        }
        EditorPreferences.colorSchemeID = (sender.selectedItem?.representedObject as? String) ?? ColorSchemes.defaultID
        syncFromPreferences()
    }
    @objc func textFontChanged(_ sender: NSPopUpButton) {
        EditorPreferences.bodyFontFamily = sender.selectedItem?.representedObject as? String
        syncFromPreferences()
    }
    @objc func codeFontChanged(_ sender: NSPopUpButton) {
        EditorPreferences.codeFontFamily = sender.selectedItem?.representedObject as? String
        syncFromPreferences()
    }
    @objc func sizeFieldChanged(_ sender: NSTextField) {
        // text that is not a number (the formatter refuses it when typed, but a field can be set from code) changes nothing; a number outside 9 ... 40 is clamped
        if let n = (sender.formatter as? NumberFormatter)?.number(from: sender.stringValue) { EditorPreferences.fontSize = CGFloat(n.doubleValue) }
        sender.abortEditing()
        shownSize = 0                                      // whatever the field shows now, it must show the size in use
        syncFromPreferences()
    }
    @objc func sizeStepperChanged(_ sender: NSStepper) {
        EditorPreferences.fontSize = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func codeSizeFieldChanged(_ sender: NSTextField) {
        // in points; kept as a share of the text size (clamped to half ... one and a half times it)
        if let n = (sender.formatter as? NumberFormatter)?.number(from: sender.stringValue) { EditorPreferences.codeFontSize = CGFloat(n.doubleValue) }
        sender.abortEditing()
        shownCodeSize = 0
        syncFromPreferences()
    }
    @objc func codeSizeStepperChanged(_ sender: NSStepper) {
        EditorPreferences.codeFontSize = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func spacingSliderChanged(_ sender: NSSlider) {
        EditorPreferences.lineHeightFactor = CGFloat(sender.doubleValue)       // dragging the slider is choosing a factor: "Automatic" goes off
        syncFromPreferences()
    }
    @objc func spacingAutomaticChanged(_ sender: NSButton) {
        if sender.state == .on { EditorPreferences.lineHeightFactor = nil }
        else {
            // off: keep the line box the automatic curve gives right now as the chosen factor (nothing moves when the box is unticked)
            let size = EditorPreferences.fontSize
            EditorPreferences.lineHeightFactor = (Theme.lineHeightRatio(baseSize: size) * size).rounded() / size
        }
        syncFromPreferences()
    }
    @objc func limitChanged(_ sender: NSButton) {
        EditorPreferences.readableWidth = sender.state == .on
        syncFromPreferences()
    }
    @objc func widthSliderChanged(_ sender: NSSlider) {
        EditorPreferences.columnWidth = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func paneFontChanged(_ sender: NSPopUpButton) {
        EditorPreferences.paneFontFamily = sender.selectedItem?.representedObject as? String
        syncFromPreferences()
    }
    @objc func paneSizeChanged(_ sender: NSPopUpButton) {
        if let s = sender.selectedItem?.representedObject as? Double { EditorPreferences.paneFontSize = CGFloat(s) }
        syncFromPreferences()
    }
    @objc func paneOpacityChanged(_ sender: NSSlider) {
        EditorPreferences.paneOpacity = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func openInTabsChanged(_ sender: NSButton) { EditorPreferences.openInTabs = sender.state == .on; syncFromPreferences() }
    @objc func continueListsChanged(_ sender: NSButton) { EditorPreferences.continueLists = sender.state == .on; syncFromPreferences() }
    @objc func tablesChanged(_ sender: NSButton) { EditorPreferences.renderTables = sender.state == .on; syncFromPreferences() }
    @objc func imagesChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let m = EditorPreferences.ImageMode(rawValue: raw) { EditorPreferences.renderImages = m }
        syncFromPreferences()
    }
    @objc func reloadBehaviorChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let b = EditorPreferences.ReloadBehavior(rawValue: raw) { EditorPreferences.reloadBehavior = b }
        syncFromPreferences()
    }
    @objc func showOutlineChanged(_ sender: NSButton) { EditorPreferences.showOutline = sender.state == .on; syncFromPreferences() }
    @objc func showWordCountChanged(_ sender: NSButton) { EditorPreferences.showWordCount = sender.state == .on; syncFromPreferences() }
    @objc func showSyntaxBarChanged(_ sender: NSButton) { EditorPreferences.showSyntaxBar = sender.state == .on; syncFromPreferences() }
    @objc func showReadingTimeChanged(_ sender: NSButton) { EditorPreferences.showReadingTime = sender.state == .on; syncFromPreferences() }
    @objc func paddingSliderChanged(_ sender: NSSlider) {
        EditorPreferences.padding = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func outlineSpacingChanged(_ sender: NSSlider) {
        EditorPreferences.outlineLineHeight = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func outlineWrapChanged(_ sender: NSButton) {
        EditorPreferences.outlineWraps = sender.state == .on
        syncFromPreferences()
    }
    /// Restore Defaults: after a confirmation (one click used to undo every setting at once).
    @objc func restoreDefaults(_ sender: Any?) {
        #if LUFTIG_SELFTEST
        if SettingsWindowController.headless { applyRestoreDefaults(); return }
        #endif
        let alert = NSAlert()
        alert.messageText = "Restore every setting to its default?"
        alert.informativeText = "Fonts, sizes, spacing, column width, the colour scheme, the panels and the padding go back to how luftig came. Imported and custom colour schemes are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in if r == .alertFirstButtonReturn { self?.applyRestoreDefaults() } }
        if let w = window, w.isVisible { alert.beginSheetModal(for: w, completionHandler: finish) } else { finish(alert.runModal()) }
    }
    func applyRestoreDefaults() {
        EditorPreferences.restoreDefaults()
        shownSize = 0; shownCodeSize = 0
        syncFromPreferences()
    }

    // MARK: ⌘+ ⌘- ⌘0 and the View menu keep working while this window is key

    @objc func luftigIncreaseFontSize(_ sender: Any?) { EditorPreferences.fontSize += 1 }
    @objc func luftigDecreaseFontSize(_ sender: Any?) { EditorPreferences.fontSize -= 1 }
    @objc func luftigResetFontSize(_ sender: Any?) { EditorPreferences.fontSize = EditorPreferences.defaultFontSize }
    @objc func luftigToggleReadableWidth(_ sender: Any?) { EditorPreferences.readableWidth.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(luftigIncreaseFontSize(_:)): return EditorPreferences.fontSize < EditorPreferences.fontSizeRange.upperBound
        case #selector(luftigDecreaseFontSize(_:)): return EditorPreferences.fontSize > EditorPreferences.fontSizeRange.lowerBound
        case #selector(luftigResetFontSize(_:)): return EditorPreferences.fontSize != EditorPreferences.defaultFontSize
        case #selector(luftigToggleReadableWidth(_:)): item.state = EditorPreferences.readableWidth ? .on : .off
        default: break
        }
        return true
    }
}
