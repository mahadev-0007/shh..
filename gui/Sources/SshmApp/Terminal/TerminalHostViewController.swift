import AppKit

/// Holds every live session's terminal view. Terminals are added once and then
/// only hidden or shown — removing one from the hierarchy makes SwiftTerm
/// re-measure and resize the remote pty, which redraws whatever full-screen
/// agent is running.
final class TerminalHostViewController: NSViewController {
    private(set) var sessions: [SSHSession] = []
    private(set) var current: SSHSession?

    /// Multicast: the shell watches these to refresh pills, and the sessions
    /// page watches them to rebuild its list. A single closure meant whichever
    /// registered last silently replaced the other.
    private var changeObservers: [(key: String, body: () -> Void)] = []
    private var selectObservers: [(key: String, body: () -> Void)] = []

    func onSessionsChanged(_ key: String, _ body: @escaping () -> Void) {
        changeObservers.removeAll { $0.key == key }
        changeObservers.append((key, body))
    }
    func onSessionSelected(_ key: String, _ body: @escaping () -> Void) {
        selectObservers.removeAll { $0.key == key }
        selectObservers.append((key, body))
    }
    private func sessionsChanged() { updateStatusCard(); changeObservers.forEach { $0.body() } }
    private func sessionSelected() { updateStatusCard(); selectObservers.forEach { $0.body() } }

    /// Close a tab through the shell, so the tab bar hears about it.
    var onCloseRequest: ((String) -> Void)?
    /// End a session (close the tab and kill its tmux session), through the shell.
    var onEndRequest: ((SSHSession) -> Void)?

    /// Floats over the bottom of the terminal while the session isn't connected.
    private let statusCard = SessionStatusCard()
    private var keyMonitor: Any?

    /// Bring a session forward — used when a notification is clicked.
    var onRequestFocus: ((String) -> Void)?

    /// Transient feedback for the image bridge, floated over the terminal so it
    /// never writes into the session's output.
    private let banner = ToastView()
    private var bannerHide: DispatchWorkItem?

    override func loadView() {
        let root = ThemedCanvas()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.alphaValue = 0
        root.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.md),
            banner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])

        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusCard.isHidden = true
        root.addSubview(statusCard)
        let wide = statusCard.widthAnchor.constraint(equalToConstant: 620)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            statusCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Space.xl),
            statusCard.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusCard.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor,
                                              constant: -Space.xl * 2),
            wide,
        ])
        statusCard.onReconnect = { [weak self] in self?.current?.reconnectNow() }
        statusCard.onStop = { [weak self] in self?.current?.stopReconnecting() }
        statusCard.onEnd = { [weak self] in
            guard let self, let s = self.current else { return }
            self.onEndRequest?(s)
        }
        statusCard.onClose = { [weak self] in
            guard let self, let id = self.current?.id else { return }
            if let close = self.onCloseRequest { close(id) } else { self.close(id: id) }
        }

        // ⏎ in a finished session reconnects it. The terminal itself can't be
        // taught this (SwiftTerm's keyDown isn't open), so catch it on the way in.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // ⇧⏎ is how Claude Code and friends take a newline. Talking to us
            // directly they turn on the kitty keyboard protocol and SwiftTerm
            // reports the shift. Inside tmux (durable sessions) that request
            // never reaches us, so ⇧⏎ would arrive as a bare ⏎ and submit.
            // Send a line feed instead — the newline every agent accepts
            // (it's ⌃J), and a plain shell still runs the line.
            if let self, let s = self.current, s.isRunning,
               e.window === self.view.window,
               e.window?.firstResponder === s.terminal,
               e.keyCode == 36 || e.keyCode == 76,
               e.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift,
               s.terminal.getTerminal().keyboardEnhancementFlags.isEmpty {
                s.terminal.send(txt: "\n")
                return nil
            }
            guard let self, let s = self.current, case .ended = s.state,
                  e.window === self.view.window,
                  e.window?.firstResponder === s.terminal,
                  e.keyCode == 36 || e.keyCode == 76,
                  e.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return e }
            s.reconnectNow()
            return nil
        }
        view = root
    }

    private func updateStatusCard() {
        guard isViewLoaded else { return }
        let show = current.map { statusCard.show($0) } ?? false
        if show {
            // keep it above whichever terminal is in front
            view.addSubview(statusCard, positioned: .above, relativeTo: nil)
            if statusCard.isHidden {
                statusCard.alphaValue = 0
                statusCard.isHidden = false
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2
                    statusCard.animator().alphaValue = 1 }
            }
        } else if !statusCard.isHidden {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15
                statusCard.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.current.map({ !self.statusCard.show($0) }) ?? true
                else { return }
                self.statusCard.isHidden = true
            })
        }
    }

    func showToast(_ text: String, isError: Bool) {
        banner.set(text: text, isError: isError)
        view.addSubview(banner, positioned: .above, relativeTo: nil)
        bannerHide?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15
            banner.animator().alphaValue = 1 }
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3
                self?.banner.animator().alphaValue = 0 }
        }
        bannerHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 6 : 2.5), execute: w)
    }

    @discardableResult
    func open(_ spec: LaunchSpec) -> SSHSession {
        let s = SSHSession(spec: spec)
        // second session of a project is "#2", and gets its own tmux session
        if let pid = spec.projectID {
            let taken = sessions.filter { $0.projectID == pid }.map(\.ordinal)
            if let wanted = spec.ordinal, !taken.contains(wanted) {
                s.ordinal = wanted
            } else {
                s.ordinal = (taken.max() ?? 0) + 1
            }
        }
        s.onStateChange = { [weak self] in self?.sessionsChanged() }
        s.onImageStatus = { [weak self] text, isError in
            self?.showToast(text, isError: isError)
        }
        s.onNotify = { [weak self] title, body, kind in
            guard let self else { return }
            Notifier.shared.notify(sessionID: s.id, title: title, body: body, kind: kind,
                                   isVisible: self.current === s)
        }
        s.terminal.sessionTitle = { [weak s] in s?.title ?? "Session" }
        sessions.append(s)

        let t = s.terminal
        t.translatesAutoresizingMaskIntoConstraints = false
        t.isHidden = true
        view.addSubview(t)
        NSLayoutConstraint.activate([
            // edge to edge: a terminal wants every column it can get
            t.topAnchor.constraint(equalTo: view.topAnchor, constant: Space.sm),
            t.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Space.md),
            t.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            t.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        select(id: s.id)
        s.start()
        ServerCapabilities.probe(spec.server, controlPath: s.controlPath)
        sessionsChanged()
        return s
    }

    /// Every session belonging to a project, in the order they were opened.
    func sessions(forProject id: String) -> [SSHSession] {
        sessions.filter { $0.projectID == id }
    }

    func session(forProject id: String) -> SSHSession? {
        sessions.first { $0.projectID == id }
    }

    func select(id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        current = s
        for other in sessions { other.terminal.isHidden = other !== s }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        view.layer?.backgroundColor = Theme.wash(s.spec.accent, dark: dark).cgColor
        // looking at it counts as reading it
        s.markSeen()
        Notifier.shared.clear(sessionID: s.id)
        focusCurrent()
        sessionSelected()
    }

    func focusCurrent() {
        guard let s = current else { return }
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(s.terminal)
        }
    }

    /// Recently closed tabs, newest last, for "Reopen Closed Session".
    private var closed: [(spec: LaunchSpec, index: Int)] = []
    var canReopen: Bool { !closed.isEmpty }

    func popClosed() -> (spec: LaunchSpec, index: Int)? { closed.popLast() }

    /// Put the sessions in this order (ids not listed keep their place at the end).
    func reorder(ids: [String]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let sorted = sessions.enumerated().sorted {
            (rank[$0.element.id] ?? ids.count + $0.offset)
                < (rank[$1.element.id] ?? ids.count + $1.offset)
        }.map(\.element)
        guard sorted.map(\.id) != sessions.map(\.id) else { return }
        sessions = sorted
        sessionsChanged()
    }

    /// Move one session to a position, clamped to the ends.
    func move(id: String, to index: Int) {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: from)
        sessions.insert(s, at: max(0, min(index, sessions.count)))
        sessionsChanged()
    }

    func close(id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: i)
        closed.append((s.spec, i))
        if closed.count > 20 { closed.removeFirst() }
        s.terminate()
        s.terminal.removeFromSuperview()
        if current === s {
            current = nil
            if !sessions.isEmpty { select(id: sessions[min(i, sessions.count - 1)].id) }
        }
        Notifier.shared.clear(sessionID: id)
        sessionsChanged()
    }

    /// Close everything except one — the "Close others" tab action.
    func closeOthers(keeping id: String) {
        for s in sessions where s.id != id { close(id: s.id) }
    }

    /// Close every session after this one — the "Close to the right" tab action.
    func closeAfter(id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        for s in sessions[(i + 1)...].reversed() { close(id: s.id) }
    }

    /// Select by position: 1-based, and 9 always means the last one.
    func select(number n: Int) {
        guard !sessions.isEmpty else { return }
        let i = n >= 9 ? sessions.count - 1 : n - 1
        guard sessions.indices.contains(i) else { return }
        select(id: sessions[i].id)
    }

    func cycle(_ delta: Int) {
        guard !sessions.isEmpty else { return }
        let i = current.flatMap { sessions.firstIndex(of: $0) } ?? 0
        let n = ((i + delta) % sessions.count + sessions.count) % sessions.count
        select(id: sessions[n].id)
    }

    func closeAll() {
        sessions.forEach { $0.terminate() }
        sessions.removeAll()
        current = nil
    }
}


/// A small floating message. Used for image-bridge feedback, which must not be
/// written into the terminal itself.
final class ToastView: ThemedView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var isError = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        softCorners(Radius.pill)
        layer?.borderWidth = 1
        label.font = Fonts.caption
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Space.sm),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, isError: Bool) {
        self.isError = isError
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: isError ? "exclamationmark.triangle.fill"
                                                       : "photo.on.rectangle.angled",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        applyTheme()
    }

    override func applyTheme() {
        layer?.backgroundColor = Ink.surface.cg(self)
        layer?.borderColor = (isError ? Ink.error : Ink.border).cg(self)
        label.textColor = isError ? Ink.error : Text.primary
        icon.contentTintColor = isError ? Ink.error : Ink.accent
    }
}
