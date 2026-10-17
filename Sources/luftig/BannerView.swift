import AppKit

/// Non-modal strip above the text: message + buttons (external-change notifications, see EditorBanner).
final class BannerView: NSView {
    let messageField = NSTextField(wrappingLabelWithString: "")
    let buttonStack = NSStackView()
    private let separator = NSBox()
    private var actions: [() -> Void] = []
    private var style: EditorBanner.Style = .warning
    private var schemeObserver: NSObjectProtocol?

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
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageField)
        addSubview(buttonStack)
        addSubview(separator)
        schemeObserver = NotificationCenter.default.addObserver(forName: Palette.didChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.needsDisplay = true }
        NSLayoutConstraint.activate([
            messageField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            messageField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            messageField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: messageField.trailingAnchor, constant: 12),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let o = schemeObserver { NotificationCenter.default.removeObserver(o) } }

    func configure(_ b: EditorBanner) {
        style = b.style
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
        needsDisplay = true
    }
    @objc private func pressed(_ sender: NSButton) { if actions.indices.contains(sender.tag) { actions[sender.tag]() } }

    // The tint is a dynamic colour resolved for the CURRENT appearance every time the layer is updated.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (style == .warning ? Palette.bannerWarning : Palette.bannerInfo).cgColor
        }
        // a colour scheme's own text colour on its own banner tint (the default scheme keeps the system's label colour)
        messageField.textColor = Palette.isSystemScheme ? .labelColor : Palette.text
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
