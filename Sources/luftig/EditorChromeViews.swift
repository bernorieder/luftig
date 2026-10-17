// EditorChromeViews.swift - the three understated elements around the text: an outline on the left, the word count at the top right, the syntax bar at
// the bottom. Plain text on the page colour: no lines, no boxes, no titles, nothing that looks like a button. The colour is the scheme's marker colour
// (the dim one of the syntax punctuation, >= 3:1 on the page in every scheme) and the body / code family of the Settings at 12 pt; what the pointer is
// over, and the section the window is in, use the scheme's text colour. The logic (what is a heading, what a click inserts) lives in EditorChrome.swift.

import AppKit

/// Colours and fonts shared by the three elements: the Settings window's pane font (nil = the editor's text font), size and opacity.
enum ChromeStyle {
    static var fontSize: CGFloat { EditorPreferences.paneFontSize }
    static var opacity: CGFloat { EditorPreferences.paneOpacity }
    /// The dim colour (the scheme's marker colour) and the stronger one (the text colour), at the panes' opacity, resolved for `appearance` (the default
    /// scheme's colours are dynamic: they must be resolved for the window's appearance, and again when it changes).
    static func dim(for appearance: NSAppearance) -> NSColor { resolve(Palette.marker, appearance) }
    static func strong(for appearance: NSAppearance) -> NSColor { resolve(Palette.text, appearance) }
    private static func resolve(_ c: NSColor, _ appearance: NSAppearance) -> NSColor {
        var out = c
        appearance.performAsCurrentDrawingAppearance { out = (c.usingColorSpace(.sRGB) ?? c).withAlphaComponent(opacity) }
        return out
    }
    static func family(_ theme: Theme) -> String? { EditorPreferences.paneFontFamily ?? theme.bodyFamily }
    static func font(_ theme: Theme, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        FontFactory.face(family: family(theme), mono: false, size: fontSize, weight: weight, italic: italic).font
    }
}

/// The root view of the editor: paints the page colour behind everything (the elements are transparent, the scroll view paints its own).
final class EditorRootView: NSView {
    private var schemeObserver: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Palette.background.cgColor } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - a label that reacts to the pointer

/// A piece of text, or a symbol, that does something when clicked: dim, a little stronger under the pointer, never a bezel.
final class SoftLabel: NSView {
    let field = NSTextField(labelWithString: "")
    let imageView = NSImageView()
    let face: SyntaxElement.Face
    var action: (() -> Void)?
    private(set) var hovered = false
    private var tracking: NSTrackingArea?

    init(face: SyntaxElement.Face, theme: Theme) {
        self.face = face
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let inner: NSView
        switch face {
        case .text:
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byClipping
            field.isSelectable = false
            inner = field
        case .symbol:
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleNone
            inner = imageView
        }
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: leadingAnchor), inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.topAnchor.constraint(equalTo: topAnchor), inner.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])
        apply(theme: theme)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The face at the panes' current font and size.
    func apply(theme: Theme) {
        switch face {
        case let .text(s, bold, italic, strike, _):
            let font = ChromeStyle.font(theme, weight: bold ? .bold : .regular, italic: italic)
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            field.font = font
            field.attributedStringValue = NSAttributedString(string: s, attributes: attrs)
        case let .symbol(name):
            let config = NSImage.SymbolConfiguration(pointSize: ChromeStyle.fontSize + 1, weight: .regular)
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        }
        refreshColors()
    }

    func refreshColors() {
        let color = hovered ? ChromeStyle.strong(for: effectiveAppearance) : ChromeStyle.dim(for: effectiveAppearance)
        switch face {
        case .text:
            field.textColor = color
            if let a = field.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
                a.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: a.length))
                field.attributedStringValue = a
            }
        case .symbol: imageView.contentTintColor = color
        }
    }
    override func viewDidChangeEffectiveAppearance() { refreshColors() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshColors() }
    override func mouseDown(with event: NSEvent) {
        // act on mouse up inside, like a button, without ever looking like one
        guard let w = window else { return }
        var inside = true
        while let e = w.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp { break }
        }
        if inside { action?() }
    }
    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - the word count

final class WordCountView: NSView {
    static let height: CGFloat = 22
    let field = NSTextField(labelWithString: "")
    private var schemeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.isSelectable = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WordCountView.height),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            field.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
        ])
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.refreshColors() }
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }
    func apply(theme: Theme) { field.font = ChromeStyle.font(theme); refreshColors() }
    func refreshColors() { field.textColor = ChromeStyle.dim(for: effectiveAppearance) }
    override func viewDidChangeEffectiveAppearance() { refreshColors() }

    /// "1,234 words"; with a selection "12 of 1,234 words".
    static func label(total: Int, selected: Int?) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let all = f.string(from: NSNumber(value: total)) ?? "\(total)"
        if let s = selected { return "\(f.string(from: NSNumber(value: s)) ?? "\(s)") of \(all) words" }
        return total == 1 ? "1 word" : "\(all) words"
    }
}

// MARK: - the outline

final class OutlineView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 220
    static let rowHeight: CGFloat = 20
    static let indentPerLevel: CGFloat = 11

    let table = NSTableView()
    let scroll = NSScrollView()
    var onSelect: ((OutlineEntry) -> Void)?
    private var font = NSFont.systemFont(ofSize: ChromeStyle.fontSize)
    private var schemeObserver: NSObjectProtocol?
    private var hoveredRow = -1
    private var tracking: NSTrackingArea?

    var entries: [OutlineEntry] = [] {
        didSet { if entries != oldValue { table.reloadData(); if let c = currentIndex, c >= entries.count { currentIndex = nil } } }
    }
    /// The entry whose section the window shows (drawn in the text colour).
    var currentIndex: Int? {
        didSet {
            guard currentIndex != oldValue else { return }
            for r in [oldValue, currentIndex].compactMap({ $0 }) where r < entries.count { refreshRow(r) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = OutlineView.rowHeight
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsets = NSEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: OutlineView.width),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.refreshColors() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }

    func apply(theme: Theme) {
        font = ChromeStyle.font(theme)
        table.rowHeight = max(OutlineView.rowHeight, ceil(font.ascender - font.descender) + 6)
        table.reloadData()
    }
    func refreshColors() { table.reloadData() }
    override func viewDidChangeEffectiveAppearance() { refreshColors() }

    private func refreshRow(_ r: Int) {
        guard r >= 0, r < table.numberOfRows, let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTextField else { return }
        cell.textColor = color(forRow: r)
    }
    private func color(forRow r: Int) -> NSColor { (r == currentIndex || r == hoveredRow) ? ChromeStyle.strong(for: effectiveAppearance) : ChromeStyle.dim(for: effectiveAppearance) }

    // the row under the pointer
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let p = table.convert(event.locationInWindow, from: nil)
        setHovered(table.row(at: p))
    }
    override func mouseExited(with event: NSEvent) { setHovered(-1) }
    private func setHovered(_ r: Int) {
        guard r != hoveredRow else { return }
        let old = hoveredRow; hoveredRow = r
        if old >= 0 { refreshRow(old) }
        if r >= 0 { refreshRow(r) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // NSTableView
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("outline-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.isSelectable = false
            f.cell?.truncatesLastVisibleLine = true
            return f
        }()
        let e = entries[row]
        cell.font = font
        cell.stringValue = e.title.isEmpty ? "(untitled)" : e.title
        cell.textColor = color(forRow: row)
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = OutlineRowView()
        v.indent = 16 + CGFloat(max(0, entries[row].level - 1)) * OutlineView.indentPerLevel
        return v
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    @objc private func rowClicked(_ sender: Any?) {
        let r = table.clickedRow
        guard r >= 0, r < entries.count else { return }
        onSelect?(entries[r])
    }
    /// Test access: the click on a row.
    func click(row: Int) { guard row >= 0, row < entries.count else { return }; onSelect?(entries[row]) }
}

/// A row that indents its cell by the heading level and never paints a selection.
final class OutlineRowView: NSTableRowView {
    var indent: CGFloat = 16
    override func layout() {
        super.layout()
        for v in subviews { v.frame = NSRect(x: indent, y: 0, width: max(0, bounds.width - indent - 12), height: bounds.height) }
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

// MARK: - the syntax bar

final class SyntaxBarView: NSView {
    static let height: CGFloat = 40
    static let gapInGroup: CGFloat = 16
    static let gapBetweenGroups: CGFloat = 30
    let stack = NSStackView()
    private(set) var labels: [SyntaxElement: SoftLabel] = [:]
    var onInsert: ((SyntaxElement) -> Void)?
    private var schemeObserver: NSObjectProtocol?

    /// `theme`: the editor's (the panes' font follows its text font unless the Settings choose another family).
    init(theme: Theme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = SyntaxBarView.gapBetweenGroups
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        for group in SyntaxElement.groups {
            let g = NSStackView()
            g.orientation = .horizontal
            g.spacing = SyntaxBarView.gapInGroup
            g.alignment = .centerY
            for e in group {
                let l = SoftLabel(face: e.face, theme: theme)
                l.toolTip = e.name
                l.action = { [weak self] in self?.onInsert?(e) }
                labels[e] = l
                g.addArrangedSubview(l)
            }
            stack.addArrangedSubview(g)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SyntaxBarView.height),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.refreshColors() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }

    func apply(theme: Theme) { for l in labels.values { l.apply(theme: theme) } }
    func refreshColors() { for l in labels.values { l.refreshColors() } }
    /// Test access: the click on an element.
    func click(_ e: SyntaxElement) { onInsert?(e) }
}
