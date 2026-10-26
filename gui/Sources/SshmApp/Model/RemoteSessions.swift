import Foundation

/// A tmux session shh started on a server that no tab is attached to — the
/// tab was closed, or the app quit, but the agent in it is still running.
struct BackgroundSession: Equatable {
    var server: Server
    /// The tmux session name, `shh-<slug>-<ordinal>-<id4>`.
    var name: String
    var ordinal: Int
    /// The project it belongs to, when that project still exists.
    var projectID: String?
    var created: Date
    var lastActivity: Date
    /// Clients attached right now — another Mac, or a terminal on the box.
    var attachedClients: Int
}

/// Finding and ending shh's tmux sessions on a server, outside any tab.
enum RemoteSessions {
    /// Find tmux the way the session wrapper does (Homebrew's isn't on a bare PATH).
    private static let findTmux = "t=$(command -v tmux 2>/dev/null); "
        + "for c in \(Shell.tmuxPaths); do [ -z \"$t\" ] && [ -x \"$c\" ] && t=$c; done; "

    /// Every `shh-` tmux session on a server. No tmux, or no tmux server
    /// running, is an empty list rather than an error.
    static func list(server: Server, projects: [Project],
                     completion: @escaping (Result<[BackgroundSession], Error>) -> Void) {
        let script = findTmux + "[ -n \"$t\" ] || exit 0; "
            + "\"$t\" list-sessions -F "
            + "'#{session_name}|#{session_created}|#{session_activity}|#{session_attached}' "
            + "2>/dev/null; exit 0"
        run(server: server, script: script) { result in
            completion(result.map { out in
                out.split(separator: "\n").compactMap { parse(String($0), server: server,
                                                             projects: projects) }
            })
        }
    }

    /// Kill one session by exact name. Already gone counts as success.
    static func kill(server: Server, name: String, controlPath: String? = nil,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        let target = Shell.quote("=" + name)
        let script = findTmux + "[ -n \"$t\" ] || exit 0; "
            + "\"$t\" has-session -t \(target) 2>/dev/null || exit 0; "
            + "exec \"$t\" kill-session -t \(target)"
        run(server: server, script: script, controlPath: controlPath) {
            completion($0.map { _ in () })
        }
    }

    private static func parse(_ line: String, server: Server,
                              projects: [Project]) -> BackgroundSession? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, f[0].hasPrefix("shh-") else { return nil }
        let name = f[0]
        // shh-<slug>-<ordinal>-<id4>; the slug itself may contain dashes
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 4, let ordinal = Int(parts[parts.count - 2]) else { return nil }
        let id4 = parts[parts.count - 1]
        let slug = parts[1..<(parts.count - 2)].joined(separator: "-")

        // the id prefix is what identifies the project; the slug only breaks
        // a tie, since a renamed project keeps its id but not its slug
        let candidates = projects.filter { $0.id.prefix(4).lowercased() == id4 }
        let project = candidates.first { Slug.make($0.name) == slug } ?? candidates.first

        func date(_ s: String) -> Date {
            Date(timeIntervalSince1970: TimeInterval(Int(s) ?? 0))
        }
        return BackgroundSession(server: server, name: name, ordinal: ordinal,
                                 projectID: project?.id, created: date(f[1]),
                                 lastActivity: date(f[2]), attachedClients: Int(f[3]) ?? 0)
    }

    /// Rides an open session's socket when there is one, and otherwise opens
    /// one that lingers a minute so the next check is free.
    private static func run(server: Server, script: String, controlPath: String? = nil,
                            completion: @escaping (Result<String, Error>) -> Void) {
        let shared = AppModel.shared.settings.shareConnectionPerServer
        let path = controlPath ?? RemoteExec.controlPath(for: server)
        let args = ["-p", server.port]
            + RemoteExec.options(for: server, controlPath: path,
                                 master: controlPath != nil || shared)
            + [server.target, "sh -c \(Shell.quote(script))"]
        RemoteExec.run(Tools.ssh, args: args, password: server.password, completion: completion)
    }
}
