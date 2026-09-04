import AppKit

/// The main event: a card per project. Click one and it opens with its agent.
final class ProjectsPageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let grid = FlowStackView()
    private var filter = "all"

    override var pillItems: [PillItem] {
        var items = [PillItem(id: "all", title: "All"),
                     PillItem(id: "recent", title: "Recent")]
        items += AppModel.shared.serverList.map {
            PillItem(id: "srv:\($0.slug)", title: $0.title, icon: $0.icon, accent: $0.accent)
        }
        return items
    }
    override var selectedPill: String? { filter }
    override func pillSelected(_ id: String) { filter = id; reload() }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Projects"
        pageSubtitle = "A directory on a server, opened with a coding agent."
        grid.itemHeight = 150
        grid.itemWidth = 270
    }

    func addProject() {
        guard !AppModel.shared.serverList.isEmpty else {
            let a = NSAlert()
            a.messageText = "Add a server first"
            a.informativeText = "A project lives in a directory on a server, so there has to be a server to put it on."
            a.addButton(withTitle: "OK")
            if let w = view.window { a.beginSheetModal(for: w) }
            return
        }
        pushPage?(ProjectEditPageVC(editing: nil))
    }

    private var visibleProjects: [ProjectVM] {
        let all = AppModel.shared.projectList
        switch filter {
        case "recent": return AppModel.shared.recentProjects
        case let f where f.hasPrefix("srv:"):
            let slug = String(f.dropFirst(4))
            return all.filter { $0.project.server == slug }
        default: return all
        }
    }

    override func reload() {
        clearBody()
        onPillsChanged?()

        let projects = visibleProjects
        guard !projects.isEmpty else {
            let b = SoftButton("New project", symbol: "plus", style: .primary)
            b.onClick = { [weak self] in self?.addProject() }
            let empty = EmptyStateView(
                emoji: "🌱",
                title: filter == "all" ? "No projects yet" : "Nothing here",
                message: filter == "all"
                    ? "Point sshm at a directory on one of your servers, pick an agent, and it's one click from here on."
                    : "No projects match this filter.",
                action: filter == "all" ? b : nil)
            empty.heightAnchor.constraint(equalToConstant: 320).isActive = true
            body.addWide(empty)
            return
        }

        grid.set(projects.map(card))
        body.addWide(grid)
    }

    private func card(_ vm: ProjectVM) -> NSView {
        let card = CardView()
        card.accent = vm.accent
        card.isDimmed = vm.isOrphan

        let chip = IconChip(size: 40)
        chip.configure(icon: vm.icon, accent: vm.accent)

        let name = NSTextField(labelWithString: vm.title)
        name.font = Fonts.rounded(15, .semibold)
        name.textColor = Text.primary
        name.truncates(.byTruncatingTail)

        let sub = NSTextField(labelWithString: vm.subtitle)
        sub.font = Fonts.caption
        sub.textColor = Text.secondary
        sub.truncates(.byTruncatingMiddle)

        let path = NSTextField(labelWithString: vm.project.path)
        path.font = Fonts.mono(10.5)
        path.textColor = Text.muted
        path.truncates(.byTruncatingMiddle)

        let texts = NSStackView(views: [name, sub, path])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let topRow = NSStackView(views: [chip, texts])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = Space.md

        let agentTag = AgentTag(text: vm.agentName, accent: vm.accent)
        let edit = SoftButton("Edit", style: .quiet)
        edit.onClick = { [weak self] in self?.pushPage?(ProjectEditPageVC(editing: vm)) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [agentTag, spacer, edit])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = Space.sm

        let stack = NSStackView(views: [topRow, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.content.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -Space.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.content.bottomAnchor,
                                          constant: -Space.lg),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        if !vm.isOrphan {
            card.onClick = { [weak self] event in
                guard let spec = AppModel.shared.launchSpec(for: vm) else { return }
                // hold ⌥ to force a second session on a project that's already open
                self?.openSession?(spec, event.modifierFlags.contains(.option))
            }
            card.toolTip = "Open with \(vm.agentName) — ⌥-click for a second session"
        } else {
            card.toolTip = "The server “\(vm.project.server)” is no longer in servers.conf"
        }
        return card
    }
}

/// The little rounded label naming a project's agent.
final class AgentTag: NSView {
    init(text: String, accent: NSColor) {
        super.init(frame: .zero)
        softCorners(7)
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        let l = NSTextField(labelWithString: text)
        l.font = Fonts.rounded(10.5, .semibold)
        l.textColor = accent
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
