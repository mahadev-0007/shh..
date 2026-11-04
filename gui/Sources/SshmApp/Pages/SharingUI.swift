import AppKit

/// Settings → Sharing: the host's side of remote sessions.
final class SharingPanel: NSObject {
    private weak var page: PageViewController?
    private var access: RemoteAccess { .shared }

    init(page: PageViewController) {
        self.page = page
        super.init()
    }

    func build() -> [NSView] {
        var out: [NSView] = []

        let toggle = NSSwitch()
        toggle.state = access.file.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggled)
        out.append(FormRow("Allow remote sessions", toggle,
                           hint: "Let people you invite ssh into this Mac over Tailscale. "
                               + "Each invite works once, for one person, and you approve "
                               + "them when they use it. Turning this off removes everyone.",
                           labelWidth: 150))

        guard access.file.enabled else { return out }

        out.append(FormRow("Tailscale", statusView(), labelWidth: 150))
        out.append(FormRow("Remote Login", remoteLoginView(), labelWidth: 150))

        let newInvite = SoftButton("New invite", symbol: "plus", style: .primary,
                                   accent: Pastel.color(5))
        newInvite.onClick = { [weak self] in self?.makeInvite() }
        out.append(sectionHeader("Invites", newInvite))
        let invites = access.file.invites.filter { !$0.isExpired }
        if invites.isEmpty {
            out.append(note("No open invites. An invite expires 15 minutes after you make it."))
        }
        let time = DateFormatter()
        time.timeStyle = .short
        for i in invites {
            let cancel = SoftButton("Cancel", style: .quiet)
            cancel.onClick = { [weak self] in self?.access.cancelInvite(id: i.id) }
            out.append(row(icon: "envelope", title: i.label,
                           subtitle: "Unused · expires \(time.string(from: Date(timeIntervalSince1970: i.expires)))",
                           buttons: [cancel]))
        }

        out.append(sectionHeader("People with access"))
        if access.file.guests.isEmpty {
            out.append(note("Nobody yet."))
        }
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        for g in access.file.guests {
            let revoke = SoftButton("Revoke", symbol: "xmark", style: .destructive)
            revoke.onClick = { [weak self] in self?.confirmRevoke(g) }
            out.append(row(icon: "person.crop.circle",
                           title: g.displayName == g.label ? g.displayName : "\(g.displayName) · \(g.label)",
                           subtitle: "\(g.login) on \(g.node) · since "
                               + date.string(from: Date(timeIntervalSince1970: g.added)),
                           buttons: [revoke]))
        }

        out.append(note(
            "Guests sign in as \(NSUserName()) with their own key, accepted only from their "
          + "device's Tailscale address, with port and agent forwarding turned off. Access "
          + "lasts while this switch is on, even if shh is closed."))
        return out
    }

    // MARK: - pieces

    private func statusView() -> NSView {
        switch access.status {
        case .off:
            return statusLabel(.idle, text: "Off")
        case .starting:
            return statusLabel(.connecting, text: "Starting…")
        case .listening(let me):
            let where_ = me.dnsName.isEmpty ? me.ipv4 : "\(me.dnsName) (\(me.ipv4))"
            return statusLabel(.online, text: "Ready on \(where_)")
        case .problem(let msg):
            let l = statusLabel(.offline, text: msg)
            if Tailscale.cli == nil {
                let get = LinkButton("Download Tailscale")
                get.onClick = {
                    NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                }
                return stack([l, get])
            }
            return l
        }
    }

    private func remoteLoginView() -> NSView {
        let open = LinkButton("Open Sharing settings")
        open.onClick = { RemoteAccess.openRemoteLoginSettings() }
        let recheck = LinkButton("Check again")
        recheck.onClick = { RemoteAccess.shared.checkRemoteLogin() }
        switch access.remoteLoginOn {
        case .some(true):
            return statusLabel(.online, text: "On")
        case .some(false):
            return stack([statusLabel(.warning,
                                      text: "Off — guests can't sign in until you turn it on"),
                          open, recheck])
        case .none:
            return statusLabel(.connecting, text: "Checking…")
        }
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = Space.md
        s.alignment = .centerY
        return s
    }

    private func note(_ text: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: text)
        n.font = Fonts.caption
        n.textColor = Text.muted
        n.wraps(lines: 4)
        return n
    }

    private func row(icon: String, title: String, subtitle: String, buttons: [NSView]) -> NSView {
        let card = CardView()
        card.accent = Pastel.color(5)
        card.tintStrength = 0.05

        let img = NSImageView()
        img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        img.contentTintColor = Text.secondary

        let t = NSTextField(labelWithString: title)
        t.font = Fonts.bodyMed
        t.textColor = Text.primary
        t.truncates(.byTruncatingTail)
        let s = NSTextField(labelWithString: subtitle)
        s.font = Fonts.caption
        s.textColor = Text.secondary
        s.truncates(.byTruncatingTail)
        let texts = NSStackView(views: [t, s])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let h = NSStackView(views: [img, texts, spacer] + buttons)
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = Space.md
        h.translatesAutoresizingMaskIntoConstraints = false
        card.content.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: card.content.topAnchor, constant: Space.md),
            h.bottomAnchor.constraint(equalTo: card.content.bottomAnchor, constant: -Space.md),
            h.leadingAnchor.constraint(equalTo: card.content.leadingAnchor, constant: Space.lg),
            h.trailingAnchor.constraint(equalTo: card.content.trailingAnchor, constant: -Space.lg),
        ])
        return card
    }

    // MARK: - actions

    @objc private func toggled(_ s: NSSwitch) {
        if s.state == .on {
            access.setEnabled(true)
            return
        }
        guard !access.file.guests.isEmpty else { access.setEnabled(false); return }
        let a = NSAlert()
        a.messageText = "Turn off remote sessions?"
        a.informativeText = "Everyone you've let in loses access, and any session they have "
            + "open is ended."
        a.addButton(withTitle: "Turn Off")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { access.setEnabled(false) }
        else { s.state = .on }
    }

    private func makeInvite() {
        let ask = NSAlert()
        ask.messageText = "Who is this invite for?"
        ask.informativeText = "Only you see this name. It's shown when they use the invite, "
            + "so you know who you're letting in."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Alice"
        ask.accessoryView = field
        ask.addButton(withTitle: "Create")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        let code: InviteCode
        do { code = try access.createInvite(label: label) } catch {
            let e = NSAlert(error: error)
            e.runModal()
            return
        }
        showInvite(code, label: label)
    }

    private func showInvite(_ code: InviteCode, label: String) {
        let link = code.string
        let a = NSAlert()
        a.messageText = label.isEmpty ? "Invite ready" : "Invite for \(label)"
        a.informativeText =
            "Send this to them directly. It works once and expires in 15 minutes. "
          + "When they use it, you'll be asked to approve them.\n\n"
          + "They need shh and Tailscale, and must be able to reach this Mac on Tailscale — "
          + "the same tailnet, or share this machine with them from the Tailscale admin console."
        let text = NSTextField(wrappingLabelWithString: link)
        text.isSelectable = true
        text.font = Fonts.mono(11)
        text.frame = NSRect(x: 0, y: 0, width: 360, height: 72)
        a.accessoryView = text
        a.addButton(withTitle: "Copy Link")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
    }

    private func confirmRevoke(_ g: RemoteAccess.Guest) {
        let a = NSAlert()
        a.messageText = "Revoke \(g.displayName)?"
        a.informativeText = "Their key is removed from this Mac and any session they have "
            + "open is ended. You can invite them again later."
        a.addButton(withTitle: "Revoke")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { access.revoke(guestID: g.id) }
    }
}

/// The guest's sheet: paste an invite, wait for approval, get a server.
final class JoinInviteController: NSViewController {
    private let field = SoftTextField(placeholder: "shh://join?…", mono: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let join = SoftButton("Join", symbol: "arrow.right", style: .primary)
    private let cancel = SoftButton("Cancel", style: .quiet)
    private var busy = false
    private let prefill: String?
    /// Called with the new server's slug once it's saved.
    var onJoined: ((String) -> Void)?

    init(prefill: String? = nil) {
        self.prefill = prefill
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 260))

        let title = NSTextField(labelWithString: "Join with an invite")
        title.font = Fonts.title
        title.textColor = Text.primary
        let sub = NSTextField(wrappingLabelWithString:
            "Paste the link someone sent you from their shh. You both need Tailscale "
          + "connected. They'll be asked to approve you.")
        sub.font = Fonts.caption
        sub.textColor = Text.muted

        field.stringValue = prefill ?? clipboardInvite() ?? ""
        status.font = Fonts.caption
        status.textColor = Text.secondary
        status.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        join.onClick = { [weak self] in self?.go() }
        cancel.onClick = { [weak self] in
            guard let self, !self.busy else { return }
            self.dismiss(nil)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spinner, spacer, cancel, join])
        buttons.orientation = .horizontal
        buttons.spacing = Space.sm

        let stack = NSStackView(views: [title, sub, field, status, buttons])
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
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        field.focus()
    }

    private func clipboardInvite() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string),
              InviteCode(parsing: s) != nil else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func show(_ text: String, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? Ink.error : Text.secondary
        status.isHidden = false
    }

    private func go() {
        guard !busy else { return }
        guard let invite = InviteCode(parsing: field.stringValue) else {
            show("That isn't a shh invite link. It starts with shh://join", error: true)
            return
        }
        busy = true
        join.alphaValue = 0.5
        spinner.startAnimation(nil)
        show("Waiting for \(invite.hostLabel) to approve you…")

        JoinInvite.redeem(invite) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.join.alphaValue = 1
            self.spinner.stopAnimation(nil)
            switch result {
            case .failure(let e):
                self.show(e.localizedDescription, error: true)
            case .success(let slug):
                self.dismiss(nil)
                self.onJoined?(slug)
            }
        }
    }
}
