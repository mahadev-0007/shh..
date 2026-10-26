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
    private var keyMonitor: Any?

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
        pillBar.onContextMenu = { [weak self] id in self?.sessionMenu(for: id) }
        pillBar.onReorder = { [weak self] ids in
            self?.terminals.reorder(ids: ids.filter { $0.hasPrefix("s:") }
                                             .map { String($0.dropFirst(2)) })
        }

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
        terminals.onSessionsChanged("shell") { [weak self] in self?.refreshPills() }
        terminals.onCloseRequest = { [weak self] id in self?.closeSessionPill("s:\(id)") }
        terminals.onEndRequest = { [weak self] s in self?.endSession(s) }
        terminals.onSessionSelected("shell") { [weak self] in self?.refreshPills() }
        Notifier.shared.onActivateSession = { [weak self] id in
            self?.focusSession(id: id)
        }
        // ⌃Tab / ⌃⇧Tab cycle tabs like a browser. A local monitor, because the
        // focused terminal would otherwise take the key for itself.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.view.window, e.keyCode == 48,
                  e.modifierFlags.contains(.control),
                  !e.modifierFlags.contains(.command),
                  !self.terminals.sessions.isEmpty else { return e }
            e.modifierFlags.contains(.shift) ? self.prevSession() : self.nextSession()
            return nil
        }
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
        for vm in AppModel.shared.serverList {
            rows.append(.init(group: "Files", title: "Browse files on \(vm.title)",
                              detail: vm.subtitle, icon: .symbol("folder"),
                              accent: vm.accent) { [weak self] in
                self?.browseFiles(server: vm, path: "~")
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
            ("Go to files", "folder", { [weak self] in self?.root?.go(to: .files) }),
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
        case .files:     page = FilesHomePageVC()
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
        present(page)
        refreshPills()
    }

    func pop() {
        guard var stack = stacks[section], stack.count > 1 else { return }
        let gone = stack.removeLast()
        stacks[section] = stack
        gone.removeFromParent()
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

    /// Show the current session's terminal.
    ///
    /// The Sessions page is the one and only place the terminal host lives.
    /// It used to be dropped straight into the content area from here as well,
    /// and the two fought over it: the next status change reloaded the
    /// off-screen Sessions page, which pulled the terminals into itself and
    /// left the window blank until another tab was clicked.
    private func showCurrentSession() {
        guard let s = terminals.current else { return }
        if section != .sessions {
            root?.go(to: .sessions)
        } else {
            while (stacks[.sessions]?.count ?? 0) > 1 { pop() }
        }
        guard let page = stacks[.sessions]?.first as? SessionsPageVC else { return }
        if page.view.superview !== container { present(page) }
        page.show(sessionID: s.id)
        refreshPills()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.title = "🤫 \(s.spec.title) · \(s.spec.subtitle)"
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
        // the Sessions page watches the host and moves to the neighbour, or
        // back to its list when this was the last one
        terminals.close(id: String(id.dropFirst(2)))
        refreshPills()
    }

    // MARK: - pill bar

    private func refreshPills() {
        var items: [PillItem] = []
        var divider: Int?

        if let page = top {
            items = page.pillItems
        }

        let selected = top?.selectedPill ?? items.first?.id
        pillBar.set(items: items, selected: selected, dividerBefore: divider)
        // A lone page pill is noise, but a lone *session* pill is the only way
        // back to that tab — it must never be hidden.
        let show = items.count >= 2 || !terminals.sessions.isEmpty
        pillBar.isHidden = !show
        pillHeight.constant = show ? 40 : 0
    }

    private func pillTapped(_ id: String) {
        // session pills only exist on the Sessions page, which handles both kinds
        top?.pillSelected(id)
        refreshPills()
    }

    // MARK: - commands

    /// Right-click menu for a session tab.
    private func sessionMenu(for pillID: String) -> NSMenu? {
        guard pillID.hasPrefix("s:") else { return nil }
        let sessionID = String(pillID.dropFirst(2))
        guard let session = terminals.sessions.first(where: { $0.id == sessionID })
        else { return nil }

        let menu = NSMenu()
        func add(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run)
            menu.addItem(item)
        }

        add("Duplicate Session") { [weak self] in self?.duplicate(session) }
        add("Browse Files") { [weak self] in self?.browseFiles(of: session) }
        menu.addItem(.separator())
        if case .reconnecting = session.state {
            add("Reconnect Now") { session.reconnectNow() }
            add("Stop Reconnecting") { session.stopReconnecting() }
        } else if !session.isRunning {
            add("Reconnect") { session.reconnectNow() }
        }
        add("Close Tab") { [weak self] in self?.closeSessionPill(pillID) }
        if session.tmuxName != nil {
            add("End Session…") { [weak self] in self?.endSession(session) }
        }
        if terminals.sessions.count > 1 {
            add("Close Other Sessions") { [weak self] in
                self?.terminals.closeOthers(keeping: sessionID)
                self?.refreshPills()
            }
        }
        if terminals.sessions.last?.id != sessionID {
            add("Close Sessions to the Right") { [weak self] in
                self?.terminals.closeAfter(id: sessionID)
                self?.refreshPills()
            }
        }
        if terminals.canReopen {
            menu.addItem(.separator())
            add("Reopen Closed Session") { [weak self] in self?.reopenClosedSession() }
        }
        return menu
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    /// Open the file browser on a server in the Files section, replacing
    /// whatever browser was there so Back always lands on the server list.
    func browseFiles(server: ServerVM, path: String) {
        root?.go(to: .files)
        while (stacks[.files]?.count ?? 0) > 1 { pop() }
        push(FilesPageVC(server: server, startPath: path))
    }

    /// Files for a session's server, starting where the session started (⇧⌘F).
    func browseFiles(of session: SSHSession) {
        let vm = AppModel.shared.serverVM(slug: session.server.name)
            ?? ServerVM(server: session.server, meta: nil)
        browseFiles(server: vm, path: session.spec.path ?? "~")
    }

    /// The "New server" form, from whichever section asked for it.
    func addServerFromAnywhere() {
        root?.go(to: .servers)
        (topPage as? ServersPageVC)?.addServer()
    }

    func browseCurrentSessionFiles() {
        guard let s = terminals.current else { return }
        browseFiles(of: s)
    }

    /// Duplicate whichever session is on screen (⇧⌘D).
    func duplicateCurrentSession() {
        guard let s = terminals.current else { return }
        duplicate(s)
    }

    /// A second, independent session on the same project — its own tab and
    /// its own tmux session on the server — placed right after the original.
    func duplicate(_ s: SSHSession) {
        let at = (terminals.sessions.firstIndex { $0 === s } ?? terminals.sessions.count) + 1
        openSession(s.spec, forceNew: true)
        if let new = terminals.current, new !== s { terminals.move(id: new.id, to: at) }
    }

    /// Close the tab *and* stop what's running in it on the server.
    ///
    /// Closing a tab only detaches from its tmux session — the agent keeps
    /// going and the next open lands back in it. This is the other one.
    func endSession(_ s: SSHSession) {
        guard s.tmuxName != nil else { closeSessionPill("s:\(s.id)"); return }
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "End “\(s.title)”?"
        let what = s.spec.agent.flatMap { $0.command.isEmpty ? nil : $0.name }
        a.informativeText = "This stops \(what ?? "everything running") in it on "
            + "\(s.server.display) and closes its tmux session. "
            + "Next time it opens fresh.\n\nTo leave it running, just close the tab."
        a.alertStyle = .warning
        a.addButton(withTitle: "End Session")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            // close first: the tmux client detaches cleanly, then the kill
            // has nothing attached to fight with
            self.closeSessionPill("s:\(s.id)")
            s.endRemote { [weak self] result in
                if case .failure(let e) = result {
                    self?.terminals.showToast("Couldn't end “\(s.title)” on the server: "
                                              + e.localizedDescription, isError: true)
                }
            }
        }
    }

    func endCurrentSession() {
        guard let c = terminals.current else { return }
        endSession(c)
    }

    /// Bring back the most recently closed tab, where it was (⇧⌘T).
    func reopenClosedSession() {
        guard let last = terminals.popClosed() else { return }
        openSession(last.spec, forceNew: true)
        if let new = terminals.current { terminals.move(id: new.id, to: last.index) }
    }

    /// ⌘1…⌘8 pick that tab, ⌘9 the last one.
    func selectSession(number n: Int) {
        guard !terminals.sessions.isEmpty else { return }
        terminals.select(number: n)
        showCurrentSession()
    }

    /// Bring an already-running session forward (the Dashboard's "Running now").
    func focusSession(id: String) {
        guard terminals.sessions.contains(where: { $0.id == id }) else { return }
        terminals.select(id: id)
        showCurrentSession()
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

    func nextSession() { terminals.cycle(+1); showCurrentSession() }
    func prevSession() { terminals.cycle(-1); showCurrentSession() }

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


/// Boxes a closure so it can ride on an NSMenuItem's representedObject.
final class MenuAction {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
