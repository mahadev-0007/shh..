import AppKit

/// One record of ~/.config/sshm/servers.conf:  name|host|user|port|auth|secret
/// The format is fixed by the bash TUI and must stay byte-compatible.
struct Server: Equatable {
    var name: String
    var host: String
    var user: String
    var port: String
    var auth: String       // "pass" | "key"
    var secret: String     // base64(password) when auth==pass, else identity path

    var target: String { "\(user)@\(host)" }
    var display: String { port == "22" ? target : "\(target):\(port)" }

    /// The plaintext password, or nil for key auth.
    var password: String? {
        guard auth == "pass", !secret.isEmpty,
              let d = Data(base64Encoded: secret) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Same stable name->hue hash the bash TUI uses, so a server keeps its
    /// identity across both front ends.
    var hue: Int {
        var sum = 0
        for (i, u) in name.unicodeScalars.enumerated() {
            sum += Int(u.value) * (i + 3)
        }
        return ((sum % Palette.count) + Palette.count) % Palette.count
    }

    var color: NSColor { Palette.color(hue) }
}

/// The TUI's twelve vivid hues, in the same order. Used for the terminal wash;
/// `Pastel` is the soft counterpart used by the UI chrome.
enum Palette {
    static let rgb: [(Int, Int, Int)] = [
        (167, 139, 250), (34, 211, 238), (52, 211, 153), (251, 191, 36),
        (251, 113, 133), (56, 189, 248), (163, 230, 53), (232, 121, 249),
        (251, 146, 60), (45, 212, 191), (129, 140, 248), (248, 113, 113),
    ]
    static let names = ["violet", "cyan", "emerald", "amber", "rose", "sky",
                        "lime", "fuchsia", "orange", "teal", "indigo", "red"]
    static var count: Int { rgb.count }

    static func color(_ i: Int) -> NSColor {
        let (r, g, b) = rgb[((i % rgb.count) + rgb.count) % rgb.count]
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// Reads and writes servers.conf. Malformed lines are skipped, not fatal.
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [Server] = []

    private let store: AtomicFile
    private var watcher: FileWatcher?
    /// mtime as of our last read, so a concurrent write by the bash TUI can be
    /// detected instead of silently clobbered.
    private var loadedMtime: Date?

    var file: URL { store.url }

    private init() {
        store = AtomicFile(url: ConfigPaths.dir.appendingPathComponent("servers.conf"))
        ConfigPaths.ensureDir()
        ensureFile()
        load()
        watcher = FileWatcher(url: store.url) { [weak self] in self?.externalChange() }
    }

    private func ensureFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: store.url.path) {
            fm.createFile(atPath: store.url.path,
                          contents: Data(Self.header.utf8),
                          attributes: [.posixPermissions: 0o600])
        } else if let attrs = try? fm.attributesOfItem(atPath: store.url.path),
                  let perms = attrs[.posixPermissions] as? NSNumber,
                  perms.int16Value & 0o077 != 0 {
            // the script tightens loose permissions on sight; so do we
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        }
    }

    private static let header = "# sshm servers - name|host|user|port|auth|secret\n"

    // MARK: - loading

    func load() {
        loadedMtime = mtime()
        guard let data = store.read(), let text = String(data: data, encoding: .utf8) else {
            servers = []; return
        }
        servers = Self.parse(text)
    }

    static func parse(_ text: String) -> [Server] {
        var out: [Server] = []
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(" ") { continue }
            let f = line.components(separatedBy: "|")
            guard f.count >= 3, !f[0].isEmpty, !f[1].isEmpty, !f[2].isEmpty else { continue }
            out.append(Server(
                name: f[0], host: f[1], user: f[2],
                port: f.count > 3 && !f[3].isEmpty ? f[3] : "22",
                auth: f.count > 4 && !f[4].isEmpty ? f[4] : "pass",
                secret: f.count > 5 ? f[5] : ""))
        }
        return out
    }

    private func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: store.url.path))?[.modificationDate] as? Date
    }

    private func externalChange() {
        let data = store.read()
        if store.isOwnWrite(data) { return }
        load()
        NotificationCenter.default.post(name: .sshmModelChanged, object: self)
    }

    // MARK: - saving

    private func serialize(_ list: [Server]) -> String {
        var text = Self.header
        for s in list {
            text += "\(s.name)|\(s.host)|\(s.user)|\(s.port)|\(s.auth)|\(s.secret)\n"
        }
        return text
    }

    /// Applies one mutation to the in-memory list and writes it out. If the file
    /// changed underneath us (the bash TUI added a server), reload first and
    /// re-apply, so the other writer's edit survives.
    private func commit(_ mutate: (inout [Server]) -> Void) {
        if let m = mtime(), let l = loadedMtime, m != l { load() }
        var list = servers
        mutate(&list)
        servers = list
        store.write(Data(serialize(list).utf8))
        loadedMtime = mtime()
        NotificationCenter.default.post(name: .sshmModelChanged, object: self)
    }

    func add(_ s: Server) { commit { $0.append(s) } }

    func update(_ s: Server, slug: String) {
        commit { list in
            if let i = list.firstIndex(where: { $0.name == slug }) { list[i] = s }
            else { list.append(s) }
        }
    }

    func remove(slug: String) {
        commit { $0.removeAll { $0.name == slug } }
    }

    func server(slug: String) -> Server? { servers.first { $0.name == slug } }

    var slugs: Set<String> { Set(servers.map(\.name)) }
}
