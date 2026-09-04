import AppKit

/// A card per server. Servers are setup, not the daily surface, so this page is
/// deliberately quiet — the work happens on Projects.
final class ServersPageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let grid = FlowStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Servers"
        pageSubtitle = "Machines you can reach. Shared with the sshm terminal app."
        grid.itemHeight = 146
        grid.itemWidth = 280
    }

    func addServer() {
        let page = ServerEditPageVC(editing: nil)
        pushPage?(page)
    }

    override func reload() {
        clearBody()
        let servers = AppModel.shared.serverList
        guard !servers.isEmpty else {
            let b = SoftButton("Add your first server", symbol: "plus", style: .primary)
            b.onClick = { [weak self] in self?.addServer() }
            let empty = EmptyStateView(
                emoji: "🖥️", title: "No servers yet",
                message: "Add a machine and sshm will remember how to reach it.",
                action: b)
            empty.heightAnchor.constraint(equalToConstant: 320).isActive = true
            body.addWide(empty)
            return
        }

        grid.set(servers.map(card))
        body.addWide(grid)

        let note = NSTextField(labelWithString:
            "Stored in \(ServerStore.shared.file.path) — the same file the terminal app reads.")
        note.font = Fonts.caption
        note.textColor = Text.muted
        body.addArrangedSubview(note)
    }

    private func card(_ vm: ServerVM) -> NSView {
        let card = CardView()
        card.accent = vm.accent

        let chip = IconChip(size: 40)
        chip.configure(icon: vm.icon, accent: vm.accent)

        let name = NSTextField(labelWithString: vm.title)
        name.font = Fonts.rounded(15, .semibold)
        name.textColor = Text.primary
        name.truncates(.byTruncatingTail)

        let sub = NSTextField(labelWithString: vm.subtitle)
        sub.font = Fonts.mono(11)
        sub.textColor = Text.secondary
        sub.truncates(.byTruncatingMiddle)

        let n = AppModel.shared.projects(onServer: vm.slug).count
        let meta = NSTextField(labelWithString:
            "\(vm.server.auth == "key" ? "key" : "password") · "
            + (n == 1 ? "1 project" : "\(n) projects"))
        meta.font = Fonts.caption
        meta.textColor = Text.secondary

        let shell = SoftButton("Shell", symbol: "terminal", style: .quiet)
        shell.onClick = { [weak self] in
            self?.openSession?(AppModel.shared.launchSpec(forServer: vm), false)
        }
        let edit = SoftButton("Edit", symbol: "slider.horizontal.3", style: .quiet)
        edit.onClick = { [weak self] in
            self?.pushPage?(ServerEditPageVC(editing: vm))
        }
        let buttons = NSStackView(views: [shell, edit])
        buttons.orientation = .horizontal
        buttons.spacing = Space.xs

        let texts = NSStackView(views: [name, sub, meta])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let topRow = NSStackView(views: [chip, texts])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = Space.md

        let stack = NSStackView(views: [topRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.content.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.content.trailingAnchor,
                                            constant: -Space.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.content.bottomAnchor,
                                          constant: -Space.lg),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: card.content.trailingAnchor,
                                            constant: -Space.lg),
        ])
        return card
    }
}
