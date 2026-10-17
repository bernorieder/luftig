// EditorWindowController.swift
//
// REFERENCE implementation of the editor side (window controller + view controller + banner strip) so that the
// document layer can be exercised end to end. The real Scribe replaces `EditorViewController`'s text view and
// highlighter; the contract with the document is only `EditorHost` (+ `document.editorWillChangeText()`).
//
// Plain TextKit 1 stack on purpose (explicit NSTextStorage/NSLayoutManager/NSTextContainer): non-contiguous layout is
// the proven fast path for 10 MB documents.

import AppKit

final class EditorWindowController: NSWindowController, NSWindowDelegate {

    var editorHost: EditorHost? { (contentViewController as? EditorViewController) }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: true)
        w.minSize = NSSize(width: 360, height: 240)
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        // Tabbing: .automatic = follow the system setting ("Prefer tabs: in full screen only" by default).
        // All Scribe windows share one tabbing identifier so "Merge All Windows" / drag-to-tab work.
        w.tabbingIdentifier = NSWindow.TabbingIdentifier("local.scribe.document")
        w.tabbingMode = .automatic
        super.init(window: w)
        shouldCascadeWindows = true
        w.contentViewController = EditorViewController()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var document: AnyObject? {
        didSet { (contentViewController as? EditorViewController)?.document = document as? MarkdownDocument }
    }
}

/// Custom actions reachable through the responder chain (selectors used by MainMenu.swift).
@objc protocol ScribeEditorActions {
    func scribeIncreaseFontSize(_ sender: Any?)
    func scribeDecreaseFontSize(_ sender: Any?)
    func scribeResetFontSize(_ sender: Any?)
    func scribeToggleWrapLines(_ sender: Any?)
    func scribeToggleInvisibles(_ sender: Any?)
}

final class EditorViewController: NSViewController, TextViewEditorHost, NSTextViewDelegate, NSMenuItemValidation, ScribeEditorActions {

    weak var document: MarkdownDocument?
    let scrollView = NSScrollView()
    let textView: NSTextView
    private let banner = BannerView()
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    static let fontSizeKey = "ScribeFontSize"
    static let defaultFontSize: CGFloat = 14
    private(set) var fontSize: CGFloat

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        storage.addLayoutManager(layoutManager)
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        layoutManager.allowsNonContiguousLayout = true
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        let saved = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = saved >= 8 ? CGFloat(saved) : Self.defaultFontSize
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }
    convenience init() { self.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let tv = textView
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.textContainerInset = NSSize(width: 24, height: 16)
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Substitutions OFF by default: a Markdown source editor must not turn quotes/dashes/links into rich text.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.delegate = self

        scrollView.documentView = tv
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
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
        stack.frame = NSRect(x: 0, y: 0, width: 820, height: 760)
        view = stack
    }

    // MARK: EditorHost (banner part; the rest comes from TextViewEditorHost)

    func showBanner(_ b: EditorBanner) { banner.configure(b); banner.isHidden = false }
    func hideBanner() { banner.isHidden = true }
    var bannerVisible: Bool { !banner.isHidden }
    var bannerText: String { banner.messageField.stringValue }
    var bannerButtonTitles: [String] { banner.buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    func pressBannerButton(_ title: String) { (banner.buttonStack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.title == title })?.performClick(nil) }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        document?.editorWillChangeText()
        return true
    }
    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }

    // MARK: view actions (menu)

    private func applyFontSize(_ size: CGFloat) {
        fontSize = min(48, max(8, size))
        UserDefaults.standard.set(Double(fontSize), forKey: Self.fontSizeKey)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    @objc func scribeIncreaseFontSize(_ sender: Any?) { applyFontSize(fontSize + 1) }
    @objc func scribeDecreaseFontSize(_ sender: Any?) { applyFontSize(fontSize - 1) }
    @objc func scribeResetFontSize(_ sender: Any?) { applyFontSize(Self.defaultFontSize) }

    @objc func scribeToggleWrapLines(_ sender: Any?) {
        let wrap = !container.widthTracksTextView
        container.widthTracksTextView = wrap
        textView.isHorizontallyResizable = !wrap
        scrollView.hasHorizontalScroller = !wrap
        if wrap { container.size = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude) }
        else { container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) }
    }
    @objc func scribeToggleInvisibles(_ sender: Any?) { layoutManager.showsInvisibleCharacters.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(scribeToggleWrapLines(_:)): item.state = container.widthTracksTextView ? .on : .off
        case #selector(scribeToggleInvisibles(_:)): item.state = layoutManager.showsInvisibleCharacters ? .on : .off
        case #selector(scribeIncreaseFontSize(_:)): return fontSize < 48
        case #selector(scribeDecreaseFontSize(_:)): return fontSize > 8
        case #selector(scribeResetFontSize(_:)): return fontSize != Self.defaultFontSize
        default: break
        }
        return true
    }
}

/// Non-modal strip above the text: message + buttons.
final class BannerView: NSView {
    let messageField = NSTextField(wrappingLabelWithString: "")
    let buttonStack = NSStackView()
    private var actions: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.font = NSFont.systemFont(ofSize: 12)
        messageField.maximumNumberOfLines = 2
        messageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageField)
        addSubview(buttonStack)
        NSLayoutConstraint.activate([
            messageField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            messageField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            messageField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: messageField.trailingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ b: EditorBanner) {
        messageField.stringValue = b.message
        buttonStack.arrangedSubviews.forEach { buttonStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        actions = b.buttons.map { $0.action }
        for (i, btn) in b.buttons.enumerated() {
            let button = NSButton(title: btn.title, target: self, action: #selector(pressed(_:)))
            button.tag = i
            button.controlSize = .small
            button.bezelStyle = .rounded
            buttonStack.addArrangedSubview(button)
        }
        layer?.backgroundColor = (b.style == .warning ? NSColor.systemYellow.withAlphaComponent(0.22) : NSColor.systemBlue.withAlphaComponent(0.14)).cgColor
    }
    @objc private func pressed(_ sender: NSButton) { if actions.indices.contains(sender.tag) { actions[sender.tag]() } }
}
