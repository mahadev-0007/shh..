import Foundation
import CryptoKit

/// The invite a host sends to one person, written as a shh:// link.
///
///     shh://join?v=1&a=100.101.102.103&h=bobs-mbp.tail1234.ts.net&u=bob
///         &p=7022&fp=<host key sha256, base64url>&t=<token>&n=Bob's MacBook
///
/// Everything in it is an address except the token, which works once and
/// expires; the host key fingerprint lets the guest refuse an impostor.
struct InviteCode: Equatable {
    static let scheme = "shh"

    var address: String          // host's tailnet IPv4
    var dnsName: String          // MagicDNS name, may be empty
    var user: String
    var invitePort: UInt16
    var fingerprint: String      // "SHA256:…" as ssh-keygen prints it
    var token: String
    var hostLabel: String

    var string: String {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "join"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "a", value: address),
            URLQueryItem(name: "h", value: dnsName),
            URLQueryItem(name: "u", value: user),
            URLQueryItem(name: "p", value: String(invitePort)),
            URLQueryItem(name: "fp", value: Self.toURLSafe(fingerprint)),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "n", value: hostLabel),
        ]
        return c.string ?? ""
    }

    /// Accepts the link as pasted, including the stray whitespace, quotes or
    /// angle brackets chat apps like to wrap around it.
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "<>\"'`")))
        guard let c = URLComponents(string: trimmed), c.scheme == Self.scheme,
              c.host == "join" else { return nil }
        var q: [String: String] = [:]
        for i in c.queryItems ?? [] { q[i.name] = i.value ?? "" }
        guard let a = q["a"], !a.isEmpty, let u = q["u"], !u.isEmpty,
              let t = q["t"], !t.isEmpty, let fp = q["fp"], !fp.isEmpty,
              Self.isPlain(a), Self.isPlain(u), Self.isPlain(q["h"] ?? "")
        else { return nil }
        address = a
        dnsName = q["h"] ?? ""
        user = u
        invitePort = UInt16(q["p"] ?? "") ?? RemoteAccess.defaultPort
        fingerprint = Self.fromURLSafe(fp)
        token = t
        hostLabel = (q["n"] ?? "").isEmpty ? (dnsName.isEmpty ? a : dnsName) : q["n"]!
    }

    init(address: String, dnsName: String, user: String, invitePort: UInt16,
         fingerprint: String, token: String, hostLabel: String) {
        self.address = address; self.dnsName = dnsName; self.user = user
        self.invitePort = invitePort; self.fingerprint = fingerprint
        self.token = token; self.hostLabel = hostLabel
    }

    /// Hosts and user names end up in servers.conf and on an ssh command line,
    /// so anything beyond the characters they really use is refused.
    private static func isPlain(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.:@".unicodeScalars.contains($0)
        }
    }

    // "+" and "/" in a fingerprint get mangled by some chat apps' link parsing
    private static func toURLSafe(_ fp: String) -> String {
        fp.replacingOccurrences(of: "SHA256:", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
    private static func fromURLSafe(_ s: String) -> String {
        "SHA256:" + s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
    }
}

/// Key, fingerprint and authorized_keys plumbing.
enum SSHKeys {
    /// Where ~/.ssh is. Overridable so the sharing code can be exercised
    /// without touching the real authorized_keys.
    static var sshDir: URL {
        if let d = ProcessInfo.processInfo.environment["SSHM_SSH_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }
    static var authorizedKeys: URL { sshDir.appendingPathComponent("authorized_keys") }
    static var knownHosts: URL { sshDir.appendingPathComponent("known_hosts") }
    static var guestKeyDir: URL { ConfigPaths.dir.appendingPathComponent("keys") }

    static let allowedTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521", "ssh-rsa", "sk-ssh-ed25519@openssh.com",
    ]

    /// "type base64" from a public key line, with any comment or options
    /// dropped. nil unless it is exactly one well-formed key.
    static func normalizePublicKey(_ line: String) -> String? {
        guard Shell.isSafe(line), !line.contains("\"") else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, allowedTypes.contains(String(parts[0])),
              let blob = Data(base64Encoded: String(parts[1])), blob.count >= 32
        else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// SHA256 fingerprint in ssh-keygen's format.
    static func fingerprint(ofPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// This Mac's sshd host keys, best first ("type base64").
    static func hostKeys() -> [String] {
        let order = ["ed25519", "ecdsa", "rsa"]
        return order.compactMap { kind in
            let path = "/etc/ssh/ssh_host_\(kind)_key.pub"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return normalizePublicKey(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func randomToken(bytes n: Int = 18) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
    }

    // MARK: - authorized_keys

    /// The tag that marks a line as ours. Revoking deletes exactly the lines
    /// carrying a guest's tag and never touches anything else in the file.
    static func tag(for guestID: String) -> String { "shh-guest:\(guestID)" }

    /// Locked to the guest's own tailnet addresses. No forwarding of any kind:
    /// a shell and an agent are what is being shared, not this Mac's network.
    static func authorizedLine(key: String, from addresses: [String], guestID: String) -> String {
        let from = addresses.filter { Shell.isSafe($0) && !$0.contains("\"") && !$0.contains(",") }
        return "from=\"\(from.joined(separator: ","))\","
            + "no-port-forwarding,no-agent-forwarding,no-X11-forwarding "
            + "\(key) \(tag(for: guestID))"
    }

    private static func ensureSSHDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshDir.path) {
            try fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
    }

    /// The real file behind authorized_keys, so a symlinked one (dotfile
    /// managers do this) is edited in place rather than replaced by a copy.
    private static func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    static func addAuthorized(_ line: String) throws {
        try ensureSSHDir()
        let url = resolved(authorizedKeys)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += line + "\n"
        guard AtomicFile(url: url).write(Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func removeAuthorized(guestIDs: Set<String>) throws {
        guard !guestIDs.isEmpty else { return }
        let url = resolved(authorizedKeys)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tags = Set(guestIDs.map(tag(for:)))
        let lines = text.components(separatedBy: "\n")
        let kept = lines.filter { line in
            let last = line.split(separator: " ").last.map(String.init) ?? ""
            return !tags.contains(last)
        }
        guard kept.count != lines.count else { return }
        guard AtomicFile(url: url).write(Data(kept.joined(separator: "\n").utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Every shh guest tag currently present in authorized_keys.
    static func authorizedGuestIDs() -> Set<String> {
        guard let text = try? String(contentsOf: resolved(authorizedKeys), encoding: .utf8)
        else { return [] }
        var ids = Set<String>()
        for line in text.components(separatedBy: "\n") {
            if let last = line.split(separator: " ").last, last.hasPrefix("shh-guest:") {
                ids.insert(String(last.dropFirst("shh-guest:".count)))
            }
        }
        return ids
    }

    // MARK: - guest side

    /// A fresh ed25519 key for one host. Returns (private key path, public line).
    static func generateGuestKey(name: String) throws -> (String, String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: guestKeyDir.path) {
            try fm.createDirectory(at: guestKeyDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        var path = guestKeyDir.appendingPathComponent(name).path
        var n = 2
        while fm.fileExists(atPath: path) {
            path = guestKeyDir.appendingPathComponent("\(name)-\(n)").path; n += 1
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Tools.which("ssh-keygen") ?? "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "shh guest", "-f", path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let pub = try? String(contentsOfFile: path + ".pub", encoding: .utf8),
              let line = normalizePublicKey(pub.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw CocoaError(.fileWriteUnknown) }
        return (path, line)
    }

    /// Trust these host keys for these names, as if the user had said "yes"
    /// to ssh's prompt — except the keys were checked against the invite.
    static func addKnownHosts(names: [String], keys: [String]) throws {
        try ensureSSHDir()
        let url = resolved(knownHosts)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let hostField = names.filter { !$0.isEmpty }.joined(separator: ",")
        guard !hostField.isEmpty else { return }
        var added = false
        for k in keys {
            let line = "\(hostField) \(k)"
            if text.contains(line) { continue }
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += line + "\n"
            added = true
        }
        guard added else { return }
        guard AtomicFile(url: url).write(Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
