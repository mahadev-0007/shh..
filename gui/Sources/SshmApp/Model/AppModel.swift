import AppKit

/// The only thing the UI talks to. Joins servers.conf with sshm.json and
/// coalesces both stores' change notifications into one.
final class AppModel {
    static let shared = AppModel()

    private let servers = ServerStore.shared
    private let meta = MetaStore.shared
    private var pendingNotify = false

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .sshmModelChanged, object: nil)
    }

    @objc private func storeChanged() {
        // both stores can fire for one logical edit; collapse to one UI rebuild
        guard !pendingNotify else { return }
        pendingNotify = true
        DispatchQueue.main.async { [weak self] in
            self?.pendingNotify = false
            NotificationCenter.default.post(name: .sshmDidChange, object: nil)
        }
    }

    // MARK: - reading

    var serverList: [ServerVM] {
        servers.servers.map { ServerVM(server: $0, meta: meta.file.servers[$0.name]) }
    }

    func serverVM(slug: String) -> ServerVM? {
        guard let s = servers.server(slug: slug) else { return nil }
        return ServerVM(server: s, meta: meta.file.servers[slug])
    }

    var agents: [AgentDef] { meta.file.agents }

    func agent(id: String?) -> AgentDef? {
        guard let id else { return nil }
        return meta.file.agents.first { $0.id == id }
    }

    var defaultAgent: AgentDef? {
        agent(id: meta.file.settings.defaultAgent) ?? meta.file.agents.first
    }

    var projectList: [ProjectVM] {
        meta.file.projects
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
            .map { p in
                ProjectVM(project: p,
                          server: serverVM(slug: p.server),
                          agent: agent(id: p.agent) ?? defaultAgent)
            }
    }

    func projectVM(id: String) -> ProjectVM? { projectList.first { $0.id == id } }

    var recentProjects: [ProjectVM] {
        projectList.filter { $0.project.lastOpenedAt > 0 }
            .sorted { $0.project.lastOpenedAt > $1.project.lastOpenedAt }
    }

    func projects(onServer slug: String) -> [ProjectVM] {
        projectList.filter { $0.project.server == slug }
    }

    var settings: AppSettings { meta.file.settings }

    var orphanCount: Int { projectList.filter(\.isOrphan).count }

    // MARK: - settings

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        meta.mutate { body(&$0.settings) }
    }

    // MARK: - servers

    /// Add or update. Returns the slug actually used.
    @discardableResult
    func saveServer(existing: String?, displayName: String, slug requested: String?,
                    host: String, user: String, port: String,
                    auth: String, secret: String, icon: IconRef?) -> String {
        let taken = servers.slugs
        let wanted = (requested?.isEmpty == false) ? requested! : displayName
        let slug = Slug.unique(wanted, taken: taken, allowing: existing)

        let record = Server(name: slug, host: host, user: user,
                            port: port.isEmpty ? "22" : port,
                            auth: auth, secret: secret)

        if let old = existing, old != slug {
            renameServer(from: old, to: slug, record: record)
        } else if existing != nil {
            servers.update(record, slug: slug)
        } else {
            servers.add(record)
        }

        meta.mutate { f in
            var m = f.servers[slug] ?? ServerMeta()
            m.displayName = displayName
            if let icon { m.icon = icon }
            f.servers[slug] = m
        }
        return slug
    }

    /// One transaction: json first, then conf. If we die in between, projects
    /// point at a name that still exists — recoverable. The other order loses
    /// the mapping entirely.
    private func renameServer(from old: String, to new: String, record: Server) {
        meta.mutate { f in
            if let m = f.servers.removeValue(forKey: old) { f.servers[new] = m }
            for i in f.projects.indices where f.projects[i].server == old {
                f.projects[i].server = new
            }
        }
        meta.saveNow()
        servers.remove(slug: old)
        servers.add(record)
    }

    enum ServerDeletion { case withProjects, keepProjects }

    func deleteServer(slug: String, mode: ServerDeletion) {
        meta.mutate { f in
            f.servers.removeValue(forKey: slug)
            if mode == .withProjects {
                f.projects.removeAll { $0.server == slug }
            }
        }
        servers.remove(slug: slug)
    }

    // MARK: - projects

    @discardableResult
    func saveProject(_ p: Project) -> Project {
        var p = p
        meta.mutate { f in
            if let i = f.projects.firstIndex(where: { $0.id == p.id }) {
                f.projects[i] = p
            } else {
                p.order = (f.projects.map(\.order).max() ?? -1) + 1
                f.projects.append(p)
            }
        }
        return p
    }

    func deleteProject(id: String) {
        meta.mutate { $0.projects.removeAll { $0.id == id } }
    }

    func markOpened(projectID: String) {
        meta.mutate { f in
            if let i = f.projects.firstIndex(where: { $0.id == projectID }) {
                f.projects[i].lastOpenedAt = Date().timeIntervalSince1970
            }
        }
    }

    func reorderProjects(_ ids: [String]) {
        meta.mutate { f in
            for (i, id) in ids.enumerated() {
                if let j = f.projects.firstIndex(where: { $0.id == id }) {
                    f.projects[j].order = i
                }
            }
        }
    }

    func removeOrphans() {
        let live = servers.slugs
        meta.mutate { f in
            f.projects.removeAll { !live.contains($0.server) }
            f.servers = f.servers.filter { live.contains($0.key) }
        }
    }

    // MARK: - agents

    func saveAgent(_ a: AgentDef) {
        meta.mutate { f in
            if let i = f.agents.firstIndex(where: { $0.id == a.id }) { f.agents[i] = a }
            else { f.agents.append(a) }
        }
    }

    func deleteAgent(id: String) {
        meta.mutate { f in
            f.agents.removeAll { $0.id == id }
            for i in f.projects.indices where f.projects[i].agent == id {
                f.projects[i].agent = nil
            }
        }
    }

    // MARK: - launching

    func launchSpec(for vm: ProjectVM) -> LaunchSpec? {
        guard let s = vm.server else { return nil }
        return LaunchSpec(server: s.server, path: vm.project.path,
                          agent: vm.agent, title: vm.title,
                          subtitle: "\(s.title) · \(vm.agentName)",
                          icon: vm.icon, accent: s.accent, projectID: vm.id)
    }

    func launchSpec(forServer vm: ServerVM) -> LaunchSpec {
        LaunchSpec(server: vm.server, path: nil,
                   agent: agents.first { $0.id == "shell" },
                   title: vm.title, subtitle: vm.subtitle,
                   icon: vm.icon, accent: vm.accent, projectID: nil)
    }
}

extension Notification.Name {
    /// Coalesced "the model changed, rebuild" signal for the UI.
    static let sshmDidChange = Notification.Name("sshm.didChange")
}
