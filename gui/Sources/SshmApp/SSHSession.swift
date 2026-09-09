import AppKit
import SwiftTerm

/// What a session is doing right now.
enum SessionState: Equatable {
    /// Built but not started yet.
    case idle
    case connecting
    case running
    /// Waiting to try again after the link dropped.
    case reconnecting(attempt: Int, secondsLeft: Int)
    case ended(ExitStatus)

    var isLive: Bool {
        switch self {
        case .connecting, .running, .reconnecting: return true
        case .idle, .ended: return false
        }
    }
    /// True only when the remote end is actually usable.
    var isConnected: Bool { self == .running || self == .connecting }
}

/// A single ssh session — connecting, connected, retrying, or finished —
/// rendered by a SwiftTerm view. One per tab.
final class SSHSession: NSObject, LocalProcessTerminalViewDelegate {
    let spec: LaunchSpec
    let terminal: SessionTerminalView
    let id = UUID().uuidString
    /// When this session first opened, so elapsed time survives view rebuilds.
    let startedAt = Date()

    /// Which session this is for its project: 1, 2, 3… Drives the tab suffix
    /// and the tmux session name, so duplicates stay independent.
    var ordinal: Int = 1

    /// Control socket for this connection. Extra channels (the remote directory
    /// browser, image uploads) ride it, so there is no second password prompt.
    let controlPath: String

    private(set) var state: SessionState = .idle {
        didSet { if state != oldValue { onStateChange?() } }
    }
    /// Something happened here worth looking at — an agent finished, a bell
    /// rang. Cleared when the session is brought to the front.
    private(set) var needsAttention = false

    private var fifoDir: URL?
    private var attempt = 0
    private var retryWork: DispatchWorkItem?
    private var countdown: Timer?
    private var lastLaunch = Date()

    var onStateChange: (() -> Void)?
    /// Progress and errors from the image bridge.
    var onImageStatus: ((String, Bool) -> Void)?
    /// Something wants the user's attention: (title, body, kind).
    var onNotify: ((String, String, NotificationKind) -> Void)?

    var server: Server { spec.server }
    var projectID: String? { spec.projectID }
    var isRunning: Bool { state.isConnected }
    var exitCode: Int32? {
        if case .ended(let s) = state, case .code(let c) = s { return c }
        return nil
    }

    /// The name shown on the tab. A second session of the same project needs to
    /// be tellable from the first.
    var title: String { ordinal > 1 ? "\(spec.title) #\(ordinal)" : spec.title }

    /// Stable, tmux-safe name for the remote session this tab owns.
    var remoteSessionName: String? {
        guard let pid = spec.projectID else { return nil }
        return "shh-\(Slug.make(spec.title))-\(ordinal)-\(pid.prefix(4).lowercased())"
    }

    init(spec: LaunchSpec) {
        self.spec = spec
        self.controlPath = SSHSession.socketPath(for: spec.server)
        self.terminal = SessionTerminalView(frame: .zero)
        super.init()
        terminal.processDelegate = self
        Theme.apply(to: terminal, hue: spec.accent)
        terminal.uploadTarget = { [weak self] in
            guard let self, self.state == .running else { return nil }
            return (self.controlPath, self.server.target)
        }
        terminal.onStatus = { [weak self] text, isError in
            self?.onImageStatus?(text, isError)
        }
        terminal.onNotify = { [weak self] title, body, kind in
            guard let self else { return }
            self.needsAttention = true
            self.onNotify?(title, body, kind)
            self.onStateChange?()
        }
    }

    /// One socket per server (not per session) means opening three projects on
    /// the same box authenticates once instead of three times.
    private static func socketPath(for server: Server) -> String {
        guard AppModel.shared.settings.shareConnectionPerServer else {
            return "/tmp/sshm-gui-\(getuid())-\(UUID().uuidString.prefix(8)).sock"
        }
        var h: UInt64 = 5381
        for b in "\(server.target):\(server.port)".utf8 { h = (h &* 33) &+ UInt64(b) }
        return "/tmp/sshm-gui-\(getuid())-\(String(h, radix: 36)).sock"
    }

    func markSeen() {
        guard needsAttention else { return }
        needsAttention = false
        onStateChange?()
    }

    // MARK: - launching

    func start() {
        guard !state.isConnected else { return }
        launch()
    }

    private func launch() {
        state = .connecting
        lastLaunch = Date()
        let wasRetrying = attempt > 0

        var args = ["-p", server.port,
                    "-o", "ServerAliveInterval=\(Env.string("SSHM_ALIVE_INTERVAL", "10"))",
                    "-o", "ServerAliveCountMax=\(Env.string("SSHM_ALIVE_COUNT", "3"))",
                    "-o", "ConnectTimeout=\(Env.string("SSHM_CONNECT_TIMEOUT", "10"))",
                    "-o", "TCPKeepAlive=yes",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(controlPath)",
                    "-o", "ControlPersist=\(AppModel.shared.settings.shareConnectionPerServer ? "60" : "no")"]

        if server.auth == "key" {
            args += ["-i", server.secret, "-o", "IdentitiesOnly=yes"]
        } else {
            // don't let ssh burn its auth attempts on agent keys first
            args += ["-o", "PubkeyAuthentication=no",
                     "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }

        // A remote command needs an explicit pty: without -t, full-screen agents
        // like claude and codex either refuse to start or render garbage.
        if let script = Shell.remoteScript(path: spec.path, agent: spec.agent,
                                           durableName: durableName) {
            args += ["-t", server.target, script]
        } else {
            args.append(server.target)
            if spec.path != nil || spec.agent?.command.isEmpty == false {
                emit("\u{1b}[33mThat path or command can't be sent safely "
                   + "(newlines aren't allowed) — opening a plain shell.\u{1b}[0m\r\n\r\n")
            }
        }

        var env = Terminal.getEnvironmentVariables(termName: Env.remoteTerm)
        env.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")

        if let pass = server.password, Tools.sshpass != nil {
            startWithPassword(pass, sshArgs: args, env: env)
        } else {
            if server.password != nil {
                emit("sshpass is not installed, so ssh will prompt for the password.\r\n"
                   + "install it with:  brew install sshpass\r\n\r\n")
            }
            terminal.startProcess(executable: Tools.ssh, args: args,
                                  environment: env, execName: nil)
        }
        state = .running

        // A connection that fails immediately will come straight back through
        // processTerminated; only call it a recovery once it has actually held.
        if wasRetrying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.state == .running else { return }
                self.emit(self.dim("reconnected"))
                self.onNotify?(self.title, "Reconnected", .reconnected)
            }
        }
    }

    /// The tmux session to attach to, or nil to run the command directly.
    private var durableName: String? {
        guard AppModel.shared.settings.durableSessions,
              spec.projectID != nil,
              ServerCapabilities.hasTmux(server) != false else { return nil }
        return remoteSessionName
    }

    /// Hand the password to sshpass on file descriptor 3, exactly as the bash
    /// script does: it never reaches argv (so it is invisible in `ps`) and never
    /// lands on disk. The fd is a fifo in a 0700 directory, unlinked immediately
    /// after the write.
    private func startWithPassword(_ pass: String, sshArgs: [String], env: [String]) {
        guard let sshpass = Tools.sshpass, let fifo = makeFifo() else {
            terminal.startProcess(executable: Tools.ssh, args: sshArgs,
                                  environment: env, execName: nil)
            return
        }

        let script = "exec \(Shell.quote(sshpass)) -d 3 \(Shell.quote(Tools.ssh))"
                   + " \"$@\" 3< \(Shell.quote(fifo.path))"
        terminal.startProcess(executable: "/bin/bash",
                              args: ["-c", script, "sshm"] + sshArgs,
                              environment: env, execName: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // O_WRONLY on a fifo blocks until a reader arrives; poll instead so
            // a child that dies before opening cannot wedge this thread forever.
            var fd: Int32 = -1
            for _ in 0..<100 {
                fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { break }
                usleep(50_000)
            }
            if fd >= 0 {
                var flags = fcntl(fd, F_GETFL)
                flags &= ~O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
                var bytes = Array(pass.utf8); bytes.append(0x0A)
                _ = bytes.withUnsafeBufferPointer {
                    Darwin.write(fd, $0.baseAddress, $0.count)
                }
                close(fd)
            }
            self?.cleanupFifo()
        }
    }

    private func makeFifo() -> URL? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshm-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        let path = dir.appendingPathComponent("pw")
        guard mkfifo(path.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: dir); return nil
        }
        fifoDir = dir
        return path
    }

    private func cleanupFifo() {
        if let d = fifoDir { try? FileManager.default.removeItem(at: d); fifoDir = nil }
    }

    // MARK: - reconnecting

    private static let backoff: [Int] = [1, 2, 4, 8, 15, 30, 30, 30]

    private func scheduleReconnect() {
        guard attempt < Self.backoff.count else {
            emit(dim("gave up reconnecting after \(attempt) attempts — "
                   + "press Reconnect to try again"))
            state = .ended(.code(255))
            return
        }
        let wait = Self.backoff[attempt]
        attempt += 1
        state = .reconnecting(attempt: attempt, secondsLeft: wait)

        // Don't burn attempts against a dead interface; NetworkWatch fires the
        // moment connectivity is back.
        guard NetworkWatch.shared.isOnline else {
            emit(dim("waiting for the network…"))
            NetworkWatch.shared.onceOnline { [weak self] in self?.reconnectNow() }
            return
        }

        emit(dim("connection lost — reconnecting in \(wait)s "
               + "(attempt \(attempt)/\(Self.backoff.count))"))

        countdown?.invalidate()
        var left = wait
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            left -= 1
            if left <= 0 { t.invalidate() }
            if case .reconnecting = self.state {
                self.state = .reconnecting(attempt: self.attempt, secondsLeft: max(0, left))
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.reconnectNow() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(wait), execute: work)
    }

    /// Retry immediately, whatever the backoff was about to do.
    func reconnectNow() {
        retryWork?.cancel(); retryWork = nil
        countdown?.invalidate(); countdown = nil
        guard !state.isConnected else { return }
        emit(dim("reconnecting…"))

        // SwiftTerm calls the termination delegate *before* clearing its own
        // `running` flag, and startProcess is a no-op while that flag is set.
        // Hopping a runloop turn guarantees the relaunch is not swallowed.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.state.isConnected else { return }
            self.clearStaleControlSocket()
            self.launch()
        }
    }

    /// Stop retrying and leave the session closed.
    func stopReconnecting() {
        retryWork?.cancel(); retryWork = nil
        countdown?.invalidate(); countdown = nil
        if case .reconnecting = state {
            emit(dim("stopped reconnecting"))
            state = .ended(.code(255))
        }
    }

    /// Sessions share one control master. When the link drops the master dies
    /// but its socket file stays behind, and the next connect can hang on it.
    private func clearStaleControlSocket() {
        guard FileManager.default.fileExists(atPath: controlPath) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.ssh)
        p.arguments = ["-S", controlPath, "-O", "check", server.target]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            try? FileManager.default.removeItem(atPath: controlPath)
        }
    }

    // MARK: - control

    func terminate() {
        retryWork?.cancel(); retryWork = nil
        countdown?.invalidate(); countdown = nil
        cleanupFifo()
        terminal.terminate()
    }

    private func emit(_ note: String) { terminal.feed(text: note) }

    private func dim(_ text: String) -> String {
        "\r\n\u{1b}[2m── \(text)\u{1b}[0m\r\n"
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode raw: Int32?) {
        cleanupFifo()
        let status = ExitStatus(rawStatus: raw ?? 0)

        // A session that held for a while and then dropped is a fresh failure,
        // not a continuation of an earlier one — don't let a flapping link
        // exhaust the attempt budget.
        if Date().timeIntervalSince(lastLaunch) > 30 { attempt = 0 }

        let retryable = status.shouldReconnect
            && AppModel.shared.settings.autoReconnect
            && spec.projectID != nil

        if retryable {
            onNotify?(title, "Connection lost — reconnecting", .disconnected)
            scheduleReconnect()
            return
        }

        var line = "session ended · \(status.label)"
        if let d = status.detail, case .code(let c) = status, c != 0 { line += "  (\(d))" }
        emit(dim(line))
        if !status.isClean {
            onNotify?(title, status.detail ?? status.label, .disconnected)
        }
        attempt = 0
        state = .ended(status)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
