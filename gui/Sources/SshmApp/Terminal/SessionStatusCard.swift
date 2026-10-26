import AppKit

/// What happened to a session that is no longer connected, as a native card
/// floating over the bottom of its terminal — instead of dim text lines
/// written into the scrollback, where they read like program output.
final class SessionStatusCard: ThemedView {
    var onReconnect: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onEnd: (() -> Void)?

    private let tile = ThemedDisc()
    private let symbol = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var tone: NSColor = Ink.neutral
    /// Which button set is showing. The countdown refreshes the card every
    /// second, and rebuilding the buttons each time would swallow a click
    /// that landed mid-rebuild.
    private var buttonsKey = ""

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        softCorners(Radius.card)
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        // the shadow needs to spill past the rounded corners
        layer?.masksToBounds = false

        symbol.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [symbol, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 36),
            tile.heightAnchor.constraint(equalToConstant: 36),
            symbol.widthAnchor.constraint(equalToConstant: 18),
            symbol.heightAnchor.constraint(equalToConstant: 18),
        ])

        titleLabel.font = Fonts.rounded(14, .semibold)
        detailLabel.font = Fonts.caption
        detailLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = Fonts.mono(10.5)
        metaLabel.lineBreakMode = .byTruncatingMiddle
        for l in [titleLabel, detailLabel, metaLabel] {
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let texts = NSStackView(views: [titleLabel, detailLabel, metaLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        buttons.orientation = .horizontal
        buttons.spacing = Space.sm
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [tile, texts, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.setCustomSpacing(Space.lg, after: texts)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Space.md),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.md),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show this session's state. Returns false when there is nothing to show
    /// (it is connected), so the host can hide the card.
    @discardableResult
    func show(_ session: SSHSession) -> Bool {
        let where_ = session.server.display
        switch session.state {
        case .idle, .connecting, .running:
            return false

        case .reconnecting(let attempt, let left):
            tone = Ink.warning
            setIcon(nil, spinning: true)
            if session.waitingForNetwork {
                titleLabel.stringValue = "Waiting for the network"
                detailLabel.stringValue = "Reconnects as soon as you're back online."
            } else {
                titleLabel.stringValue = left > 0 ? "Reconnecting in \(left)s" : "Reconnecting…"
                detailLabel.stringValue = "The connection dropped. "
                    + "Attempt \(attempt) of \(SSHSession.maxAttempts)."
            }
            metaLabel.stringValue = where_
            setButtons(key: "retry:\(session.id)", [
                button("Reconnect now", symbol: "arrow.clockwise", style: .primary,
                       accent: session.spec.accent) { [weak self] in self?.onReconnect?() },
                button("Stop", style: .quiet) { [weak self] in self?.onStop?() },
            ])

        case .ended(let status):
            let lost = status.shouldReconnect
            if status.isClean {
                tone = Ink.neutral
                setIcon("checkmark.circle", spinning: false)
                titleLabel.stringValue = "Session closed"
                detailLabel.stringValue = "The remote shell exited normally."
            } else if lost {
                tone = Ink.error
                setIcon("wifi.exclamationmark", spinning: false)
                titleLabel.stringValue = "Connection lost"
                detailLabel.stringValue = session.gaveUp
                    ? "Gave up after \(SSHSession.maxAttempts) attempts. The server may be down."
                    : "The server closed the connection or couldn't be reached."
            } else {
                tone = Ink.error
                setIcon("exclamationmark.octagon", spinning: false)
                titleLabel.stringValue = "Session ended"
                detailLabel.stringValue = (status.detail ?? status.label).prefix(1).uppercased()
                    + String((status.detail ?? status.label).dropFirst()) + "."
            }
            var meta = "\(where_) · \(status.label)"
            if let at = session.endedAt { meta += " · \(Self.timeFormat.string(from: at))" }
            metaLabel.stringValue = meta
            var views = [
                button("Reconnect", symbol: "arrow.clockwise",
                       style: status.isClean ? .secondary : .primary,
                       accent: session.spec.accent, hint: "⏎") { [weak self] in
                    self?.onReconnect?()
                },
                button("Close tab", style: .quiet) { [weak self] in self?.onClose?() },
            ]
            // a dropped link leaves the tmux session alive on the server
            if session.tmuxName != nil, !status.isClean {
                views.append(button("End session", style: .quiet) { [weak self] in
                    self?.onEnd?()
                })
            }
            setButtons(key: "ended:\(session.id):\(status.isClean):\(session.tmuxName != nil)",
                       views)
        }
        applyTheme()
        return true
    }

    private func setIcon(_ name: String?, spinning: Bool) {
        if spinning {
            symbol.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            symbol.isHidden = false
            symbol.image = name.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
            }
        }
    }

    private func setButtons(key: String, _ make: @autoclosure () -> [NSView]) {
        guard key != buttonsKey else { return }
        buttonsKey = key
        let views = make()
        buttons.arrangedSubviews.forEach {
            buttons.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        views.forEach { buttons.addArrangedSubview($0) }
    }

    private func button(_ title: String, symbol: String? = nil, style: SoftButton.Style,
                        accent: NSColor = Pastel.color(0), hint: String? = nil,
                        run: @escaping () -> Void) -> NSView {
        let b = SoftButton(title, symbol: symbol, style: style, accent: accent)
        b.onClick = run
        if let hint { b.toolTip = "\(title) (\(hint))" }
        return b
    }

    override func applyTheme() {
        layer?.backgroundColor = Ink.surface.cg(self)
        layer?.borderColor = Ink.border.cg(self)
        titleLabel.textColor = Text.primary
        detailLabel.textColor = Text.secondary
        metaLabel.textColor = Text.muted
        symbol.contentTintColor = tone
        tile.fill = tone.withAlphaComponent(0.14)
    }
}

/// A filled circle behind the card's icon.
final class ThemedDisc: ThemedView {
    var fill: NSColor = .clear { didSet { applyTheme() } }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func applyTheme() { layer?.backgroundColor = fill.cg(self) }
}
