import AppKit

/// ⌘K. Projects, servers and actions in one list, filtered as you type. For a
/// tool whose whole job is "get me into that directory", this is the fastest
/// path in the product.
final class CommandPalette: NSWindowController, NSTextFieldDelegate {

    struct Row {
        var group: String
        var title: String
        var detail: String
        var icon: IconRef
        var accent: NSColor
        var run: () -> Void
    }

    private let field = NSTextField()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private var all: [Row] = []
    private var shown: [Row] = []
    private var highlighted = 0

    static func present(rows: [Row], over parent: NSWindow?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                         styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        let c = CommandPalette(window: w)
        c.all = rows
        c.build()
        c.filter("")
        if let parent {
            let f = parent.frame
            w.setFrameOrigin(NSPoint(x: f.midX - 310, y: f.midY - 40))
        } else {
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(c.field)
        NSApp.activate(ignoringOtherApps: true)
        c.retain()
    }

    private static var live: CommandPalette?
    private func retain() { CommandPalette.live = self }

    private func build() {
        guard let content = window?.contentView else { return }
        let shell = PaletteShell()
        shell.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shell)
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: content.topAnchor),
            shell.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            shell.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let glass = NSImageView()
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        glass.contentTintColor = Text.muted

        field.placeholderString = "Search projects, servers or run a command…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.sys(16, .regular)
        field.textColor = Text.primary
        field.delegate = self

        let head = NSStackView(views: [glass, field])
        head.orientation = .horizontal
        head.spacing = Space.md
        head.alignment = .centerY
        head.translatesAutoresizingMaskIntoConstraints = false

        let divider = ThemedDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        list.edgeInsets = NSEdgeInsets(top: Space.sm, left: Space.sm,
                                       bottom: Space.sm, right: Space.sm)

        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        shell.addSubview(head); shell.addSubview(divider); shell.addSubview(scroll)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: shell.topAnchor, constant: Space.lg),
            head.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: Space.lg),
            head.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -Space.lg),
            divider.topAnchor.constraint(equalTo: head.bottomAnchor, constant: Space.lg),
            divider.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    private func filter(_ query: String) {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter {
            $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q)
                || $0.group.lowercased().contains(q)
        }
        highlighted = 0
        rebuild()
    }

    private func rebuild() {
        list.arrangedSubviews.forEach {
            list.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        var lastGroup = ""
        var index = 0
        for row in shown {
            if row.group != lastGroup {
                lastGroup = row.group
                let h = NSTextField(labelWithString: row.group.uppercased())
                h.font = Fonts.sys(10, .semibold)
                h.textColor = Text.muted
                let box = NSView()
                h.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(h)
                NSLayoutConstraint.activate([
                    h.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Space.md),
                    h.topAnchor.constraint(equalTo: box.topAnchor, constant: Space.sm),
                    h.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
                ])
                list.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: list.widthAnchor,
                                           constant: -Space.lg).isActive = true
            }
            let r = PaletteRow(row: row, isHighlighted: index == highlighted)
            let captured = row
            r.onClick = { [weak self] in self?.fire(captured) }
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor,
                                     constant: -Space.lg).isActive = true
            index += 1
        }
    }

    private func fire(_ row: Row) {
        window?.close()
        CommandPalette.live = nil
        row.run()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: window?.close(); CommandPalette.live = nil          // esc
        case 125: move(1)                                            // down
        case 126: move(-1)                                           // up
        case 36, 76:                                                 // return
            if shown.indices.contains(highlighted) { fire(shown[highlighted]) }
        default: super.keyDown(with: event)
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        highlighted = max(0, min(shown.count - 1, highlighted + d))
        rebuild()
    }

    /// The field swallows arrows and return, so route them here first.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):   move(1); return true
        case #selector(NSResponder.moveUp(_:)):     move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if shown.indices.contains(highlighted) { fire(shown[highlighted]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.close(); CommandPalette.live = nil; return true
        default: return false
        }
    }
}

final class PaletteShell: ThemedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        softCorners(16)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func applyTheme() {
        layer?.backgroundColor = Ink.surface.cg(self)
        layer?.borderColor = Ink.border.cg(self)
    }
}

final class PaletteRow: ThemedView {
    var onClick: (() -> Void)?
    private let highlighted: Bool
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(row: CommandPalette.Row, isHighlighted: Bool) {
        self.highlighted = isHighlighted
        super.init(frame: .zero)
        softCorners(Radius.pill)

        let tile = IconTile(side: 26, radius: 7)
        tile.configure(icon: row.icon, accent: row.accent)

        let title = NSTextField(labelWithString: row.title)
        title.font = Fonts.bodyMed
        title.textColor = Text.primary
        let detail = NSTextField(labelWithString: row.detail)
        detail.font = Fonts.caption
        detail.textColor = Text.muted
        detail.truncates(.byTruncatingMiddle)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: [tile, title, spacer, detail])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = Space.md
        r.translatesAutoresizingMaskIntoConstraints = false
        addSubview(r)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            r.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.md),
            r.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.md),
            r.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (highlighted || hovering ? Ink.hover : NSColor.clear).cg(self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeAlways,
                                         .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
