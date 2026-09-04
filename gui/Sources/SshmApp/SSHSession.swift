import AppKit
import SwiftTerm

/// A single ssh session — connecting, connected, or finished — rendered by a
/// SwiftTerm view. One per tab.
final class SSHSession: NSObject, LocalProcessTerminalViewDelegate {
    let spec: LaunchSpec
    let terminal: SessionTerminalView
    let id = UUID().uuidString

    /// Control socket for this connection. Extra channels (the remote directory
    /// browser, future uploads) ride it, so there is no second password prompt.
    let controlPath: String

    private(set) var isRunning = false
    private(set) var exitCode: Int32?
    private var fifoDir: URL?

    var onStateChange: (() -> Void)?
    /// Progress and errors from the image bridge.
    var onImageStatus: ((String, Bool) -> Void)?

    var server: Server { spec.server }
    var projectID: String? { spec.projectID }

    init(spec: LaunchSpec) {
        self.spec = spec
        self.controlPath = SSHSession.socketPath(for: spec.server)
        self.terminal = SessionTerminalView(frame: .zero)
        super.init()
        terminal.processDelegate = self
        Theme.apply(to: terminal, hue: spec.accent)
        terminal.uploadTarget = { [weak self] in
            guard let self, self.isRunning else { return nil }
            return (self.controlPath, self.server.target)
        }
        terminal.onStatus = { [weak self] text, isError in
            self?.onImageStatus?(text, isError)
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

    // MARK: - launching

    func start() {
        guard !isRunning else { return }
        isRunning = true

        var args = ["-p", server.port,
                    "-o", "ServerAliveInterval=\(Env.string("SSHM_ALIVE_INTERVAL", "20"))",
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
        if let script = Shell.remoteScript(path: spec.path, agent: spec.agent) {
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

    // MARK: - control

    func terminate() {
        cleanupFifo()
        terminal.terminate()
    }

    private func emit(_ note: String) { terminal.feed(text: note) }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode code: Int32?) {
        isRunning = false
        exitCode = code
        cleanupFifo()
        let c = code ?? 0
        var line = "\r\n\u{1b}[2m── session ended · exit \(c)"
        switch c {
        case 5:   line += "  (sshpass: wrong password)"
        case 6:   line += "  (host key not accepted — connect once by hand to trust it)"
        case 255: line += "  (ssh could not connect — host, port, firewall or auth method)"
        default:  break
        }
        line += "\u{1b}[0m\r\n"
        emit(line)
        onStateChange?()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
