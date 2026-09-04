import AppKit

/// The window's top strip: command search, a live environment indicator, the
/// theme switch, and the one primary action.
final class TopBar: ThemedView {
    var onSearch: (() -> Void)?
    var onPrimary: (() -> Void)?
    var onTheme: (() -> Void)?

    private let search = SearchTrigger()
    private let statusStack = NSStackView()
    private let statusDot = StatusDot(.idle)
    private let statusLabel = NSTextField(labelWithString: "")
    private let themeButton = IconButton(symbol: "circle.lefthalf.filled")
    private let primary = SoftButton("New project", symbol: "plus", style: .primary)

    override init(frame: NSRect) {
        super.init(frame: frame)

        search.onClick = { [weak self] in self?.onSearch?() }
        themeButton.onClick = { [weak self] in self?.onTheme?() }
        primary.onClick = { [weak self] in self?.onPrimary?() }

        statusLabel.font = Fonts.caption
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 7
        statusStack.setViews([statusDot, statusLabel], in: .leading)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [search, spacer, statusStack, themeButton, primary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            search.widthAnchor.constraint(equalToConstant: 420),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setEnvironment(online: Int, total: Int, checking: Bool) {
        if checking {
            statusDot.set(.connecting)
            statusLabel.stringValue = "Checking servers…"
            statusLabel.textColor = Text.secondary
        } else if total == 0 {
            statusStack.isHidden = true
            return
        } else {
            let state: Status = online == total ? .online : (online == 0 ? .offline : .warning)
            statusDot.set(state)
            statusLabel.stringValue = "\(online)/\(total) servers online"
            statusLabel.textColor = Text.secondary
        }
        statusStack.isHidden = false
    }

    func setTheme(_ mode: ThemeMode) {
        themeButton.setSymbol(mode.symbol)
        themeButton.toolTip = "Appearance: \(mode.label)"
    }

    func setPrimary(title: String) { primary.title = title }

    override func applyTheme() {
        layer?.backgroundColor = Ink.bg.cg(self)
    }
}

/// Looks like a search field, behaves like a button — it opens the palette.
final class SearchTrigger: ThemedView {
    var onClick: (() -> Void)?
    private let glass = NSImageView()
    private let placeholder = NSTextField(labelWithString:
        "Search projects, servers or run a command…")
    private let shortcut = NSTextField(labelWithString: "⌘K")
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        softCorners(Radius.field)
        layer?.borderWidth = 1

        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        placeholder.font = Fonts.body
        shortcut.font = Fonts.micro

        let key = ThemedKeyCap(shortcut)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [glass, placeholder, spacer, key])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.sm),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (hovering ? Ink.hover : Ink.surface).cg(self)
        layer?.borderColor = (hovering ? Ink.borderStrong : Ink.border).cg(self)
        glass.contentTintColor = Text.muted
        placeholder.textColor = Text.muted
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// `⌘K` rendered as a key, not as text.
final class ThemedKeyCap: ThemedView {
    private let label: NSTextField
    init(_ label: NSTextField) {
        self.label = label
        super.init(frame: .zero)
        softCorners(5)
        layer?.borderWidth = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func applyTheme() {
        layer?.backgroundColor = Ink.hover.cg(self)
        layer?.borderColor = Ink.border.cg(self)
        label.textColor = Text.muted
    }
}

/// A square icon-only button.
final class IconButton: ThemedView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(symbol: String) {
        super.init(frame: .zero)
        softCorners(Radius.field)
        layer?.borderWidth = 1
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSymbol(symbol)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ s: String) {
        icon.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        applyTheme()
    }
    override func applyTheme() {
        layer?.backgroundColor = (hovering ? Ink.hover : Ink.surface).cg(self)
        layer?.borderColor = (hovering ? Ink.borderStrong : Ink.border).cg(self)
        icon.contentTintColor = hovering ? Text.primary : Text.secondary
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
