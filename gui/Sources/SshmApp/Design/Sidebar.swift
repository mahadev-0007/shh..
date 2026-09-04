import AppKit

enum RailSection: String, CaseIterable {
    case dashboard, projects, servers, sessions, settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .projects:  return "Projects"
        case .servers:   return "Servers"
        case .sessions:  return "Sessions"
        case .settings:  return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .projects:  return "folder"
        case .servers:   return "externaldrive.connected.to.line.below"
        case .sessions:  return "terminal"
        case .settings:  return "gearshape"
        }
    }
    var glyph: String {
        switch self {
        case .dashboard: return "▦"
        case .projects:  return "▤"
        case .servers:   return "▥"
        case .sessions:  return ">_"
        case .settings:  return "⚙"
        }
    }
    /// Everything above the divider.
    static var primary: [RailSection] { [.dashboard, .projects, .servers, .sessions] }
}

/// The left column: brand, navigation, then settings and the account row pinned
/// to the bottom.
final class Sidebar: ThemedView {
    static let width: CGFloat = 232

    var onSelect: ((RailSection) -> Void)?
    var selected: RailSection = .dashboard {
        didSet { rows.forEach { $0.isActive = $0.section == selected } }
    }

    private var rows: [NavRow] = []
    private let divider = ThemedDivider()
    private let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        // brand
        let mark = IconTile(side: 32, radius: 9)
        mark.configure(icon: .emoji("🤫"), accent: Ink.accent)
        let name = NSTextField(labelWithString: "shh")
        name.font = Fonts.sys(14, .semibold)
        name.textColor = Text.primary
        let tag = NSTextField(labelWithString: "Projects. Servers. Anywhere.")
        tag.font = Fonts.sys(10.5, .regular)
        tag.textColor = Text.muted
        let words = NSStackView(views: [name, tag])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 0
        let brand = NSStackView(views: [mark, words])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = Space.md

        rows = RailSection.allCases.map { s in
            let r = NavRow(section: s)
            r.onSelect = { [weak self] in self?.onSelect?(s) }
            return r
        }
        let primary = rows.filter { RailSection.primary.contains($0.section) }
        let settingsRow = rows.first { $0.section == .settings }!

        let nav = NSStackView(views: primary)
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2

        // account row
        let avatar = IconTile(side: 28, radius: 14)
        avatar.configure(icon: .symbol("person.fill"), accent: Ink.accent)
        let who = NSTextField(labelWithString: NSFullUserName())
        who.font = Fonts.bodyMed
        who.textColor = Text.primary
        let chev = NSImageView()
        chev.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chev.contentTintColor = Text.muted
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let account = NSStackView(views: [avatar, who, spacer, chev])
        account.orientation = .horizontal
        account.alignment = .centerY
        account.spacing = Space.sm

        for v in [brand, nav, divider, settingsRow, account] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),

            brand.topAnchor.constraint(equalTo: topAnchor, constant: 46),
            brand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Space.md),

            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: Space.xl),
            nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            nav.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),

            account.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            account.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
            account.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.lg),

            settingsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            settingsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
            settingsRow.bottomAnchor.constraint(equalTo: account.topAnchor, constant: -Space.md),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.lg),
            divider.bottomAnchor.constraint(equalTo: settingsRow.topAnchor, constant: -Space.md),
        ])
        selected = .dashboard
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = Ink.sidebar.cg(self)
    }
}

final class ThemedDivider: ThemedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func applyTheme() { layer?.backgroundColor = Ink.border.cg(self) }
}

/// One navigation row: icon, label, and an accent bar when active.
final class NavRow: ThemedView {
    let section: RailSection
    var onSelect: (() -> Void)?
    var isActive = false { didSet { applyTheme() } }

    private let iconView = NSImageView()
    private let glyph = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let marker = ThemedView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(section: RailSection) {
        self.section = section
        super.init(frame: .zero)
        softCorners(Radius.pill)

        if let img = NSImage(systemSymbolName: section.symbol,
                             accessibilityDescription: section.title) {
            iconView.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            glyph.isHidden = true
        } else {
            glyph.stringValue = section.glyph
            glyph.font = Fonts.sys(13, .medium)
            iconView.isHidden = true
        }
        label.stringValue = section.title
        label.font = Fonts.bodyMed

        marker.softCorners(1.5)
        marker.translatesAutoresizingMaskIntoConstraints = false

        let iconBox = iconView.isHidden ? glyph : iconView
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(marker); addSubview(iconBox); addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Space.md + 4),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.heightAnchor.constraint(equalToConstant: 18),
            iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: Space.md),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Space.sm),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (isActive ? Ink.hover
                                  : (hovering ? Ink.hover.withAlphaComponent(0.6)
                                              : NSColor.clear)).cg(self)
        layer?.borderWidth = isActive ? 1 : 0
        layer?.borderColor = Ink.border.cg(self)
        marker.layer?.backgroundColor = (isActive ? Ink.accent : NSColor.clear).cg(self)
        let tint: NSColor = isActive ? Text.primary : (hovering ? Text.primary : Text.secondary)
        label.textColor = tint
        glyph.textColor = tint
        iconView.contentTintColor = isActive ? Ink.accent : tint
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
    override func mouseDown(with event: NSEvent) { onSelect?() }
}
