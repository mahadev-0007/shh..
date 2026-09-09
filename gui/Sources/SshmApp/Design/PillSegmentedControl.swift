import AppKit

/// One entry in the pill bar. Page tabs and live sessions share the shape; a
/// session adds a status dot and a close button.
struct PillItem: Equatable {
    var id: String
    var title: String
    var icon: IconRef?
    var accent: NSColor?
    /// nil = not a session. true = process alive.
    var running: Bool?
    var closable: Bool = false
    /// Something happened in this session that hasn't been seen.
    var attention: Bool = false
}

/// The rounded dark track with a raised chip that springs between items. Stock
/// NSSegmentedControl can't do a sliding chip, per-item icons and dots, or a
/// close button, so this is drawn by hand.
final class PillSegmentedControl: ThemedView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// Right-click on a pill; return the menu to show, or nil for none.
    var onContextMenu: ((String) -> NSMenu?)?

    private(set) var items: [PillItem] = []
    private(set) var selectedID: String?
    /// Index at which the session group starts; a divider is drawn before it.
    private var dividerBefore: Int?

    private let track = NSView()
    private let chip = NSView()
    private let divider = NSView()
    private var buttons: [PillButton] = []
    /// False right after a rebuild, so a bar that just appeared places its
    /// chip instead of sliding it in from wherever the last one sat.
    private var animateNextLayout = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        track.softCorners(Radius.pill + 4)
        track.layer?.borderWidth = 1
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)

        chip.softCorners(Radius.pill)
        chip.layer?.borderWidth = 1
        track.addSubview(chip)

        // shrink before overflowing the window, but never grow past the content
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        divider.wantsLayer = true
        track.addSubview(divider)

        NSLayoutConstraint.activate([
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        track.layer?.backgroundColor = Ink.hover.cg(self)
        track.layer?.borderColor = Ink.border.cg(self)
        chip.layer?.backgroundColor = Ink.surface.cg(self)
        chip.layer?.borderColor = Ink.borderStrong.cg(self)
        divider.layer?.backgroundColor = Ink.border.cg(self)
    }

    /// Laying the buttons out by hand means the view has no intrinsic width of
    /// its own — and with only leading and a `trailing <=` constraint, Auto
    /// Layout resolves that to zero. The bar then renders and hit-tests as a
    /// sliver. So the measured content width *is* the intrinsic size.
    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth, height: 40)
    }

    private var contentWidth: CGFloat {
        guard !buttons.isEmpty else { return 0 }
        var x: CGFloat = 4
        for (i, b) in buttons.enumerated() {
            if dividerBefore == i { x += 9 }
            x += b.preferredWidth + 2
        }
        return x + 2
    }

    func set(items: [PillItem], selected: String?, dividerBefore: Int? = nil) {
        // Rebuilding the buttons on every selection throws away the chip's
        // current position, so it teleports instead of sliding. Only rebuild
        // when the bar's shape actually changed.
        // title and attention must be part of "shape": a renamed tab (#2) or a
        // newly-lit attention dot has to rebuild, or it never appears
        let sameShape = items.map(\.id) == self.items.map(\.id)
            && items.map(\.running) == self.items.map(\.running)
            && items.map(\.title) == self.items.map(\.title)
            && items.map(\.attention) == self.items.map(\.attention)
            && dividerBefore == self.dividerBefore

        self.items = items
        self.dividerBefore = dividerBefore
        divider.isHidden = dividerBefore == nil

        if sameShape {
            if selectedID != selected {
                selectedID = selected
                applySelection(animated: true)
            }
            return
        }

        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.map { item in
            let b = PillButton(item: item)
            b.onSelect = { [weak self] in self?.select(item.id, notify: true) }
            b.onClose = { [weak self] in self?.onClose?(item.id) }
            b.onContextMenu = { [weak self] in self?.onContextMenu?(item.id) }
            track.addSubview(b)
            return b
        }
        selectedID = selected
        animateNextLayout = false      // a bar that just appeared shouldn't slide
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func select(_ id: String, notify: Bool) {
        if selectedID != id {
            selectedID = id
            applySelection(animated: true)
        }
        if notify { onSelect?(id) }
    }

    private func applySelection(animated: Bool) {
        buttons.forEach { $0.isActive = $0.item.id == selectedID }
        layoutSubtreeIfNeeded()        // button frames must be current first
        placeChip(animated: animated)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        let h = bounds.height - 8
        for (i, b) in buttons.enumerated() {
            if dividerBefore == i {
                divider.frame = NSRect(x: x + 3, y: 9, width: 1, height: bounds.height - 18)
                x += 9
            }
            let w = b.preferredWidth
            b.frame = NSRect(x: x, y: 4, width: w, height: h)
            x += w + 2
        }
        track.frame = NSRect(x: 0, y: 0, width: max(0, min(x + 2, bounds.width)),
                             height: bounds.height)
        buttons.forEach { $0.isActive = $0.item.id == selectedID }
        placeChip(animated: animateNextLayout)
        animateNextLayout = true
    }

    private func placeChip(animated: Bool) {
        guard let id = selectedID, let b = buttons.first(where: { $0.item.id == id }),
              b.frame.width > 0 else {
            chip.isHidden = true; return
        }
        chip.isHidden = false
        let target = b.frame
        guard animated, let l = chip.layer, chip.frame != target else {
            chip.frame = target; return
        }

        // a spring, not a linear slide — this bounce is most of the charm
        let from = l.position
        let fromWidth = l.bounds.width
        chip.frame = target

        let pos = CASpringAnimation(keyPath: "position")
        pos.mass = 1; pos.stiffness = 220; pos.damping = 26
        pos.fromValue = NSValue(point: NSPoint(x: from.x, y: from.y))
        pos.toValue = NSValue(point: NSPoint(x: target.midX, y: target.midY))
        pos.duration = pos.settlingDuration

        let bnd = CABasicAnimation(keyPath: "bounds.size.width")
        bnd.fromValue = fromWidth
        bnd.toValue = target.width
        bnd.duration = 0.24
        bnd.timingFunction = CAMediaTimingFunction(name: .easeOut)

        l.add(pos, forKey: "pos")
        l.add(bnd, forKey: "w")
    }

}

/// One pill. Not an NSButton — it needs a dot, an emoji, and its own close hit
/// region, and NSButton's cell fights all three.
final class PillButton: ThemedView {
    let item: PillItem
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?

    var isActive = false { didSet { applyTheme() } }

    private let label = NSTextField(labelWithString: "")
    private let iconLabel = NSTextField(labelWithString: "")
    private let iconImage = NSImageView()
    private let dot = NSView()
    private let closeButton = NSButton()
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(item: PillItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true

        label.stringValue = item.title
        label.font = Fonts.caption
        label.truncates(.byTruncatingTail)

        iconLabel.font = NSFont.systemFont(ofSize: 13)
        iconImage.imageScaling = .scaleProportionallyDown

        if let icon = item.icon {
            if icon.isEmoji {
                iconLabel.stringValue = icon.value; iconImage.isHidden = true
            } else if let img = icon.image(pointSize: 12, tint: Text.secondary) {
                iconImage.image = img; iconLabel.isHidden = true
            }
        } else {
            iconLabel.isHidden = true; iconImage.isHidden = true
        }

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.isHidden = item.running == nil

        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "close")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.contentTintColor = Text.muted
        closeButton.isHidden = !item.closable

        let stack = NSStackView(views: [dot, iconLabel, iconImage, label, closeButton]
            .filter { !$0.isHidden })
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),
            iconImage.widthAnchor.constraint(equalToConstant: 13),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        var w = label.intrinsicContentSize.width + 26
        if item.icon != nil { w += 19 }
        if item.running != nil { w += 12 }
        if item.closable { w += 19 }
        return min(max(w, 76), 200)
    }

    override func applyTheme() {
        label.textColor = isActive ? Text.primary : (hovering ? Text.secondary : Text.muted)
        label.font = isActive ? Fonts.rounded(12.5, .semibold) : Fonts.caption
        if let running = item.running {
            // amber wins: unseen activity matters more than merely being alive
            let tone: NSColor = item.attention ? Ink.warning
                                               : (running ? Ink.success : Ink.neutral)
            dot.layer?.backgroundColor = tone.cg(self)
        }
        closeButton.contentTintColor = isActive ? Text.secondary : Text.muted
        iconImage.contentTintColor = isActive ? Text.primary : Text.muted
        alphaValue = isActive ? 1 : 0.92
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

    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme() }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    @objc private func closeClicked() { onClose?() }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
}
