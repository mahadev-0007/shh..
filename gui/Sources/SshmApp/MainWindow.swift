import AppKit

/// Window chrome only. Everything else lives in RootSplitViewController.
final class MainWindowController: NSWindowController {
    let root = RootSplitViewController()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "shh"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = Ink.bg
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.setFrameAutosaveName("sshm.main")
        // the sidebar plus the top bar's own fitting width set the real floor
        w.minSize = NSSize(width: 960, height: 560)
        self.init(window: w)
        w.contentViewController = root
    }

    // MARK: - menu targets (reached through the responder chain)

    @objc func newItem(_ sender: Any?) {
        switch root.shell.section {
        case .servers: root.go(to: .servers); currentServersPage?.addServer()
        default:       root.go(to: .projects); currentProjectsPage?.addProject()
        }
    }

    @objc func newServer(_ sender: Any?) {
        root.go(to: .servers)
        currentServersPage?.addServer()
    }

    @objc func joinInvite(_ sender: Any?) { joinInvite(link: nil) }

    func joinInvite(link: String?) {
        root.go(to: .servers)
        // the page is created by go(to:); let it land before presenting on it
        DispatchQueue.main.async { [weak self] in
            self?.currentServersPage?.joinInvite(prefill: link)
        }
    }

    @objc func showDashboard(_ sender: Any?) { root.go(to: .dashboard) }
    @objc func showProjects(_ sender: Any?)  { root.go(to: .projects) }
    @objc func showServers(_ sender: Any?)   { root.go(to: .servers) }
    @objc func showSessions(_ sender: Any?)  { root.go(to: .sessions) }
    @objc func showFiles(_ sender: Any?)     { root.go(to: .files) }
    @objc func commandPalette(_ sender: Any?) { root.shell.openPalette() }
    @objc func toggleTheme(_ sender: Any?)   { root.shell.cycleTheme() }
    @objc func toggleFocusMode(_ sender: Any?) { root.shell.toggleFocusMode() }
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }
    @objc func showSettings(_ sender: Any?)  { root.go(to: .settings) }

    @objc func closeSession(_ sender: Any?) { root.shell.closeCurrentSession() }
    @objc func endSession(_ sender: Any?) { root.shell.endCurrentSession() }
    @objc func duplicateSession(_ sender: Any?) { root.shell.duplicateCurrentSession() }
    @objc func browseFiles(_ sender: Any?) { root.shell.browseCurrentSessionFiles() }
    @objc func reopenClosedSession(_ sender: Any?) { root.shell.reopenClosedSession() }
    @objc func selectSessionNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        root.shell.selectSession(number: item.tag)
    }
    @objc func nextSession(_ sender: Any?)  { root.shell.nextSession() }
    @objc func prevSession(_ sender: Any?)  { root.shell.prevSession() }

    @objc func reloadConfig(_ sender: Any?) {
        ServerStore.shared.load()
        MetaStore.shared.load()
        NotificationCenter.default.post(name: .sshmDidChange, object: nil)
    }

    private var currentServersPage: ServersPageVC? {
        root.shell.children.compactMap { $0 as? ServersPageVC }.last
    }
    private var currentProjectsPage: ProjectsPageVC? {
        root.shell.children.compactMap { $0 as? ProjectsPageVC }.last
    }
}
