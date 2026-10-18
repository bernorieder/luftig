// SettingsWindowController.swift - luftig > Settings… (⌘,)
//
// ONE window (a singleton: opening it again raises it), plain AppKit (NSGridView + Auto Layout, no nib, no SwiftUI). Every control applies at once to
// every open editor window and is saved in UserDefaults (EditorPreferences); there are no OK / Apply buttons. The window never holds state of its
// own: it reads the preferences, shows them, and writes them back when a control is used; it follows changes made elsewhere (⌘+ ⌘- ⌘0, the
// View menu) because it observes `EditorPreferences.didChange` like an editor does.
//
//   [ live preview: the real Theme + lexer + decorations, read-only ]   <- on both screens
//   ( Text | Panes )                                   <- two screens, a segmented control under the preview; the chosen one is remembered
//   Text:
//   Color scheme   [swatch luftig (follows system appearance)  v]
//   Text font       [System (SF Pro)  v]
//   Code font       [System Mono (SF Mono)  v]
//   Size            [ 16 ] (stepper) pt
//   Line spacing    ----o------   1.42 ×  (23 pt)
//                   [x] Automatic   (a note here when the fonts raised the line box)
//   Column width    [x] Limit line length (centered column)
//                   ----o------   760 pt
//                   about 85 characters per line
//   Panes:
//   Show            [x] Outline  [x] Word count  [x] Syntax bar       (the View menu's switches, the other way to reach them)
//   Padding         ----o------   1.00 ×                                (ONE factor for all the air: text insets, pane margins and heights - luftig)
//   Font            [Same as text font  v]
//   Size            [12 pt v]
//   Opacity         ----o------   100 %
//   Outline         [x] Wrap long headings
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
    static let sliderWidth: CGFloat = 250
    static let sliderGap: CGFloat = 10
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
    let restoreButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
    // the three panes (the View menu's switches too) and the padding factor
    let showOutlineCheckbox = NSButton(checkboxWithTitle: "Outline", target: nil, action: nil)
    let showWordCountCheckbox = NSButton(checkboxWithTitle: "Word count", target: nil, action: nil)
    let showSyntaxBarCheckbox = NSButton(checkboxWithTitle: "Syntax bar", target: nil, action: nil)
    let paddingSlider = SettingsSlider(value: 1, minValue: Double(EditorPreferences.paddingRange.lowerBound), maxValue: Double(EditorPreferences.paddingRange.upperBound), target: nil, action: nil)
    let paddingValueLabel = NSTextField(labelWithString: "")
    let paddingNoteLabel = NSTextField(labelWithString: "")
    /// The screens: Text and Panes; the segmented control under the preview switches, the choice is remembered.
    enum Screen: Int, CaseIterable { case text = 0, panes = 1
        var title: String { self == .text ? "Text" : "Panes" }
    }
    static let screenKey = "LuftigSettingsScreen"
    let screenControl = NSSegmentedControl(labels: Screen.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    let textScreen = NSView()
    let panesScreen = NSView()
    private(set) var screen: Screen = .text

    /// The families the two font popups offer (the code font: monospaced ones only).
    private(set) var textFamilies: [String] = []
    private(set) var codeFamilies: [String] = []
    private var fontTitlesApplied = Set<ObjectIdentifier>()
    private var observer: NSObjectProtocol?
    private var syncing = false
    /// The size the size field was last made to show (what a change of the preference is compared with while the field is being edited).
    private var shownSize: CGFloat = 0
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
            popup.widthAnchor.constraint(equalToConstant: W.popupWidth).isActive = true
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
        sizeField.formatter = formatter
        sizeField.alignment = .right
        sizeField.delegate = self
        sizeField.target = self; sizeField.action = #selector(sizeFieldChanged(_:))
        sizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        sizeField.setAccessibilityLabel("Font size")
        sizeStepper.minValue = Double(EditorPreferences.fontSizeRange.lowerBound)
        sizeStepper.maxValue = Double(EditorPreferences.fontSizeRange.upperBound)
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self; sizeStepper.action = #selector(sizeStepperChanged(_:))
        sizeStepper.onTracking = { [weak self, weak sizeStepper] began in if let sizeStepper { self?.tracking(sizeStepper, began: began) } }
        sizeStepper.setAccessibilityLabel("Font size stepper")

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
        outlineWrapCheckbox.target = self; outlineWrapCheckbox.action = #selector(outlineWrapChanged(_:))
        outlineWrapCheckbox.setAccessibilityLabel("Wrap long headings in the outline")

        for (box, action, name) in [(showOutlineCheckbox, #selector(showOutlineChanged(_:)), "Show the outline"), (showWordCountCheckbox, #selector(showWordCountChanged(_:)), "Show the word count"), (showSyntaxBarCheckbox, #selector(showSyntaxBarChanged(_:)), "Show the syntax bar")] {
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
        paddingNoteLabel.stringValue = "The air around the text and in the panes, all in proportion."

        screenControl.target = self; screenControl.action = #selector(screenChanged(_:))
        screenControl.segmentStyle = .automatic
        screenControl.setAccessibilityLabel("Settings screen")
        screenControl.translatesAutoresizingMaskIntoConstraints = false
        for (i, sc) in Screen.allCases.enumerated() { screenControl.setWidth(90, forSegment: i); screenControl.setLabel(sc.title, forSegment: i) }

        restoreButton.target = self; restoreButton.action = #selector(restoreDefaults(_:))
        restoreButton.bezelStyle = .rounded
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        // -- rows
        let sizeRow = NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])
        sizeRow.orientation = .horizontal; sizeRow.spacing = 4
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
        let showRow = NSStackView(views: [showOutlineCheckbox, showWordCountCheckbox, showSyntaxBarCheckbox])
        showRow.orientation = .horizontal; showRow.spacing = 14
        let paddingSliderRow = NSStackView(views: [paddingSlider, paddingValueLabel])
        paddingSliderRow.orientation = .horizontal; paddingSliderRow.spacing = W.sliderGap
        let paddingColumn = NSStackView(views: [paddingSliderRow, paddingNoteLabel])
        paddingColumn.orientation = .vertical; paddingColumn.alignment = .leading; paddingColumn.spacing = 6

        // the grids share the label column width, so the controls of both screens start at the same x
        let textLabels = ["Color scheme:", "Text font:", "Code font:", "Size:", "Line spacing:", "Column width:"].map { label($0) }
        let panesLabels = ["Show:", "Padding:", "Font:", "Size:", "Opacity:", "Outline:"].map { label($0) }
        let labelWidth = ceil((textLabels + panesLabels).map { $0.intrinsicContentSize.width }.max() ?? 90)
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
        let grid = makeGrid([
            [textLabels[0], schemePopup],
            [textLabels[1], bodyFontPopup],
            [textLabels[2], codeFontPopup],
            [textLabels[3], sizeRow],
            [textLabels[4], spacingRow],
            [textLabels[5], widthColumn],
        ])
        let panesGrid = makeGrid([
            [panesLabels[0], showRow],
            [panesLabels[1], paddingColumn],
            [panesLabels[2], paneFontPopup],
            [panesLabels[3], paneSizePopup],
            [panesLabels[4], opacityRow],
            [panesLabels[5], outlineWrapCheckbox],
        ])

        let previewView = preview.scrollView
        previewView.translatesAutoresizingMaskIntoConstraints = false

        let content = SettingsContentView(frame: NSRect(x: 0, y: 0, width: W.defaultContentWidth, height: 700))
        for screenView in [textScreen, panesScreen] { screenView.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(screenView) }
        content.addSubview(previewView)
        content.addSubview(screenControl)
        textScreen.addSubview(grid)
        panesScreen.addSubview(panesGrid)
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
            panesScreen.topAnchor.constraint(equalTo: screenControl.bottomAnchor, constant: 14),
            panesScreen.leadingAnchor.constraint(equalTo: content.leadingAnchor), panesScreen.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // Text: its grid
            grid.topAnchor.constraint(equalTo: textScreen.topAnchor),
            grid.centerXAnchor.constraint(equalTo: textScreen.centerXAnchor),                       // centred, at its own fixed width: nothing is left to stretch or to guess
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: textScreen.leadingAnchor, constant: m),    // (the minimum window width keeps these two satisfied)
            grid.trailingAnchor.constraint(lessThanOrEqualTo: textScreen.trailingAnchor, constant: -m),
            grid.bottomAnchor.constraint(equalTo: textScreen.bottomAnchor),
            // Panes: its grid, at the top of the screen
            panesGrid.topAnchor.constraint(equalTo: panesScreen.topAnchor),
            panesGrid.centerXAnchor.constraint(equalTo: panesScreen.centerXAnchor),
            panesGrid.leadingAnchor.constraint(greaterThanOrEqualTo: panesScreen.leadingAnchor, constant: m),
            panesGrid.trailingAnchor.constraint(lessThanOrEqualTo: panesScreen.trailingAnchor, constant: -m),
            panesGrid.bottomAnchor.constraint(equalTo: panesScreen.bottomAnchor),
            // the button under the taller screen, on both screens
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: textScreen.bottomAnchor, constant: 18),
            restoreButton.topAnchor.constraint(greaterThanOrEqualTo: panesScreen.bottomAnchor, constant: 18),
            restoreButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
        ])
        window.contentView = content
        showScreen(Screen(rawValue: UserDefaults.standard.integer(forKey: W.screenKey)) ?? .text)

        // -- size: the height is the content's (computed ONCE: nothing in the window changes size), the width is the user's from the minimum up; the position is remembered
        syncFromPreferences()
        content.layoutSubtreeIfNeeded()
        // (the button's FRAME is taller than the rectangle the constraints place - its alignment rect - by the room of its shadow and focus ring)
        let restoreHeight = restoreButton.alignmentRect(forFrame: NSRect(origin: .zero, size: restoreButton.fittingSize)).height
        let switchHeight = ceil(screenControl.fittingSize.height)
        let tallest = max(grid.fittingSize.height, panesGrid.fittingSize.height)
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
        textScreen.isHidden = sc != .text
        panesScreen.isHidden = sc != .panes
        screenControl.selectedSegment = sc.rawValue
        UserDefaults.standard.set(sc.rawValue, forKey: SettingsWindowController.screenKey)
    }
    @objc func screenChanged(_ sender: NSSegmentedControl) { showScreen(Screen(rawValue: sender.selectedSegment) ?? .text) }

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
        schemePopup.menu = menu
    }

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

        showSize(s.baseSize)

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

        showOutlineCheckbox.state = EditorPreferences.showOutline ? .on : .off
        showWordCountCheckbox.state = EditorPreferences.showWordCount ? .on : .off
        showSyntaxBarCheckbox.state = EditorPreferences.showSyntaxBar ? .on : .off
        let padding = EditorPreferences.padding
        if trackedControl !== paddingSlider { paddingSlider.doubleValue = Double(padding) }
        paddingValueLabel.stringValue = String(format: "%.2f ×", Double(padding))
    }

    /// The size field and its stepper show `size`, whatever has the keyboard focus.
    ///
    /// The field used to be skipped while it was being edited (`if sizeField.currentEditor() == nil`, so that a sync never overwrote what the user was typing):
    /// after a click in the field it stays first responder, so the stepper arrows and ⌘+ ⌘- ⌘0 changed the size and the number beside them stayed (the user
    /// saw the old number with its text selected). Now a CHANGE of the size goes into the field editor - selected, as if it had been typed: the next digit
    /// replaces it - and text the user is typing while the size does NOT change is left alone.
    private func showSize(_ size: CGFloat) {
        sizeStepper.doubleValue = Double(size)
        let number = NSNumber(value: Double(size))
        if let editor = sizeField.currentEditor() {
            if size != shownSize {
                let text = (sizeField.formatter as? NumberFormatter)?.string(from: number) ?? String(Double(size))
                editor.string = text
                editor.selectAll(nil)
            }
        } else {
            sizeField.objectValue = number
        }
        shownSize = size
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
        guard control === sizeField else { return true }
        sizeField.abortEditing()
        shownSize = 0
        syncFromPreferences()
        return false
    }

    // MARK: controls -> preferences

    @objc func schemeChanged(_ sender: NSPopUpButton) {
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
    @objc func showOutlineChanged(_ sender: NSButton) { EditorPreferences.showOutline = sender.state == .on; syncFromPreferences() }
    @objc func showWordCountChanged(_ sender: NSButton) { EditorPreferences.showWordCount = sender.state == .on; syncFromPreferences() }
    @objc func showSyntaxBarChanged(_ sender: NSButton) { EditorPreferences.showSyntaxBar = sender.state == .on; syncFromPreferences() }
    @objc func paddingSliderChanged(_ sender: NSSlider) {
        EditorPreferences.padding = CGFloat(sender.doubleValue)
        syncFromPreferences()
    }
    @objc func outlineWrapChanged(_ sender: NSButton) {
        EditorPreferences.outlineWraps = sender.state == .on
        syncFromPreferences()
    }
    @objc func restoreDefaults(_ sender: Any?) {
        EditorPreferences.restoreDefaults()
        shownSize = 0
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
