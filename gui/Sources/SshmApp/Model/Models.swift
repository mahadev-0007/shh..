import AppKit

/// An icon is an emoji character, an SF Symbol name, a drawn brand mark, or a
/// picture the user supplied. All four render at any size.
struct IconRef: Codable, Equatable {
    enum Kind: String, Codable {
        case emoji
        case symbol
        /// A vector mark drawn by BrandMarks; `value` is its id.
        case mark
        /// A file in ~/.config/sshm/icons/; `value` is the filename.
        case image
    }
    var kind: Kind
    var value: String

    static func emoji(_ v: String) -> IconRef { IconRef(kind: .emoji, value: v) }
    static func symbol(_ v: String) -> IconRef { IconRef(kind: .symbol, value: v) }
    static func mark(_ v: String) -> IconRef { IconRef(kind: .mark, value: v) }

    var isEmoji: Bool { kind == .emoji }
    /// True when the image carries its own colour and must not be tinted.
    var isFullColor: Bool { kind == .image || kind == .mark }

    /// Unknown kinds decode as an emoji dot rather than failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        self.kind = Kind(rawValue: raw) ?? .emoji
        self.value = try c.decode(String.self, forKey: .value)
        if Kind(rawValue: raw) == nil { self.value = "•" }
    }

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// nil for emoji — those are drawn as text, since forcing them through
    /// NSImage loses colour and shifts the baseline.
    func image(pointSize: CGFloat, tint: NSColor) -> NSImage? {
        switch kind {
        case .emoji:
            return nil
        case .symbol:
            guard let img = NSImage(systemSymbolName: value, accessibilityDescription: nil)
            else { return nil }
            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            let out = img.withSymbolConfiguration(cfg) ?? img
            out.isTemplate = true
            return out
        case .mark:
            return BrandMarks.image(for: value, side: max(pointSize * 3, 64))
        case .image:
            return IconStore.image(named: value)
        }
    }
}

/// Decoration for a server, keyed by its slug in servers.conf.
struct ServerMeta: Codable, Equatable {
    var displayName: String?
    var icon: IconRef?
}

/// A directory on a server that opens with an agent.
struct Project: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var icon: IconRef?
    /// The server's slug — the join key into servers.conf.
    var server: String
    var path: String
    var agent: String?          // AgentDef.id; nil = the default agent
    var createdAt: Double = Date().timeIntervalSince1970
    var lastOpenedAt: Double = 0
    var order: Int = 0

    init(id: String = UUID().uuidString, name: String, icon: IconRef? = nil,
         server: String, path: String, agent: String? = nil,
         createdAt: Double = Date().timeIntervalSince1970,
         lastOpenedAt: Double = 0, order: Int = 0) {
        self.id = id; self.name = name; self.icon = icon; self.server = server
        self.path = path; self.agent = agent; self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt; self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // a project without an id, a name or a server is not recoverable
        id = lenient(c, .id, UUID().uuidString)
        name = try c.decode(String.self, forKey: .name)
        server = try c.decode(String.self, forKey: .server)
        icon = lenient(c, .icon, nil)
        path = lenient(c, .path, "~")
        agent = lenient(c, .agent, nil)
        createdAt = lenient(c, .createdAt, Date().timeIntervalSince1970)
        lastOpenedAt = lenient(c, .lastOpenedAt, 0)
        order = lenient(c, .order, 0)
    }
}

/// A named command template. Opening a project runs `cd <path>` then this.
struct AgentDef: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var icon: IconRef?
    /// Empty means "just cd there" — the plain-shell case.
    var command: String
    /// The wrapper that provides PATH.
    ///
    /// It is login *and* interactive on purpose. `-lc` alone skips ~/.bashrc and
    /// ~/.zshrc — and those rc files are where nvm, asdf and npm prefixes
    /// actually put these CLIs on the PATH, usually behind a guard that returns
    /// early for non-interactive shells. `-lic` reproduces exactly what you get
    /// by typing the command at a prompt, which is the only sane benchmark.
    var shell: String = AgentDef.defaultShell
    /// Drop to a prompt in the directory when the command exits.
    var keepShell: Bool = true
    var builtin: Bool = false

    init(id: String, name: String, icon: IconRef? = nil, command: String,
         shell: String = AgentDef.defaultShell, keepShell: Bool = true,
         builtin: Bool = false) {
        self.id = id; self.name = name; self.icon = icon; self.command = command
        self.shell = shell; self.keepShell = keepShell; self.builtin = builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = lenient(c, .name, id)
        icon = lenient(c, .icon, nil)
        command = lenient(c, .command, "")
        shell = lenient(c, .shell, AgentDef.defaultShell)
        keepShell = lenient(c, .keepShell, true)
        builtin = lenient(c, .builtin, false)
    }
}

extension AgentDef {
    static let defaultShell = "${SHELL:-/bin/sh} -lic"
    /// What the field used to default to, before -lic. Used to spot agents that
    /// still carry the old value so a migration can update them safely.
    static let legacyShell = "${SHELL:-/bin/sh} -lc"
}

enum SeedAgents {
    // bumped when the seeded set changes, so existing installs pick up the
    // new marks without resurrecting agents the user deleted
    static let version = 4
    static let all: [AgentDef] = [
        AgentDef(id: "claude", name: "Claude Code", icon: .mark("claude"),
                 command: "claude", builtin: true),
        AgentDef(id: "claude-continue", name: "Claude Code (continue)", icon: .mark("claude"),
                 command: "claude --continue", builtin: true),
        AgentDef(id: "codex", name: "Codex", icon: .mark("openai"),
                 command: "codex", builtin: true),
        AgentDef(id: "gemini", name: "Gemini CLI", icon: .mark("gemini"),
                 command: "gemini", builtin: true),
        AgentDef(id: "command", name: "Command Code", icon: .mark("command"),
                 command: "cmd", builtin: true),
        AgentDef(id: "aider", name: "Aider", icon: .mark("aider"),
                 command: "aider", builtin: true),
        AgentDef(id: "opencode", name: "opencode", icon: .mark("opencode"),
                 command: "opencode", builtin: true),
        AgentDef(id: "cursor", name: "Cursor Agent", icon: .mark("cursor"),
                 command: "cursor-agent", builtin: true),
        AgentDef(id: "shell", name: "Shell", icon: .mark("terminal"),
                 command: "", builtin: true),
        AgentDef(id: "tmux", name: "tmux", icon: .mark("tmux"),
                 command: "tmux new -A -s sshm", builtin: true),
        AgentDef(id: "editor", name: "Editor", icon: .mark("editor"),
                 command: "${EDITOR:-vim} .", builtin: true),
    ]
}

/// Reads a key, falling back to `def` when it is absent or the wrong type.
///
/// Swift's synthesized `init(from:)` ignores property defaults entirely: a key
/// added in a later version makes every older file fail to decode. This config
/// gains fields regularly, so every type in it decodes leniently.
private func lenient<T: Decodable, K: CodingKey>(
    _ c: KeyedDecodingContainer<K>, _ key: K, _ def: T) -> T {
    ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def
}

struct AppSettings: Codable, Equatable {
    var defaultAgent: String = "claude"
    var fontSize: Double = 13
    var lastSection: String = "dashboard"
    var shareConnectionPerServer: Bool = true
    var theme: ThemeMode = .dark
    /// Paste or drop an image into a session and it is uploaded to the
    /// server, with the remote path typed in. Never writes the clipboard.
    var pasteImagesToServer: Bool = true
    var automaticUpdates: Bool = true

    /// Keep the agent running on the server inside tmux, so a dropped link can
    /// reattach to it instead of losing the work.
    var durableSessions: Bool = true
    /// Retry automatically when a connection drops.
    var autoReconnect: Bool = true

    var notifyOnBell: Bool = true
    var notifyOnRemote: Bool = true
    var notifyOnDisconnect: Bool = true
    /// Output going quiet after a long run. The one heuristic that misfires,
    /// so it stays off unless asked for.
    var notifyOnIdle: Bool = false
    /// Ring the system alert sound as well as showing a banner.
    var bellSound: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        defaultAgent = lenient(c, .defaultAgent, d.defaultAgent)
        fontSize = lenient(c, .fontSize, d.fontSize)
        lastSection = lenient(c, .lastSection, d.lastSection)
        shareConnectionPerServer = lenient(c, .shareConnectionPerServer,
                                           d.shareConnectionPerServer)
        theme = lenient(c, .theme, d.theme)
        pasteImagesToServer = lenient(c, .pasteImagesToServer, d.pasteImagesToServer)
        automaticUpdates = lenient(c, .automaticUpdates, d.automaticUpdates)
        // every new field needs a line here as well as a stored property —
        // this initialiser replaces the synthesized one, so anything missing
        // silently resets to its default on load
        durableSessions = lenient(c, .durableSessions, d.durableSessions)
        autoReconnect = lenient(c, .autoReconnect, d.autoReconnect)
        notifyOnBell = lenient(c, .notifyOnBell, d.notifyOnBell)
        notifyOnRemote = lenient(c, .notifyOnRemote, d.notifyOnRemote)
        notifyOnDisconnect = lenient(c, .notifyOnDisconnect, d.notifyOnDisconnect)
        notifyOnIdle = lenient(c, .notifyOnIdle, d.notifyOnIdle)
        bellSound = lenient(c, .bellSound, d.bellSound)
    }
}

/// Everything in sshm.json.
struct MetaFile: Codable, Equatable {
    var version: Int = 1
    var seededAgents: Int = 0
    var servers: [String: ServerMeta] = [:]
    var projects: [Project] = []
    var agents: [AgentDef] = []
    var settings: AppSettings = AppSettings()

    init(version: Int = 1, seededAgents: Int = 0, servers: [String: ServerMeta] = [:],
         projects: [Project] = [], agents: [AgentDef] = [],
         settings: AppSettings = AppSettings()) {
        self.version = version
        self.seededAgents = seededAgents
        self.servers = servers
        self.projects = projects
        self.agents = agents
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = lenient(c, .version, 1)
        seededAgents = lenient(c, .seededAgents, 0)
        servers = lenient(c, .servers, [:])
        projects = lenient(c, .projects, [])
        agents = lenient(c, .agents, [])
        settings = lenient(c, .settings, AppSettings())
    }
}

// MARK: - view models

/// A server joined with its decoration. This is what the UI actually renders.
struct ServerVM: Equatable {
    var server: Server
    var meta: ServerMeta?

    var slug: String { server.name }
    var title: String {
        let n = meta?.displayName ?? ""
        return n.isEmpty ? server.name : n
    }
    var icon: IconRef { meta?.icon ?? .emoji(Pastel.emoji[server.hue]) }
    var accent: NSColor { Pastel.color(server.hue) }
    var subtitle: String { server.display }
}

/// A project joined with its server and agent. `server == nil` means the server
/// vanished from servers.conf — an orphan, shown dimmed rather than deleted.
struct ProjectVM: Equatable {
    var project: Project
    var server: ServerVM?
    var agent: AgentDef?

    var id: String { project.id }
    var title: String { project.name }
    var isOrphan: Bool { server == nil }
    var accent: NSColor { server?.accent ?? NSColor(white: 0.5, alpha: 1) }
    var icon: IconRef { project.icon ?? .emoji("📁") }
    var agentName: String { agent?.name ?? "Shell" }
    var subtitle: String {
        guard let s = server else { return "server missing · \(project.server)" }
        return "\(s.title) · \(project.path)"
    }
}

/// What a terminal tab needs in order to open.
struct LaunchSpec {
    var server: Server
    var path: String?
    var agent: AgentDef?
    var title: String
    var subtitle: String
    var icon: IconRef
    var accent: NSColor
    /// Set when this session belongs to a project, so a second click can find it.
    var projectID: String?
}

/// Turn a typed name into a servers.conf key: lowercase, dashes, no pipes.
enum Slug {
    static func make(_ s: String) -> String {
        var out = ""
        var lastDash = true
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "server" : out
    }

    /// `make`, then a numeric suffix until it doesn't collide.
    static func unique(_ s: String, taken: Set<String>, allowing keep: String? = nil) -> String {
        let base = make(s)
        if base == keep || !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}
