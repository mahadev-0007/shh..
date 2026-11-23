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
                           hint: "You approve each person when they use their invite. "
                               + "Turning this off removes everyone.",
                           labelWidth: 150))

        guard access.file.enabled else { return out }

        let ready = access.isReady
        if ready, case .listening(let me) = access.status {
            out.append(FormRow("Status",
                               statusLabel(.online, text: "Ready — people you invite reach this "
                                   + "Mac at \(me.dnsName.isEmpty ? me.ipv4 : me.dnsName)"),
                               labelWidth: 150))
        } else {
            out.append(sectionHeader("Finish setup"))
            out.append(tailscaleStep())
            out.append(remoteLoginStep())
        }

        let invites = access.file.invites.filter { !$0.isExpired }
        if ready {
            let newInvite = SoftButton("Invite someone", symbol: "plus", style: .primary,
                                       accent: Pastel.color(5))
            newInvite.onClick = { [weak self] in self?.makeInvite() }
            out.append(sectionHeader("Invites", newInvite))
            if invites.isEmpty {
                out.append(note("No open invites. Each invite works once and expires after "
                              + "15 minutes."))
            }
        } else {
            out.append(sectionHeader("Invites"))
            out.append(note("Finish the steps above and you can invite someone."))
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
            "Guests sign in as \(NSUserName()) with their own key, and only from their own "
          + "device on Tailscale. Access lasts while the switch is on, even if shh is closed."))
        return out
    }

    // MARK: - setup steps

    private enum StepState { case done, todo, working }

    private func step(_ state: StepState, title: String, subtitle: String,
                      buttons: [NSView] = []) -> NSView {
        switch state {
        case .done:
            return row(icon: "checkmark.circle.fill", tint: Ink.success, title: title,
                       subtitle: subtitle, buttons: buttons)
        case .todo:
            return row(icon: "exclamationmark.circle.fill", tint: Ink.warning, title: title,
                       subtitle: subtitle, buttons: buttons)
        case .working:
            return row(icon: "ellipsis.circle", tint: Text.muted, title: title,
                       subtitle: subtitle, buttons: buttons)
        }
    }

    private func checkAgain() -> NSView {
        let b = SoftButton("Check again", style: .quiet)
        b.onClick = { RemoteAccess.shared.recheck() }
        return b
    }

    private func tailscaleStep() -> NSView {
        switch access.status {
        case .off, .starting:
            return step(.working, title: "Checking Tailscale…", subtitle: "One moment.")
        case .listening(let me):
            return step(.done, title: "Tailscale is connected",
                        subtitle: me.dnsName.isEmpty ? me.ipv4 : me.dnsName)
        case .problem(let msg):
            let app = "/Applications/Tailscale.app"
            if Tailscale.cli == nil {
                let get = SoftButton("Get Tailscale", symbol: "arrow.down.circle", style: .primary,
                                     accent: Pastel.color(5))
                get.onClick = {
                    NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                }
                return step(.todo, title: "Install Tailscale",
                            subtitle: "It's the private network your guests reach this Mac over.",
                            buttons: [checkAgain(), get])
            }
            var buttons = [checkAgain()]
            if FileManager.default.fileExists(atPath: app) {
                let open = SoftButton("Open Tailscale", style: .primary, accent: Pastel.color(5))
                open.onClick = { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
                buttons.append(open)
            }
            return step(.todo, title: "Connect Tailscale", subtitle: msg, buttons: buttons)
        }
    }

    private func remoteLoginStep() -> NSView {
        switch access.remoteLoginOn {
        case .none:
            return step(.working, title: "Checking Remote Login…", subtitle: "One moment.")
        case .some(true) where access.hostKeyReady:
            return step(.done, title: "Remote Login is on",
                        subtitle: "macOS accepts ssh sign-ins on this Mac.")
        case .some(true):
            return step(.working, title: "Finishing Remote Login…",
                        subtitle: "Preparing this Mac's ssh key. This takes a few seconds.",
                        buttons: [checkAgain()])
        case .some(false):
            let on = SoftButton("Turn On", symbol: "power", style: .primary,
                                accent: Pastel.color(5))
            on.onClick = { RemoteAccess.shared.turnOnRemoteLogin() }
            return step(.todo, title: "Turn on Remote Login",
                        subtitle: "macOS needs this before guests can sign in. "
                                + "You'll be asked for your Mac password.",
                        buttons: [on])
        }
    }

    private func note(_ text: String) -> NSTextField {
        let n = NSTextField(wrappingLabelWithString: text)
        n.font = Fonts.caption
        n.textColor = Text.muted
        n.wraps(lines: 4)
        return n
    }

    private func row(icon: String, tint: NSColor = Text.secondary, title: String,
                     subtitle: String, buttons: [NSView]) -> NSView {
        let card = CardView()
        card.accent = Pastel.color(5)
        card.tintStrength = 0.05

        let img = NSImageView()
        img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        img.contentTintColor = tint

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
        ask.messageText = "Who are you inviting?"
        ask.informativeText = "Just a name for your own list, so you know who you're "
            + "letting in. You'll get a link to send them."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Alice"
        ask.accessoryView = field
        ask.addButton(withTitle: "Create Link")
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

    /// The link is already on the clipboard by the time this shows: the only
    /// thing left for the host to do is paste it to their guest.
    private func showInvite(_ code: InviteCode, label: String) {
        let link = code.string
        let copy = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        copy()
        let who = label.isEmpty ? "them" : label
        let a = NSAlert()
        a.messageText = "Invite link copied"
        a.informativeText =
            "Paste it in a message to \(who). They open it in shh, and you'll be asked to "
          + "approve them. The link works once and expires in 15 minutes.\n\n"
          + "They need shh and Tailscale, and to be on your tailnet — or share this Mac "
          + "with them from the Tailscale admin console."
        a.addButton(withTitle: "Done")
        a.addButton(withTitle: "Copy Again")
        if a.runModal() == .alertSecondButtonReturn { copy() }
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
