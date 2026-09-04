import AppKit

/// Rail on the left, everything else on the right.
final class RootSplitViewController: NSSplitViewController {
    let rail = Sidebar()
    let shell = ShellViewController()

    private lazy var railVC: NSViewController = {
        let vc = NSViewController()
        let host = ThemedSidebarHost()
        rail.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rail)
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: host.topAnchor),
            rail.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            rail.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        vc.view = host
        return vc
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let railItem = NSSplitViewItem(viewController: railVC)
        railItem.canCollapse = true
        railItem.minimumThickness = Sidebar.width
        railItem.maximumThickness = Sidebar.width
        railItem.holdingPriority = .defaultHigh + 1
        addSplitViewItem(railItem)

        addSplitViewItem(NSSplitViewItem(viewController: shell))

        rail.onSelect = { [weak self] s in
            self?.shell.show(section: s)
            self?.rail.selected = s
        }

        let start = RailSection(rawValue: AppModel.shared.settings.lastSection) ?? .dashboard
        rail.selected = start
        shell.show(section: start)
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        splitViewItems.first?.animator().isCollapsed = collapsed
    }

    func go(to section: RailSection) {
        rail.selected = section
        shell.show(section: section)
        AppModel.shared.updateSettings { $0.lastSection = section.rawValue }
    }
}


/// Plain themed background rather than vibrancy — a blurred sidebar fights a
/// flat neutral canvas, and the design calls for flat surfaces.
final class ThemedSidebarHost: ThemedView {
    override func applyTheme() {
        layer?.backgroundColor = Ink.sidebar.cg(self)
    }
}
