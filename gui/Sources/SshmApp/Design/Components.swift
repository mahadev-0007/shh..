import AppKit

// The small primitives. Everything in the app is assembled from these rather
// than from ad-hoc rectangles and text.

// MARK: - StatusDot

enum Status {
    case online, offline, connecting, warning, idle

    var color: NSColor {
        switch self {
        case .online:     return Ink.success
        case .offline:    return Ink.error
        case .connecting: return Ink.warning
        case .warning:    return Ink.warning
        case .idle:       return Ink.neutral
        }
    }
    var label: String {
        switch self {
        case .online:     return "Online"
        case .offline:    return "Offline"
        case .connecting: return "Connecting"
        case .warning:    return "Degraded"
        case .idle:       return "Idle"
        }
    }
}

final class StatusDot: ThemedView {
    private var status: Status
    private let size: CGFloat

    init(_ status: Status, size: CGFloat = 7) {
        self.status = status
        self.size = size
        super.init(frame: .zero)
        softCorners(size / 2)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: Status) { status = s; applyTheme() }

    override func applyTheme() {
        layer?.backgroundColor = status.color.cg(self)
    }
}

/// A dot with its label: `● Online`
func statusLabel(_ status: Status, text: String? = nil, font: NSFont = Fonts.caption) -> NSStackView {
    let l = NSTextField(labelWithString: text ?? status.label)
    l.font = font
    l.textColor = status.color
    let s = NSStackView(views: [StatusDot(status), l])
    s.orientation = .horizontal
    s.spacing = 6
    s.alignment = .centerY
    return s
}

// MARK: - Badge

enum BadgeTone {
    case neutral, accent, terminal, info, success, warning, error

    var color: NSColor {
        switch self {
        case .neutral:  return Ink.neutral
        case .accent:   return Ink.accent
        case .terminal: return Ink.terminal
        case .info:     return Ink.info
        case .success:  return Ink.success
        case .warning:  return Ink.warning
        case .error:    return Ink.error
        }
    }
}

/// `[ SSH ]` `[ Command Code ]` — a tinted label, small enough that colour reads
/// as meaning rather than decoration.
final class Badge: ThemedView {
    private let tone: BadgeTone
    private let label = NSTextField(labelWithString: "")

    init(_ text: String, tone: BadgeTone = .neutral) {
        self.tone = tone
        super.init(frame: .zero)
        softCorners(Radius.badge)
        label.stringValue = text
        label.font = Fonts.badge
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = tone.color.withAlphaComponent(0.14).cg(self)
        label.textColor = tone.color
    }
}

// MARK: - IconTile

/// The rounded square holding a project/server/agent icon.
final class IconTile: ThemedView {
    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let side: CGFloat
    private var accent: NSColor = Ink.accent
    private var icon: IconRef = .emoji("•")
    private var imageScale: NSLayoutConstraint!

    var onDropImage: ((IconRef) -> Void)? {
        didSet { registerForDraggedTypes(onDropImage == nil ? [] : [.fileURL]) }
    }

    init(side: CGFloat = 40, radius: CGFloat? = nil) {
        self.side = side
        super.init(frame: .zero)
        softCorners(radius ?? (side <= 28 ? 8 : Radius.tile))
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: side * 0.5)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        for v in [label, imageView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageScale = imageView.widthAnchor.constraint(equalToConstant: side * 0.5)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageScale,
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: IconRef, accent: NSColor) {
        self.icon = icon
        self.accent = accent
        if icon.isEmoji {
            label.isHidden = false; imageView.isHidden = true
            label.stringValue = icon.value
        } else if let img = icon.image(pointSize: side * 0.46, tint: accent) {
            label.isHidden = true; imageView.isHidden = false
            imageView.image = img
            imageScale.constant = side * (icon.kind == .image ? 0.74 : 0.48)
        } else {
            label.isHidden = false; imageView.isHidden = true
            label.stringValue = "•"
        }
        applyTheme()
    }

    override func applyTheme() {
        // a tinted plate, not a saturated fill — the icon carries the colour
        layer?.backgroundColor = icon.isFullColor
            ? Ink.hover.cg(self)
            : accent.withAlphaComponent(0.16).cg(self)
        if !icon.isEmoji && !icon.isFullColor {
            imageView.contentTintColor = accent
        } else if icon.kind == .mark {
            imageView.contentTintColor = nil
        }
    }
}

extension IconTile {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageURL(sender) == nil ? [] : .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = droppedImageURL(sender) != nil
        layer?.borderWidth = ok ? 2 : 0
        layer?.borderColor = Ink.accent.cg(self)
        return ok ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let url = droppedImageURL(sender),
              let ref = IconStore.importImage(from: url) else { return false }
        onDropImage?(ref)
        return true
    }
    private func droppedImageURL(_ sender: NSDraggingInfo) -> URL? {
        guard onDropImage != nil,
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first,
              IconStore.acceptedTypes.contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }
}

// MARK: - Surface

/// The neutral card everything sits on. Colour arrives through borders and
/// small components, never through the fill.
class Surface: ThemedView {
    var isHovering = false { didSet { applyTheme() } }
    var isSelected = false { didSet { applyTheme() } }
    var isInteractive = false
    var onClick: ((NSEvent) -> Void)?
    /// Shown at the trailing edge on hover, as an affordance.
    private var arrow: NSImageView?
    private var tracking: NSTrackingArea?

    init(radius: CGFloat = Radius.card, showsArrow: Bool = false) {
        super.init(frame: .zero)
        softCorners(radius)
        layer?.borderWidth = 1
        if showsArrow {
            let a = NSImageView()
            a.image = NSImage(systemSymbolName: "arrow.right",
                              accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            a.alphaValue = 0
            a.translatesAutoresizingMaskIntoConstraints = false
            addSubview(a)
            NSLayoutConstraint.activate([
                a.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.lg),
                a.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            arrow = a
        }
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (isHovering && isInteractive ? Ink.hover : Ink.surface).cg(self)
        layer?.borderColor = isSelected
            ? Ink.accent.cg(self)
            : (isHovering && isInteractive ? Ink.borderStrong : Ink.border).cg(self)
        arrow?.contentTintColor = Ink.accent
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        guard isInteractive, isHovering != on else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.allowsImplicitAnimation = true
            isHovering = on
            arrow?.animator().alphaValue = on ? 1 : 0
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event)
    }
}

// MARK: - MetricTile

/// `▣ Projects / 01 / +1 this week` — an icon, a label, a number, a footnote.
final class MetricTile: Surface {
    init(symbol: String, label: String, value: String,
         footnote: NSView, tone: BadgeTone = .neutral) {
        super.init(radius: Radius.card, showsArrow: false)

        let tile = IconTile(side: 34, radius: 9)
        tile.configure(icon: .symbol(symbol), accent: tone.color)

        let name = NSTextField(labelWithString: label)
        name.font = Fonts.bodyMed
        name.textColor = Text.secondary

        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.contentTintColor = Text.muted

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [tile, name, spacer, chevron])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = Space.md

        let number = NSTextField(labelWithString: value)
        number.font = Fonts.metric
        number.textColor = Text.primary

        let stack = NSStackView(views: [head, number, footnote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(Space.md, after: head)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Space.lg),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.lg),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.lg),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Space.lg),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        isInteractive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - section header

/// `Running now  ● 1 active            View all →`
func sectionHeader(_ title: String, note: NSView? = nil,
                   action: (title: String, run: () -> Void)? = nil) -> NSView {
    let container = NSView()
    let l = NSTextField(labelWithString: title)
    l.font = Fonts.section
    l.textColor = Text.primary

    var views: [NSView] = [l]
    if let note { views.append(note) }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    views.append(spacer)

    if let action {
        let b = LinkButton(action.title, symbol: "arrow.right")
        b.onClick = action.run
        views.append(b)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = Space.md
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    return container
}

/// A quiet text action: `View all →`
final class LinkButton: ThemedView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(_ title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        label.stringValue = title
        label.font = Fonts.caption
        var views: [NSView] = [label]
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            views.append(icon)
        }
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 5
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor),
            s.bottomAnchor.constraint(equalTo: bottomAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor),
            s.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        let c = hovering ? Ink.accent : Text.secondary
        label.textColor = c
        icon.contentTintColor = c
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

// MARK: - OverflowMenu

final class OverflowButton: ThemedView {
    var items: [(String, () -> Void)] = []
    private let icon = NSImageView()
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        softCorners(Radius.pill)
        icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        layer?.backgroundColor = (hovering ? Ink.hover : NSColor.clear).cg(self)
        layer?.borderWidth = hovering ? 1 : 0
        layer?.borderColor = Ink.border.cg(self)
        icon.contentTintColor = hovering ? Text.primary : Text.muted
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.inVisibleRect, .activeInKeyWindow,
                                         .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, run) in items {
            let i = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = Box(run)
            menu.addItem(i)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
    @objc private func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.run()
    }
    private final class Box {
        let run: () -> Void
        init(_ r: @escaping () -> Void) { run = r }
    }
}
