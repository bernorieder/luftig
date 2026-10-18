// SettingsPreview.swift - the live preview at the top of the Settings window.
//
// A read-only text view built by the SAME factory as the editor (TextKit 1, the decorating layout manager, the readable column) and styled
// by the SAME Theme and lexer with the CURRENT preferences, so fonts, size, line spacing, column width and colour scheme change in front of
// the user's eyes exactly as they will in a document. The text is a few hundred characters, so everything is styled at once (no LazyStyler).

import AppKit
import MarkdownKit

final class SettingsPreview {

    /// One of everything the Theme styles differently: headings, emphasis, a link, inline code, a nested list with a long wrapping item,
    /// a task, a quote, a fenced code block and a table.
    static let sampleText = """
    # A quiet page to write on
    ## Set the way you like it

    Body text with **bold**, *italic*, ~~struck~~ words, `inline code` and a [link](https://example.com). Change the fonts, the size, the line spacing or the column width and this text follows.

    - A list item that is long enough to wrap onto a second line, so you can see where the continuation lines start
      - A nested item
    > A quote is set apart by its bar and a gentler color.

    ```swift
    let answer = 42
    ```
    | Setting | Value |
    |---------|-------|
    | size    | 16    |

    """

    let scrollView: NSScrollView
    let textView: LuftigEditorTextView
    private let storage: NSTextStorage
    private let layoutManager: LuftigLayoutManager
    private let column: ReadableColumnController
    /// The theme the text is styled with right now (rebuilt by `refresh()` when the preferences changed).
    private(set) var theme: Theme
    private var appliedSchemeID: String
    private var forcedAppearance = false

    init() {
        let settings = EditorPreferences.themeSettings
        theme = Theme(settings: settings)
        appliedSchemeID = EditorPreferences.colorSchemeID
        let stack = LuftigEditorFactory.make(frame: NSRect(x: 0, y: 0, width: 640, height: 340), theme: theme)
        scrollView = stack.scrollView
        textView = stack.textView
        storage = stack.storage
        layoutManager = stack.layoutManager
        column = ReadableColumnController(scrollView: stack.scrollView, textView: stack.textView, maxColumnWidth: EditorPreferences.columnWidth)
        column.trailingExtra = Padding(factor: EditorPreferences.padding).textTrailingExtra
        textView.isEditable = false
        textView.isSelectable = false
        scrollView.borderType = .bezelBorder
        scrollView.setAccessibilityLabel("Preview of the text settings")
        textView.string = SettingsPreview.sampleText
        restyle()
        applyColors()
    }

    deinit { storage.removeLayoutManager(layoutManager) }       // the same TextKit 1 leak work-around as EditorViewController.deinit

    /// Rebuild the theme if (and only if) a preference that shapes it changed, and follow the column preferences.
    @discardableResult
    func refresh() -> Bool {
        var rebuilt = false
        let settings = EditorPreferences.themeSettings, scheme = EditorPreferences.colorSchemeID
        if settings != theme.settings || scheme != appliedSchemeID {
            theme = Theme(settings: settings)
            if scheme != appliedSchemeID { appliedSchemeID = scheme; applyColors() }
            restyle()
            rebuilt = true
        }
        column.maxColumnWidth = EditorPreferences.columnWidth
        column.isEnabled = EditorPreferences.readableWidth
        return rebuilt
    }

    /// Base attributes over everything, then one complete attribute dictionary per styled run: what the editor's styler does for the visible part.
    private func restyle() {
        let text = storage.string as NSString
        let runs = theme.styledRuns(MarkdownStyler().lexAll(text), text: text)
        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: storage.length))
        for run in runs { storage.setAttributes(run.attributes, range: run.range) }
        storage.endEditing()
        textView.typingAttributes = theme.baseAttributes
        textView.needsDisplay = true
    }

    /// Page colour, and the appearance a light / dark scheme forces (the system scheme follows the Settings window).
    private func applyColors() {
        textView.backgroundColor = Palette.background
        scrollView.backgroundColor = Palette.background
        switch Palette.scheme.appearance {
        case .light: scrollView.appearance = NSAppearance(named: .aqua); forcedAppearance = true
        case .dark: scrollView.appearance = NSAppearance(named: .darkAqua); forcedAppearance = true
        case .system: if forcedAppearance { scrollView.appearance = nil; forcedAppearance = false }
        }
        textView.needsDisplay = true
    }

    /// How many characters of the body font fit on a line of `width` points (an average over a pangram: a guide, not a promise).
    static func charactersPerLine(width: CGFloat, font: NSFont) -> Int {
        let sample = "The quick brown fox jumps over the lazy dog, then rests." as NSString
        let average = sample.size(withAttributes: [.font: font]).width / CGFloat(sample.length)
        return average > 0 ? Int((width / average).rounded()) : 0
    }
}
