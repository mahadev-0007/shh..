import AppKit

/// The Files section's front door: pick a server, or jump straight into a
/// project's folder. The browser itself is FilesPageVC, pushed on top.
final class FilesHomePageVC: PageViewController, NavigatingPage {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let serverGrid = FlowStackView()
    private let projectGrid = FlowStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Files"
        pageSubtitle = "Browse, upload and download over SFTP."
        for g in [serverGrid, projectGrid] {
            g.itemHeight = 76
            g.itemWidth = 280
        }
    }

    override func reload() {
        clearBody()
        let servers = AppModel.shared.serverList
        guard !servers.isEmpty else {
            let b = SoftButton("Add a server", symbol: "plus", style: .primary)
            b.onClick = { [weak self] in self?.shellController?.addServerFromAnywhere() }
            let empty = EmptyStateView(
                emoji: "📂", title: "No servers yet",
                message: "Add a machine first, then browse its files here.",
                action: b)
            empty.heightAnchor.constraint(equalToConstant: 320).isActive = true
            body.addWide(empty)
            return
        }

        body.addWide(heading("Servers"))
        serverGrid.set(servers.map { vm in
            card(icon: vm.icon, accent: vm.accent, title: vm.title, detail: vm.subtitle) {
                [weak self] in self?.open(vm, path: "~")
            }
        })
        body.addWide(serverGrid)

        let projects = AppModel.shared.projectList.filter { !$0.isOrphan }
        guard !projects.isEmpty else { return }
        body.addWide(heading("Project folders"))
        projectGrid.set(projects.compactMap { vm in
            guard let server = vm.server else { return nil }
            return card(icon: vm.icon, accent: vm.accent, title: vm.title,
                        detail: "\(server.title) · \(vm.project.path)") { [weak self] in
                self?.open(server, path: vm.project.path)
            }
        })
        body.addWide(projectGrid)
    }

    private func open(_ server: ServerVM, path: String) {
        pushPage?(FilesPageVC(server: server, startPath: path))
    }

    private func heading(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = Fonts.section
        l.textColor = Text.primary
        return l
    }

    private func card(icon: IconRef, accent: NSColor, title: String, detail: String,
                      run: @escaping () -> Void) -> NSView {
        let card = CardView()
        card.accent = accent

        let chip = IconChip(size: 36)
        chip.configure(icon: icon, accent: accent)

        let name = NSTextField(labelWithString: title)
        name.font = Fonts.rounded(14, .semibold)
        name.textColor = Text.primary
        name.truncates(.byTruncatingTail)

        let sub = NSTextField(labelWithString: detail)
        sub.font = Fonts.mono(10.5)
        sub.textColor = Text.secondary
        sub.truncates(.byTruncatingMiddle)

        let texts = NSStackView(views: [name, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let row = NSStackView(views: [chip, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.lg),
            row.trailingAnchor.constraint(lessThanOrEqualTo: card.content.trailingAnchor,
                                          constant: -Space.lg),
            row.centerYAnchor.constraint(equalTo: card.content.centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: card.content.trailingAnchor,
                                            constant: -Space.lg),
        ])
        card.onClick = { _ in run() }
        card.toolTip = "Browse files"
        return card
    }
}
