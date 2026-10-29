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
    func luftigToggleOutline(_ sender: Any?)
    func luftigToggleWordCount(_ sender: Any?)
    func luftigToggleSyntaxBar(_ sender: Any?)
    func luftigToggleReadingTime(_ sender: Any?)
    /// Format menu: the item's `tag` names the SyntaxElement (`SyntaxElement.menuTag`); the same edit as a click on the syntax bar.
    func luftigInsertSyntax(_ sender: Any?)
    /// Edit > Open Link: the link at the caret (the same as a ⌘-click on it).
    func luftigOpenLink(_ sender: Any?)
    /// View > Typewriter Mode (the `typewriter` extension).
    func luftigToggleTypewriterMode(_ sender: Any?)
    /// View > Tables as Grids (TableRender.swift).
    func luftigToggleTableGrids(_ sender: Any?)
    /// Edit > Copy as HTML / Copy as Rich Text: the selection (or everything) rendered (MarkdownHTML.swift).
    func luftigCopyAsHTML(_ sender: Any?)
    func luftigCopyAsRichText(_ sender: Any?)
    /// Format > Align Table: pads the table at the caret with spaces so that it is aligned in the file too (TableFormatter).
    func luftigAlignTable(_ sender: Any?)
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
    let banner = BannerView()
    private var preferenceObserver: NSObjectProtocol?
    // the three elements around the text (EditorChromeViews.swift); their data is computed in bounded steps, see the `chrome` extension below
    let outline = OutlineView()
    let wordCount = WordCountView()
    let syntaxBar: SyntaxBarView
    var chromeObservers: [NSObjectProtocol] = []
    var chromeTimer: Timer?
    var chromeScanner: OutlineScanner?
    var chromeCounter: WordCounter?
    var chromeStepScheduled = false
    var chromeGeneration = 0
    var chromeDataGeneration = -1
    var chromeWordTotal = 0
    var windowPaddingConstraints: [NSLayoutConstraint] = []
    var verticalInsetConstraints: [NSLayoutConstraint] = []
    var topPaddingConstraint: NSLayoutConstraint!
    var bottomPaddingConstraint: NSLayoutConstraint!
    var barGapConstraint: NSLayoutConstraint!
    var viewportBottomConstraint: NSLayoutConstraint!
    /// Whether the outline / word count hold data for the current text (hidden elements are not computed; shown later, they are).
    var chromeOutlineValid = false
    var chromeWordsValid = false
    /// How many times the outline / word count were recomputed (tests).
    var chromeRefreshCount = 0

    private(set) var theme: Theme
    private(set) var fontSize: CGFloat
    /// The palette (`Palette.serial`: the built colours of a scheme) the editor was last styled with; another one rebuilds the theme (its cached attribute
    /// dictionaries hold the colours). The serial, not the scheme id: the draft of Settings > Colors changes colours under one id, and so does a re-import.
    private var appliedPaletteSerial: Int
    /// True while this editor's window carries an appearance that the colour scheme forced (a dark scheme on a light system and vice versa).
    private var schemeForcedAppearance = false

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        let settings = EditorPreferences.themeSettings
        fontSize = settings.baseSize
        appliedPaletteSerial = Palette.serial
        theme = Theme(settings: settings)
        syntaxBar = SyntaxBarView(theme: theme)
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
        column.roomBelow = true
        column.isEnabled = EditorPreferences.readableWidth
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        #if LUFTIG_SELFTEST
        LaunchProbe.mark("EditorViewController: stack built")
        #endif
        textView.delegate = self
        if let tc = stack.textView.textContainer { _ = provider.tables.setWidthLimit(tc.size.width - 2 * tc.lineFragmentPadding) }
        column.onContainerWidthChange = { [weak self] width in self?.tableWidthChanged(width) }
        provider.tables.renderTables = EditorPreferences.renderTables
        provider.tables.renderImages = EditorPreferences.renderImages
        provider.tables.revealed = [NSRange(location: 0, length: 0)]          // (the caret of a new document: a table at its very start shows its Markdown)
        provider.tables.onDecided = { [weak self] in self?.scheduleReconcile() }
        preferenceObserver = NotificationCenter.default.addObserver(forName: EditorPreferences.didChange, object: nil, queue: nil) { [weak self] _ in        // synchronous, on the posting (main) thread
            self?.preferencesDidChange()
        }
    }
    convenience init() { self.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let o = preferenceObserver { NotificationCenter.default.removeObserver(o) }
        chromeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        chromeTimer?.invalidate()
        // AppKit (macOS 27.0.1) keeps the NSTextStorage + NSLayoutManager (+ container) of a TextKit 1 stack alive after the view that
        // showed them is gone, in a fraction of the cases that varies with timing (8 % of the closed 1 MB documents, 47 % of 40 documents
        // closed together; reproduced in a bare AppKit program without any luftig code): the document's text, its attributes and the
        // glyph / layout data stay in memory for the rest of the session. Breaking the storage -> layout manager link releases everything
        // (bare program: 0 of 50 alive instead of 18-28; in luftig: 0 of 100 / 0 of 40).
        storage.removeLayoutManager(layoutManager)
    }

    override func loadView() {
        // banner / word count / [outline | text column: viewport over the syntax bar], top to bottom; a hidden element takes no space (NSStackView
        // detaches hidden views). The bar belongs to the text column, so it is always centred under the text; the outline runs on past it.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let textColumn = NSView()
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.addSubview(scrollView)
        textColumn.addSubview(syntaxBar)
        let middle = NSStackView(views: [outline, textColumn])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.alignment = .top
        middle.distribution = .fill
        middle.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [banner, wordCount, middle])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        let root = EditorRootView(frame: NSRect(origin: .zero, size: EditorViewController.initialSize))
        root.addSubview(stack)
        // the window padding: the frame between the window's edge and the panels - Padding.window on the sides, Padding.windowVertical (half) at the top and the bottom
        let w = padding.window
        windowPaddingConstraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: w), root.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: w),
        ]
        topPaddingConstraint = stack.topAnchor.constraint(equalTo: root.topAnchor, constant: padding.windowVertical)
        bottomPaddingConstraint = root.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: padding.windowVertical)
        // the vertical padding of the text viewport and of the outline: a margin OUTSIDE the scrolling, the same for both, so that scrolled text starts
        // exactly where the outline's first entry starts (the text container itself has no vertical inset)
        let v = padding.textInsetVertical
        barGapConstraint = syntaxBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: v)                 // the bar shown: the gap above it
        viewportBottomConstraint = textColumn.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: v)   // the bar hidden: the margin below the viewport
        verticalInsetConstraints = [
            outline.topAnchor.constraint(equalTo: middle.topAnchor, constant: v), middle.bottomAnchor.constraint(equalTo: outline.bottomAnchor, constant: v),
            scrollView.topAnchor.constraint(equalTo: textColumn.topAnchor, constant: v), barGapConstraint, viewportBottomConstraint,
        ]
        viewportBottomConstraint.isActive = false
        NSLayoutConstraint.activate(windowPaddingConstraints + [verticalInsetConstraints[0], verticalInsetConstraints[1], verticalInsetConstraints[2], barGapConstraint, topPaddingConstraint, bottomPaddingConstraint] + [
            banner.leadingAnchor.constraint(equalTo: stack.leadingAnchor), banner.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            wordCount.leadingAnchor.constraint(equalTo: stack.leadingAnchor), wordCount.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            middle.leadingAnchor.constraint(equalTo: stack.leadingAnchor), middle.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            textColumn.topAnchor.constraint(equalTo: middle.topAnchor), textColumn.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
            syntaxBar.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor), syntaxBar.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
            syntaxBar.bottomAnchor.constraint(equalTo: textColumn.bottomAnchor),
        ])
        view = root
        installChrome()
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
        // the outline and the count: right away for a small document (a 300 K-unit scan is well under a millisecond), after the first screen for a big one
        if storage.length <= EditorViewController.chromeSynchronousLimit { refreshChromeNow() } else { scheduleChromeRefresh(after: 0.15) }
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
        scheduleChromeRefresh()
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

    /// Return, Tab and Shift-Tab on a list item or quote line (ListEditing.swift; Settings > General > Continue lists on Return). Everything else, and
    /// these keys on any other line, inside a code block, or during an IME composition, is the text view's own.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard EditorPreferences.continueLists, textView.isEditable, !textView.hasMarkedText() else { return false }
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let change: TextChange?
        let name: String
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !caretIsInCodeBlock(selection) else { return false }
            change = ListContinuation.returnChange(in: text, selection: selection); name = "New List Item"
        case #selector(NSResponder.insertTab(_:)):
            guard !caretIsInCodeBlock(selection) else { return false }
            change = ListContinuation.indentChange(in: text, selection: selection, outdent: false); name = "Indent List Item"
        case #selector(NSResponder.insertBacktab(_:)):
            change = ListContinuation.indentChange(in: text, selection: selection, outdent: true); name = "Outdent List Item"
        default: return false
        }
        guard let change else { return false }
        apply(change, actionName: name)
        return true
    }

    /// A code block line (the `.luftigBlock` mark of the styled text; unstyled text counts as prose): a `- ` inside a fence is code, not a list.
    private func caretIsInCodeBlock(_ selection: NSRange) -> Bool {
        let at = min(selection.location, max(0, storage.length - 1))
        guard storage.length > 0, let mark = BlockMark.decode(storage.attribute(.luftigBlock, at: at, effectiveRange: nil)) else { return false }
        return mark.kind == .code
    }

    // MARK: preferences (fonts, size, line spacing, column, colour scheme): shared by all windows

    private func preferencesDidChange() {
        // A slider / stepper of the Settings window is being dragged and nobody can see this window (minimized, a background tab, another Space, the app hidden):
        // wait. The drag ends with one more broadcast (`EditorPreferences.endAdjusting`) that finds this editor out of date and brings it up to date.
        if EditorPreferences.isAdjusting && isHiddenFromUser { return }
        let settings = EditorPreferences.themeSettings
        let serial = Palette.serial
        if settings != theme.settings || serial != appliedPaletteSerial { rebuildTheme(settings: settings, paletteSerial: serial) }
        column.maxColumnWidth = EditorPreferences.columnWidth
        column.isEnabled = EditorPreferences.readableWidth
        applyChromeVisibility()
        applyChromeTheme()                   // (the panes' font, size and opacity are preferences of their own: cheap to re-apply on every change)
        applyTypewriterMode()
        if provider.tables.renderTables != EditorPreferences.renderTables || provider.tables.renderImages != EditorPreferences.renderImages {
            provider.tables.renderTables = EditorPreferences.renderTables
            provider.tables.renderImages = EditorPreferences.renderImages
            restyleKeepingViewport { $0.forgetStyled() }
        }
    }

    /// Restyle what `forget` drops, keeping the line at the top of the window where it was.
    func restyleKeepingViewport(_ forget: (LazyStyler) -> Void) {
        let anchor = ViewportAnchor.capture(in: textView)
        forget(styler)
        styler.styleVisible()
        if let anchor, anchor.restoreSameCharacter(in: textView) { styler.styleVisible() }
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
    private var tableRestyleScheduled = false
    /// The tables the selection touched when it was last set (TableRender.swift: they show their Markdown).
    var revealedExtents: [NSRange] = []
    private var reconcileScheduled = false
    private var imageRestyleScheduled = false

    /// New settings (size, fonts, line spacing, colour scheme): new Theme (new attribute caches), base attributes over the whole text (so NOT yet
    /// styled text changes too), restyle what is visible, keep the line at the top of the window where it was.
    private func rebuildTheme(settings: ThemeSettings, paletteSerial: Int) {
        themeRebuildCount += 1
        fontSize = settings.baseSize
        let anchor = ViewportAnchor.capture(in: textView)
        theme = Theme(settings: settings)
        provider.theme = theme
        if paletteSerial != appliedPaletteSerial {
            appliedPaletteSerial = paletteSerial
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
        applyChromeTheme()
    }

    /// The text column got wider or narrower: a table that fits only on one side of the change is aligned on one side only (TableAlignment.swift).
    /// Restyled after the layout pass that changed the width (not from inside it), keeping the line at the top of the window where it was.
    private func tableWidthChanged(_ width: CGFloat) {
        guard provider.tables.setWidthLimit(width), !tableRestyleScheduled else { return }
        tableRestyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableRestyleScheduled = false
            let anchor = ViewportAnchor.capture(in: self.textView)
            self.styler.forgetStyled()
            self.styler.styleVisible()
            if let anchor, anchor.restoreSameCharacter(in: self.textView) { self.styler.styleVisible() }
        }
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
    @objc func luftigToggleOutline(_ sender: Any?) { EditorPreferences.showOutline.toggle() }
    @objc func luftigToggleWordCount(_ sender: Any?) { EditorPreferences.showWordCount.toggle() }
    @objc func luftigToggleSyntaxBar(_ sender: Any?) { EditorPreferences.showSyntaxBar.toggle() }
    @objc func luftigToggleReadingTime(_ sender: Any?) { EditorPreferences.showReadingTime.toggle() }
    @objc func luftigInsertSyntax(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag, let e = SyntaxElement.element(menuTag: tag) else { return }
        insert(e)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(luftigInsertSyntax(_:)): return textView.isEditable && SyntaxElement.element(menuTag: item.tag) != nil
        case #selector(luftigOpenLink(_:)): return linkDestination(at: textView.selectedRange().location) != nil
        case #selector(luftigAlignTable(_:)): return textView.isEditable && caretIsInTable
        case #selector(luftigToggleTypewriterMode(_:)): item.state = EditorPreferences.typewriterMode ? .on : .off
        case #selector(luftigToggleTableGrids(_:)): item.state = EditorPreferences.renderTables ? .on : .off
        case #selector(luftigCopyAsHTML(_:)), #selector(luftigCopyAsRichText(_:)):
            item.title = (item.action == #selector(luftigCopyAsHTML(_:)) ? "Copy" : "Copy") + (textView.selectedRange().length > 0 ? "" : " All") + (item.action == #selector(luftigCopyAsHTML(_:)) ? " as HTML" : " as Rich Text")
            return storage.length > 0
        case #selector(luftigToggleReadableWidth(_:)): item.state = column.isEnabled ? .on : .off
        case #selector(luftigToggleSpellChecking(_:)): item.state = textView.isContinuousSpellCheckingEnabled ? .on : .off
        case #selector(luftigToggleOutline(_:)): item.title = EditorPreferences.showOutline ? "Hide Outline" : "Show Outline"
        case #selector(luftigToggleWordCount(_:)): item.title = EditorPreferences.showWordCount ? "Hide Word Count" : "Show Word Count"
        case #selector(luftigToggleSyntaxBar(_:)): item.title = EditorPreferences.showSyntaxBar ? "Hide Syntax Bar" : "Show Syntax Bar"
        case #selector(luftigToggleReadingTime(_:)): item.title = EditorPreferences.showReadingTime ? "Hide Reading Time" : "Show Reading Time"
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

// MARK: - the elements around the text (outline, word count, syntax bar)

extension EditorViewController {

    /// Wires the three elements (called once from `loadView`).
    func installChrome() {
        applyChromeTheme()
        applyChromeVisibility()
        outline.onSelect = { [weak self] e in self?.jump(toOutlineEntry: e) }
        syntaxBar.onInsert = { [weak self] e in self?.insert(e) }
        editorTextView.onCommandClick = { [weak self] index in self?.followLink(at: index) ?? false }
        editorTextView.onPlainClick = { [weak self] point in self?.clickIntoTable(at: point) ?? false }
        editorTextView.onDropImages = { [weak self] urls, index in self?.insertImageLinks(urls, at: index) ?? false }
        let nc = NotificationCenter.default
        // images: a size became known (a web image arrived) -> restyle; pixels were decoded -> redraw; the app is active again -> look at the files again
        chromeObservers.append(nc.addObserver(forName: ImageStore.didChange, object: nil, queue: nil) { [weak self] note in
            guard let self, self.provider.tables.renderImages != .never else { return }
            if note.userInfo?["kind"] as? String == "size" { self.scheduleImageRestyle() } else { self.textView.needsDisplay = true }
        })
        chromeObservers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, self.provider.tables.renderImages != .never, self.provider.tables.sawTables else { return }
            ImageStore.shared.forgetFiles()
            self.scheduleImageRestyle()
        })
        // a text change: recompute the outline and the count a little later (coalesced: typing never recomputes per keystroke)
        chromeObservers.append(nc.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [weak self] _ in self?.scheduleChromeRefresh() })
        chromeObservers.append(nc.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: nil) { [weak self] _ in self?.tableSelectionChanged(); self?.updateChromeSelection(); self?.typewriterSelectionChanged() })
        chromeObservers.append(nc.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [weak self] _ in self?.typewriterTextChanged() })
        applyTypewriterMode()
        chromeObservers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in self?.updateCurrentOutlineEntry() })
    }

    func applyChromeTheme() {
        outline.wrapsHeadings = EditorPreferences.outlineWraps
        let p = Padding(points: EditorPreferences.padding)
        for c in windowPaddingConstraints { c.constant = p.window }
        for c in verticalInsetConstraints { c.constant = p.textInsetVertical }
        topPaddingConstraint.constant = p.windowVertical
        bottomPaddingConstraint.constant = p.windowVertical
        outline.padding = p; wordCount.padding = p; syntaxBar.padding = p
        outline.lineHeightFactor = EditorPreferences.outlineLineHeight
        column.minInset = p.textInsetHorizontal; column.update()
        outline.apply(theme: theme); wordCount.apply(theme: theme); syntaxBar.apply(theme: theme)
    }
    /// The padding in effect (tests).
    var padding: Padding { Padding(points: EditorPreferences.padding) }

    /// The View menu's switches, shared by every window (the word count's row holds the count, the reading time, or both).
    func applyChromeVisibility() {
        let o = EditorPreferences.showOutline, w = EditorPreferences.showWordCount || EditorPreferences.showReadingTime, s = EditorPreferences.showSyntaxBar
        if outline.isHidden == o { outline.isHidden = !o }
        if wordCount.isHidden == w { wordCount.isHidden = !w }
        if w { updateChromeSelection() }                      // (which of the two is shown may have changed)
        if syntaxBar.isHidden == s { syntaxBar.isHidden = !s }
        // the bar shown: the viewport ends a gap above it; hidden (NSStackView would detach it, but it is a plain subview here): the margin below the viewport
        syntaxBar.isHidden = !s
        barGapConstraint?.isActive = s
        viewportBottomConstraint?.isActive = !s
        // an element shown without data for the current text (hidden at open, or hidden during the last edit) is computed now
        if (o && !chromeOutlineValid) || (w && !chromeWordsValid) { scheduleChromeRefresh(after: 0) }
    }

    /// The coalescing delay after an edit: a little longer for very large documents (their scan takes longer and the user is typing).
    var chromeRefreshDelay: Double { storage.length > 4_000_000 ? 1.0 : 0.3 }
    /// Up to this many UTF-16 units the first scan runs synchronously at open (measured: 300 K units in ~0.5 ms for both scans together).
    static let chromeSynchronousLimit = 300_000

    /// Recompute now, in one go (open of a small document, tests).
    func refreshChromeNow() {
        chromeGeneration += 1
        chromeOutlineValid = false; chromeWordsValid = false
        chromeTimer?.invalidate(); chromeTimer = nil
        guard !outline.isHidden || !wordCount.isHidden else { chromeScanner = nil; chromeCounter = nil; return }
        chromeScanner = outline.isHidden ? nil : OutlineScanner()
        chromeCounter = wordCount.isHidden ? nil : WordCounter()
        chromeStep(generation: chromeGeneration, budget: storage.length + 1)      // one step that covers the whole text
    }

    /// Recompute the outline and the word count `after` seconds (default: the coalescing delay). A new request restarts the clock; a scan in progress
    /// is abandoned (the text changed under it).
    func scheduleChromeRefresh(after: Double? = nil) {
        chromeGeneration += 1
        chromeScanner = nil; chromeCounter = nil
        chromeOutlineValid = false; chromeWordsValid = false
        guard !outline.isHidden || !wordCount.isHidden else { return }
        chromeTimer?.invalidate()
        let t = Timer(timeInterval: after ?? chromeRefreshDelay, repeats: false) { [weak self] _ in self?.startChromeScan() }
        RunLoop.main.add(t, forMode: .common)
        chromeTimer = t
    }

    private func startChromeScan() {
        chromeTimer = nil
        chromeScanner = outline.isHidden ? nil : OutlineScanner()
        chromeCounter = wordCount.isHidden ? nil : WordCounter()
        chromeStep(generation: chromeGeneration)
    }

    /// One bounded step of the scans (about a millisecond for a megabyte), then the next one on the next run-loop turn until both are finished.
    private func chromeStep(generation: Int, budget: Int = 1_000_000) {
        guard generation == chromeGeneration, chromeScanner != nil || chromeCounter != nil else { return }
        let text = storage.string as NSString
        if chromeScanner != nil, chromeScanner!.scan(text, budget: budget) == false { scheduleChromeStep(generation: generation); return }
        if chromeCounter != nil, chromeCounter!.scan(text, budget: budget) == false { scheduleChromeStep(generation: generation); return }
        // done
        chromeDataGeneration = generation
        chromeRefreshCount += 1
        if let s = chromeScanner { outline.entries = s.entries; chromeOutlineValid = true; updateCurrentOutlineEntry() }
        if let c = chromeCounter { chromeWordTotal = c.count; chromeWordsValid = true; updateChromeSelection() }
        chromeScanner = nil; chromeCounter = nil
    }

    private func scheduleChromeStep(generation: Int) {
        guard !chromeStepScheduled else { return }
        chromeStepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chromeStepScheduled = false
            self.chromeStep(generation: generation)
        }
    }

    /// True while the outline / word count are being recomputed (tests wait for it).
    var chromeRefreshPending: Bool { chromeTimer != nil || chromeScanner != nil || chromeCounter != nil }

    /// The word count label: the document's words, and the selection's when there is one (counted right away for a selection up to 200 000 units).
    func updateChromeSelection() {
        guard !wordCount.isHidden else { return }
        let sel = textView.selectedRange()
        var selected: Int?
        if sel.length > 0, sel.length <= 200_000, EditorPreferences.showWordCount { selected = WordCounter.words(in: storage.string as NSString, range: sel) }
        wordCount.text = WordCountView.label(total: chromeWordTotal, selected: selected, words: EditorPreferences.showWordCount, readingTime: EditorPreferences.showReadingTime)
    }

    /// The outline entry of the section at the top of the window.
    func updateCurrentOutlineEntry() {
        guard !outline.isHidden, !outline.entries.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer, storage.length > 0 else { return }
        // the character just under the top edge plus the text inset: a heading that sits at the top of the window (where a click puts it) is current
        let origin = textView.textContainerOrigin
        let probe = NSPoint(x: 0, y: textView.visibleRect.minY - origin.y + 2)
        let top = lm.characterIndexForGlyph(at: lm.glyphIndex(for: probe, in: tc, fractionOfDistanceThroughGlyph: nil))
        // the last heading at or before `top` (binary search: entries are in document order)
        var lo = 0, hi = outline.entries.count
        while lo < hi { let mid = (lo + hi) / 2; if outline.entries[mid].location <= top { lo = mid + 1 } else { hi = mid } }
        outline.currentIndex = lo > 0 ? lo - 1 : nil
    }

    /// Up to this many UTF-16 units above the target a jump styles and lays out EVERYTHING above it first, so that it lands exactly (the non-contiguous
    /// layout only estimates the height of text it has not laid out, pitfall 27: measured, a heading 80 lines down was placed at 192 pt instead of ~1900).
    /// Beyond it the jump lands on the estimate and the display refines it (the cost of an exact jump is a layout pass over the text above).
    static let exactJumpLimit = 300_000

    /// A click on an outline entry (or an anchor link): the heading line at the top of the window, the caret on it.
    func jump(toOutlineEntry e: OutlineEntry) {
        let length = storage.length
        guard e.location <= length else { return }
        let loc = min(e.location, max(0, length - 1))
        let exact = loc <= EditorViewController.exactJumpLimit
        if exact { styler.styleAll(upTo: min(length, loc + 2000)) } else { styler.prestyle(aroundCharacter: loc) }
        if let lm = textView.layoutManager, let tc = textView.textContainer, length > 0 {
            if exact { lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, loc + 2000))) }
            else { lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: min(2000, length - loc))) }
            textView.sizeToFit()                      // the frame follows the layout now (AppKit does it at the end of a layout pass; a jump cannot wait for one)
            let glyph = lm.glyphIndexForCharacter(at: loc)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = max(0, line.minY + textView.textContainerOrigin.y)
            let clip = scrollView.contentView
            let maxY = max(0, textView.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(y, maxY)))
            scrollView.reflectScrolledClipView(clip)
            _ = tc
        }
        textView.setSelectedRange(NSRange(location: e.location, length: 0))
        styler.styleVisible()
        view.window?.makeFirstResponder(textView)
    }

    /// A click on the syntax bar (or its menu item / shortcut): the edit goes through the text view's own change protocol (undoable, marks the document
    /// dirty, restyled by the styler).
    func insert(_ element: SyntaxElement) {
        let tv = textView
        guard tv.isEditable else { return }
        let change = SyntaxInsertion.change(for: element, in: storage.string as NSString, selection: tv.selectedRange())
        apply(change, actionName: element.name.components(separatedBy: " (").first ?? element.name)
        view.window?.makeFirstResponder(tv)
    }

    /// One computed edit (syntax bar, list continuation) through NSTextView's change protocol, as one undo step named `actionName`.
    func apply(_ change: TextChange, actionName: String) {
        let tv = textView
        guard tv.isEditable else { return }
        // outside an event (a test, a script) no undo group is open: NSTextView's change protocol registers undo and insists on one
        let um = tv.undoManager
        let opensGroup = (um?.groupingLevel ?? 1) == 0
        if opensGroup { um?.beginUndoGrouping() }
        defer { if opensGroup { um?.endUndoGrouping() } }
        tv.breakUndoCoalescing()                                       // typed text before it stays a step of its own
        guard tv.shouldChangeText(in: change.range, replacementString: change.replacement) else { return }
        um?.setActionName(actionName)
        storage.replaceCharacters(in: change.range, with: change.replacement)
        tv.didChangeText()
        let sel = NSIntersectionRange(change.selection, NSRange(location: 0, length: storage.length))
        tv.setSelectedRange(sel.length == 0 && change.selection.location <= storage.length ? NSRange(location: change.selection.location, length: 0) : sel)
        tv.scrollRangeToVisible(tv.selectedRange())
    }
}

// MARK: - Format > Align Table (TableAlignment.swift)

extension EditorViewController {

    @objc func luftigToggleTableGrids(_ sender: Any?) { EditorPreferences.renderTables.toggle() }

    /// The selection moved: a table it now touches shows its Markdown, a table it left is drawn as a grid again (TableRender.swift). Only the tables at the
    /// ends of the old and the new selection can change, plus whatever a selected range covers.
    func tableSelectionChanged() {
        let tables = provider.tables
        let selection = textView.selectedRanges.map { $0.rangeValue }
        let old = tables.revealed
        tables.revealed = selection
        guard tables.drawsBlocks, tables.sawTables else { return }
        defer { reconcileTables() }
        guard old != selection else { return }
        let length = storage.length
        if (old + selection).contains(where: { $0.length > 0 }) { textView.needsDisplay = true }       // (the tint of drawn rows a selection passes over)
        func extents(_ ranges: [NSRange]) -> [NSRange] {
            var out: [NSRange] = []
            for r in ranges {
                for loc in Set([r.location, NSMaxRange(r)]) where loc <= length {
                    if let t = tableExtent(at: loc), !out.contains(t) { out.append(t) }
                }
            }
            return out
        }
        // the tables of the old selection were found when it was made (typing moves the selection, so they are as current as the text)
        var was = revealedExtents
        for t in extents(old) where !was.contains(t) { was.append(t) }           // (also a table shown by an edit rather than by a selection change)
        let now = extents(selection)
        revealedExtents = now
        guard was != now else { return }           // the caret moved within one table, or between lines outside tables
        restyleKeepingViewport { styler in
            for r in was + now { styler.forgetStyled(NSIntersectionRange(r, NSRange(location: 0, length: length))) }
        }
    }

    /// The tables styled since the last look, against the selection as it is now: an edit is styled before the text view moves the selection (a pasted
    /// or typed table, an external change), so one may be drawn although the caret is in it, or shown as Markdown although the caret has gone.
    func reconcileTables() {
        let tables = provider.tables
        let decided = tables.takeDecided()
        guard tables.drawsBlocks, !decided.isEmpty else { return }
        let length = storage.length
        let stale = decided.filter { NSMaxRange($0.range) <= length && $0.drawn == tables.isRevealed($0.range) }
        guard !stale.isEmpty else { return }
        restyleKeepingViewport { styler in for d in stale { styler.forgetStyled(d.range) } }
        _ = tables.takeDecided()                 // (just restyled with this selection)
    }
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in self?.reconcileScheduled = false; self?.reconcileTables() }
    }

    /// The document's file moved or got a name: relative image paths start from its folder.
    func documentURLDidChange(_ url: URL?) {
        let folder = url?.deletingLastPathComponent()
        guard folder != provider.tables.baseURL else { return }
        provider.tables.baseURL = folder
        if provider.tables.renderImages != .never, storage.length > 0 { restyleKeepingViewport { $0.forgetStyled() } }
    }

    private func scheduleImageRestyle() {
        guard !imageRestyleScheduled else { return }
        imageRestyleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageRestyleScheduled = false
            self.restyleKeepingViewport { $0.forgetStyled() }
        }
    }

    /// Image files (or web images) dropped at `index`: one `![name](path)` line each (ImageDrop), as one undoable edit; the caret after them.
    func insertImageLinks(_ urls: [URL], at index: Int) -> Bool {
        guard textView.isEditable, !urls.isEmpty else { return false }
        let text = storage.string as NSString
        let at = min(max(0, index), text.length)
        var insert = urls.map { ImageDrop.markdown(for: $0, documentFolder: provider.tables.baseURL) }.joined(separator: "\n")
        if at > 0, ![0x0A, 0x0D].contains(text.character(at: at - 1)) { insert = "\n" + insert }      // on lines of their own
        let breakFollows = at < text.length && [0x0A, 0x0D].contains(text.character(at: at))
        if !breakFollows { insert += "\n" }
        let caret = at + (insert as NSString).length + (breakFollows ? 1 : 0)                          // (after the line: the image is drawn at once)
        textView.window?.makeFirstResponder(textView)
        apply(TextChange(range: NSRange(location: at, length: 0), replacement: insert, selection: NSRange(location: caret, length: 0)), actionName: "Insert Image")
        return true
    }

    /// The characters of the table that holds `location` (a caret right after its last character included), or nil (also for a table over the size
    /// bound: it is never drawn, and looking for its ends would cost every keystroke in it). A line that holds only an image counts as a block too.
    func tableExtent(at location: Int) -> NSRange? {
        let length = storage.length
        guard length > 0 else { return nil }
        var candidates = [min(location, length - 1)]
        // the character before: a caret right after the table's last character; not a line break (the caret is then on the line after the table, which
        // TableAligner.isRevealed does not count)
        if location > 0, location - 1 < length, ![0x0A, 0x0D].contains((storage.string as NSString).character(at: location - 1)) { candidates.append(location - 1) }
        for loc in candidates {
            if let t = table(at: loc, limit: TableAligner.maxTableUnits), let first = t.lines.first, let last = t.lines.last {
                return NSRange(location: first.start, length: last.next - first.start)
            }
            // an image line: cheap, from the text (`![` ... `)` and nothing else; a false hit only restyles a line)
            let text = storage.string as NSString
            let line = text.lineRange(for: NSRange(location: loc, length: 0))
            let s = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("![") && s.hasSuffix(")") { return line }
        }
        return nil
    }

    /// A click into a table drawn as a grid: the caret goes to the end of the clicked cell's text (which shows the table's Markdown).
    func clickIntoTable(at point: NSPoint) -> Bool {
        guard provider.tables.drawsBlocks, let lm = textView.layoutManager, let tc = textView.textContainer, storage.length > 0 else { return false }
        let o = textView.textContainerOrigin
        let local = NSPoint(x: point.x - o.x, y: point.y - o.y)
        let glyph = lm.glyphIndex(for: local, in: tc)
        guard glyph < lm.numberOfGlyphs else { return false }
        var fragGlyphs = NSRange(location: 0, length: 0)
        let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragGlyphs)
        guard frag.contains(local) || (local.y >= frag.minY && local.y < frag.maxY) else { return false }
        // the row is the line whose line break this fragment holds (hidden glyphs at the start of the NEXT row can belong to it too)
        let text = storage.string as NSString
        let chars = lm.characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
        var char = max(chars.location, NSMaxRange(chars) - 1)
        for c in chars.location..<NSMaxRange(chars) where text.character(at: c) == 0x0A || text.character(at: c) == 0x0D { char = c; break }
        if char < storage.length, storage.attribute(.luftigImage, at: char, effectiveRange: nil) != nil {
            // a drawn image: the caret to the end of its line (which shows its Markdown)
            let line = text.lineRange(for: NSRange(location: char, length: 0))
            var end = NSMaxRange(line)
            while end > line.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: end, length: 0))
            return true
        }
        guard char < storage.length, let row = storage.attribute(.luftigTableRow, at: char, effectiveRange: nil) as? TableRenderRow else { return false }
        let line = text.lineRange(for: NSRange(location: char, length: 0))
        let indent = (storage.attribute(.paragraphStyle, at: char, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        let x = local.x - frag.minX - indent
        var k = row.edges.count - 2
        while k > 0 && x < row.edges[k] { k -= 1 }
        let offset = row.cellEnds.isEmpty ? 0 : row.cellEnds[min(max(0, k), row.cellEnds.count - 1)]
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: min(line.location + offset, NSMaxRange(line)), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// The caret's line is a table row (the lexer's answer, not the styling's: a table in a quote has no panel mark).
    var caretIsInTable: Bool {
        let text = storage.string as NSString
        guard text.length > 0 else { return false }
        let line = text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length - 1), length: 0))
        let r = provider.styler.styleRuns(in: line, of: text)
        return r.runs.contains { $0.style.contains(.table) && NSIntersectionRange($0.range, line).length > 0 }
    }

    /// The lines of the table at `location` and the lexer runs that cover them (any size: an explicit command, not styling). nil: no table there.
    func table(at location: Int, limit: Int = Int.max / 4) -> (lines: [TableAligner.Line], runs: [MDRun])? {
        let text = storage.string as NSString
        guard text.length > 0 else { return nil }
        let loc = min(location, text.length - 1)
        let line = text.lineRange(for: NSRange(location: loc, length: 0))
        let lex: (NSRange) -> MDResult = { [provider] in provider.styler.styleRuns(in: $0, of: text) }
        let here = lex(line)
        guard let mine = TableAligner.lines(here.runs, text: text, in: here.range).first(where: { $0.start <= loc && ($0.next > loc || $0.next == text.length) }),
              mine.isTable else { return nil }
        let start = mine.isHeader ? mine.start : (TableExtent.start(above: mine.start, text: text, limit: limit, lex: lex) ?? mine.start)
        let end = mine.next >= text.length ? text.length : (TableExtent.end(below: mine.next, text: text, limit: limit, lex: lex) ?? mine.next)
        let r = lex(NSRange(location: start, length: max(1, end - start)))
        let lines = TableAligner.lines(r.runs, text: text, in: r.range).filter { $0.start >= start && $0.start < max(end, start + 1) && $0.isTable }
        guard let first = lines.first, first.isHeader else { return nil }
        return (lines, r.runs)
    }

    @objc func luftigAlignTable(_ sender: Any?) {
        guard textView.isEditable, let t = table(at: textView.selectedRange().location) else { NSSound.beep(); return }
        guard let change = TableFormatter.change(text: storage.string as NSString, runs: t.runs, lines: t.lines, caret: textView.selectedRange().location) else { return }
        apply(change, actionName: "Align Table")
    }
}

// MARK: - links (⌘-click, Edit > Open Link; LinkFollowing.swift)

extension EditorViewController {

    /// What opens a web URL or a file luftig does not edit itself (NSWorkspace; the self-test replaces it to see what would open).
    nonisolated(unsafe) static var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// What opens a Markdown / text file as a document (the self-test replaces it as well).
    nonisolated(unsafe) static var openDocument: (URL, _ anchor: String?) -> Void = { url, anchor in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
            if let anchor, let host = (doc as? MarkdownDocument)?.host as? EditorViewController { host.jump(toAnchor: anchor) }
        }
    }

    /// The destination of the link at `index`, as written (nil: no link there).
    func linkDestination(at index: Int) -> String? {
        let text = storage.string as NSString
        guard text.length > 0, index <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(index, text.length - 1), length: 0))
        let runs = provider.styler.styleRuns(in: line, of: text).runs
        return LinkFollowing.destination(at: index, in: text, runs: runs)
    }

    /// The target of the link at `index`.
    func linkTarget(at index: Int) -> LinkTarget? {
        guard let d = linkDestination(at: index) else { return nil }
        return LinkFollowing.target(for: d, base: document?.fileURL?.deletingLastPathComponent())
    }

    /// Follow the link at `index`: a web URL in the browser, a Markdown / text file in luftig (at its anchor), any other file in its application, an
    /// anchor in this document by scrolling to the heading. Returns false when there is no link there (the click is an ordinary click then).
    @discardableResult
    func followLink(at index: Int) -> Bool {
        guard let target = linkTarget(at: index) else { return false }
        switch target {
        case .web(let url):
            EditorViewController.openExternally(url)
        case .anchor(let a):
            if !jump(toAnchor: a) { NSSound.beep() }
        case .file(let url, let anchor):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { NSSound.beep(); return true }
            if !isDir.boolValue, LinkFollowing.opensAsDocument(url) {
                if document?.fileURL?.standardizedFileURL == url { if let anchor { _ = jump(toAnchor: anchor) } }
                else { EditorViewController.openDocument(url, anchor) }
            } else {
                EditorViewController.openExternally(url)
            }
        }
        return true
    }

    /// The heading an anchor names at the top of the window (the outline's jump). False when no heading matches.
    @discardableResult
    func jump(toAnchor anchor: String) -> Bool {
        let entries = outline.entries.isEmpty || !chromeOutlineValid ? OutlineScanner.headings(in: storage.string as NSString) : outline.entries
        guard let e = LinkFollowing.entry(for: anchor, in: entries) else { return false }
        jump(toOutlineEntry: e)
        return true
    }

    @objc func luftigOpenLink(_ sender: Any?) {
        if !followLink(at: textView.selectedRange().location) { NSSound.beep() }
    }
}

// MARK: - Typewriter Mode (View menu; EditorPreferences.typewriterMode)

extension EditorViewController {

    @objc func luftigToggleTypewriterMode(_ sender: Any?) { EditorPreferences.typewriterMode.toggle() }

    /// The switch, from the preferences (every window follows): the column's typewriter inset, and the caret's line to the middle.
    func applyTypewriterMode() {
        let typewriter = EditorPreferences.typewriterMode
        if column.typewriter != typewriter {
            column.typewriter = typewriter
            column.typewriterLineHeight = theme.bodyLineHeight
            column.update()
        } else if typewriter, column.typewriterLineHeight != theme.bodyLineHeight {
            column.typewriterLineHeight = theme.bodyLineHeight
            column.update()
        }
        if typewriter { centerCaretLine() }
    }

    func typewriterSelectionChanged() { if EditorPreferences.typewriterMode { centerCaretLine() } }
    func typewriterTextChanged() { if EditorPreferences.typewriterMode { centerCaretLine() } }

    /// The line fragment (container coordinates) that holds the caret at `location`; the extra line after a trailing line break for a caret at the very end.
    func caretLineRect(at location: Int) -> NSRect? {
        guard let lm = textView.layoutManager, storage.length > 0 else { return nil }
        let length = storage.length
        if location >= length {
            let last = storage.string.utf16.last ?? 0
            if last == 0x0A || last == 0x0D { lm.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1)); if lm.extraLineFragmentRect.height > 0 { return lm.extraLineFragmentRect } }
        }
        let loc = min(location, length - 1)
        lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: 1))
        let glyph = lm.glyphIndexForCharacter(at: loc)
        guard glyph < lm.numberOfGlyphs else { return nil }
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Typewriter Mode: the line that holds the caret in the middle of the viewport (the column's inset gives the first and the last line room to get there).
    /// The non-contiguous layout only estimates the height of text it has not laid out, so the line's y settles in a few passes (pitfall 27: like ViewportAnchor).
    func centerCaretLine() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer, storage.length > 0, !textView.hasMarkedText() else { return }
        let clip = scrollView.contentView
        for _ in 0..<4 {
            guard let line = caretLineRect(at: textView.selectedRange().location) else { return }
            textView.sizeToFit()
            let target = (line.midY + textView.textContainerOrigin.y - clip.bounds.height / 2).rounded()
            let maxY = max(0, textView.frame.height - clip.bounds.height)
            let y = max(0, min(target, maxY))
            if abs(clip.bounds.origin.y - y) < 0.5 { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            styler.styleVisible()
            lm.ensureLayout(forBoundingRect: textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y), in: tc)
        }
    }
}

// MARK: - HTML (Edit > Copy as HTML / Copy as Rich Text; MarkdownHTML.swift)

extension EditorViewController {

    /// The HTML body of the selection (whole lines) or, without a selection, of the whole document.
    func htmlOfSelectionOrAll() -> String {
        let text = storage.string as NSString
        guard text.length > 0 else { return "" }
        let sel = textView.selectedRange()
        let runs = provider.styler.lexAll(text)
        return MarkdownHTML.html(text, runs: runs, range: sel.length > 0 ? sel : nil)
    }

    /// The HTML (as text and as HTML) on `pasteboard`.
    func copyAsHTML(to pasteboard: NSPasteboard) {
        let html = htmlOfSelectionOrAll()
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(html, forType: .string)
    }

    /// Rich text (RTF, made from the HTML by AppKit), the HTML and the plain words on `pasteboard`.
    func copyAsRichText(to pasteboard: NSPasteboard) {
        let html = htmlOfSelectionOrAll()
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.html, .string]
        var rtf: Data?
        var plain = ""
        if let data = html.data(using: .utf8), let attributed = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
            rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            plain = attributed.string
            if rtf != nil { types.insert(.rtf, at: 0) }
        }
        pasteboard.declareTypes(types, owner: nil)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain.isEmpty ? html : plain, forType: .string)
    }

    @objc func luftigCopyAsHTML(_ sender: Any?) { copyAsHTML(to: .general) }
    @objc func luftigCopyAsRichText(_ sender: Any?) { copyAsRichText(to: .general) }
}
