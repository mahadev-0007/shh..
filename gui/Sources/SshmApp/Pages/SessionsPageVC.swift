import AppKit

/// Sessions are a place you navigate to, not tabs bolted to the chrome. The
/// page lists what is running and hands the whole area to a terminal once you
/// pick one.
final class SessionsPageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let host: TerminalHostViewController
    private var showingTerminal = false

    init(host: TerminalHostViewController) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var pillItems: [PillItem] {
        guard !host.sessions.isEmpty else { return [] }
        return [PillItem(id: "list", title: "All sessions")] + host.sessions.map { s in
            PillItem(id: "s:\(s.id)", title: s.title, icon: s.spec.icon,
                     accent: s.spec.accent, running: s.isRunning, closable: true,
                     attention: s.needsAttention)
        }
    }
    override var selectedPill: String? {
        showingTerminal ? host.current.map { "s:\($0.id)" } : "list"
    }
    override func pillSelected(_ id: String) {
        if id == "list" { showList() } else { show(sessionID: String(id.dropFirst(2))) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Sessions"
        pageSubtitle = "Everything you have open right now."
        host.onSessionsChanged("sessionsPage") { [weak self] in self?.reload() }
    }

    func show(sessionID: String) {
        host.select(id: sessionID)
        showingTerminal = true
        reload()
    }

    func showList() {
        showingTerminal = false
        reload()
    }

    /// A second, independent session on the same project.
    func duplicate(_ session: SSHSession) {
        openSession?(session.spec, true)
    }

    func closeSession(id: String) {
        host.close(id: id)
        if host.sessions.isEmpty { showingTerminal = false }
        reload()
    }

    override func reload() {
        clearBody()
        onPillsChanged?()
        setActions([])

        if showingTerminal, host.current != nil {
            setFullBleed(host.view)
            host.focusCurrent()
            return
        }
        setFullBleed(nil)

        guard !host.sessions.isEmpty else {
            let empty = EmptyStateView(
                emoji: "🫙", title: "Nothing running",
                message: "Open a project from the dashboard and its session shows up here.",
                action: nil)
            empty.heightAnchor.constraint(equalToConstant: 300).isActive = true
            body.addWide(empty)
            return
        }

        let count = host.sessions.filter(\.isRunning).count
        body.addWide(sectionHeader("Active",
                                   note: statusLabel(count > 0 ? .online : .idle,
                                                     text: "\(count) running")))
        for s in host.sessions { body.addWide(LiveSessionCard(session: s, page: self)) }
    }
}

/// A live session as a control surface: identity, state, elapsed time, actions.
final class LiveSessionCard: Surface {
    private let session: SSHSession
    private weak var page: SessionsPageVC?
    private let elapsed = NSTextField(labelWithString: "")
    private var timer: Timer?

    init(session: SSHSession, page: SessionsPageVC?) {
        self.session = session
        self.page = page
        super.init(radius: Radius.card, showsArrow: false)

        let tile = IconTile(side: 38)
        tile.configure(icon: session.spec.icon, accent: session.spec.accent)

        let name = NSTextField(labelWithString: session.spec.title)
        name.font = Fonts.title
        name.textColor = Text.primary

        let where_ = NSTextField(labelWithString: session.spec.subtitle)
        where_.font = Fonts.caption
        where_.textColor = Text.secondary
        where_.truncates(.byTruncatingMiddle)

        let identity = NSStackView(views: [name, where_])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1

        var badges: [NSView] = [Badge("SSH", tone: .info)]
        if let a = session.spec.agent, !a.command.isEmpty {
            badges.append(Badge(a.name, tone: .terminal))
        }
        let badgeRow = NSStackView(views: badges)
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6

        let state: NSStackView
        switch session.state {
        case .idle:
            state = statusLabel(.idle, text: "Idle", font: Fonts.bodyMed)
        case .connecting:
            state = statusLabel(.connecting, text: "Connecting", font: Fonts.bodyMed)
        case .running:
            state = statusLabel(.online, text: "Running", font: Fonts.bodyMed)
        case .reconnecting(let attempt, let left):
            state = statusLabel(.warning,
                                text: left > 0 ? "Reconnecting in \(left)s"
                                               : "Reconnecting… (\(attempt))",
                                font: Fonts.bodyMed)
        case .ended(let status):
            state = statusLabel(status.isClean ? .idle : .offline,
                                text: status.isClean ? "Exited" : status.label,
                                font: Fonts.bodyMed)
        }
        elapsed.font = Fonts.mono(11)
        elapsed.textColor = Text.muted
        let stateStack = NSStackView(views: [state, elapsed])
        stateStack.orientation = .vertical
        stateStack.alignment = .trailing
        stateStack.spacing = 1

        let open: SoftButton
        switch session.state {
        case .reconnecting:
            open = SoftButton("Reconnect now", symbol: "arrow.clockwise", style: .secondary)
            open.onClick = { session.reconnectNow() }
        case .ended:
            open = SoftButton("Reconnect", symbol: "arrow.clockwise", style: .secondary)
            open.onClick = { session.reconnectNow() }
        default:
            open = SoftButton("Open terminal", symbol: "arrow.up.forward.app",
                              style: .secondary)
            open.onClick = { [weak page] in page?.show(sessionID: session.id) }
        }

        let more = OverflowButton()
        var actions: [(String, () -> Void)] = [
            ("Open terminal", { [weak page] in page?.show(sessionID: session.id) }),
            ("Duplicate session", { [weak page] in page?.duplicate(session) }),
        ]
        if case .reconnecting = session.state {
            actions.append(("Stop reconnecting", { session.stopReconnecting() }))
        }
        actions.append(("Close session", { [weak page] in page?.closeSession(id: session.id) }))
        more.items = actions

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [tile, identity, badgeRow, spacer,
                                      stateStack, open, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 76),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private func tick() {
        guard session.isRunning else { elapsed.stringValue = ""; timer?.invalidate(); return }
        // measured from when the session opened, so it survives a list rebuild
        let d = Int(Date().timeIntervalSince(session.startedAt))
        elapsed.stringValue = String(format: "%02d:%02d:%02d", d / 3600, (d % 3600) / 60, d % 60)
    }
}
