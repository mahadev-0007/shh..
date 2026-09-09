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

    @objc func showDashboard(_ sender: Any?) { root.go(to: .dashboard) }
    @objc func showProjects(_ sender: Any?)  { root.go(to: .projects) }
    @objc func showServers(_ sender: Any?)   { root.go(to: .servers) }
    @objc func showSessions(_ sender: Any?)  { root.go(to: .sessions) }
    @objc func commandPalette(_ sender: Any?) { root.shell.openPalette() }
    @objc func toggleTheme(_ sender: Any?)   { root.shell.cycleTheme() }
    @objc func toggleFocusMode(_ sender: Any?) { root.shell.toggleFocusMode() }
    @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates() }
    @objc func showSettings(_ sender: Any?)  { root.go(to: .settings) }

    @objc func closeSession(_ sender: Any?) { root.shell.closeCurrentSession() }
    @objc func duplicateSession(_ sender: Any?) { root.shell.duplicateCurrentSession() }
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
