import AppKit
import Network

/// "Allow remote sessions": letting one specific person ssh into this Mac
/// over Tailscale with an invite you send them.
///
/// The host makes an invite, which carries a one-time token. The guest's shh
/// redeems it by POSTing the token and a fresh public key to a tiny listener
/// bound only to this Mac's tailnet address. Tailscale itself says who is
/// calling (`tailscale whois`), the host clicks Allow, and the key goes into
/// authorized_keys locked to the guest's tailnet addresses. From then on it is
/// plain ssh to macOS Remote Login.
///
/// Turning it off removes every key it added.
final class RemoteAccess {
    static let shared = RemoteAccess()
    static let defaultPort: UInt16 = 7022
    static let inviteLifetime: TimeInterval = 15 * 60

    struct Invite: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        var tokenHash: String
        var created: Double
        var expires: Double
        var isExpired: Bool { Date().timeIntervalSince1970 > expires }
    }

    struct Guest: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        var login: String
        var displayName: String
        var node: String
        var addresses: [String]
        var keyFingerprint: String
        var inviteHash: String
        var added: Double
    }

    struct File: Codable, Equatable {
        var enabled = false
        var invites: [Invite] = []
        var guests: [Guest] = []
    }

    enum Status: Equatable {
        case off
        case starting
        case listening(Tailscale.SelfNode)
        case problem(String)
    }

    private(set) var file = File()
    private(set) var status: Status = .off
    /// nil until checked.
    private(set) var remoteLoginOn: Bool?

    private let store = AtomicFile(url: ConfigPaths.dir.appendingPathComponent("sharing.json"))
    private var server: MiniHTTP.Server?
    private var retry: Timer?
    private var sweep: Timer?
    private var failures: [String: (count: Int, since: Date)] = [:]

    var port: UInt16 {
        UInt16(Env.string("SSHM_SHARE_PORT", "")) ?? Self.defaultPort
    }

    /// Bind somewhere other than the tailnet address and skip whois — only for
    /// exercising this code on a machine without Tailscale.
    private var testBind: String? {
        let v = Env.string("SSHM_SHARE_TEST_BIND", "")
        return v.isEmpty ? nil : v
    }

    private init() {
        ConfigPaths.ensureDir()
        if let d = store.read(), let f = try? JSONDecoder().decode(File.self, from: d) {
            file = f
        }
        reconcile()
    }

    // MARK: - lifecycle

    /// Called at launch: pick up where we left off.
    func resume() {
        if file.enabled { start() }
        checkRemoteLogin()
    }

    func setEnabled(_ on: Bool) {
        if on {
            mutate { $0.enabled = true }
            start()
        } else {
            revokeAll()
            mutate { f in f.enabled = false; f.invites = [] }
            stop()
        }
        checkRemoteLogin()
    }

    private func start() {
        stop()
        status = .starting
        changed()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let node: Result<Tailscale.SelfNode, Error>
            if let bind = self.testBind {
                node = .success(Tailscale.SelfNode(hostName: "test", dnsName: "", ipv4: bind))
            } else {
                node = Result { try Tailscale.selfNode() }
            }
            DispatchQueue.main.async { self.bind(node) }
        }
    }

    private func bind(_ node: Result<Tailscale.SelfNode, Error>) {
        guard file.enabled else { return }
        switch node {
        case .failure(let e):
            fail(e.localizedDescription)
        case .success(let me):
            do {
                let s = try MiniHTTP.Server(host: me.ipv4, port: port) { [weak self] req, reply in
                    DispatchQueue.main.async { self?.handle(req, reply: reply) }
                }
                server = s
                s.start { [weak self] state in
                    guard let self, self.server === s else { return }
                    switch state {
                    case .ready:
                        self.status = .listening(me)
                        self.changed()
                    case .failed(let e):
                        self.server = nil
                        self.fail("Couldn't listen on \(me.ipv4):\(self.port) — \(e.localizedDescription)")
                    default: break
                    }
                }
                sweep?.invalidate()
                sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    self?.dropExpiredInvites()
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Stay enabled and keep trying: Tailscale may simply not be up yet.
    private func fail(_ message: String) {
        server?.stop(); server = nil
        status = .problem(message)
        changed()
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.file.enabled else { return }
            self.start()
        }
    }

    private func stop() {
        retry?.invalidate(); retry = nil
        sweep?.invalidate(); sweep = nil
        server?.stop(); server = nil
        status = .off
        changed()
    }

    func checkRemoteLogin() {
        MiniHTTP.probe(host: "127.0.0.1", port: 22) { [weak self] on in
            guard let self, self.remoteLoginOn != on else { return }
            self.remoteLoginOn = on
            self.changed()
        }
    }

    static func openRemoteLoginSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - invites

    enum InviteError: LocalizedError {
        case notListening, noHostKey
        var errorDescription: String? {
            switch self {
            case .notListening:
                return "Remote sessions aren't ready yet. Check the status above."
            case .noHostKey:
                return "This Mac has no ssh host key yet. Turn on Remote Login first."
            }
        }
    }

    func createInvite(label: String) throws -> InviteCode {
        guard case .listening(let me) = status else { throw InviteError.notListening }
        guard let key = SSHKeys.hostKeys().first,
              let fp = SSHKeys.fingerprint(ofPublicKey: key) else { throw InviteError.noHostKey }
        let token = SSHKeys.randomToken()
        let now = Date().timeIntervalSince1970
        let invite = Invite(id: SSHKeys.randomToken(bytes: 6),
                            label: label.isEmpty ? "Invite" : label,
                            tokenHash: SSHKeys.hash(token),
                            created: now, expires: now + Self.inviteLifetime)
        mutate { $0.invites.append(invite) }
        return InviteCode(address: me.ipv4, dnsName: me.dnsName, user: NSUserName(),
                          invitePort: port, fingerprint: fp, token: token,
                          hostLabel: Host.current().localizedName ?? me.hostName)
    }

    func cancelInvite(id: String) {
        mutate { $0.invites.removeAll { $0.id == id } }
    }

    private func dropExpiredInvites() {
        guard file.invites.contains(where: \.isExpired) else { return }
        mutate { $0.invites.removeAll(where: \.isExpired) }
    }

    // MARK: - guests

    func revoke(guestID: String) {
        try? SSHKeys.removeAuthorized(guestIDs: [guestID])
        endSessions(of: [guestID])
        mutate { $0.guests.removeAll { $0.id == guestID } }
    }

    private func revokeAll() {
        let ids = Set(file.guests.map(\.id)).union(SSHKeys.authorizedGuestIDs())
        try? SSHKeys.removeAuthorized(guestIDs: ids)
        endSessions(of: Array(ids))
        mutate { $0.guests = [] }
    }

    /// Revoking access should also end what they already have open, not just
    /// stop the next login. The per-session sshd child runs as us, so we may
    /// signal it; it is found by the guest's tailnet address on its socket.
    private func endSessions(of ids: [String]) {
        let addrs = file.guests.filter { ids.contains($0.id) }.flatMap(\.addresses)
        guard !addrs.isEmpty else { return }
        DispatchQueue.global().async {
            // `sshd: user@ttys003` processes carry no address, but their
            // network sockets do; lsof maps one to the other.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-a", "-u", NSUserName(), "-c", "sshd", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pn"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let text = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            p.waitUntilExit()
            var pid: Int32?
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid,
                        let remote = line.components(separatedBy: "->").last {
                    let host = remote.hasPrefix("[")
                        ? String(remote.dropFirst().prefix { $0 != "]" })
                        : String(remote.prefix { $0 != ":" })
                    if addrs.contains(host) { kill(pid, SIGTERM) }
                }
            }
        }
    }

    /// authorized_keys is the source of truth for who can actually get in. A
    /// guest whose line was removed by hand is gone; a tagged line with no
    /// guest behind it is left alone here but removed when sharing turns off.
    private func reconcile() {
        let present = SSHKeys.authorizedGuestIDs()
        let live = file.guests.filter { present.contains($0.id) }
        if live.count != file.guests.count { mutate { $0.guests = live } }
        if file.invites.contains(where: \.isExpired) {
            mutate { $0.invites.removeAll(where: \.isExpired) }
        }
    }

    // MARK: - the join request

    private func handle(_ req: MiniHTTP.Request, reply: @escaping MiniHTTP.Server.Reply) {
        let none: (Bool) -> Void = { _ in }
        guard req.method == "POST", req.path == "/shh/join" else {
            reply(.error(404, "Not found."), none); return
        }
        guard let ip = req.remoteIP, testBind != nil || Self.isTailnet(ip) else {
            reply(.error(403, "Only reachable over Tailscale."), none); return
        }
        if let f = failures[ip], f.count >= 5, Date().timeIntervalSince(f.since) < 600 {
            reply(.error(429, "Too many bad invites from this device. Try again later."), none)
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let token = obj["token"] as? String,
              let rawKey = obj["publicKey"] as? String,
              let key = SSHKeys.normalizePublicKey(rawKey)
        else { reply(.error(400, "Malformed request."), none); return }
        let deviceName = (obj["name"] as? String).map { String($0.prefix(80)) } ?? ""

        dropExpiredInvites()
        let hash = SSHKeys.hash(token)
        guard let invite = file.invites.first(where: { $0.tokenHash == hash }) else {
            noteFailure(ip)
            if let g = file.guests.first(where: { $0.inviteHash == hash }) {
                Notifier.shared.notifySharing(
                    title: "An invite was used twice",
                    body: "Someone at \(ip) tried the invite already used by \(g.displayName). "
                        + "They were turned away.")
            }
            reply(.error(403, "This invite has expired or was already used. "
                            + "Ask for a new one."), none)
            return
        }
        // Burn it now, before anyone is asked anything: two people racing the
        // same link must not both reach the Allow prompt.
        mutate { $0.invites.removeAll { $0.id == invite.id } }

        identify(ip) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                reply(.error(403, "This Mac couldn't confirm who you are on Tailscale: "
                                + e.localizedDescription), none)
            case .success(let peer):
                self.approve(invite: invite, peer: peer, device: deviceName, key: key,
                             hash: hash, reply: reply)
            }
        }
    }

    private func identify(_ ip: String, completion: @escaping (Result<Tailscale.Peer, Error>) -> Void) {
        if testBind != nil {
            completion(.success(Tailscale.Peer(login: "test@local", displayName: "Test guest",
                                               node: "loopback", addresses: [ip])))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try Tailscale.whois(ip) }
            DispatchQueue.main.async { completion(r) }
        }
    }

    private func approve(invite: Invite, peer: Tailscale.Peer, device: String, key: String,
                         hash: String, reply: @escaping MiniHTTP.Server.Reply) {
        let none: (Bool) -> Void = { _ in }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)

        let a = NSAlert()
        a.messageText = "\(peer.displayName) wants to use your invite"
        a.informativeText =
            "Invite: \(invite.label)\n"
          + "Tailscale account: \(peer.login)\n"
          + "Device: \(peer.node.isEmpty ? device : peer.node)\n\n"
          + "If you allow this, they can sign in to this Mac as \(NSUserName()) over ssh "
          + "until you revoke access or turn off remote sessions."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Deny")
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else {
            reply(.error(403, "The owner of that Mac declined."), none)
            return
        }
        guard file.enabled else {
            reply(.error(403, "Remote sessions were turned off."), none); return
        }

        let guest = Guest(id: SSHKeys.randomToken(bytes: 6),
                          label: invite.label, login: peer.login,
                          displayName: peer.displayName,
                          node: peer.node.isEmpty ? device : peer.node,
                          addresses: peer.addresses,
                          keyFingerprint: SSHKeys.fingerprint(ofPublicKey: key) ?? "",
                          inviteHash: hash, added: Date().timeIntervalSince1970)
        do {
            try SSHKeys.addAuthorized(SSHKeys.authorizedLine(key: key, from: guest.addresses,
                                                             guestID: guest.id))
        } catch {
            reply(.error(500, "This Mac couldn't update its authorized_keys."), none)
            return
        }
        mutate { $0.guests.append(guest) }

        var me: Tailscale.SelfNode?
        if case .listening(let n) = status { me = n }
        let body: [String: Any] = [
            "user": NSUserName(),
            "host": me?.dnsName ?? "",
            "address": me?.ipv4 ?? "",
            "sshPort": 22,
            "hostKeys": SSHKeys.hostKeys(),
            "name": Host.current().localizedName ?? "",
        ]
        reply(MiniHTTP.Response(status: 200, json: body)) { [weak self] delivered in
            // they gave up waiting before Allow was clicked: they never got the
            // server details, so the key we just added would be a dangling door
            guard !delivered else { return }
            DispatchQueue.main.async { self?.revoke(guestID: guest.id) }
        }
    }

    private func noteFailure(_ ip: String) {
        var f = failures[ip] ?? (0, Date())
        if Date().timeIntervalSince(f.since) > 600 { f = (0, Date()) }
        f.count += 1
        failures[ip] = f
    }

    /// 100.64.0.0/10, the CGNAT range Tailscale hands out, or its v6 ULA.
    static func isTailnet(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let o = ip.split(separator: ".").compactMap { Int($0) }
        return o.count == 4 && o[0] == 100 && (64...127).contains(o[1])
    }

    // MARK: - persistence

    private func mutate(_ body: (inout File) -> Void) {
        var f = file
        body(&f)
        guard f != file else { return }
        file = f
        if let d = try? JSONEncoder().encode(f) { store.write(d) }
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: .sshmSharingChanged, object: self)
    }
}

extension Notification.Name {
    static let sshmSharingChanged = Notification.Name("sshm.sharingChanged")
}
