import AppKit

/// The right-hand side of the window: a pill bar and whatever page is on top of
/// the current section's stack. Sessions live here too, as pills after a divider.
///
/// The rule that keeps this from becoming a controller zoo: a view controller
/// exists only if it occupies the content area. Cards, rows and pills are views.
final class ShellViewController: NSViewController {

    let topBar = TopBar()
    private let pillBar = PillSegmentedControl()
    private let container = NSView()
    /// Collapsed to nothing on pages that have no sub-views and no sessions, so
    /// they don't sit under an empty band.
    private var pillHeight: NSLayoutConstraint!
    private var topBarHeight: NSLayoutConstraint!
    /// Focus mode: chrome out of the way so a session owns the window.
    private(set) var isFocusMode = false

    /// One nav stack per rail section, so switching sections and coming back
    /// restores scroll position and any half-filled form.
    private var stacks: [RailSection: [PageViewController]] = [:]
    private(set) var section: RailSection = .dashboard

    let terminals = TerminalHostViewController()
    private var showingTerminal = false

    /// The page currently on top of the active section's stack.
    var topPage: PageViewController? { stacks[section]?.last }
    private var top: PageViewController? { topPage }

    override func loadView() {
        let root = ThemedCanvas()

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBarHeight = topBar.heightAnchor.constraint(equalToConstant: 64)
        topBarHeight.priority = .required - 1
        topBarHeight.isActive = true
        root.addSubview(topBar)
        pillBar.translatesAutoresizingMaskIntoConstraints = false
        pillBar.onSelect = { [weak self] id in self?.pillTapped(id) }
        pillBar.onClose = { [weak self] id in self?.closeSessionPill(id) }

        container.translatesAutoresizingMaskIntoConstraints = false
        pillHeight = pillBar.heightAnchor.constraint(equalToConstant: 40)
        pillHeight.priority = .required - 1
        root.addSubview(pillBar)
        root.addSubview(container)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.page),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.page),

            pillBar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: Space.xs),
            pillHeight,
            pillBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.page),
            pillBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                              constant: -Space.page),
            container.topAnchor.constraint(equalTo: pillBar.bottomAnchor, constant: Space.sm),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root

        addChild(terminals)
        terminals.onSessionsChanged = { [weak self] in self?.refreshPills() }
        terminals.onSessionSelected = { [weak self] in self?.refreshPills() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        topBar.onSearch = { [weak self] in self?.openPalette() }
        topBar.onTheme = { [weak self] in self?.cycleTheme() }
        topBar.onPrimary = { [weak self] in self?.primaryAction() }
        topBar.setTheme(AppModel.shared.settings.theme)
        show(section: .dashboard)
    }

    // MARK: - chrome actions

    private func primaryAction() {
        switch section {
        case .servers:
            (topPage as? ServersPageVC)?.addServer()
        default:
            root?.go(to: .projects)
            (topPage as? ProjectsPageVC)?.addProject()
        }
    }

    private var root: RootSplitViewController? {
        view.window?.contentViewController as? RootSplitViewController
    }

    func cycleTheme() {
        let all = ThemeMode.allCases
        let next = all[(all.firstIndex(of: AppModel.shared.settings.theme).map { $0 + 1 } ?? 0)
                       % all.count]
        AppModel.shared.updateSettings { $0.theme = next }
        Theme.apply(mode: next)
        topBar.setTheme(next)
    }

    func openPalette() {
        var rows: [CommandPalette.Row] = []
        for vm in AppModel.shared.projectList where !vm.isOrphan {
            rows.append(.init(group: "Projects", title: vm.title,
                              detail: "\(vm.server?.title ?? "") · \(vm.project.path)",
                              icon: vm.icon, accent: vm.accent) { [weak self] in
                guard let spec = AppModel.shared.launchSpec(for: vm) else { return }
                self?.openSession(spec, forceNew: false)
            })
        }
        for vm in AppModel.shared.serverList {
            rows.append(.init(group: "Servers", title: vm.title, detail: vm.subtitle,
                              icon: vm.icon, accent: vm.accent) { [weak self] in
                self?.openSession(AppModel.shared.launchSpec(forServer: vm), forceNew: false)
            })
        }
        for s in terminals.sessions {
            rows.append(.init(group: "Sessions", title: s.spec.title,
                              detail: s.isRunning ? "running" : "exited",
                              icon: s.spec.icon, accent: s.spec.accent) { [weak self] in
                self?.root?.go(to: .sessions)
                (self?.topPage as? SessionsPageVC)?.show(sessionID: s.id)
            })
        }
        let actions: [(String, String, () -> Void)] = [
            ("New project", "plus", { [weak self] in
                self?.root?.go(to: .projects)
                (self?.topPage as? ProjectsPageVC)?.addProject() }),
            ("New server", "plus", { [weak self] in
                self?.root?.go(to: .servers)
                (self?.topPage as? ServersPageVC)?.addServer() }),
            ("Go to dashboard", "square.grid.2x2", { [weak self] in self?.root?.go(to: .dashboard) }),
            ("Go to sessions", "terminal", { [weak self] in self?.root?.go(to: .sessions) }),
            ("Settings", "gearshape", { [weak self] in self?.root?.go(to: .settings) }),
            ("Toggle appearance", "circle.lefthalf.filled", { [weak self] in self?.cycleTheme() }),
        ]
        for (title, symbol, run) in actions {
            rows.append(.init(group: "Actions", title: title, detail: "",
                              icon: .symbol(symbol), accent: Ink.accent, run: run))
        }
        CommandPalette.present(rows: rows, over: view.window)
    }

    // MARK: - sections and pages

    func show(section s: RailSection) {
        section = s
        if stacks[s] == nil { stacks[s] = [makeRoot(for: s)] }
        showingTerminal = false
        present(top!)
        refreshPills()
        topBar.setPrimary(title: s == .servers ? "New server" : "New project")
    }

    private func makeRoot(for s: RailSection) -> PageViewController {
        let page: PageViewController
        switch s {
        case .dashboard: page = DashboardPageVC()
        case .projects:  page = ProjectsPageVC()
        case .servers:   page = ServersPageVC()
        case .sessions:  page = SessionsPageVC(host: terminals)
        case .settings:  page = SettingsPageVC()
        }
        wire(page)
        return page
    }

    private func wire(_ page: PageViewController) {
        page.onPillsChanged = { [weak self] in self?.refreshPills() }
        if let nav = page as? NavigatingPage {
            nav.pushPage = { [weak self] p in self?.push(p) }
            nav.openSession = { [weak self] spec, forceNew in
                self?.openSession(spec, forceNew: forceNew)
            }
        }
    }

    func push(_ page: PageViewController) {
        wire(page)
        page.onBack = { [weak self] in self?.pop() }
        stacks[section, default: []].append(page)
        page.installBackButton()
        showingTerminal = false
        present(page)
        refreshPills()
    }

    func pop() {
        guard var stack = stacks[section], stack.count > 1 else { return }
        let gone = stack.removeLast()
        stacks[section] = stack
        gone.removeFromParent()
        showingTerminal = false
        present(stack.last!)
        refreshPills()
    }

    private func present(_ page: PageViewController) {
        let incoming = page.view
        if page.parent == nil { addChild(page) }
        incoming.translatesAutoresizingMaskIntoConstraints = false

        for v in container.subviews { v.removeFromSuperview() }
        container.addSubview(incoming)
        NSLayoutConstraint.activate([
            incoming.topAnchor.constraint(equalTo: container.topAnchor),
            incoming.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            incoming.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            incoming.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        page.reload()
        // The terminal swallows plain keys once focused, so focus has to be
        // handed back explicitly every time a page comes forward.
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.view.window else { return }
            w.makeFirstResponder(page.initialResponder ?? page.view)
            w.title = "sshm — \(page.pageTitle)"
        }
    }

    private func presentTerminals() {
        showingTerminal = true
        let v = terminals.view
        v.translatesAutoresizingMaskIntoConstraints = false
        for sub in container.subviews { sub.removeFromSuperview() }
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminals.focusCurrent()
        if let s = terminals.current {
            view.window?.title = "🤫 \(s.spec.title) · \(s.spec.subtitle)"
        }
    }

    // MARK: - sessions

    func openSession(_ spec: LaunchSpec, forceNew: Bool) {
        if !forceNew, let pid = spec.projectID,
           let existing = terminals.session(forProject: pid), existing.isRunning {
            terminals.select(id: existing.id)
        } else {
            terminals.open(spec)
        }
        if let pid = spec.projectID { AppModel.shared.markOpened(projectID: pid) }
        // sessions have their own destination now
        root?.go(to: .sessions)
        if let id = terminals.current?.id {
            (topPage as? SessionsPageVC)?.show(sessionID: id)
        }
    }

    private func closeSessionPill(_ id: String) {
        guard id.hasPrefix("s:") else { return }
        terminals.close(id: String(id.dropFirst(2)))
        if terminals.sessions.isEmpty {
            showingTerminal = false
            if let t = top { present(t) }
        } else {
            presentTerminals()
        }
        refreshPills()
    }

    // MARK: - pill bar

    private func refreshPills() {
        var items: [PillItem] = []
        var divider: Int?

        if let page = top {
            items = page.pillItems
        }

        let selected: String?
        if showingTerminal, let c = terminals.current {
            selected = "s:\(c.id)"
        } else {
            selected = top?.selectedPill ?? items.first?.id
        }
        pillBar.set(items: items, selected: selected, dividerBefore: divider)
        // A lone page pill is noise, but a lone *session* pill is the only way
        // back to that tab — it must never be hidden.
        let show = items.count >= 2 || !terminals.sessions.isEmpty
        pillBar.isHidden = !show
        pillHeight.constant = show ? 40 : 0
    }

    private func pillTapped(_ id: String) {
        if id.hasPrefix("s:") {
            terminals.select(id: String(id.dropFirst(2)))
            presentTerminals()
        } else {
            if showingTerminal, let t = top { showingTerminal = false; present(t) }
            top?.pillSelected(id)
        }
        refreshPills()
    }

    // MARK: - commands

    /// Bring an already-running session forward (the Dashboard's "Running now").
    func focusSession(id: String) {
        guard terminals.sessions.contains(where: { $0.id == id }) else { return }
        terminals.select(id: id)
        presentTerminals()
        refreshPills()
    }

    /// Hide the sidebar and top bar so the terminal fills the window. The pill
    /// bar stays: it is the only way back out.
    func toggleFocusMode() {
        isFocusMode.toggle()
        let root = self.root
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            root?.setSidebarCollapsed(isFocusMode)
            topBar.isHidden = isFocusMode
            topBarHeight.constant = isFocusMode ? 0 : 64
            view.layoutSubtreeIfNeeded()
        }
        terminals.focusCurrent()
    }

    func nextSession() { terminals.cycle(+1); if terminals.current != nil { presentTerminals() }; refreshPills() }
    func prevSession() { terminals.cycle(-1); if terminals.current != nil { presentTerminals() }; refreshPills() }

    func closeCurrentSession() {
        guard let c = terminals.current else { return }
        closeSessionPill("s:\(c.id)")
    }
}

/// Pages that need to push another page or open a session adopt this; the shell
/// fills the closures in when it wires them up.
protocol NavigatingPage: AnyObject {
    var pushPage: ((PageViewController) -> Void)? { get set }
    var openSession: ((LaunchSpec, Bool) -> Void)? { get set }
}
