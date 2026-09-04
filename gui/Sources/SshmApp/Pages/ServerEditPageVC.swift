import AppKit

/// Add or edit a server. A full page, pushed onto the Servers stack — not a
/// sheet, so there is room for the icon, the derived slug and the auth switch.
final class ServerEditPageVC: PageViewController {
    private let existing: ServerVM?

    private let nameField = SoftTextField(placeholder: "SaaS Server")
    private let slugField = SoftTextField(placeholder: "saas-server", mono: true)
    private let hostField = SoftTextField(placeholder: "10.0.0.5 or host.example.com", mono: true)
    private let userField = SoftTextField(placeholder: NSUserName(), mono: true)
    private let portField = SoftTextField(placeholder: "22", mono: true)
    private let passField = SoftTextField(placeholder: "••••••••", secure: true)
    private let keyField  = SoftTextField(placeholder: "~/.ssh/id_ed25519", mono: true)
    private let authTabs = PillSegmentedControl()
    private let iconButton = SoftButton("", style: .secondary)
    private let iconChip = IconChip(size: 44, radius: 14)

    private var icon: IconRef
    private var accent: NSColor
    private var auth = "pass"
    private var slugEdited = false
    private var secretRow: NSView!
    private var keyRow: NSView!

    init(editing: ServerVM?) {
        self.existing = editing
        self.icon = editing?.icon ?? .emoji(Pastel.emoji[Int.random(in: 0..<12)])
        self.accent = editing?.accent ?? Pastel.color(Int.random(in: 0..<12))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var initialResponder: NSView? { nameField.field }
    override var contentWidthLimit: CGFloat { 660 }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = existing == nil ? "Add server" : "Edit server"
        pageSubtitle = existing == nil
            ? "Connection details live in servers.conf; the name and icon live beside it."
            : existing!.subtitle

        let save = SoftButton(existing == nil ? "Add server" : "Save",
                              symbol: "checkmark", style: .primary, accent: accent)
        save.onClick = { [weak self] in self?.save() }
        var actions: [NSView] = [save]
        if let e = existing {
            let del = SoftButton("Delete", symbol: "trash", style: .destructive)
            del.onClick = { [weak self] in self?.confirmDelete(e) }
            actions.insert(del, at: 0)
        }
        setActions(actions)

        // the slug follows the name until the user touches it themselves
        nameField.onChange = { [weak self] v in
            guard let self, !self.slugEdited else { return }
            self.slugField.stringValue = Slug.make(v)
        }
        slugField.onChange = { [weak self] _ in self?.slugEdited = true }

        authTabs.set(items: [PillItem(id: "pass", title: "Password"),
                             PillItem(id: "key", title: "Key file")],
                     selected: "pass")
        authTabs.onSelect = { [weak self] id in self?.setAuth(id) }

        iconChip.configure(icon: icon, accent: accent)
        iconChip.onDropImage = { [weak self] ref in self?.setIcon(ref) }
        iconChip.toolTip = "Click Change, or drop an image here"
        iconButton.title = "Change"
        iconButton.onClick = { [weak self] in self?.pickIcon() }

        fill()
    }

    private func fill() {
        guard let e = existing else { return }
        nameField.stringValue = e.title
        slugField.stringValue = e.slug
        slugEdited = true
        hostField.stringValue = e.server.host
        userField.stringValue = e.server.user
        portField.stringValue = e.server.port
        if e.server.auth == "key" {
            keyField.stringValue = e.server.secret
            authTabs.select("key", notify: false)
            setAuth("key")
        } else {
            passField.stringValue = e.server.password ?? ""
        }
    }

    private func setAuth(_ id: String) {
        auth = id
        secretRow?.isHidden = id != "pass"
        keyRow?.isHidden = id != "key"
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

    override func reload() {
        guard body.arrangedSubviews.isEmpty else { return }   // a form, not a list

        let iconStack = NSStackView(views: [iconChip, iconButton])
        iconStack.orientation = .horizontal
        iconStack.spacing = Space.md
        iconStack.alignment = .centerY

        let browse = SoftButton("Choose…", symbol: "folder", style: .secondary)
        browse.onClick = { [weak self] in self?.browseKey() }
        let keyStack = NSStackView(views: [keyField, browse])
        keyStack.orientation = .horizontal
        keyStack.spacing = Space.sm

        secretRow = FormRow("Password", passField,
                            hint: "Stored base64-encoded in servers.conf. That is obfuscation, "
                                + "not encryption — use a key for anything that matters.")
        keyRow = FormRow("Key file", keyStack)

        let rows: [NSView] = [
            FormRow("Icon", iconStack),
            FormRow("Name", nameField, hint: "What you'll see everywhere in this app."),
            FormRow("Short name", slugField,
                    hint: "The key in servers.conf, so `sshm \(slugField.stringValue.isEmpty ? "name" : slugField.stringValue)` "
                        + "works in the terminal too."),
            FormRow("Host", hostField),
            FormRow("User", userField),
            FormRow("Port", portField),
            FormRow("Auth", authTabs),
            secretRow, keyRow,
        ]
        for r in rows { body.addWide(r) }
        setAuth(auth)
    }

    private func browseKey() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.showsHiddenFiles = true
        p.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        if p.runModal() == .OK, let u = p.url { keyField.stringValue = u.path }
    }

    private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !host.isEmpty else {
            complain("A name and a host are required."); return
        }
        guard !name.contains("|"), !host.contains("|") else {
            complain("The character “|” separates fields in servers.conf, so it can't appear in a name or host.")
            return
        }
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = auth == "key"
            ? keyField.stringValue.trimmingCharacters(in: .whitespaces)
            : Data(passField.stringValue.utf8).base64EncodedString()

        AppModel.shared.saveServer(
            existing: existing?.slug, displayName: name,
            slug: slugField.stringValue.trimmingCharacters(in: .whitespaces),
            host: host, user: user.isEmpty ? NSUserName() : user,
            port: portField.stringValue.trimmingCharacters(in: .whitespaces),
            auth: auth, secret: secret, icon: icon)
        onBack?()
    }

    private func confirmDelete(_ vm: ServerVM) {
        let n = AppModel.shared.projects(onServer: vm.slug).count
        let a = NSAlert()
        a.messageText = "Delete “\(vm.title)”?"
        a.alertStyle = .warning
        if n > 0 {
            a.informativeText = "\(n) project\(n == 1 ? "" : "s") point at this server."
            a.addButton(withTitle: "Delete server and \(n) project\(n == 1 ? "" : "s")")
            a.addButton(withTitle: "Delete server, keep projects")
            a.addButton(withTitle: "Cancel")
        } else {
            a.informativeText = "This removes it from servers.conf."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
        }
        guard let w = view.window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self else { return }
            if n > 0 {
                switch r {
                case .alertFirstButtonReturn:
                    AppModel.shared.deleteServer(slug: vm.slug, mode: .withProjects)
                case .alertSecondButtonReturn:
                    AppModel.shared.deleteServer(slug: vm.slug, mode: .keepProjects)
                default: return
                }
            } else if r == .alertFirstButtonReturn {
                AppModel.shared.deleteServer(slug: vm.slug, mode: .withProjects)
            } else { return }
            self.onBack?()
        }
    }

    private func complain(_ text: String) {
        let a = NSAlert()
        a.messageText = "Can't save yet"
        a.informativeText = text
        a.alertStyle = .informational
        if let w = view.window { a.beginSheetModal(for: w) }
    }
}
