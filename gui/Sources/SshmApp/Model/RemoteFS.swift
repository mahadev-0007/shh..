import Foundation

/// Lists directories on a server so the project form can browse instead of
/// making you remember paths. Rides the session control socket when one is open,
/// so it usually costs no handshake and no password.
enum RemoteFS {
    struct Listing {
        var path: String
        var directories: [String]
    }

    typealias RemoteError = RemoteExec.RemoteError

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

        let shared = AppModel.shared.settings.shareConnectionPerServer
        let args = ["-p", server.port]
            + RemoteExec.options(for: server, controlPath: RemoteExec.controlPath(for: server),
                                 master: shared)
            + [server.target, script]

        RemoteExec.run(Tools.ssh, args: args, password: server.password) { result in
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
}
