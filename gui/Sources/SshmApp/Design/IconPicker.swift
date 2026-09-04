import AppKit

/// Emoji + SF Symbols in one popover. The system character palette is not used:
/// it opens its own window, can't be constrained to a popover, and delivers text
/// through the responder chain instead of returning it.
final class IconPickerController: NSViewController {
    var onPick: ((IconRef) -> Void)?
    private var accent: NSColor

    private let search = SoftTextField(placeholder: "Search icons")
    private let tabs = PillSegmentedControl()
    private let grid = FlowStackView()
    private let upload = SoftButton("Choose image…", symbol: "photo", style: .secondary)
    private let hint = NSTextField(labelWithString:
        "Or drop an image straight onto any icon.")
    private var mode: IconRef.Kind = .emoji
    private var query = ""

    init(accent: NSColor) {
        self.accent = accent
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = ThemedCanvas(frame: NSRect(x: 0, y: 0, width: 396, height: 420))

        tabs.set(items: [PillItem(id: "emoji", title: "Emoji"),
                         PillItem(id: "symbol", title: "Symbols"),
                         PillItem(id: "mark", title: "Logos"),
                         PillItem(id: "image", title: "Custom")],
                 selected: "emoji")
        tabs.onSelect = { [weak self] id in
            self?.mode = IconRef.Kind(rawValue: id) ?? .emoji
            self?.reload()
        }
        search.onChange = { [weak self] q in self?.query = q.lowercased(); self?.reload() }

        grid.itemWidth = 40
        grid.itemHeight = 40
        grid.gap = 6
        grid.stretches = false
        grid.translatesAutoresizingMaskIntoConstraints = false

        let scroll = makeScrollView(grid)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        search.translatesAutoresizingMaskIntoConstraints = false

        upload.onClick = { [weak self] in self?.chooseFile() }
        upload.translatesAutoresizingMaskIntoConstraints = false
        hint.font = Fonts.caption
        hint.textColor = Text.muted
        hint.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(tabs); root.addSubview(search); root.addSubview(scroll)
        root.addSubview(upload); root.addSubview(hint)
        NSLayoutConstraint.activate([
            upload.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Space.sm),
            upload.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.md),
            hint.centerYAnchor.constraint(equalTo: upload.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: upload.trailingAnchor, constant: Space.sm),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                           constant: -Space.md),
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.md),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.md),

            search.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: Space.sm),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.md),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.md),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: Space.sm),
            scroll.topAnchor.constraint(greaterThanOrEqualTo: upload.bottomAnchor,
                                        constant: Space.sm),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.md),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Space.md),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Space.md),
            grid.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = root
        reload()
    }

    private func reload() {
        search.isHidden = (mode == .image || mode == .mark)
        upload.isHidden = mode != .image
        hint.isHidden = mode != .image

        var refs: [IconRef]
        switch mode {
        case .emoji:  refs = IconCatalog.emoji(matching: query).map { IconRef.emoji($0) }
        case .symbol: refs = IconCatalog.symbols(matching: query).map { IconRef.symbol($0) }
        case .mark:   refs = BrandMarks.ids.map { IconRef.mark($0) }
        case .image:  refs = IconStore.all()
        }

        var cells: [NSView] = refs.map { ref in
            let cell = IconCell(icon: ref, accent: accent)
            cell.onClick = { [weak self] in self?.pick(ref) }
            if ref.kind == .image {
                cell.onDelete = { [weak self] in
                    IconStore.delete(ref)
                    self?.reload()
                }
            }
            cell.toolTip = ref.kind == .mark ? BrandMarks.name(for: ref.value) : ref.value
            return cell
        }
        if mode == .image && cells.isEmpty {
            cells = []
        }
        grid.set(cells)
    }

    private func pick(_ ref: IconRef) {
        onPick?(ref)
        view.window?.close()
    }

    @objc private func chooseFile() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedFileTypes = IconStore.acceptedTypes
        p.message = "Pick a logo or photo — it's copied into ~/.config/sshm/icons/"
        guard p.runModal() == .OK, let url = p.url,
              let ref = IconStore.importImage(from: url) else { return }
        pick(ref)
    }
}

private final class IconCell: NSView {
    var onClick: (() -> Void)?
    /// Only set for custom images — removes the file.
    var onDelete: (() -> Void)?
    private let chip = IconChip(size: 38, radius: 10)
    private var hovering = false
    private var tracking: NSTrackingArea?
    private let icon: IconRef
    private let accent: NSColor

    init(icon: IconRef, accent: NSColor) {
        self.icon = icon
        self.accent = accent
        super.init(frame: .zero)
        chip.configure(icon: icon, accent: accent, filled: false)
        chip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: centerXAnchor),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = icon.value
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) {
        chip.configure(icon: icon, accent: accent, filled: true)
    }
    override func mouseExited(with event: NSEvent) {
        chip.configure(icon: icon, accent: accent, filled: false)
    }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onDelete != nil else { return nil }
        let m = NSMenu()
        let i = NSMenuItem(title: "Delete this icon", action: #selector(deleteClicked),
                           keyEquivalent: "")
        i.target = self
        m.addItem(i)
        return m
    }

    @objc private func deleteClicked() { onDelete?() }
}

/// Opens the picker anchored to a view.
enum IconPicker {
    static func show(from anchor: NSView, accent: NSColor, pick: @escaping (IconRef) -> Void) {
        let vc = IconPickerController(accent: accent)
        let popover = NSPopover()
        vc.onPick = { ref in pick(ref); popover.close() }
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

/// Curated icon lists. Symbols are validated at launch — macOS 13 ships SF
/// Symbols 4, so anything newer returns nil and must not reach the grid.
enum IconCatalog {
    static let emojiAll: [(String, String)] = [
        ("🚀","rocket launch ship deploy"), ("🛰️","satellite space"), ("🌍","world earth globe"),
        ("🐳","whale docker container"), ("🐙","octopus git github"), ("🦀","crab rust"),
        ("🐍","snake python"), ("🦫","beaver go"), ("☕","coffee java"),
        ("🧠","brain ai model think"), ("🤖","robot bot agent ai"), ("✨","sparkle magic ai new"),
        ("🔮","crystal ball predict magic"), ("🧩","puzzle piece plugin module"),
        ("🛠️","tools build wrench"), ("⚙️","gear settings config"), ("🔧","wrench fix tool"),
        ("🧪","test lab experiment"), ("🔬","microscope research"), ("📡","antenna signal api"),
        ("💾","floppy save disk"), ("🗄️","cabinet database archive"), ("🗃️","card box database"),
        ("📦","package box build artifact"), ("📁","folder directory"), ("📂","open folder"),
        ("📚","books docs library"), ("📖","book docs read"), ("📝","memo notes write"),
        ("📊","chart bar analytics stats"), ("📈","chart up growth metrics"),
        ("🧾","receipt invoice billing"), ("💳","card payment billing"), ("💰","money bag revenue"),
        ("🔐","lock key security auth"), ("🔑","key auth secret"), ("🛡️","shield security"),
        ("🚨","siren alert incident"), ("🔥","fire hot urgent"), ("⚡","bolt fast speed"),
        ("💡","bulb idea"), ("🎯","target goal"), ("🏁","flag finish release"),
        ("🚦","traffic light ci status"), ("🧭","compass navigate discover"),
        ("⏰","alarm clock cron schedule"), ("⏳","hourglass wait queue"),
        ("🌱","seedling staging grow new"), ("🌿","herb green staging"), ("🌳","tree main trunk"),
        ("🍀","clover luck"), ("🌸","blossom pink"), ("🌺","hibiscus flower"),
        ("🌼","daisy flower"), ("🌙","moon night dark"), ("⭐","star favourite"),
        ("🌈","rainbow pride"), ("☁️","cloud aws hosting"), ("🌊","wave stream"),
        ("❄️","snow cold cache"), ("🔆","bright light"), ("🫧","bubbles light"),
        ("🐝","bee busy worker"), ("🐞","ladybug bug fix"), ("🦋","butterfly light"),
        ("🐢","turtle slow"), ("🐇","rabbit fast"), ("🐱","cat kitty"),
        ("🐶","dog puppy"), ("🦊","fox"), ("🐻","bear"), ("🐼","panda"),
        ("🐨","koala"), ("🦉","owl night wise"), ("🦆","duck"), ("🐧","penguin linux"),
        ("🦭","seal"), ("🐬","dolphin"), ("🐠","fish"), ("🦑","squid"),
        ("🍎","apple mac"), ("🍊","orange fruit"), ("🍋","lemon fruit yellow"),
        ("🍓","strawberry"), ("🍑","peach"), ("🍇","grapes"), ("🥝","kiwi"),
        ("🥑","avocado"), ("🌽","corn"), ("🍄","mushroom"), ("🍪","cookie"),
        ("🧁","cupcake"), ("🍰","cake"), ("🍩","donut"), ("🍭","lollipop"),
        ("🍵","tea matcha"), ("🧋","boba tea"), ("🍯","honey"),
        ("🎨","art palette design ui"), ("🖌️","brush design"), ("🎬","clapper video media"),
        ("🎵","music note audio"), ("🎧","headphones audio"), ("📷","camera photo"),
        ("🖥️","desktop computer server"), ("💻","laptop dev"), ("⌨️","keyboard input"),
        ("🖱️","mouse cursor"), ("📱","phone mobile ios"), ("🕹️","joystick game"),
        ("🏠","house home main"), ("🏢","office building corp"), ("🏭","factory build"),
        ("🏰","castle legacy"), ("⛩️","shrine gate"), ("🗼","tower"),
        ("🧊","ice cube block"), ("🪵","wood log"), ("🪄","wand magic"),
        ("🧵","thread tmux session"), ("🪢","knot bind"), ("🔗","link chain url"),
        ("📌","pin fixed"), ("📎","clip attach"), ("🗑️","trash delete"),
        ("♻️","recycle refresh retry"), ("🔁","repeat loop"), ("🔀","shuffle branch"),
        ("✅","check done pass"), ("❌","cross fail error"), ("⚠️","warning caution"),
        ("🚧","construction wip"), ("🩹","bandage patch hotfix"), ("💊","pill fix"),
        ("🫀","heart core"), ("👀","eyes watch review"), ("🤫","shush ssh secret"),
        ("🎁","gift release"), ("🎉","party launch celebrate"), ("🏆","trophy win"),
        ("🥇","medal first"), ("🧙","wizard magic"), ("👻","ghost spooky"),
        ("🛸","ufo alien"), ("🪐","planet saturn"), ("🌟","glowing star"),
    ]

    /// Curated names, filtered to what this OS actually has.
    static let symbolsAll: [String] = {
        let candidates = [
            "folder.fill", "folder.badge.gearshape", "doc.text.fill", "doc.on.doc.fill",
            "shippingbox.fill", "archivebox.fill", "tray.full.fill", "externaldrive.fill",
            "internaldrive.fill", "server.rack", "cpu.fill", "memorychip.fill",
            "network", "globe", "antenna.radiowaves.left.and.right", "wifi",
            "cloud.fill", "icloud.fill", "arrow.up.circle.fill", "arrow.down.circle.fill",
            "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
            "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "slider.horizontal.3",
            "bolt.fill", "flame.fill", "sparkles", "wand.and.stars", "brain.head.profile",
            "cube.fill", "cube.transparent.fill", "square.stack.3d.up.fill", "shippingbox",
            "lock.fill", "lock.shield.fill", "key.fill", "checkmark.shield.fill",
            "eye.fill", "bell.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill",
            "checkmark.circle.fill", "clock.fill", "calendar", "timer",
            "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill", "gauge.medium",
            "list.bullet.rectangle.fill", "tablecells.fill", "text.book.closed.fill",
            "book.fill", "bookmark.fill", "tag.fill", "paperclip",
            "star.fill", "heart.fill", "flag.fill", "pin.fill",
            "house.fill", "building.2.fill", "building.columns.fill", "storefront.fill",
            "leaf.fill", "tree.fill", "drop.fill", "snowflake", "moon.fill", "sun.max.fill",
            "pawprint.fill", "ant.fill", "ladybug.fill", "tortoise.fill", "hare.fill",
            "figure.walk", "person.2.fill", "person.crop.circle.fill",
            "envelope.fill", "paperplane.fill", "bubble.left.and.bubble.right.fill",
            "play.circle.fill", "pause.circle.fill", "stop.circle.fill", "arrow.clockwise",
            "arrow.triangle.branch", "arrow.triangle.merge", "arrow.triangle.2.circlepath",
            "puzzlepiece.extension.fill", "app.badge.fill", "square.grid.2x2.fill",
            "circle.hexagongrid.fill", "point.3.connected.trianglepath.dotted",
            "waveform", "waveform.path.ecg", "scope", "target",
            "trash.fill", "wrench.fill", "screwdriver.fill", "paintbrush.fill",
            "camera.fill", "photo.fill", "film.fill", "music.note",
            "airplane", "car.fill", "bicycle", "sailboat.fill", "ferry.fill",
            "gift.fill", "crown.fill", "trophy.fill", "medal.fill", "party.popper.fill",
            "graduationcap.fill", "lightbulb.fill", "magnifyingglass", "questionmark.circle.fill",
        ]
        return candidates.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }()

    static func emoji(matching q: String) -> [String] {
        guard !q.isEmpty else { return emojiAll.map(\.0) }
        return emojiAll.filter { $0.1.contains(q) || $0.0.contains(q) }.map(\.0)
    }

    static func symbols(matching q: String) -> [String] {
        guard !q.isEmpty else { return symbolsAll }
        return symbolsAll.filter { $0.contains(q) }
    }
}
