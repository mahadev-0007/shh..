import Foundation

/// What a server can do, discovered once and remembered for the session.
///
/// Durable sessions need tmux on the far side. Rather than assume it, probe on
/// first connect over the control socket that is already open, and fall back to
/// a plain session when it isn't there.
enum ServerCapabilities {
    private static var tmux: [String: Bool] = [:]
    private static var probing: Set<String> = []

    /// nil while unknown — callers should treat unknown as "probably yes" and
    /// let the remote script degrade gracefully, rather than block on a probe.
    static func hasTmux(_ server: Server) -> Bool? {
        tmux[key(server)]
    }

    static func probe(_ server: Server, controlPath: String) {
        let k = key(server)
        guard tmux[k] == nil, !probing.contains(k) else { return }
        probing.insert(k)

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: Tools.ssh)
            // ride the session's existing master: no second handshake
            p.arguments = ["-S", controlPath, "-o", "BatchMode=yes",
                           server.target, "command -v tmux >/dev/null && echo yes || echo no"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var found = false
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                found = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
            }
            DispatchQueue.main.async {
                probing.remove(k)
                // a failed probe proves nothing about tmux, only about the
                // socket, so don't cache a negative in that case
                if found { tmux[k] = true }
                else if p.terminationStatus == 0 { tmux[k] = false }
            }
        }
    }

    private static func key(_ s: Server) -> String { "\(s.target):\(s.port)" }
}
