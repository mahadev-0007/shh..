import AppKit
import UniformTypeIdentifiers

/// An SFTP file browser for one server: browse, upload, download, rename,
/// delete, new folder. Everything rides the session's control socket when one
/// is open, so it costs no extra login.
final class FilesPageVC: PageViewController, NavigatingPage,
                         NSTableViewDataSource, NSTableViewDelegate,
                         NSMenuDelegate, NSFilePromiseProviderDelegate {
    var pushPage: ((PageViewController) -> Void)?
    var openSession: ((LaunchSpec, Bool) -> Void)?

    private let server: ServerVM
    private let files: RemoteFiles
    private var path: String
    private var entries: [RemoteEntry] = []
    private var showHidden = false
    private var built = false

    private let pathField = NSTextField()
    private let table = NSTableView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let transfers = NSStackView()
    private let hiddenToggle = NSButton(checkboxWithTitle: "Show hidden files",
                                        target: nil, action: nil)

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(server: ServerVM, startPath: String) {
        self.server = server
        self.files = RemoteFiles(server: server.server)
        self.path = startPath.isEmpty ? "~" : startPath
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var initialResponder: NSView? { table }

    override func viewDidLoad() {
        super.viewDidLoad()
        pageTitle = "Files"
        pageSubtitle = "\(server.title) · \(server.subtitle)"
    }

    /// Built once: the listing is live state, and a model change elsewhere
    /// (a project saved, a server renamed) is no reason to throw it away.
    override func reload() {
        guard !built else { return }
        built = true
        build()
        load()
    }

    override func handleModelChange() {}

    // MARK: - layout

    private func build() {
        pathField.font = Fonts.mono(12)
        pathField.textColor = Text.primary
        pathField.placeholderString = "~"
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.target = self
        pathField.action = #selector(pathEntered)

        let up = SoftButton("Up", symbol: "arrow.up", style: .secondary)
        up.onClick = { [weak self] in self?.goUp() }
        let home = SoftButton("Home", symbol: "house", style: .secondary)
        home.onClick = { [weak self] in self?.go(to: "~") }
        let refresh = SoftButton("Refresh", symbol: "arrow.clockwise", style: .secondary)
        refresh.onClick = { [weak self] in self?.load() }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let nav = NSStackView(views: [up, home, pathField, spinner, refresh])
        nav.orientation = .horizontal
        nav.alignment = .centerY
        nav.spacing = Space.sm
        pathField.setContentHuggingPriority(.init(1), for: .horizontal)

        let upload = SoftButton("Upload…", symbol: "arrow.up.doc", style: .primary,
                                accent: server.accent)
        upload.onClick = { [weak self] in self?.chooseUpload() }
        let download = SoftButton("Download…", symbol: "arrow.down.doc", style: .secondary)
        download.onClick = { [weak self] in self?.chooseDownload() }
        let newFolder = SoftButton("New Folder", symbol: "folder.badge.plus", style: .secondary)
        newFolder.onClick = { [weak self] in self?.newFolder() }
        let rename = SoftButton("Rename", symbol: "pencil", style: .quiet)
        rename.onClick = { [weak self] in self?.renameSelected() }
        let delete = SoftButton("Delete", symbol: "trash", style: .destructive)
        delete.onClick = { [weak self] in self?.deleteSelected() }

        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)
        hiddenToggle.font = Fonts.caption

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let actions = NSStackView(views: [upload, download, newFolder, rename, delete,
                                          spacer, hiddenToggle])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Space.sm

        status.font = Fonts.caption
        status.textColor = Ink.error
        status.isHidden = true

        configureTable()
        let scroll = makeScrollView(table)
        scroll.hasHorizontalScroller = false
        scroll.heightAnchor.constraint(equalToConstant: 440).isActive = true

        let hint = NSTextField(labelWithString:
            "Drop files from Finder to upload. Drag rows out to download. "
            + "Double-click a file to save it to Downloads.")
        hint.font = Fonts.caption
        hint.textColor = Text.muted

        transfers.orientation = .vertical
        transfers.alignment = .leading
        transfers.spacing = Space.xs

        let stack = NSStackView(views: [nav, actions, status, scroll, hint, transfers])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Space.md
        body.addWide(stack)
        for v in [nav, actions, scroll] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 360), ("size", "Size", 90), ("modified", "Modified", 170),
        ]
        for (id, title, width) in columns {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = id == "name" ? 160 : 70
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 26
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    // MARK: - listing

    private var visible: [RemoteEntry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }

    private var selected: [RemoteEntry] {
        let rows = visible
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    private func load() {
        pathField.stringValue = path
        spinner.startAnimation(nil)
        files.list(path: path) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            switch result {
            case .success(let listing):
                self.status.isHidden = true
                self.path = listing.path
                self.pathField.stringValue = listing.path
                self.entries = listing.entries
            case .failure(let e):
                self.showError(e.localizedDescription)
                self.entries = []
            }
            self.table.reloadData()
        }
    }

    private func go(to newPath: String) {
        path = newPath
        load()
    }

    private func goUp() {
        var parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { parent = "/" }
        go(to: parent)
    }

    @objc private func pathEntered() {
        let p = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        go(to: p.isEmpty ? "~" : p)
    }

    @objc private func toggleHidden() {
        showHidden = hiddenToggle.state == .on
        table.reloadData()
    }

    private func showError(_ text: String) {
        status.stringValue = text
        status.isHidden = false
    }

    private func remotePath(_ e: RemoteEntry) -> String { RemoteFiles.join(path, e.name) }

    // MARK: - actions

    @objc private func openSelected() {
        let rows = visible
        guard rows.indices.contains(table.clickedRow) else { return }
        let e = rows[table.clickedRow]
        if e.isDir {
            go(to: remotePath(e))
        } else {
            download([e], into: Self.downloadsFolder, reveal: true)
        }
    }

    private func chooseUpload() {
        guard let w = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to \(path) on \(server.title)"
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let self else { return }
            self.upload(panel.urls, to: self.path)
        }
    }

    private func chooseDownload() {
        let items = selected
        guard !items.isEmpty else { showError("Select something to download first."); return }
        guard let w = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = Self.downloadsFolder
        panel.prompt = "Download Here"
        panel.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let dir = panel.url else { return }
            self?.download(items, into: dir, reveal: true)
        }
    }

    private func newFolder() {
        askName(title: "New folder", button: "Create", initial: "untitled folder") {
            [weak self] name in
            guard let self else { return }
            self.files.makeDirectory(RemoteFiles.join(self.path, name)) { result in
                self.finished(result)
            }
        }
    }

    private func renameSelected() {
        guard let e = selected.first, selected.count == 1 else {
            showError("Select one item to rename."); return
        }
        askName(title: "Rename “\(e.name)”", button: "Rename", initial: e.name) {
            [weak self] name in
            guard let self, name != e.name else { return }
            self.files.rename(self.remotePath(e), to: RemoteFiles.join(self.path, name)) {
                self.finished($0)
            }
        }
    }

    private func deleteSelected() {
        let items = selected
        guard !items.isEmpty else { showError("Select something to delete first."); return }
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = items.count == 1
            ? "Delete “\(items[0].name)” from \(server.title)?"
            : "Delete \(items.count) items from \(server.title)?"
        a.informativeText = items.contains(where: \.isDir)
            ? "Folders are deleted with everything inside them. This can't be undone."
            : "This can't be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.files.delete(items.map(self.remotePath)) { self.finished($0) }
        }
    }

    private func finished(_ result: Result<Void, Error>) {
        if case .failure(let e) = result { showError(e.localizedDescription) }
        load()
    }

    /// A sheet with a text field. Slashes are refused: a name is one path
    /// component, never a way to move something somewhere else.
    private func askName(title: String, button: String, initial: String,
                         then run: @escaping (String) -> Void) {
        guard let w = view.window else { return }
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  Shell.isSafe(name) else {
                self?.showError("“\(name)” isn't a usable name."); return
            }
            run(name)
        }
    }

    // MARK: - transfers

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func upload(_ urls: [URL], to dir: String) {
        guard !urls.isEmpty else { return }
        let done = track(urls.count == 1 ? "Uploading \(urls[0].lastPathComponent)"
                                         : "Uploading \(urls.count) items")
        files.upload(urls, toDirectory: dir) { [weak self] result in
            done(result)
            self?.load()
        }
    }

    private func download(_ items: [RemoteEntry], into dir: URL, reveal: Bool) {
        let pairs = items.map { (remote: remotePath($0),
                                 local: Self.unique(dir.appendingPathComponent($0.name))) }
        let done = track(items.count == 1 ? "Downloading \(items[0].name)"
                                          : "Downloading \(items.count) items")
        files.download(pairs) { result in
            done(result)
            if case .success = result, reveal {
                NSWorkspace.shared.activateFileViewerSelecting(pairs.map(\.local))
            }
        }
    }

    /// Never overwrite something already on the Mac: "name 2.ext", "name 3.ext"…
    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Adds a row to the transfer strip and hands back the closure that
    /// settles it. Only the last few stay on screen.
    private func track(_ title: String) -> (Result<Void, Error>) -> Void {
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        let label = NSTextField(labelWithString: title + "…")
        label.font = Fonts.caption
        label.textColor = Text.secondary
        label.lineBreakMode = .byTruncatingMiddle
        let row = NSStackView(views: [spin, label])
        row.orientation = .horizontal
        row.spacing = Space.sm
        transfers.addArrangedSubview(row)
        while transfers.arrangedSubviews.count > 5 {
            let old = transfers.arrangedSubviews[0]
            transfers.removeArrangedSubview(old); old.removeFromSuperview()
        }
        return { result in
            spin.stopAnimation(nil)
            spin.isHidden = true
            switch result {
            case .success:
                label.stringValue = "✓ " + title
            case .failure(let e):
                label.stringValue = "✗ \(title): \(e.localizedDescription)"
                label.textColor = Ink.error
            }
        }
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let rows = visible
        guard rows.indices.contains(row), let id = c?.identifier.rawValue else { return nil }
        let e = rows[row]
        let cell = NSTableCellView()

        let text: String
        switch id {
        case "size":
            text = e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size,
                                                             countStyle: .file)
        case "modified":
            text = Self.dateFormat.string(from: e.modified)
        default:
            text = e.name
        }
        let l = NSTextField(labelWithString: text)
        l.font = id == "name" ? Fonts.mono(12) : Fonts.caption
        l.textColor = id == "name" ? (e.isHidden ? Text.muted : Text.primary) : Text.secondary
        l.lineBreakMode = .byTruncatingMiddle
        l.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(l)

        var leading = cell.leadingAnchor
        if id == "name" {
            let symbol = e.isDir ? "folder.fill" : (e.isLink ? "arrow.up.right.square" : "doc")
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol,
                                                  accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = e.isDir ? server.accent : Text.secondary
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leading, constant: 6),
            l.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            l.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if id == "name" { cell.toolTip = "\(e.mode)  \(e.name)" }
        return cell
    }

    // MARK: - context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        // right-clicking outside the selection acts on the clicked row alone
        if row >= 0, !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        func add(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(run)
            menu.addItem(item)
        }
        if row >= 0 {
            let e = visible[row]
            if e.isDir { add("Open") { [weak self] in self?.go(to: self?.remotePath(e) ?? "~") } }
            add("Download to Downloads") { [weak self] in
                guard let self else { return }
                self.download(self.selected, into: Self.downloadsFolder, reveal: true)
            }
            add("Download…") { [weak self] in self?.chooseDownload() }
            add("Copy Path") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    self.selected.map(self.remotePath).joined(separator: "\n"), forType: .string)
            }
            menu.addItem(.separator())
            if table.selectedRowIndexes.count == 1 {
                add("Rename…") { [weak self] in self?.renameSelected() }
            }
            add("Delete…") { [weak self] in self?.deleteSelected() }
            menu.addItem(.separator())
        }
        add("Upload…") { [weak self] in self?.chooseUpload() }
        add("New Folder…") { [weak self] in self?.newFolder() }
        add("Refresh") { [weak self] in self?.load() }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    // MARK: - drag in (upload)

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // our own rows dragged back in are promises, not files to upload
        if (info.draggingSource as? NSTableView) === table { return [] }
        let rows = visible
        if op == .on, rows.indices.contains(row), rows[row].isDir { return .copy }
        t.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let rows = visible
        let dir = rows.indices.contains(row) && rows[row].isDir ? remotePath(rows[row]) : path
        upload(urls, to: dir)
        return true
    }

    // MARK: - drag out (download)

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let rows = visible
        guard rows.indices.contains(row) else { return nil }
        let e = rows[row]
        let type = e.isDir ? UTType.folder : (UTType(filenameExtension:
            (e.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = remotePath(e)
        return provider
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType type: String) -> String {
        ((p.userInfo as? String).map { ($0 as NSString).lastPathComponent }) ?? "download"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let remote = p.userInfo as? String else { completionHandler(nil); return }
        let done = track("Downloading \(url.lastPathComponent)")
        files.download([(remote: remote, local: url)]) { result in
            done(result)
            if case .failure(let e) = result { completionHandler(e) } else { completionHandler(nil) }
        }
    }
}
