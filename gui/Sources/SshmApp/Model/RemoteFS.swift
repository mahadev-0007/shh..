import Foundation

/// Lists directories on a server so the project form can browse instead of
/// making you remember paths. Rides the session control socket when one is open,
/// so it usually costs no handshake and no password.
enum RemoteFS {
    struct Listing {
        var path: String
        var directories: [String]
    }

    /// `ls -1p` and keep the entries ending in "/" — one round trip, no find,
    /// nothing that can wander off across a big filesystem.
    static func list(server: Server, path: String,
                     completion: @escaping (Result<Listing, Error>) -> Void) {
        var path = path.isEmpty ? "~" : path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // `|| true` matters: grep exits 1 when a directory simply has no
        // subdirectories, and that is a perfectly good empty listing, not a
        // failure. Only the cd is allowed to decide the exit status.
        // A distinct exit code for "that isn't a directory", so it can be told
        // apart from ssh itself failing to connect.
        let script = "cd -- \(Shell.quotePath(path)) 2>/dev/null || exit 9; "
                   + "pwd; ls -1p 2>/dev/null | grep '/$' || true"

        // Browsing is a sequence of small round trips. With ControlMaster=no
        // each step opens a fresh authenticated connection, and a few levels of
        // clicking is enough for sshd to start refusing the logins. `auto`
        // reuses an open session's connection when there is one and otherwise
        // becomes the master itself, so the whole browse costs one handshake.
        let shared = AppModel.shared.settings.shareConnectionPerServer
        var args = ["-p", server.port,
                    "-o", "ConnectTimeout=8",
                    "-o", "ControlMaster=\(shared ? "auto" : "no")",
                    "-o", "ControlPersist=60",
                    "-o", "ControlPath=\(controlPath(for: server))"]
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
        args += [server.target, script]

        run(args: args, password: server.password) { result in
            switch result {
            case .failure(let e):
                if case RemoteError.exited(9, _) = e {
                    completion(.failure(RemoteError.notADirectory(path)))
                } else {
                    completion(.failure(e))
                }
            case .success(let out):
                var lines = out.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                // no pwd line means the cd never happened
                guard !lines.isEmpty else {
                    completion(.failure(RemoteError.notADirectory(path))); return
                }
                let resolved = lines.removeFirst()
                let dirs = lines.map { String($0.dropLast()) }.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                completion(.success(Listing(path: resolved, directories: dirs)))
            }
        }
    }

    /// Matches SSHSession's socket naming so an open session's connection is
    /// reused instead of opening a second one.
    private static func controlPath(for server: Server) -> String {
        var h: UInt64 = 5381
        for b in "\(server.target):\(server.port)".utf8 { h = (h &* 33) &+ UInt64(b) }
        return "/tmp/sshm-gui-\(getuid())-\(String(h, radix: 36)).sock"
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
                return "The server refused that listing (exit \(code))."
            }
        }
    }

    private static func run(args: [String], password: String?,
                            completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err

            // BatchMode means no prompt is possible, so a password host needs
            // sshpass here too. This one uses SSHPASS in the environment rather
            // than the fd-3 fifo a session gets: it is a short-lived helper with
            // no pty, and the env of a process is readable only by its own user
            // — the same boundary that already protects servers.conf.
            if let pass = password, let sshpass = Tools.sshpass {
                p.executableURL = URL(fileURLWithPath: sshpass)
                p.arguments = ["-e", Tools.ssh] + args
                p.standardInput = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["SSHPASS"] = pass
                p.environment = env
            } else {
                p.executableURL = URL(fileURLWithPath: Tools.ssh)
                p.arguments = args
            }

            do { try p.run() } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
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
