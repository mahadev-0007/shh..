import AppKit

/// Add or edit a project: which server, which directory, which agent.
final class ProjectEditPageVC: PageViewController {
    private let existing: ProjectVM?
    private var project: Project

    private let nameField = SoftTextField(placeholder: "API Service")
    private let pathField = SoftTextField(placeholder: "~/code/api", mono: true)
    private let serverPopup = NSPopUpButton()
    private let agentPopup = NSPopUpButton()
    private let iconChip = IconChip(size: 44, radius: 14)
    private let iconButton = SoftButton("Change", style: .secondary)
    private let previewLabel = NSTextField(labelWithString: "")

    private var icon: IconRef
    private var accent: NSColor { serverVM?.accent ?? Pastel.color(2) }
    private var serverVM: ServerVM? {
        AppModel.shared.serverVM(slug: project.server)
    }

    init(editing: ProjectVM?) {
        self.existing = editing
        self.project = editing?.project
            ?? Project(name: "", icon: nil,
                       server: AppModel.shared.serverList.first?.slug ?? "",
                       path: "~/", agent: AppModel.shared.settings.defaultAgent)
        self.icon = editing?.project.icon ?? .emoji("📁")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var initialResponder: NSView? { nameField.field }
    override var contentWidthLimit: CGFloat { 660 }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = existing == nil ? "New project" : "Edit project"
        pageSubtitle = "A directory on a server, plus the agent that opens it."

        let save = SoftButton(existing == nil ? "Create" : "Save",
                              symbol: "checkmark", style: .primary, accent: accent)
        save.onClick = { [weak self] in self?.save() }
        var actions: [NSView] = [save]
        if existing != nil {
            let del = SoftButton("Delete", symbol: "trash", style: .destructive)
            del.onClick = { [weak self] in self?.confirmDelete() }
            actions.insert(del, at: 0)
        }
        setActions(actions)

        iconChip.configure(icon: icon, accent: accent)
        iconChip.onDropImage = { [weak self] ref in self?.setIcon(ref) }
        iconChip.toolTip = "Click Change, or drop an image here"
        iconButton.onClick = { [weak self] in self?.pickIcon() }

        nameField.stringValue = project.name
        pathField.stringValue = project.path
        pathField.onChange = { [weak self] v in
            self?.project.path = v
            self?.updatePreview()
        }

        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        for p in [serverPopup, agentPopup] {
            p.bezelStyle = .rounded
            p.font = Fonts.body
        }
        rebuildPopups()
    }

    private func rebuildPopups() {
        serverPopup.removeAllItems()
        for s in AppModel.shared.serverList {
            serverPopup.addItem(withTitle: s.title)
            serverPopup.lastItem?.representedObject = s.slug
            serverPopup.lastItem?.image = menuIcon(s.icon)
        }
        serverPopup.selectItem(at: AppModel.shared.serverList
            .firstIndex { $0.slug == project.server } ?? 0)

        agentPopup.removeAllItems()
        for a in AppModel.shared.agents {
            agentPopup.addItem(withTitle: a.name)
            agentPopup.lastItem?.representedObject = a.id
            agentPopup.lastItem?.image = menuIcon(a.icon ?? .emoji("⚡"))
        }
        let target = project.agent ?? AppModel.shared.settings.defaultAgent
        agentPopup.selectItem(at: AppModel.shared.agents.firstIndex { $0.id == target } ?? 0)
    }

    @objc private func serverChanged() {
        project.server = serverPopup.selectedItem?.representedObject as? String ?? project.server
        iconChip.configure(icon: icon, accent: accent)
        updatePreview()
    }

    @objc private func agentChanged() {
        project.agent = agentPopup.selectedItem?.representedObject as? String
        updatePreview()
    }

    private func pickIcon() {
        IconPicker.show(from: iconButton, accent: accent) { [weak self] ref in
            self?.setIcon(ref)
        }
    }

    private func setIcon(_ ref: IconRef) {
        icon = ref
        iconChip.configure(icon: ref, accent: accent)
    }

    /// Show the exact command that will run — no mystery about what "open" does.
    private func updatePreview() {
        let agent = AppModel.shared.agent(id: project.agent) ?? AppModel.shared.defaultAgent
        let target = serverVM?.server.target ?? "server"
        previewLabel.stringValue = Shell.preview(target: target,
                                                 path: pathField.stringValue,
                                                 agent: agent)
    }

    override func reload() {
        guard body.arrangedSubviews.isEmpty else { rebuildPopups(); return }

        let iconStack = NSStackView(views: [iconChip, iconButton])
        iconStack.orientation = .horizontal
        iconStack.spacing = Space.md
        iconStack.alignment = .centerY

        let browse = SoftButton("Browse…", symbol: "folder", style: .secondary)
        browse.onClick = { [weak self] in self?.browseRemote() }
        let pathStack = NSStackView(views: [pathField, browse])
        pathStack.orientation = .horizontal
        pathStack.spacing = Space.sm

        previewLabel.font = Fonts.mono(10.5)
        previewLabel.textColor = Text.muted
        previewLabel.wraps(lines: 4)
        let previewCard = CardView(radius: Radius.field)
        previewCard.accent = accent
        previewCard.tintStrength = 0.05
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewCard.content.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.topAnchor.constraint(equalTo: previewCard.content.topAnchor, constant: 9),
            previewLabel.bottomAnchor.constraint(equalTo: previewCard.content.bottomAnchor, constant: -9),
            previewLabel.leadingAnchor.constraint(equalTo: previewCard.content.leadingAnchor, constant: 11),
            previewLabel.trailingAnchor.constraint(equalTo: previewCard.content.trailingAnchor, constant: -11),
        ])

        let rows: [NSView] = [
            FormRow("Icon", iconStack),
            FormRow("Name", nameField),
            FormRow("Server", serverPopup),
            FormRow("Directory", pathStack,
                    hint: "Where the agent starts. ~ is expanded on the server."),
            FormRow("Agent", agentPopup,
                    hint: "Edit these, or add your own, in Settings → Agents."),
            FormRow("Runs", previewCard),
        ]
        for r in rows { body.addWide(r) }
        updatePreview()
    }

    // MARK: - remote browser

    private func browseRemote() {
        guard let vm = serverVM else { return }
        let browser = RemoteBrowserController(server: vm, start: pathField.stringValue)
        browser.onPick = { [weak self] path in
            self?.pathField.stringValue = path
            self?.project.path = path
            self?.updatePreview()
        }
        presentAsSheet(browser)
    }

    // MARK: - saving

    private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !path.isEmpty, !project.server.isEmpty else {
            let a = NSAlert()
            a.messageText = "Can't save yet"
            a.informativeText = "A project needs a name, a server and a directory."
            if let w = view.window { a.beginSheetModal(for: w) }
            return
        }
        project.name = name
        project.path = path
        project.icon = icon
        AppModel.shared.saveProject(project)
        onBack?()
    }

    private func confirmDelete() {
        let a = NSAlert()
        a.messageText = "Delete “\(project.name)”?"
        a.informativeText = "Only the entry in sshm — nothing on the server is touched."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            AppModel.shared.deleteProject(id: self.project.id)
            self.onBack?()
        }
    }
}

/// A minimal remote directory picker: current path, a list of subdirectories,
/// up and choose. One `ls` per step over the session's control socket.
final class RemoteBrowserController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onPick: ((String) -> Void)?

    private let server: ServerVM
    private var path: String
    private var dirs: [String] = []
    private let pathLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")

    init(server: ServerVM, start: String) {
        self.server = server
        self.path = start.isEmpty ? "~" : start
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedCanvas(frame: NSRect(x: 0, y: 0, width: 460, height: 420))

        let title = NSTextField(labelWithString: server.title)
        title.font = Fonts.section
        title.textColor = Text.primary

        pathLabel.font = Fonts.mono(11.5)
        pathLabel.textColor = Text.secondary
        pathLabel.truncates(.byTruncatingMiddle)

        status.font = Fonts.caption
        status.textColor = Ink.error
        status.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let col = NSTableColumn(identifier: .init("d"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(descend)

        let scroll = makeScrollView(table)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let up = SoftButton("Up", symbol: "arrow.up", style: .secondary)
        up.onClick = { [weak self] in self?.goUp() }
        let open = SoftButton("Open", symbol: "arrow.right", style: .secondary)
        open.onClick = { [weak self] in self?.descend() }
        let choose = SoftButton("Choose this directory", symbol: "checkmark",
                                style: .primary, accent: server.accent)
        choose.onClick = { [weak self] in
            guard let self else { return }
            self.onPick?(self.path)
            self.dismiss(nil)
        }
        let cancel = SoftButton("Cancel", style: .quiet)
        cancel.onClick = { [weak self] in self?.dismiss(nil) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [up, open, spacer, cancel, choose])
        buttons.orientation = .horizontal
        buttons.spacing = Space.sm

        let head = NSStackView(views: [title, spinner])
        head.orientation = .horizontal
        head.spacing = Space.sm

        let stack = NSStackView(views: [head, pathLabel, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.lg),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Space.lg),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        load()
    }

    private func load() {
        pathLabel.stringValue = path
        spinner.startAnimation(nil)
        status.isHidden = true
        RemoteFS.list(server: server.server, path: path) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let listing):
                self.path = listing.path
                self.pathLabel.stringValue = listing.path
                self.dirs = listing.directories
                self.table.reloadData()
            case .failure(let e):
                self.status.stringValue = e.localizedDescription
                self.status.isHidden = false
                self.dirs = []
                self.table.reloadData()
            }
        }
    }

    private func goUp() {
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        load()
    }

    @objc private func descend() {
        guard dirs.indices.contains(table.selectedRow) else { return }
        let name = dirs[table.selectedRow]
        path = path.hasSuffix("/") ? path + name : path + "/" + name
        load()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { dirs.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let l = NSTextField(labelWithString: "📁  " + dirs[row])
        l.font = Fonts.mono(12)
        l.textColor = Text.primary
        l.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            l.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
