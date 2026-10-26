import Foundation

/// One entry in a remote directory.
struct RemoteEntry: Equatable {
    var name: String
    /// A directory, or a symlink that points at one.
    var isDir: Bool
    var isLink: Bool
    var size: Int64
    var modified: Date
    /// `ls -l` style, e.g. "drwxr-xr-x".
    var mode: String

    var isHidden: Bool { name.hasPrefix(".") }
}

/// File browsing and transfer for one server. Listing and housekeeping run as
/// shell commands over ssh; uploads and downloads go through sftp. Both ride
/// the same control socket, so an open session means no extra login at all.
final class RemoteFiles {
    let server: Server
    private let controlPath: String

    typealias RemoteError = RemoteExec.RemoteError

    init(server: Server) {
        self.server = server
        // With sharing off there is no session socket to borrow, but the
        // browser still wants one connection for all its round trips — so it
        // gets a private socket of its own.
        if AppModel.shared.settings.shareConnectionPerServer {
            controlPath = RemoteExec.controlPath(for: server)
        } else {
            controlPath = "/tmp/sshm-gui-\(getuid())-files-\(UUID().uuidString.prefix(8)).sock"
        }
    }

    // MARK: - listing

    struct Listing {
        var path: String
        var entries: [RemoteEntry]
    }

    /// One round trip: resolve the path, mark which entries are directories
    /// (following links), then a single `stat` over the lot. GNU and BSD stat
    /// spell their formats differently, so try one and fall back to the other.
    func list(path: String, completion: @escaping (Result<Listing, Error>) -> Void) {
        var path = path.isEmpty ? "~" : path
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // "D/name" can't be confused with a stat line: a name never has a slash
        let script = """
            cd -- \(Shell.quotePath(path)) 2>/dev/null || exit 9
            pwd
            set --
            for f in .[!.]* ..?* *; do
              { [ -e "$f" ] || [ -L "$f" ]; } || continue
              set -- "$@" "$f"
              [ -d "$f" ] && printf 'D/%s\\n' "$f"
            done
            echo '--'
            [ $# -eq 0 ] && exit 0
            if stat -c %s . >/dev/null 2>&1; then
              stat -c '%A|%s|%Y|%n' -- "$@" 2>/dev/null
            else
              stat -f '%Sp|%z|%m|%N' -- "$@" 2>/dev/null
            fi
            exit 0
            """
        ssh(script) { result in
            switch result {
            case .failure(let e):
                if case RemoteError.exited(9, _) = e {
                    completion(.failure(RemoteError.notADirectory(path)))
                } else {
                    completion(.failure(e))
                }
            case .success(let out):
                completion(Self.parse(out, requested: path))
            }
        }
    }

    private static func parse(_ out: String, requested: String) -> Result<Listing, Error> {
        var lines = out.components(separatedBy: "\n")
        // no pwd line means the cd never happened
        guard let resolved = lines.first, !resolved.isEmpty else {
            return .failure(RemoteError.notADirectory(requested))
        }
        lines.removeFirst()

        var dirs = Set<String>()
        var entries: [RemoteEntry] = []
        var inStat = false
        for line in lines where !line.isEmpty {
            if !inStat {
                if line == "--" { inStat = true }
                else if line.hasPrefix("D/") { dirs.insert(String(line.dropFirst(2))) }
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 3,
                                   omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let mode = String(parts[0])
            let name = String(parts[3])
            entries.append(RemoteEntry(
                name: name,
                isDir: dirs.contains(name),
                isLink: mode.hasPrefix("l"),
                size: Int64(parts[1]) ?? 0,
                modified: Date(timeIntervalSince1970: TimeInterval(Int64(parts[2]) ?? 0)),
                mode: mode))
        }
        entries.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return .success(Listing(path: resolved, entries: entries))
    }

    // MARK: - housekeeping

    func makeDirectory(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        ssh("mkdir -- \(Shell.quote(path))") { completion($0.map { _ in () }) }
    }

    /// Refuses to overwrite: `mv` onto an existing directory would quietly move
    /// the item *into* it instead of renaming it.
    func rename(_ from: String, to: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let script = "[ -e \(Shell.quote(to)) ] || [ -L \(Shell.quote(to)) ] "
                   + "&& { echo 'Something with that name already exists.' >&2; exit 1; }; "
                   + "mv -- \(Shell.quote(from)) \(Shell.quote(to))"
        ssh(script) { completion($0.map { _ in () }) }
    }

    /// Recursive. The UI is responsible for asking first.
    func delete(_ paths: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !paths.isEmpty else { completion(.success(())); return }
        ssh("rm -rf -- " + paths.map(Shell.quote).joined(separator: " ")) {
            completion($0.map { _ in () })
        }
    }

    // MARK: - transfers

    /// Copy local files or folders into a remote directory.
    func upload(_ urls: [URL], toDirectory dir: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = urls.map { url in
            "put -r \(Self.sftpQuote(url.path)) "
                + Self.sftpQuote(Self.join(dir, url.lastPathComponent))
        }
        sftp(batch, completion: completion)
    }

    /// Copy remote files or folders to exact local destinations.
    func download(_ pairs: [(remote: String, local: URL)],
                  completion: @escaping (Result<Void, Error>) -> Void) {
        let batch = pairs.map {
            "get -r \(Self.sftpQuote($0.remote)) \(Self.sftpQuote($0.local.path))"
        }
        sftp(batch, completion: completion)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// sftp splits its commands on whitespace and globs every path, so quote
    /// the whole thing and backslash the quote, the backslash and the glob
    /// characters — otherwise a file called `a*b` would also fetch `aXb`.
    static func sftpQuote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            if "\"\\*?[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out + "\""
    }

    // MARK: - plumbing

    private func options(master: Bool = true) -> [String] {
        RemoteExec.options(for: server, controlPath: controlPath, master: master)
    }

    /// The remote login shell might be fish or anything else, so hand the
    /// script to sh explicitly.
    private func ssh(_ script: String, completion: @escaping (Result<String, Error>) -> Void) {
        let args = ["-p", server.port] + options()
            + [server.target, "sh -c \(Shell.quote(script))"]
        RemoteExec.run(Tools.ssh, args: args, password: server.password,
                       completion: completion)
    }

    /// `sftp -b` forces BatchMode, which rules out password logins. So make
    /// sure a master connection is up first (a no-op when one already is),
    /// then let sftp ride it without authenticating at all.
    private func sftp(_ commands: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        ssh("true") { [self] up in
            if case .failure(let e) = up { completion(.failure(e)); return }
            let args = ["-P", server.port] + options() + ["-b", "-", server.target]
            let input = Data((commands.joined(separator: "\n") + "\n").utf8)
            RemoteExec.run(Tools.sftp, args: args, password: nil, input: input) {
                completion($0.map { _ in () })
            }
        }
    }
}
