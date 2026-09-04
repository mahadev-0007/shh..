import Foundation

extension Notification.Name {
    static let sshmModelChanged = Notification.Name("sshm.modelChanged")
}

/// Owns ~/.config/sshm/sshm.json — display names, icons, projects, agents and
/// settings. Nothing secret ever goes in here; passwords stay in servers.conf.
final class MetaStore {
    static let shared = MetaStore()

    private(set) var file = MetaFile()
    /// Set when the file on disk is a version we don't understand. We then read
    /// it but never write, so a newer build's data is not destroyed.
    private(set) var readOnly = false
    private(set) var loadError: String?

    private let store: AtomicFile
    private var watcher: FileWatcher?
    private var saveWork: DispatchWorkItem?
    private var needsMigrationSave = false

    var url: URL { store.url }

    private init() {
        store = AtomicFile(url: ConfigPaths.dir.appendingPathComponent("sshm.json"))
        ConfigPaths.ensureDir()
        load()
        if !FileManager.default.fileExists(atPath: store.url.path) {
            seedAndSave()
        } else if needsMigrationSave {
            needsMigrationSave = false
            saveNow()
        }
        watcher = FileWatcher(url: store.url) { [weak self] in self?.externalChange() }
    }

    // MARK: - loading

    func load() {
        guard let data = store.read() else {
            file = MetaFile(); return
        }
        do {
            let original = try JSONDecoder().decode(MetaFile.self, from: data)
            readOnly = original.version > MetaFile().version
            let decoded = readOnly ? original : migrate(original)
            file = decoded
            loadError = nil
            // a migration that only lives in memory would re-run on every launch
            // and never reach the file, so write it back once
            if decoded != original { needsMigrationSave = true }
        } catch {
            // A file we cannot parse is never overwritten. The old behaviour —
            // reset to seeds, then save — turned one decoding bug into silent,
            // permanent loss of every project the user had. Go read-only and
            // say so instead; the file stays on disk exactly as it is.
            loadError = "\(error)"
            readOnly = true
            file = MetaFile(seededAgents: SeedAgents.version, agents: SeedAgents.all)
            NSLog("sshm: could not read %@ — refusing to overwrite it. %@",
                  store.url.path, "\(error)")
        }
    }

    private func migrate(_ f: MetaFile) -> MetaFile {
        var f = f
        if f.seededAgents < SeedAgents.version {
            // add builtins the user has never seen, without resurrecting ones
            // they deliberately deleted
            let known = Set(f.agents.map(\.id))
            f.agents += SeedAgents.all.filter { !known.contains($0.id) }

            // v2 replaced the builtins' placeholder emoji with drawn marks;
            // adopt those, but never overwrite an icon the user chose
            if f.seededAgents < 2 {
                for (i, a) in f.agents.enumerated() where a.builtin {
                    guard let seed = SeedAgents.all.first(where: { $0.id == a.id }),
                          a.icon?.kind == .emoji else { continue }
                    f.agents[i].icon = seed.icon
                }
            }
            // v4 moved the builtins from a login shell to a login+interactive
            // one, because -lc misses the rc file that puts nvm/asdf CLIs on the
            // PATH. Only touch agents still carrying the old default.
            if f.seededAgents < 4 {
                for (i, a) in f.agents.enumerated()
                where a.builtin && a.shell == AgentDef.legacyShell {
                    f.agents[i].shell = AgentDef.defaultShell
                }
            }
            f.seededAgents = SeedAgents.version
        }
        return f
    }

    private func seedAndSave() {
        file = MetaFile(version: 1, seededAgents: SeedAgents.version,
                        servers: [:], projects: [], agents: SeedAgents.all,
                        settings: AppSettings())
        saveNow()
    }

    private func externalChange() {
        let data = store.read()
        if store.isOwnWrite(data) { return }   // our own save came back around
        load()
        NotificationCenter.default.post(name: .sshmModelChanged, object: self)
    }

    // MARK: - saving

    /// Coalesced: typing in a form or dragging cards would otherwise write on
    /// every keystroke.
    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        NotificationCenter.default.post(name: .sshmModelChanged, object: self)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        // readOnly covers both a newer file format and a file we failed to
        // parse; in either case writing would destroy someone's data.
        guard !readOnly, loadError == nil else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return }
        store.write(data)
    }

    // MARK: - mutation

    func mutate(_ body: (inout MetaFile) -> Void) {
        body(&file)
        save()
    }
}

enum ConfigPaths {
    static var dir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
        return base.appendingPathComponent("sshm")
    }

    static func ensureDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }
}
