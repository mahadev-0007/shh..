import AppKit

/// Sessions are a place you navigate to, not tabs bolted to the chrome. The
/// page lists what is running and hands the whole area to a terminal once you
/// pick one.
final class SessionsPageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let host: TerminalHostViewController
    private var showingTerminal = false

    // tmux sessions left running on servers with no tab attached
    private var background: [BackgroundSession] = []
    private var unreachable: [String] = []
    private var fetching = false
    private var lastFetch: Date?
    private var lastTabCount = 0

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
                     attention: s.needsAttention, movable: true,
                     tooltip: "\(s.title)\n\(s.spec.subtitle)")
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
        host.onSessionsChanged("sessionsPage") { [weak self] in self?.sessionsDidChange() }
    }

    /// Status changes arrive constantly — every second of a reconnect
    /// countdown, every bell. With a terminal on screen only the tabs need
    /// redrawing; rebuilding the page and re-focusing the terminal each time
    /// is wasted work and can pull focus out from under the user.
    private func sessionsDidChange() {
        // a tab just closed: its tmux session may now be running on its own
        if host.sessions.count < lastTabCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.fetchBackground(force: true)
            }
        }
        lastTabCount = host.sessions.count
        if showingTerminal, host.current != nil {
            onPillsChanged?()
            return
        }
        if showingTerminal { showingTerminal = false }   // the last one closed
        reload()
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

    func endSession(_ session: SSHSession) {
        shellController?.endSession(session)
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
        fetchBackground(force: false)

        let detached = visibleBackground
        guard !host.sessions.isEmpty || !detached.isEmpty else {
            let empty = EmptyStateView(
                emoji: "🫙", title: fetching ? "Checking your servers…" : "Nothing running",
                message: "Open a project from the dashboard and its session shows up here.",
                action: nil)
            empty.heightAnchor.constraint(equalToConstant: 300).isActive = true
            body.addWide(empty)
            addUnreachableNote()
            return
        }

        if !host.sessions.isEmpty {
            let count = host.sessions.filter(\.isRunning).count
            body.addWide(sectionHeader("Active",
                                       note: statusLabel(count > 0 ? .online : .idle,
                                                         text: "\(count) running")))
            for s in host.sessions { body.addWide(LiveSessionCard(session: s, page: self)) }
        }

        if !detached.isEmpty || fetching {
            body.addWide(sectionHeader(
                "Running in background",
                note: statusLabel(.idle, text: fetching && detached.isEmpty
                                  ? "checking…" : "\(detached.count) detached"),
                action: ("Refresh", { [weak self] in self?.fetchBackground(force: true) })))
            for b in detached { body.addWide(BackgroundSessionCard(session: b, page: self)) }
        }
        addUnreachableNote()
    }

    // MARK: - background sessions

    /// Hide any that a tab here is already attached to.
    private var visibleBackground: [BackgroundSession] {
        let open = Set(host.sessions.compactMap(\.tmuxName))
        return background.filter { !open.contains($0.name) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func addUnreachableNote() {
        guard !unreachable.isEmpty else { return }
        let l = NSTextField(labelWithString:
            "Couldn't check " + unreachable.joined(separator: ", ") + " for background sessions.")
        l.font = Fonts.caption
        l.textColor = Text.muted
        body.addWide(l)
    }

    /// Ask every server that has projects which shh tmux sessions it's running.
    /// Throttled: the list page reloads often, and each check is a round trip.
    func fetchBackground(force: Bool) {
        guard !fetching else { return }
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 20 { return }
        let projects = AppModel.shared.projectList.filter { !$0.isOrphan }
        let servers = Dictionary(grouping: projects, by: { $0.project.server })
            .compactMap { $0.value.first?.server }
        guard !servers.isEmpty else { background = []; return }

        fetching = true
        lastFetch = Date()
        var found: [BackgroundSession] = []
        var failed: [String] = []
        let group = DispatchGroup()
        for vm in servers {
            group.enter()
            let mine = projects.filter { $0.project.server == vm.slug }.map(\.project)
            RemoteSessions.list(server: vm.server, projects: mine) { result in
                switch result {
                case .success(let list): found += list
                case .failure: failed.append(vm.title)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.fetching = false
            self.background = found
            self.unreachable = failed.sorted()
            if !self.showingTerminal { self.reload() }
        }
    }

    func reattach(_ b: BackgroundSession) {
        guard let pid = b.projectID, let vm = AppModel.shared.projectVM(id: pid),
              var spec = AppModel.shared.launchSpec(for: vm) else { return }
        spec.tmuxName = b.name
        spec.ordinal = b.ordinal
        openSession?(spec, true)
    }

    func end(_ b: BackgroundSession, title: String) {
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "End “\(title)”?"
        a.informativeText = "This stops whatever is running in it on \(b.server.display) "
            + "and closes its tmux session."
        a.alertStyle = .warning
        a.addButton(withTitle: "End Session")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            // gone from the list straight away; the server catches up
            self.background.removeAll { $0.name == b.name && $0.server == b.server }
            self.reload()
            RemoteSessions.kill(server: b.server, name: b.name) { [weak self] result in
                if case .failure(let e) = result {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't end “\(title)”"
                    alert.informativeText = e.localizedDescription
                    if let w = self?.view.window { alert.beginSheetModal(for: w) }
                    self?.fetchBackground(force: true)
                }
            }
        }
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
        actions.append(("Close tab", { [weak page] in page?.closeSession(id: session.id) }))
        if session.tmuxName != nil {
            actions.append(("End session…", { [weak page] in page?.endSession(session) }))
        }
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


/// A tmux session still running on a server with no tab attached.
final class BackgroundSessionCard: Surface {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(session b: BackgroundSession, page: SessionsPageVC?) {
        super.init(radius: Radius.card, showsArrow: false)
        let vm = b.projectID.flatMap { AppModel.shared.projectVM(id: $0) }
        let server = AppModel.shared.serverVM(slug: b.server.name)
        let title = vm.map { b.ordinal > 1 ? "\($0.title) #\(b.ordinal)" : $0.title } ?? b.name
        let accent = vm?.accent ?? server?.accent ?? Ink.neutral

        let tile = IconTile(side: 38)
        tile.configure(icon: vm?.icon ?? .emoji("🫥"), accent: accent)
        tile.alphaValue = 0.75

        let name = NSTextField(labelWithString: title)
        name.font = Fonts.title
        name.textColor = Text.primary
        let where_ = NSTextField(labelWithString:
            "\(server?.title ?? b.server.display) · \(vm?.agentName ?? "project removed")")
        where_.font = Fonts.caption
        where_.textColor = Text.secondary
        where_.truncates(.byTruncatingMiddle)
        let identity = NSStackView(views: [name, where_])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1

        var badges: [NSView] = [Badge("tmux", tone: .neutral)]
        if b.attachedClients > 0 { badges.append(Badge("attached elsewhere", tone: .info)) }
        let badgeRow = NSStackView(views: badges)
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6

        let now = Date()
        let state = statusLabel(.idle, text: "Detached", font: Fonts.bodyMed)
        let times = NSTextField(labelWithString:
            "active \(Self.relative.localizedString(for: b.lastActivity, relativeTo: now))"
            + " · started \(Self.relative.localizedString(for: b.created, relativeTo: now))")
        times.font = Fonts.mono(11)
        times.textColor = Text.muted
        let stateStack = NSStackView(views: [state, times])
        stateStack.orientation = .vertical
        stateStack.alignment = .trailing
        stateStack.spacing = 1

        var trailing: [NSView] = [stateStack]
        if vm != nil {
            let open = SoftButton("Open", symbol: "arrow.up.forward.app", style: .secondary)
            open.onClick = { [weak page] in page?.reattach(b) }
            trailing.append(open)
        }
        let more = OverflowButton()
        more.items = [("End session…", { [weak page] in page?.end(b, title: title) })]
        trailing.append(more)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [tile, identity, badgeRow, spacer] + trailing)
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
    }
    required init?(coder: NSCoder) { fatalError() }
}
