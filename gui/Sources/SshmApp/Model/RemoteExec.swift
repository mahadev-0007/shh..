import Foundation

/// The plumbing every short-lived helper (folder picker, file browser) shares:
/// how to reach a server without a pty, and how to run ssh or sftp against it.
enum RemoteExec {
    /// One socket per server. SSHSession uses the same name, so helpers ride an
    /// open session's connection instead of authenticating a second time.
    static func controlPath(for server: Server) -> String {
        var h: UInt64 = 5381
        for b in "\(server.target):\(server.port)".utf8 { h = (h &* 33) &+ UInt64(b) }
        return "/tmp/sshm-gui-\(getuid())-\(String(h, radix: 36)).sock"
    }

    /// The `-o` options shared by ssh and sftp. The port flag is left out
    /// because the two disagree on it (`-p` vs `-P`).
    ///
    /// Browsing is a sequence of small round trips. With ControlMaster=no
    /// each step opens a fresh authenticated connection, and a few levels of
    /// clicking is enough for sshd to start refusing the logins. `auto`
    /// reuses an open session's connection when there is one and otherwise
    /// becomes the master itself, so the whole browse costs one handshake.
    static func options(for server: Server, controlPath: String, master: Bool) -> [String] {
        var args = ["-o", "ConnectTimeout=8",
                    "-o", "ControlMaster=\(master ? "auto" : "no")",
                    "-o", "ControlPersist=60",
                    "-o", "ControlPath=\(controlPath)"]
        if server.auth == "key" {
            // no prompt is possible or wanted here, so fail fast instead of hanging
            args += ["-i", server.secret, "-o", "IdentitiesOnly=yes",
                     "-o", "BatchMode=yes"]
        } else {
            // NOT BatchMode: it disables password auth entirely, so sshpass would
            // never be offered a prompt to answer.
            args += ["-o", "PubkeyAuthentication=no",
                     "-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "NumberOfPasswordPrompts=1"]
        }
        return args
    }

    enum RemoteError: LocalizedError {
        case notADirectory(String)
        case exited(Int32, String)
        var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "“\(p)” isn't a directory you can read."
            case .exited(let code, let s):
                // ssh is chatty; the last non-empty line is the useful one
                let detail = s.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }.last
                if let detail, !detail.isEmpty { return detail }
                if code == 255 { return "Could not reach the server." }
                return "The server refused that (exit \(code))."
            }
        }
    }

    /// Run ssh or sftp off the main thread and call back on it with stdout.
    static func run(_ tool: String, args: [String], password: String?, input: Data? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let out = Pipe(), err = Pipe()
            let stdin = input.map { _ in Pipe() }
            p.standardOutput = out
            p.standardError = err
            p.standardInput = stdin ?? FileHandle.nullDevice

            // BatchMode means no prompt is possible, so a password host needs
            // sshpass here too. This one uses SSHPASS in the environment rather
            // than the fd-3 fifo a session gets: it is a short-lived helper with
            // no pty, and the env of a process is readable only by its own user
            // — the same boundary that already protects servers.conf.
            if let pass = password, let sshpass = Tools.sshpass {
                p.executableURL = URL(fileURLWithPath: sshpass)
                p.arguments = ["-e", tool] + args
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = pass
                p.environment = env
            } else {
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
            }

            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let stdin, let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            // stderr on its own thread: a chatty sftp can fill that pipe while
            // we are still blocked reading stdout, and then both sides wait forever
            var errData = Data()
            let errDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                errDone.signal()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            p.waitUntilExit()

            let text = String(data: data, encoding: .utf8) ?? ""
            let errText = String(data: errData, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    completion(.success(text))
                } else {
                    completion(.failure(RemoteError.exited(
                        p.terminationStatus,
                        errText.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }
        }
    }
}
