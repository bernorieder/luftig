import AppKit
import MarkdownKit

/// The recommended editor stack: TextKit 1, NON-contiguous layout, one NSTextView in an NSScrollView.
///
/// Why not `NSTextView.scrollableTextView()`: that gives a TextKit 2 view. `NSTextView(frame:textContainer:)` with a container
/// that belongs to an NSLayoutManager gives TextKit 1, and the layout manager can be our subclass (decorations).
///
/// NEVER touch `textView.textLayoutManager` on a TK1 view (nil, fine) and NEVER touch `textView.layoutManager` on a TK2 view
/// (silently downgrades that view to TK1 for good).
enum LuftigEditorFactory {

    struct Stack {
        let scrollView: NSScrollView
        let textView: LuftigEditorTextView
        let layoutManager: LuftigLayoutManager
        let storage: NSTextStorage
    }

    static func make(frame: NSRect, theme: Theme, textInset: NSSize = NSSize(width: 28, height: 20)) -> Stack {
        let storage = NSTextStorage()
        let layoutManager = LuftigLayoutManager()
        // THE switch that makes 10-20 MB documents work: glyphs / layout are produced only for what is on screen.
        // Contiguous layout (the default of a hand-built TK1 stack) blocks the main thread in one background-layout chunk right
        // after open: measured 2.5 s stall at 5 MB, 4.8 s at 10 MB, 9.8 s at 20 MB; Cmd-Down then takes 1.55 s / 6.2 s, and the
        // scroller is meaningless (document height = one screen) until layout has finished.
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0          // text starts exactly at the column edge; the bands add their own outset
        layoutManager.addTextContainer(container)

        let tv = LuftigEditorTextView(frame: frame, textContainer: container)
        configure(tv, theme: theme, textInset: textInset)

        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.background
        scroll.contentView.postsBoundsChangedNotifications = true   // LazyStyler listens to this
        scroll.contentView.postsFrameChangedNotifications = true    // ReadableColumnController listens to this
        scroll.documentView = tv
        return Stack(scrollView: scroll, textView: tv, layoutManager: layoutManager, storage: storage)
    }

    /// Plain-text editing configuration. Every line here is either required for correctness (bold) or for sanity.
    /// Measured: none of the NSTextView switches changes open time or typing latency by more than noise (+-1 ms) except
    /// automatic link detection (+0.8 ms per keystroke in TK1, +1.3 ms in TK2) -> they are off for behaviour, not for speed.
    static func configure(_ tv: NSTextView, theme: Theme, textInset: NSSize) {
        // --- layout / geometry --------------------------------------------------------------------------------------
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = textInset            // must be >= DecorationMetrics.bandOutset + a little: bands live in the inset

        // --- plain text, no rich-text surprises -----------------------------------------------------------------------
        tv.isRichText = false                         // pasted RTF/HTML becomes plain text; typing attributes stay ours
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.usesFontPanel = false                      // font size is ours (Cmd +/-), not the font panel
        tv.usesRuler = false
        tv.usesInspectorBar = false
        tv.allowsDocumentBackgroundColorChange = false
        tv.allowsUndo = true                          // attribute-only restyling does NOT register undo (verified)

        // --- substitutions that would silently rewrite Markdown / code ---------------------------------------------------
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false    // also the only switch with a measurable typing cost
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = false   // expose as an Edit menu toggle; default off for Markdown source
        tv.isGrammarCheckingEnabled = false

        // --- find ------------------------------------------------------------------------------------------------------
        tv.usesFindBar = true                         // NSTextFinder bar; zero cost until used (whole-doc miss search: 56 ms @ 20 MB)
        tv.isIncrementalSearchingEnabled = true

        // --- appearance ------------------------------------------------------------------------------------------------
        tv.drawsBackground = true
        tv.backgroundColor = Palette.background
        applyBaseAppearance(tv, theme: theme)
        tv.insertionPointColor = Palette.caret         // visible on the page and on the tinted code / quote bands (>= 3:1, checked for every colour scheme)
        tv.isEditable = true
        tv.isSelectable = true
    }

    /// The colours of the text view and its scroll view that are not part of the text: page, insertion point. Called by the text view when another colour scheme
    /// becomes current (`Palette.didChangeNotification`). The colours OF THE TEXT are attributes: a new `Theme` and a restyle (as for a font size change) renew them.
    static func applySchemeColors(to tv: NSTextView) {
        tv.backgroundColor = Palette.background
        tv.insertionPointColor = Palette.caret
        if let scroll = tv.enclosingScrollView { scroll.backgroundColor = Palette.background; scroll.needsDisplay = true }
        tv.needsDisplay = true
    }

    /// Font / colour / paragraph style that NEW text gets (an empty document, text typed before the first restyle). Setting
    /// `tv.font` on a plain-text NSTextView would re-font the WHOLE document (slow for 20 MB): only call this when the text is
    /// empty or when you re-apply the base attributes yourself anyway.
    static func applyBaseAppearance(_ tv: NSTextView, theme: Theme) {
        tv.font = theme.bodyFont
        tv.textColor = Palette.text
        tv.defaultParagraphStyle = theme.paragraphStyle(Theme.LineKey(MDStyle()))
        tv.typingAttributes = theme.baseAttributes
    }
}
