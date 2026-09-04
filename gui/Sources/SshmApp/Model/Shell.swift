import Foundation

enum Env {
    static func string(_ key: String, _ fallback: String) -> String {
        let v = ProcessInfo.processInfo.environment[key] ?? ""
        return v.isEmpty ? fallback : v
    }
    /// Most servers have no terminfo entry for xterm-ghostty and friends.
    static var remoteTerm: String { string("SSHM_TERM", "xterm-256color") }
}

enum Tools {
    static let ssh = which("ssh") ?? "/usr/bin/ssh"
    static let sshpass = which("sshpass")

    static func which(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for d in dirs where !d.isEmpty {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

enum Shell {
    /// Single-quote for sh. Applied recursively, so a quoted script can be
    /// safely embedded inside another quoted script.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path may not survive quoting if it starts with ~ — the shell expands the
    /// tilde before quoting would apply, so splice $HOME in explicitly.
    static func quotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") {
            return "\"$HOME\"/" + quote(String(path.dropFirst(2)))
        }
        return quote(path)
    }

    /// Anything with a NUL or newline can't round-trip through an argv element
    /// safely, and a newline in a command is almost certainly a paste accident.
    static func isSafe(_ s: String) -> Bool {
        !s.contains("\0") && !s.contains("\n") && !s.contains("\r")
    }

    /// A human-readable version of what a project will run. The real script is
    /// fully quoted and carries a PATH-check hint, which is right to send but
    /// unreadable on screen.
    static func preview(target: String, path: String?, agent: AgentDef?) -> String {
        var inner: [String] = []
        if let p = path, !p.isEmpty { inner.append("cd \(p)") }
        let command = (agent?.command ?? "").trimmingCharacters(in: .whitespaces)
        if !command.isEmpty { inner.append(command) }
        if agent?.keepShell ?? true { inner.append("exec $SHELL -l") }
        let wrapper = agent?.shell ?? AgentDef.defaultShell
        return "ssh -t \(target)\n  \(wrapper) '\(inner.joined(separator: "; "))'"
    }

    /// The single remote-command argv element handed to `ssh -t`.
    ///
    /// ssh joins everything after the target with spaces and feeds the result to
    /// the remote login shell, so one pre-quoted element is the only way to keep
    /// a script intact. The command runs under a *login* shell because `claude`,
    /// `codex` and friends are usually nvm/asdf-managed and are not on the
    /// default non-interactive PATH.
    static func remoteScript(path: String?, agent: AgentDef?) -> String? {
        var inner: [String] = []

        if let p = path, !p.isEmpty {
            guard isSafe(p) else { return nil }
            // a failed cd must not silently run the agent in $HOME
            inner.append("cd -- \(quotePath(p)) || exit 1")
        }

        let command = (agent?.command ?? "").trimmingCharacters(in: .whitespaces)
        if !command.isEmpty {
            guard isSafe(command) else { return nil }
            // If the binary isn't on this shell's PATH, say why before the shell
            // says "command not found" — that message alone sends people hunting
            // in the wrong place.
            if let exe = command.split(separator: " ").first.map(String.init),
               !exe.hasPrefix("$"), !exe.contains("=") {
                let hint = "\(exe) isn't on the PATH of this shell. "
                    + "Settings > Agents > Shell controls how it's launched "
                    + "(try adding -i, or give the full path)."
                inner.append("command -v \(quote(exe)) >/dev/null 2>&1 || "
                           + "printf '\\033[33m%s\\033[0m\\n' \(quote(hint))")
            }
            // exec so the agent owns the pty directly and signals reach it
            inner.append((agent?.keepShell ?? true) ? command : "exec \(command)")
        }

        if agent?.keepShell ?? true {
            // drop to a prompt in the project directory when the agent exits,
            // instead of the tab dying
            inner.append("exec \(Env.string("SSHM_REMOTE_SHELL", "${SHELL:-/bin/sh}")) -l")
        }

        guard !inner.isEmpty else { return nil }
        let script = inner.joined(separator: "\n")
        let wrapper = agent?.shell ?? AgentDef.defaultShell
        guard isSafe(wrapper) else { return nil }
        return "exec \(wrapper) \(quote(script))"
    }
}
