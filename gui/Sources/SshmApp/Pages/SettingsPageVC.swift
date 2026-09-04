import AppKit

/// Agents, appearance, and where everything is stored.
final class SettingsPageVC: PageViewController {
    private var tab = "agents"

    override var pillItems: [PillItem] {
        [PillItem(id: "agents", title: "Agents"),
         PillItem(id: "appearance", title: "Appearance"),
         PillItem(id: "config", title: "Config")]
    }
    override var selectedPill: String? { tab }
    override func pillSelected(_ id: String) { tab = id; reload() }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Settings"
    }

    override func reload() {
        clearBody()
        onPillsChanged?()
        setActions([])
        switch tab {
        case "appearance": buildAppearance()
        case "config":     buildConfig()
        default:           buildAgents()
        }
    }

    // MARK: - agents

    private func buildAgents() {
        pageSubtitle = "Each agent is a command sshm runs after cd-ing into the project directory."
        let add = SoftButton("New agent", symbol: "plus", style: .primary, accent: Pastel.color(5))
        add.onClick = { [weak self] in self?.editAgent(nil) }
        setActions([add])

        let grid = FlowStackView()
        grid.itemHeight = 104
        grid.itemWidth = 250
        grid.set(AppModel.shared.agents.map(agentCard))
        body.addWide(grid)

        let note = NSTextField(wrappingLabelWithString:
            "These CLIs are usually installed by nvm, asdf or npm, which put them on the PATH from "
          + "your login profile. That's why each agent runs under a login shell. If yours lives in "
          + "~/.zshrc instead of ~/.zprofile, change its shell to ${SHELL:-/bin/sh} -lic.")
        note.font = Fonts.caption
        note.textColor = Text.muted
        body.addWide(note)
    }

    private func agentCard(_ a: AgentDef) -> NSView {
        let isDefault = a.id == AppModel.shared.settings.defaultAgent
        let accent = Pastel.color(abs(a.id.hashValue) % 12)
        let card = CardView()
        card.accent = accent

        let chip = IconChip(size: 34)
        chip.configure(icon: a.icon ?? .emoji("⚡"), accent: accent)

        let name = NSTextField(labelWithString: a.name)
        name.font = Fonts.rounded(14, .semibold)
        name.textColor = Text.primary

        let cmd = NSTextField(labelWithString: a.command.isEmpty ? "(just cd there)" : a.command)
        cmd.font = Fonts.mono(10.5)
        cmd.textColor = Text.secondary
        cmd.truncates(.byTruncatingTail)

        let texts = NSStackView(views: [name, cmd])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let top = NSStackView(views: [chip, texts])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = Space.sm

        var bottomViews: [NSView] = []
        if isDefault { bottomViews.append(AgentTag(text: "DEFAULT", accent: accent)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bottomViews.append(spacer)
        let edit = SoftButton("Edit", style: .quiet)
        edit.onClick = { [weak self] in self?.editAgent(a) }
        bottomViews.append(edit)

        let bottom = NSStackView(views: bottomViews)
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = Space.sm

        let stack = NSStackView(views: [top, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.content.topAnchor, constant: Space.md),
            stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.md),
            stack.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -Space.md),
        ])
        return card
    }

    private func editAgent(_ a: AgentDef?) {
        presentAsSheet(AgentEditorController(agent: a))
    }

    // MARK: - appearance

    private func buildAppearance() {
        pageSubtitle = "How the app and its sessions look."

        let theme = PillSegmentedControl()
        theme.set(items: ThemeMode.allCases.map {
            PillItem(id: $0.rawValue, title: $0.label, icon: .symbol($0.symbol))
        }, selected: AppModel.shared.settings.theme.rawValue)
        theme.onSelect = { [weak self] id in
            guard let mode = ThemeMode(rawValue: id) else { return }
            AppModel.shared.updateSettings { $0.theme = mode }
            Theme.apply(mode: mode)
            self?.rootShell?.topBar.setTheme(mode)
        }
        body.addWide(FormRow("Appearance", theme,
                             hint: "System follows macOS. Sessions restyle on the next repaint."))

        let size = NSSlider(value: AppModel.shared.settings.fontSize,
                            minValue: 9, maxValue: 20,
                            target: self, action: #selector(fontSizeChanged))
        size.numberOfTickMarks = 12
        size.allowsTickMarkValuesOnly = true
        size.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let share = NSSwitch()
        share.state = AppModel.shared.settings.shareConnectionPerServer ? .on : .off
        share.target = self
        share.action = #selector(shareChanged)

        let defaultAgent = NSPopUpButton()
        for a in AppModel.shared.agents {
            defaultAgent.addItem(withTitle: a.name)
            defaultAgent.lastItem?.representedObject = a.id
            defaultAgent.lastItem?.image = menuIcon(a.icon ?? .emoji("⚡"))
        }
        defaultAgent.selectItem(at: AppModel.shared.agents
            .firstIndex { $0.id == AppModel.shared.settings.defaultAgent } ?? 0)
        defaultAgent.target = self
        defaultAgent.action = #selector(defaultAgentChanged)

        body.addWide(FormRow("Terminal size", size,
                             hint: "Applies to sessions opened from now on."))
        body.addWide(FormRow("Default agent", defaultAgent))
        let paste = NSSwitch()
        paste.state = AppModel.shared.settings.pasteImagesToServer ? .on : .off
        paste.target = self
        paste.action = #selector(pasteImagesChanged)
        body.addWide(FormRow("Paste images", paste,
                             hint: "Paste or drop an image into a session and it is uploaded to "
                                 + "the server, with the remote path typed in for you. Your "
                                 + "clipboard is never overwritten."))

        body.addWide(FormRow("Share connection", share,
                             hint: "Open several projects on one server over a single "
                                 + "authenticated connection, so you're asked for the password once."))
    }

    private var rootShell: ShellViewController? {
        (view.window?.contentViewController as? RootSplitViewController)?.shell
    }

    @objc private func fontSizeChanged(_ s: NSSlider) {
        AppModel.shared.updateSettings { $0.fontSize = s.doubleValue }
        Theme.terminalFontSize = CGFloat(s.doubleValue)
    }
    @objc private func pasteImagesChanged(_ s: NSSwitch) {
        AppModel.shared.updateSettings { $0.pasteImagesToServer = s.state == .on }
    }

    @objc private func shareChanged(_ s: NSSwitch) {
        AppModel.shared.updateSettings { $0.shareConnectionPerServer = s.state == .on }
    }
    @objc private func defaultAgentChanged(_ p: NSPopUpButton) {
        guard let id = p.selectedItem?.representedObject as? String else { return }
        AppModel.shared.updateSettings { $0.defaultAgent = id }
    }

    // MARK: - config

    private func buildConfig() {
        pageSubtitle = "Where everything is kept."

        body.addWide(configCard(
            title: "servers.conf",
            path: ServerStore.shared.file.path,
            note: "Shared with the sshm terminal app — both read and write it. Passwords are "
                + "base64-encoded, which is obfuscation, not encryption: anyone who can read your "
                + "account can decode them. Use key auth for anything that matters.",
            accent: Pastel.color(4)))

        body.addWide(configCard(
            title: "sshm.json",
            path: MetaStore.shared.url.path,
            note: "Names, icons, projects, agents and settings. Nothing secret is stored here.",
            accent: Pastel.color(0)))

        let orphans = AppModel.shared.orphanCount
        if orphans > 0 {
            let clean = SoftButton("Clean up \(orphans) orphaned project\(orphans == 1 ? "" : "s")",
                                   symbol: "trash", style: .destructive)
            clean.onClick = { AppModel.shared.removeOrphans() }
            body.addArrangedSubview(clean)
        }

        let tools = NSTextField(wrappingLabelWithString:
            "ssh: \(Tools.ssh)\nsshpass: \(Tools.sshpass ?? "not installed — password servers will prompt inside the session")")
        tools.font = Fonts.mono(11)
        tools.textColor = Text.muted
        body.addWide(tools)
    }

    private func configCard(title: String, path: String, note: String, accent: NSColor) -> NSView {
        let card = CardView()
        card.accent = accent
        card.tintStrength = 0.07

        let t = NSTextField(labelWithString: title)
        t.font = Fonts.rounded(14, .semibold)
        t.textColor = Text.primary
        let p = NSTextField(labelWithString: path)
        p.font = Fonts.mono(11)
        p.textColor = Text.secondary
        p.truncates(.byTruncatingMiddle)
        let n = NSTextField(wrappingLabelWithString: note)
        n.font = Fonts.caption
        n.textColor = Text.muted

        let reveal = SoftButton("Reveal in Finder", symbol: "folder", style: .quiet)
        reveal.onClick = { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }

        let stack = NSStackView(views: [t, p, n, reveal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.content.topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -Space.lg),
            stack.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -Space.lg),
        ])
        return card
    }
}

/// Small sheet for adding or editing one agent.
final class AgentEditorController: NSViewController {
    private var agent: AgentDef
    private let isNew: Bool

    private let nameField = SoftTextField(placeholder: "Claude Code")
    private let commandField = SoftTextField(placeholder: "claude", mono: true)
    private let shellField = SoftTextField(placeholder: "${SHELL:-/bin/sh} -lc", mono: true)
    private let keepShell = NSSwitch()
    private let iconChip = IconChip(size: 44, radius: 14)
    private let iconButton = SoftButton("Change", style: .secondary)
    private var icon: IconRef
    private var accent: NSColor { Pastel.color(abs(agent.id.hashValue) % 12) }

    init(agent: AgentDef?) {
        self.isNew = agent == nil
        let a = agent ?? AgentDef(id: String(UUID().uuidString.prefix(8)).lowercased(),
                                  name: "", icon: .emoji("⚡"), command: "")
        self.agent = a
        self.icon = a.icon ?? .emoji("⚡")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedCanvas(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        let title = NSTextField(labelWithString: isNew ? "New agent" : agent.name)
        title.font = Fonts.title
        title.textColor = Text.primary

        iconChip.configure(icon: icon, accent: accent)
        iconChip.onDropImage = { [weak self] ref in self?.setIcon(ref) }
        iconChip.toolTip = "Drop a logo here, or click Change"
        iconButton.onClick = { [weak self] in
            guard let self else { return }
            IconPicker.show(from: self.iconButton, accent: self.accent) { ref in
                self.setIcon(ref)
            }
        }
        let iconStack = NSStackView(views: [iconChip, iconButton])
        iconStack.orientation = .horizontal
        iconStack.spacing = Space.md
        iconStack.alignment = .centerY

        nameField.stringValue = agent.name
        commandField.stringValue = agent.command
        shellField.stringValue = agent.shell
        keepShell.state = agent.keepShell ? .on : .off

        let save = SoftButton(isNew ? "Add" : "Save", symbol: "checkmark", style: .primary)
        save.onClick = { [weak self] in self?.save() }
        let cancel = SoftButton("Cancel", style: .quiet)
        cancel.onClick = { [weak self] in self?.dismiss(nil) }
        var buttonViews: [NSView] = []
        if !isNew {
            let del = SoftButton("Delete", symbol: "trash", style: .destructive)
            del.onClick = { [weak self] in
                guard let self else { return }
                AppModel.shared.deleteAgent(id: self.agent.id)
                self.dismiss(nil)
            }
            buttonViews.append(del)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttonViews += [spacer, cancel, save]
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = Space.sm

        let stack = NSStackView(views: [
            title,
            FormRow("Icon", iconStack, hint: "Logos tab has drawn marks; Custom takes your own image.",
                    labelWidth: 90),
            FormRow("Name", nameField, labelWidth: 90),
            FormRow("Command", commandField,
                    hint: "Runs after cd. Leave empty for a plain shell.", labelWidth: 90),
            FormRow("Shell", shellField,
                    hint: "The wrapper that supplies PATH. Use -lic if your CLIs are set up in ~/.zshrc.",
                    labelWidth: 90),
            FormRow("Keep shell", keepShell,
                    hint: "Stay at a prompt in the directory when the agent exits.", labelWidth: 90),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.xl),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.xl),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.xl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -Space.xl),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    private func setIcon(_ ref: IconRef) {
        icon = ref
        iconChip.configure(icon: ref, accent: accent)
    }

    private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        agent.name = name
        agent.command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        agent.shell = shellField.stringValue.isEmpty
            ? "${SHELL:-/bin/sh} -lc" : shellField.stringValue
        agent.keepShell = keepShell.state == .on
        agent.icon = icon
        AppModel.shared.saveAgent(agent)
        dismiss(nil)
    }
}
