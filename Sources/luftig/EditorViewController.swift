// EditorViewController.swift
//
// The real editor: LuftigEditorFactory's TextKit 1 stack (non-contiguous layout, one NSTextView in an NSScrollView), lazy
// viewport styling (LazyStyler <- MarkdownRunProvider <- MarkdownKit), the readable column, the notification banner, and the
// contract with the document layer (`EditorHost` / `TextViewEditorHost`, `document.editorWillChangeText()`).
//
// The surface the document layer and the self-tests rely on: `textView`, `scrollView`, `fontSize`, the banner introspection
// helpers (`bannerVisible`, `bannerText`, `bannerButtonTitles`, `pressBannerButton`) and the `luftig*` actions.

import AppKit
import MarkdownKit

/// Custom actions reachable through the responder chain (selectors used by MainMenu.swift).
@objc protocol LuftigEditorActions {
    func luftigIncreaseFontSize(_ sender: Any?)
    func luftigDecreaseFontSize(_ sender: Any?)
    func luftigResetFontSize(_ sender: Any?)
    func luftigToggleReadableWidth(_ sender: Any?)
    func luftigToggleSpellChecking(_ sender: Any?)
}

final class EditorViewController: NSViewController, TextViewEditorHost, NSTextViewDelegate, NSMenuItemValidation, LuftigEditorActions {

    static let defaultFontSize = EditorPreferences.defaultFontSize
    static let initialSize = NSSize(width: 860, height: 1000)

    weak var document: MarkdownDocument?
    let scrollView: NSScrollView
    var textView: NSTextView { editorTextView }
    let editorTextView: LuftigEditorTextView
    let styler: LazyStyler
    let provider: MarkdownRunProvider
    private let storage: NSTextStorage
    private let layoutManager: LuftigLayoutManager
    private let column: ReadableColumnController
    private let banner = BannerView()
    private var preferenceObserver: NSObjectProtocol?

    private(set) var theme: Theme
    private(set) var fontSize: CGFloat
    /// The colour scheme the editor was last styled with (a change rebuilds the theme: its cached attribute dictionaries hold the colours).
    private var appliedSchemeID: String
    /// True while this editor's window carries an appearance that the colour scheme forced (a dark scheme on a light system and vice versa).
    private var schemeForcedAppearance = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        let settings = EditorPreferences.themeSettings
        fontSize = settings.baseSize
        appliedSchemeID = EditorPreferences.colorSchemeID
        theme = Theme(settings: settings)
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("EditorViewController: theme created")
        #endif
        let stack = LuftigEditorFactory.make(frame: NSRect(origin: .zero, size: EditorViewController.initialSize), theme: theme)
        scrollView = stack.scrollView
        editorTextView = stack.textView
        storage = stack.storage
        layoutManager = stack.layoutManager
        provider = MarkdownRunProvider(storage: stack.storage, theme: theme)
        styler = LazyStyler(textView: stack.textView)
        provider.attach(to: styler)
        stack.textView.lazyStyler = styler
        column = ReadableColumnController(scrollView: stack.scrollView, textView: stack.textView, maxColumnWidth: EditorPreferences.columnWidth)
        column.isEnabled = EditorPreferences.readableWidth
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("EditorViewController: stack built")
        #endif
        textView.delegate = self
        preferenceObserver = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { [weak self] _ in        // synchronous, on the posting (main) thread
            self?.preferencesDidChange()
        }
    }
    convenience init() { self.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let o = preferenceObserver { NotificationCenter.default.removeObserver(o) }
        // AppKit (macOS 27.0.1) keeps the NSTextStorage + NSLayoutManager (+ container) of a TextKit 1 stack alive after the view that
        // showed them is gone, in a fraction of the cases that varies with timing (8 % of the closed 1 MB documents, 47 % of 40 documents
        // closed together; reproduced in a bare AppKit program without any luftig code): the document's text, its attributes and the
        // glyph / layout data stay in memory for the rest of the session. Breaking the storage -> layout manager link releases everything
        // (bare program: 0 of 50 alive instead of 18-28; in luftig: 0 of 100 / 0 of 40).
        storage.removeLayoutManager(layoutManager)
    }

    override func loadView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [banner, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        banner.isHidden = true
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        stack.frame = NSRect(origin: .zero, size: EditorViewController.initialSize)
        view = stack
    }

    // MARK: EditorHost (loading, external changes, banner)

    /// First load: replaces everything, no undo, not dirty. ~16 ms at 20 MB (the text copy), the first screen is styled right away.
    func loadInitialText(_ text: NSString) {
        let um = textView.undoManager
        um?.disableUndoRegistration()
        styler.replacingWholeText {                           // the styler ignores these edits, then forgets everything (lexer state, styled set)
            textView.string = text as String
            applyBaseAttributesToWholeText()
        }
        um?.enableUndoRegistration()
        um?.removeAllActions()                                // `string =` does not reset undo
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        styler.styleVisible()
    }

    @discardableResult
    func applyExternalText(_ new: NSString, mode: ExternalApplyMode) -> ExternalApplyReport {
        // minimal-diff replaceCharacters: the LazyStyler restyles the touched region from didProcessEditing (a huge hunk list
        // just forgets the styled set); then fill whatever is visible and unstyled.
        let report = defaultApplyExternalText(new, mode: mode)         // (restores selection and the scroll anchor on unstyled text)
        let anchor = ViewportAnchor.capture(in: textView)
        let before = styler.appliedRunCount
        styler.styleVisible()
        // styling changed the look of the visible text (a fence flipped everything to code: other font, other wrapping): put the
        // line that was at the top of the window back at the top
        if styler.appliedRunCount != before, let anchor { anchor.restoreSameCharacter(in: textView) }
        return report
    }

    func showBanner(_ b: EditorBanner) { banner.configure(b); banner.isHidden = false }
    func hideBanner() { banner.isHidden = true }
    var bannerVisible: Bool { !banner.isHidden }
    var bannerText: String { banner.messageField.stringValue }
    var bannerButtonTitles: [String] { banner.buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    func pressBannerButton(_ title: String) { (banner.buttonStack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == title })?.performClick(nil) }

    /// One run of base attributes over the whole text: what not yet styled text looks like (same line height as styled text).
    private func applyBaseAttributesToWholeText() {
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = theme.baseAttributes
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        document?.editorWillChangeText()
        return true
    }
    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    // MARK: preferences (fonts, size, line spacing, column, colour scheme): shared by all windows

    private func preferencesDidChange() {
        // A slider / stepper of the Settings window is being dragged and nobody can see this window (minimized, a background tab, another Space, the app hidden):
        // wait. The drag ends with one more broadcast (`EditorPreferences.endAdjusting`) that finds this editor out of date and brings it up to date.
        if EditorPreferences.isAdjusting && isHiddenFromUser { return }
        let settings = EditorPreferences.themeSettings
        let scheme = EditorPreferences.colorSchemeID
        if settings != theme.settings || scheme != appliedSchemeID { rebuildTheme(settings: settings, schemeID: scheme) }
        column.maxColumnWidth = EditorPreferences.columnWidth
        column.isEnabled = EditorPreferences.readableWidth
    }

    /// The user cannot see this window right now. `isVisible` is false for a minimized window, a background tab and a hidden app; `occlusionState` has no
    /// `.visible` when the window is completely covered or on another Space. A window that is not in a window at all has nothing to show either.
    private var isHiddenFromUser: Bool {
        #if LUFTIG_SELFTEST
        if let forced = EditorViewController.visibilityOverride { return !forced }
        #endif
        guard let w = view.window else { return true }
        return !w.isVisible || !w.occlusionState.contains(.visible)
    }

    #if LUFTIG_SELFTEST
    /// The self-test never shows a window (so `isVisible` is false for every editor): nil = ask the window as the app does, true / false = pretend.
    nonisolated(unsafe) static var visibilityOverride: Bool?
    #endif
    /// How many times this editor built a new Theme and restyled (a settings or scheme change). Tests count them.
    private(set) var themeRebuildCount = 0

    /// New settings (size, fonts, line spacing, colour scheme): new Theme (new attribute caches), base attributes over the whole text (so NOT yet
    /// styled text changes too), restyle what is visible, keep the line at the top of the window where it was.
    private func rebuildTheme(settings: ThemeSettings, schemeID: String) {
        themeRebuildCount += 1
        fontSize = settings.baseSize
        let anchor = ViewportAnchor.capture(in: textView)
        theme = Theme(settings: settings)
        provider.theme = theme
        if schemeID != appliedSchemeID {
            appliedSchemeID = schemeID
            applySchemeColors()
        }
        if storage.length == 0 {
            LuftigEditorFactory.applyBaseAppearance(textView, theme: theme)
        } else {
            applyBaseAttributesToWholeText()
        }
        styler.reset()
        styler.styleVisible()
        if let anchor, anchor.restoreSameCharacter(in: textView) { styler.styleVisible() }
        textView.needsDisplay = true
    }

    /// The page, the caret and the window's appearance follow the colour scheme. A scheme that is always light or always dark (Solarized Light,
    /// Dracula, ...) forces the window's appearance so that the title bar, scrollers and the find bar match; the system scheme gives it back.
    private func applySchemeColors() {
        textView.backgroundColor = Palette.background
        scrollView.backgroundColor = Palette.background
        textView.insertionPointColor = Palette.accent
        applySchemeAppearance()
    }

    /// Called by the window controller once the view has a window, and on every scheme change.
    func applySchemeAppearance() {
        guard let window = view.window else { return }
        switch Palette.scheme.appearance {
        case .light: window.appearance = NSAppearance(named: .aqua); schemeForcedAppearance = true
        case .dark: window.appearance = NSAppearance(named: .darkAqua); schemeForcedAppearance = true
        case .system: if schemeForcedAppearance { window.appearance = nil; schemeForcedAppearance = false }
        }
    }

    @objc func luftigIncreaseFontSize(_ sender: Any?) { EditorPreferences.fontSize = fontSize + 1 }
    @objc func luftigDecreaseFontSize(_ sender: Any?) { EditorPreferences.fontSize = fontSize - 1 }
    @objc func luftigResetFontSize(_ sender: Any?) { EditorPreferences.fontSize = EditorPreferences.defaultFontSize }
    @objc func luftigToggleReadableWidth(_ sender: Any?) { EditorPreferences.readableWidth.toggle() }
    /// View > Toggle Spell Checking (off by default). Same switch as Edit > Spelling and Grammar > Check Spelling While Typing; AppKit
    /// would rename a menu item wired straight to `toggleContinuousSpellChecking:`, so the View item has its own action.
    @objc func luftigToggleSpellChecking(_ sender: Any?) { textView.toggleContinuousSpellChecking(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(luftigToggleReadableWidth(_:)): item.state = column.isEnabled ? .on : .off
        case #selector(luftigToggleSpellChecking(_:)): item.state = textView.isContinuousSpellCheckingEnabled ? .on : .off
        case #selector(luftigIncreaseFontSize(_:)): return fontSize < EditorPreferences.fontSizeRange.upperBound
        case #selector(luftigDecreaseFontSize(_:)): return fontSize > EditorPreferences.fontSizeRange.lowerBound
        case #selector(luftigResetFontSize(_:)): return fontSize != EditorPreferences.defaultFontSize
        default: break
        }
        return true
    }

    /// Test / diagnostics access.
    var readableWidthEnabled: Bool { column.isEnabled }
}
