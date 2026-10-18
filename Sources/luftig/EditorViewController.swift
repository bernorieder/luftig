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
    /// How many times the outline / word count were recomputed (tests).
    var chromeRefreshCount = 0

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
        // banner / word count / [outline | text] / syntax bar, top to bottom; a hidden element takes no space (NSStackView detaches hidden views)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let middle = NSStackView(views: [outline, scrollView])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.alignment = .top
        middle.distribution = .fill
        middle.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [banner, wordCount, middle, syntaxBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        let root = EditorRootView(frame: NSRect(origin: .zero, size: EditorViewController.initialSize))
        root.addSubview(stack)
        // the window padding: the frame between the window's edge and the panels (Padding.window), on all four sides
        let w = padding.window
        windowPaddingConstraints = [
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: w), root.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: w),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: w), root.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: w),
        ]
        NSLayoutConstraint.activate(windowPaddingConstraints + [
            banner.leadingAnchor.constraint(equalTo: stack.leadingAnchor), banner.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            wordCount.leadingAnchor.constraint(equalTo: stack.leadingAnchor), wordCount.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            middle.leadingAnchor.constraint(equalTo: stack.leadingAnchor), middle.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            syntaxBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor), syntaxBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            outline.topAnchor.constraint(equalTo: middle.topAnchor), outline.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: middle.topAnchor), scrollView.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
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
        applyChromeVisibility()
        applyChromeTheme()                   // (the panes' font, size and opacity are preferences of their own: cheap to re-apply on every change)
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
        applyChromeTheme()
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(luftigToggleReadableWidth(_:)): item.state = column.isEnabled ? .on : .off
        case #selector(luftigToggleSpellChecking(_:)): item.state = textView.isContinuousSpellCheckingEnabled ? .on : .off
        case #selector(luftigToggleOutline(_:)): item.title = EditorPreferences.showOutline ? "Hide Outline" : "Show Outline"
        case #selector(luftigToggleWordCount(_:)): item.title = EditorPreferences.showWordCount ? "Hide Word Count" : "Show Word Count"
        case #selector(luftigToggleSyntaxBar(_:)): item.title = EditorPreferences.showSyntaxBar ? "Hide Syntax Bar" : "Show Syntax Bar"
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
        let nc = NotificationCenter.default
        // a text change: recompute the outline and the count a little later (coalesced: typing never recomputes per keystroke)
        chromeObservers.append(nc.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { [weak self] _ in self?.scheduleChromeRefresh() })
        chromeObservers.append(nc.addObserver(forName: NSTextView.didChangeSelectionNotification, object: textView, queue: nil) { [weak self] _ in self?.updateChromeSelection() })
        chromeObservers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in self?.updateCurrentOutlineEntry() })
    }

    func applyChromeTheme() {
        outline.wrapsHeadings = EditorPreferences.outlineWraps
        let p = Padding(factor: EditorPreferences.padding)
        for c in windowPaddingConstraints { c.constant = p.window }
        outline.padding = p; wordCount.padding = p; syntaxBar.padding = p
        outline.lineHeightFactor = EditorPreferences.outlineLineHeight
        column.minInset = p.textInsetHorizontal; column.verticalInset = p.textInsetVertical; column.trailingExtra = p.textTrailingExtra; column.update()
        outline.apply(theme: theme); wordCount.apply(theme: theme); syntaxBar.apply(theme: theme)
    }
    /// The padding in effect (tests).
    var padding: Padding { Padding(factor: EditorPreferences.padding) }

    /// The View menu's three switches, shared by every window.
    func applyChromeVisibility() {
        let o = EditorPreferences.showOutline, w = EditorPreferences.showWordCount, s = EditorPreferences.showSyntaxBar
        let wasStale = (outline.isHidden && o) || (wordCount.isHidden && w)
        if outline.isHidden == o { outline.isHidden = !o }
        if wordCount.isHidden == w { wordCount.isHidden = !w }
        if syntaxBar.isHidden == s { syntaxBar.isHidden = !s }
        if wasStale && chromeDataGeneration != chromeGeneration { scheduleChromeRefresh(after: 0) }
    }

    /// The coalescing delay after an edit: a little longer for very large documents (their scan takes longer and the user is typing).
    var chromeRefreshDelay: Double { storage.length > 4_000_000 ? 1.0 : 0.3 }
    /// Up to this many UTF-16 units the first scan runs synchronously at open (measured: 300 K units in ~0.5 ms for both scans together).
    static let chromeSynchronousLimit = 300_000

    /// Recompute now, in one go (open of a small document, tests).
    func refreshChromeNow() {
        chromeGeneration += 1
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
        if let s = chromeScanner { outline.entries = s.entries; updateCurrentOutlineEntry() }
        if let c = chromeCounter { chromeWordTotal = c.count; updateChromeSelection() }
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
        if sel.length > 0, sel.length <= 200_000 { selected = WordCounter.words(in: storage.string as NSString, range: sel) }
        wordCount.text = WordCountView.label(total: chromeWordTotal, selected: selected)
    }

    /// The outline entry of the section at the top of the window.
    func updateCurrentOutlineEntry() {
        guard !outline.isHidden, !outline.entries.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer, storage.length > 0 else { return }
        // the character just under the top edge plus the text inset: a heading that sits at the top of the window (where a click puts it) is current
        let origin = textView.textContainerOrigin
        let probe = NSPoint(x: 0, y: textView.visibleRect.minY - origin.y + column.verticalInset + 2)
        let top = lm.characterIndexForGlyph(at: lm.glyphIndex(for: probe, in: tc, fractionOfDistanceThroughGlyph: nil))
        // the last heading at or before `top` (binary search: entries are in document order)
        var lo = 0, hi = outline.entries.count
        while lo < hi { let mid = (lo + hi) / 2; if outline.entries[mid].location <= top { lo = mid + 1 } else { hi = mid } }
        outline.currentIndex = lo > 0 ? lo - 1 : nil
    }

    /// A click on an outline entry: the heading line at the top of the window, the caret on it.
    func jump(toOutlineEntry e: OutlineEntry) {
        let length = storage.length
        guard e.location <= length else { return }
        let loc = min(e.location, max(0, length - 1))
        styler.prestyle(aroundCharacter: loc)
        if let lm = textView.layoutManager, let tc = textView.textContainer, length > 0 {
            lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: min(2000, length - loc)))
            let glyph = lm.glyphIndexForCharacter(at: loc)
            let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = max(0, line.minY + textView.textContainerOrigin.y - column.verticalInset)
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

    /// A click on the syntax bar: the edit goes through the text view's own change protocol (undoable, marks the document dirty, restyled by the styler).
    func insert(_ element: SyntaxElement) {
        let tv = textView
        guard tv.isEditable else { return }
        let change = SyntaxInsertion.change(for: element, in: storage.string as NSString, selection: tv.selectedRange())
        // outside an event (a test, a script) no undo group is open: NSTextView's change protocol registers undo and insists on one
        let um = tv.undoManager
        let opensGroup = (um?.groupingLevel ?? 1) == 0
        if opensGroup { um?.beginUndoGrouping() }
        defer { if opensGroup { um?.endUndoGrouping() } }
        guard tv.shouldChangeText(in: change.range, replacementString: change.replacement) else { return }
        um?.setActionName(element.name.components(separatedBy: " (").first ?? element.name)
        storage.replaceCharacters(in: change.range, with: change.replacement)
        tv.didChangeText()
        let sel = NSIntersectionRange(change.selection, NSRange(location: 0, length: storage.length))
        tv.setSelectedRange(sel.length == 0 && change.selection.location <= storage.length ? NSRange(location: change.selection.location, length: 0) : sel)
        tv.scrollRangeToVisible(tv.selectedRange())
        view.window?.makeFirstResponder(tv)
    }
}
