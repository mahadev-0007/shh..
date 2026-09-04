import AppKit

/// Where you land: system state first, then what is live, then what to launch,
/// then what happened. Colour appears only where it means something.
final class DashboardPageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private(set) var reachable: [String: Bool] = [:]
    private(set) var probing = false
    private var activityFilter = "all"

    override var pillItems: [PillItem] { [] }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = greeting
        pageSubtitle = "Pick a project and get to work."
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "morning" : (h < 18 ? "afternoon" : "evening")
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "Good \(part)" : "Good \(part), \(name)"
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        probeServers()
    }

    private var root: RootSplitViewController? {
        view.window?.contentViewController as? RootSplitViewController
    }

    private var liveSessions: [SSHSession] { root?.shell.terminals.sessions ?? [] }

    // MARK: - build

    override func reload() {
        clearBody()
        pageTitle = greeting
        let model = AppModel.shared

        guard !model.serverList.isEmpty || !model.projectList.isEmpty else {
            let b = SoftButton("Add a server", symbol: "plus", style: .primary)
            b.onClick = { [weak self] in self?.root?.go(to: .servers) }
            let empty = EmptyStateView(
                emoji: "🫧", title: "Nothing set up yet",
                message: "Add a server, point a project at a directory on it, and pick the "
                       + "agent that should open it.",
                action: b)
            empty.heightAnchor.constraint(equalToConstant: 380).isActive = true
            body.addWide(empty)
            return
        }

        buildMetrics()
        buildRunningNow()
        buildQuickLaunch()
        buildActivity()
    }

    // MARK: - metrics

    private func buildMetrics() {
        let model = AppModel.shared
        let servers = model.serverList.count
        let online = reachable.values.filter { $0 }.count
        let live = liveSessions.filter(\.isRunning).count
        let health = servers == 0 ? 0 : Int(Double(online) / Double(servers) * 100)
        let newThisWeek = model.projectList.filter {
            Date().timeIntervalSince1970 - $0.project.createdAt < 7 * 86400
        }.count

        func note(_ text: String, tone: NSColor) -> NSView {
            let l = NSTextField(labelWithString: text)
            l.font = Fonts.caption
            l.textColor = tone
            return l
        }

        let tiles: [NSView] = [
            {
                let t = MetricTile(symbol: "folder", label: "Projects",
                                   value: pad(model.projectList.count),
                                   footnote: newThisWeek > 0
                                       ? note("+\(newThisWeek) this week", tone: Ink.success)
                                       : note("all projects", tone: Text.muted),
                                   tone: .accent)
                t.onClick = { [weak self] _ in self?.root?.go(to: .projects) }
                return t
            }(),
            {
                let t = MetricTile(symbol: "externaldrive.connected.to.line.below",
                                   label: "Servers", value: pad(servers),
                                   footnote: probing
                                       ? note("checking…", tone: Text.muted)
                                       : statusLabel(online == servers ? .online
                                                     : (online == 0 ? .offline : .warning),
                                                     text: "\(online) online"),
                                   tone: .info)
                t.onClick = { [weak self] _ in self?.root?.go(to: .servers) }
                return t
            }(),
            MetricTile(symbol: "waveform.path.ecg", label: "Health",
                       value: probing ? "—" : "\(health)%",
                       footnote: note("\(online) / \(servers) reachable", tone: Text.muted),
                       tone: health == 100 ? .success : (health == 0 ? .error : .warning)),
            {
                let t = MetricTile(symbol: "terminal", label: "Sessions", value: pad(live),
                                   footnote: live > 0
                                       ? statusLabel(.online, text: "active now")
                                       : note("nothing running", tone: Text.muted),
                                   tone: .terminal)
                t.onClick = { [weak self] _ in self?.root?.go(to: .sessions) }
                return t
            }(),
        ]

        let grid = FlowStackView()
        grid.itemHeight = 136
        grid.itemWidth = 168
        grid.gap = Space.md
        grid.set(tiles)
        body.addWide(grid)
    }

    /// `01` reads as a metric; `1` reads as a stray character.
    private func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    // MARK: - running now

    private func buildRunningNow() {
        let sessions = liveSessions
        guard !sessions.isEmpty else { return }
        let active = sessions.filter(\.isRunning).count
        body.addWide(sectionHeader(
            "Running now",
            note: statusLabel(active > 0 ? .online : .idle,
                              text: "\(active) active session\(active == 1 ? "" : "s")"),
            action: ("View all", { [weak self] in self?.root?.go(to: .sessions) })))
        for s in sessions.prefix(3) { body.addWide(runningRow(s)) }
    }

    private func runningRow(_ s: SSHSession) -> NSView {
        let card = Surface(radius: Radius.card)
        card.isInteractive = true
        card.onClick = { [weak self] _ in
            self?.root?.go(to: .sessions)
            (self?.root?.shell.topPage as? SessionsPageVC)?.show(sessionID: s.id)
        }

        let tile = IconTile(side: 38)
        tile.configure(icon: s.spec.icon, accent: s.spec.accent)

        let name = NSTextField(labelWithString: s.spec.title)
        name.font = Fonts.title
        name.textColor = Text.primary
        let sub = NSTextField(labelWithString: s.spec.subtitle)
        sub.font = Fonts.caption
        sub.textColor = Text.secondary
        sub.truncates(.byTruncatingMiddle)
        let identity = NSStackView(views: [name, sub])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 1

        var badges: [NSView] = [Badge("SSH", tone: .info)]
        if let a = s.spec.agent, !a.command.isEmpty {
            badges.append(Badge(a.name, tone: .terminal))
        }
        let badgeRow = NSStackView(views: badges)
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6

        let state = statusLabel(s.isRunning ? .online : .idle,
                                text: s.isRunning ? "Running" : "Exited",
                                font: Fonts.bodyMed)

        let open = SoftButton("Open terminal", symbol: "arrow.up.forward.app", style: .secondary)
        open.onClick = { [weak self] in
            self?.root?.go(to: .sessions)
            (self?.root?.shell.topPage as? SessionsPageVC)?.show(sessionID: s.id)
        }
        let more = OverflowButton()
        more.items = [("Close session", { [weak self] in
            self?.root?.shell.terminals.close(id: s.id)
            self?.reload()
        })]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [tile, identity, badgeRow, spacer, state, open, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 72),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Space.lg),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Space.md),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    // MARK: - quick launch

    private func buildQuickLaunch() {
        let projects = Array(AppModel.shared.projectList.filter { !$0.isOrphan }.prefix(5))
        body.addWide(sectionHeader(
            "Quick launch",
            note: mutedNote("Your projects, one click away."),
            action: ("View all", { [weak self] in self?.root?.go(to: .projects) })))

        var cards: [NSView] = projects.map(launcherCard)
        cards.append(newProjectCard())

        let grid = FlowStackView()
        grid.itemHeight = 146
        grid.itemWidth = 250
        grid.gap = Space.md
        grid.set(cards)
        body.addWide(grid)
    }

    private func mutedNote(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = Fonts.caption
        l.textColor = Text.muted
        return l
    }

    private func launcherCard(_ vm: ProjectVM) -> NSView {
        let card = Surface(radius: Radius.card, showsArrow: true)
        card.isInteractive = true

        let tile = IconTile(side: 40)
        tile.configure(icon: vm.icon, accent: vm.accent)

        let name = NSTextField(labelWithString: vm.title)
        name.font = Fonts.title
        name.textColor = Text.primary
        name.truncates(.byTruncatingTail)

        let server = NSTextField(labelWithString: vm.server?.title ?? "server missing")
        server.font = Fonts.caption
        server.textColor = Text.secondary

        var badges: [NSView] = [Badge("SSH", tone: .info)]
        if let a = vm.agent, !a.command.isEmpty { badges.append(Badge(a.name, tone: .terminal)) }
        let badgeRow = NSStackView(views: badges + [NSView()])
        badgeRow.orientation = .horizontal
        badgeRow.spacing = 6

        let stack = NSStackView(views: [tile, name, server, badgeRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(Space.md, after: tile)
        stack.setCustomSpacing(Space.md, after: server)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Space.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor,
                                          constant: -Space.lg),
            badgeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        card.onClick = { [weak self] event in
            guard let spec = AppModel.shared.launchSpec(for: vm) else { return }
            self?.openSession?(spec, event.modifierFlags.contains(.option))
        }
        card.toolTip = "Open with \(vm.agentName) — ⌥-click for a second session"
        return card
    }

    private func newProjectCard() -> NSView {
        let card = DashedSurface()
        card.isInteractive = true
        card.onClick = { [weak self] _ in
            self?.root?.go(to: .projects)
            (self?.root?.shell.topPage as? ProjectsPageVC)?.addProject()
        }
        let plus = IconTile(side: 40)
        plus.configure(icon: .symbol("plus"), accent: Ink.accent)
        let name = NSTextField(labelWithString: "New project")
        name.font = Fonts.title
        name.textColor = Text.primary
        let sub = NSTextField(labelWithString: "Point sshm at a directory")
        sub.font = Fonts.caption
        sub.textColor = Text.muted

        let stack = NSStackView(views: [plus, name, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(Space.md, after: plus)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor,
                                            constant: -Space.md),
        ])
        return card
    }

    // MARK: - activity

    private func buildActivity() {
        let recents = AppModel.shared.recentProjects
        guard !recents.isEmpty else { return }
        body.addWide(sectionHeader("Recent activity"))

        let list = Surface(radius: Radius.card)
        let rows = recents.prefix(6).enumerated().map { i, vm -> NSView in
            activityRow(vm, showDivider: i > 0)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: list.topAnchor),
            stack.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        body.addWide(list)
    }

    /// what → where → how → when, scannable across four columns.
    private func activityRow(_ vm: ProjectVM, showDivider: Bool) -> NSView {
        let container = HoverRow()
        container.isInteractive = !vm.isOrphan
        container.onClick = { [weak self] event in
            guard let spec = AppModel.shared.launchSpec(for: vm) else { return }
            self?.openSession?(spec, event.modifierFlags.contains(.option))
        }

        let tile = IconTile(side: 30, radius: 8)
        tile.configure(icon: vm.icon, accent: vm.accent)

        let what = NSTextField(labelWithString: vm.title)
        what.font = Fonts.bodyMed
        what.textColor = Text.primary
        let whereText = NSTextField(labelWithString: vm.project.path)
        whereText.font = Fonts.mono(11)
        // this is information you scan, so it does not get muted text
        whereText.textColor = Text.secondary
        whereText.truncates(.byTruncatingMiddle)

        let identity = NSStackView(views: [what, whereText])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 0

        let when = NSTextField(labelWithString: relative(vm.project.lastOpenedAt))
        when.font = Fonts.caption
        when.textColor = Text.muted
        when.alignment = .right

        let more = OverflowButton()
        more.items = [("Edit project", { [weak self] in
            self?.pushPage?(ProjectEditPageVC(editing: vm))
        })]

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [tile, identity, spacer,
                                      Badge(vm.agentName, tone: .terminal), when, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        var constraints: [NSLayoutConstraint] = [
            container.heightAnchor.constraint(equalToConstant: 56),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Space.lg),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Space.md),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            when.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
        ]
        if showDivider {
            let d = ThemedDivider()
            d.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(d)
            constraints += [
                d.topAnchor.constraint(equalTo: container.topAnchor),
                d.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Space.lg),
                d.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Space.lg),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func relative(_ t: Double) -> String {
        guard t > 0 else { return "" }
        let d = Date().timeIntervalSince1970 - t
        switch d {
        case ..<60:     return "Just now"
        case ..<3600:   return "\(Int(d / 60)) min ago"
        case ..<86400:  return "\(Int(d / 3600)) hr ago"
        case ..<172800: return "Yesterday"
        case ..<604800: return "\(Int(d / 86400)) days ago"
        default:
            let f = DateFormatter(); f.dateFormat = "d MMM"
            return f.string(from: Date(timeIntervalSince1970: t))
        }
    }

    // MARK: - reachability

    func probeServers() {
        let servers = AppModel.shared.serverList
        guard !servers.isEmpty, !probing else { return }
        probing = true
        root?.shell.topBar.setEnvironment(online: 0, total: servers.count, checking: true)

        let group = DispatchGroup()
        var results: [String: Bool] = [:]
        let lock = NSLock()
        for vm in servers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let ok = Reachability.canConnect(host: vm.server.host,
                                                 port: Int(vm.server.port) ?? 22, timeout: 3)
                lock.lock(); results[vm.slug] = ok; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.reachable = results
            self.probing = false
            self.root?.shell.topBar.setEnvironment(
                online: results.values.filter { $0 }.count,
                total: servers.count, checking: false)
            self.reload()
        }
    }
}

/// A row that lights up on hover — the activity list's unit.
final class HoverRow: Surface {
    init() {
        super.init(radius: 0, showsArrow: false)
        layer?.borderWidth = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (isHovering && isInteractive
                                  ? Ink.hover : NSColor.clear).cg(self)
    }
}

/// The dashed "add something" affordance.
final class DashedSurface: Surface {
    private let dash = CAShapeLayer()

    init() {
        super.init(radius: Radius.card, showsArrow: false)
        layer?.borderWidth = 0
        dash.fillColor = nil
        dash.lineDashPattern = [5, 4]
        dash.lineWidth = 1
        layer?.addSublayer(dash)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: Radius.card, cornerHeight: Radius.card,
                           transform: nil)
    }

    override func applyTheme() {
        layer?.backgroundColor = (isHovering ? Ink.hover : NSColor.clear).cg(self)
        dash.strokeColor = (isHovering ? Ink.accent : Ink.borderStrong).cg(self)
    }
}

enum Reachability {
    static func canConnect(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return false
        }
        defer { freeaddrinfo(info) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype,
                        first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
    }
}
