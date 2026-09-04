import AppKit

/// Holds every live session's terminal view. Terminals are added once and then
/// only hidden or shown — removing one from the hierarchy makes SwiftTerm
/// re-measure and resize the remote pty, which redraws whatever full-screen
/// agent is running.
final class TerminalHostViewController: NSViewController {
    private(set) var sessions: [SSHSession] = []
    private(set) var current: SSHSession?

    var onSessionsChanged: (() -> Void)?
    var onSessionSelected: (() -> Void)?

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
        view = root
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

    func open(_ spec: LaunchSpec) {
        let s = SSHSession(spec: spec)
        s.onStateChange = { [weak self] in self?.onSessionsChanged?() }
        s.onImageStatus = { [weak self] text, isError in
            self?.showToast(text, isError: isError)
        }
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
        onSessionsChanged?()
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
        focusCurrent()
        onSessionSelected?()
    }

    func focusCurrent() {
        guard let s = current else { return }
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(s.terminal)
        }
    }

    func close(id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: i)
        s.terminate()
        s.terminal.removeFromSuperview()
        if current === s {
            current = nil
            if !sessions.isEmpty { select(id: sessions[min(i, sessions.count - 1)].id) }
        }
        onSessionsChanged?()
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
