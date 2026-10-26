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
    /// Can be dragged to a new position among the other movable pills.
    var movable: Bool = false
    /// Hover text; the title is used when this is nil.
    var tooltip: String?
}

/// The rounded dark track with a raised chip that springs between items. Stock
/// NSSegmentedControl can't do a sliding chip, per-item icons and dots, or a
/// close button, so this is drawn by hand.
///
/// Session pills behave like browser tabs: drag to reorder, middle-click to
/// close, and they shrink to share the width instead of running off the edge.
final class PillSegmentedControl: ThemedView {
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// Right-click on a pill; return the menu to show, or nil for none.
    var onContextMenu: ((String) -> NSMenu?)?
    /// A drag finished with a new order: the ids of every movable pill, in order.
    var onReorder: (([String]) -> Void)?

    private(set) var items: [PillItem] = []
    private(set) var selectedID: String?
    /// Index at which the session group starts; a divider is drawn before it.
    private var dividerBefore: Int?

    private let track = NSView()
    private let chip = NSView()
    private let divider = NSView()
    private var buttons: [PillButton] = []
    /// False until the bar has been laid out once, so a bar that just appeared
    /// places its chip instead of sliding it in from wherever the last one sat.
    private var hasLaidOut = false
    private var lastLayoutWidth: CGFloat = -1

    // drag to reorder
    private var pressed: PillButton?
    private var dragging: PillButton?
    private var pressX: CGFloat = 0
    private var pressOriginX: CGFloat = 0
    private var pressOrder: [String] = []
    /// Items that arrived mid-drag. Applying them would yank the dragged pill
    /// back to its old slot, so they wait for the drop.
    private var pendingItems: (items: [PillItem], selected: String?, divider: Int?)?

    /// The browser trick: after a tab is closed with the mouse, the others keep
    /// their width until the pointer leaves the bar, so the next close button
    /// lands right under the cursor instead of sliding away from it.
    private var frozenWidth: CGFloat?
    private var tracking: NSTrackingArea?

    static let gap: CGFloat = 2

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
        NSSize(width: naturalWidth, height: 40)
    }

    private var naturalWidth: CGFloat {
        guard !buttons.isEmpty else { return 0 }
        return chrome + buttons.reduce(0) { $0 + $1.preferredWidth }
    }

    /// Everything that isn't a pill: insets, gaps, the divider slot.
    private var chrome: CGFloat {
        4 + 2 + CGFloat(buttons.count) * Self.gap + (dividerBefore != nil ? 9 : 0)
    }

    // MARK: - items

    func set(items: [PillItem], selected: String?, dividerBefore: Int? = nil) {
        if dragging != nil {
            pendingItems = (items, selected, dividerBefore)
            // refresh what each pill shows, but leave the order alone
            for b in buttons { if let i = items.first(where: { $0.id == b.item.id }) { b.update(i) } }
            return
        }

        // Pills are reused by id and updated in place. Rebuilding them on every
        // status change threw away hover state, restarted the chip, and cost a
        // full view rebuild per tick of a reconnect countdown.
        // widths before the update: reused pills are changed in place below
        let oldWidths = buttons.map(\.preferredWidth)
        var reuse = Dictionary(buttons.map { ($0.item.id, $0) },
                               uniquingKeysWith: { a, _ in a })
        var next: [PillButton] = []
        for item in items {
            if let b = reuse.removeValue(forKey: item.id) {
                b.update(item)
                next.append(b)
            } else {
                let b = PillButton(item: item)
                wire(b)
                track.addSubview(b)
                next.append(b)
            }
        }
        reuse.values.forEach { $0.removeFromSuperview() }

        let orderChanged = next.map(\.item.id) != buttons.map(\.item.id)
        let widthsChanged = next.map(\.preferredWidth) != oldWidths
        buttons = next
        self.items = items
        self.dividerBefore = dividerBefore
        divider.isHidden = dividerBefore == nil
        selectedID = selected
        // a bar with nothing movable on it can't have a frozen width left over
        if !items.contains(where: \.movable) { frozenWidth = nil }

        invalidateIntrinsicContentSize()
        if orderChanged || widthsChanged || !hasLaidOut {
            relayout(animated: hasLaidOut)
        } else {
            applySelection(animated: true)
        }
    }

    private func wire(_ b: PillButton) {
        b.onSelect = { [weak self, weak b] in
            guard let self, let b else { return }
            self.select(b.item.id, notify: true)
        }
        b.onClose = { [weak self, weak b] viaMouse in
            guard let self, let b else { return }
            if viaMouse { self.freezeWidths() }
            self.onClose?(b.item.id)
        }
        b.onContextMenu = { [weak self, weak b] in
            guard let self, let b else { return nil }
            return self.onContextMenu?(b.item.id)
        }
        b.onPress = { [weak self, weak b] e in if let b { self?.press(b, e) } }
        b.onDrag = { [weak self] e in self?.drag(e) }
        b.onRelease = { [weak self] in self?.release() }
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
        let targets = slotFrames()
        if let i = buttons.firstIndex(where: { $0.item.id == selectedID }) {
            // narrow pills show a different set of parts when active
            buttons[i].fit(width: targets[i].width)
        }
        placeChip(animated: animated, targets: targets)
    }

    // MARK: - layout

    override func layout() {
        super.layout()
        // Only a resize needs a full pass here. Re-placing every pill on each
        // layout call would cut short the slide animations started elsewhere.
        if bounds.width != lastLayoutWidth || !hasLaidOut {
            relayout(animated: false)
        }
    }

    /// Where each pill belongs right now. Movable pills share whatever width is
    /// left once the fixed ones are placed, down to a floor; the rest keep
    /// their natural size.
    private func slotFrames() -> [NSRect] {
        let natural = buttons.map(\.preferredWidth)
        var widths = natural
        let movable = buttons.indices.filter { buttons[$0].item.movable }
        if !movable.isEmpty {
            let fixedWidth = buttons.indices.filter { !buttons[$0].item.movable }
                .reduce(CGFloat(0)) { $0 + natural[$1] }
            let room = bounds.width - chrome - fixedWidth
            var cap = natural.reduce(0, +) + chrome > bounds.width
                ? max(PillButton.minWidth, room / CGFloat(movable.count))
                : .greatestFiniteMagnitude
            if let f = frozenWidth { cap = min(cap, f) }
            for i in movable { widths[i] = min(natural[i], cap) }
        }

        var frames: [NSRect] = []
        var x: CGFloat = 4
        let h = bounds.height - 8
        for i in buttons.indices {
            if dividerBefore == i { x += 9 }
            frames.append(NSRect(x: x, y: 4, width: widths[i], height: h))
            x += widths[i] + Self.gap
        }
        return frames
    }

    private func relayout(animated: Bool) {
        lastLayoutWidth = bounds.width
        let frames = slotFrames()
        var end: CGFloat = 4
        for (i, (b, f)) in zip(buttons, frames).enumerated() {
            if dividerBefore == i {
                divider.frame = NSRect(x: f.minX - 6, y: 9, width: 1, height: bounds.height - 18)
            }
            end = f.maxX + Self.gap
            b.isActive = b.item.id == selectedID
            b.fit(width: f.width)
            guard b !== dragging else { continue }
            if animated, b.frame != .zero, b.frame != f {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    b.animator().frame = f
                }
            } else {
                b.frame = f
            }
        }
        track.frame = NSRect(x: 0, y: 0, width: max(0, min(end + 2, bounds.width)),
                             height: bounds.height)
        placeChip(animated: animated, targets: frames)
        hasLaidOut = true
    }

    private func placeChip(animated: Bool, targets: [NSRect]) {
        guard let i = buttons.firstIndex(where: { $0.item.id == selectedID }),
              targets.indices.contains(i), targets[i].width > 0 else {
            chip.isHidden = true; return
        }
        chip.isHidden = false
        // a pill being dragged carries the chip with it
        let target = buttons[i] === dragging ? buttons[i].frame : targets[i]
        guard animated, let l = chip.layer, chip.frame != target else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.frame = target
            CATransaction.commit()
            return
        }

        // Start from where the chip is *on screen*, not its model value, so a
        // second click mid-slide carries on from there instead of jumping.
        let shown = l.presentation() ?? l
        let fromPosition = shown.position
        let fromBounds = shown.bounds
        l.removeAnimation(forKey: "pos")
        l.removeAnimation(forKey: "size")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = target
        CATransaction.commit()

        // One spring drives both position and size so they land together. The
        // destination is read back from the layer rather than computed: a
        // layer-backed view's anchor is its corner, not its centre, and
        // aiming at the centre made the chip overshoot and then snap.
        func spring(_ key: String, from: NSValue, to: NSValue) -> CASpringAnimation {
            let a = CASpringAnimation(keyPath: key)
            a.mass = 1
            a.stiffness = 380
            a.damping = 34          // just under critical: settles, barely any bounce
            a.fromValue = from
            a.toValue = to
            a.duration = a.settlingDuration
            return a
        }
        l.add(spring("position", from: NSValue(point: fromPosition),
                     to: NSValue(point: l.position)), forKey: "pos")
        l.add(spring("bounds", from: NSValue(rect: fromBounds),
                     to: NSValue(rect: l.bounds)), forKey: "size")
    }

    // MARK: - closing with the mouse

    private func freezeWidths() {
        // only worth it when the pills are squeezed and so all the same width
        let frames = slotFrames()
        guard let i = buttons.indices.first(where: {
            buttons[$0].item.movable && frames[$0].width < buttons[$0].preferredWidth
        }) else { return }
        frozenWidth = frames[i].width
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

    override func mouseExited(with event: NSEvent) {
        guard frozenWidth != nil else { return }
        frozenWidth = nil
        relayout(animated: true)
    }

    // MARK: - drag to reorder

    private func press(_ b: PillButton, _ e: NSEvent) {
        guard b.item.movable else { return }
        pressed = b
        pressX = convert(e.locationInWindow, from: nil).x
        pressOriginX = b.frame.minX
        pressOrder = buttons.map(\.item.id)
    }

    private func drag(_ e: NSEvent) {
        guard let b = pressed else { return }
        let dx = convert(e.locationInWindow, from: nil).x - pressX
        if dragging == nil {
            // a little slop, so a click with a shaky hand is still a click
            guard abs(dx) > 4 else { return }
            dragging = b
            b.isDragging = true
            track.addSubview(b, positioned: .above, relativeTo: nil)
        }

        let frames = slotFrames()
        let movable = buttons.indices.filter { buttons[$0].item.movable }
        guard let first = movable.first, let last = movable.last else { return }
        let lo = frames[first].minX
        let hi = frames[last].maxX - b.frame.width
        var f = b.frame
        f.origin.x = min(max(pressOriginX + dx, lo), hi)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        b.frame = f
        CATransaction.commit()

        // the slot is decided by midpoints: cross a neighbour's centre and it
        // steps aside
        guard let from = buttons.firstIndex(of: b) else { return }
        var to = first
        for i in movable where buttons[i] !== b && frames[i].midX < f.midX { to += 1 }
        to = min(to, last)
        if to != from {
            buttons.remove(at: from)
            buttons.insert(b, at: to)
            let item = items.remove(at: from)
            items.insert(item, at: to)
            relayout(animated: true)
        } else {
            placeChip(animated: false, targets: frames)
        }
    }

    private func release() {
        guard let b = pressed else { return }
        pressed = nil
        guard dragging === b else { return }
        dragging = nil
        b.isDragging = false
        relayout(animated: true)

        let order = buttons.map(\.item.id)
        if order != pressOrder {
            onReorder?(buttons.filter(\.item.movable).map(\.item.id))
        }
        if let p = pendingItems {
            pendingItems = nil
            set(items: p.items, selected: p.selected, dividerBefore: p.divider)
        }
    }
}

/// One pill. Not an NSButton — it needs a dot, an emoji, and its own close hit
/// region, and NSButton's cell fights all three.
final class PillButton: ThemedView {
    /// Narrow enough for the icon and the status dot, nothing else.
    static let minWidth: CGFloat = 44

    private(set) var item: PillItem
    var onSelect: (() -> Void)?
    /// true when the close came from the mouse (button or middle-click).
    var onClose: ((Bool) -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: (() -> Void)?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            // a quick crossfade, so the title doesn't snap between weights
            // while the chip is gliding underneath it
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            label.layer?.add(fade, forKey: "weight")
            applyTheme()
            applyFit()
        }
    }
    var isDragging = false {
        didSet {
            layer?.shadowOpacity = isDragging ? 0.18 : 0
            layer?.shadowRadius = 6
            layer?.shadowOffset = NSSize(width: 0, height: -1)
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let iconLabel = NSTextField(labelWithString: "")
    private let iconImage = NSImageView()
    private let dot = NSView()
    private let closeButton = NSButton()
    private let stack = NSStackView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var width: CGFloat = 0
    /// Whether an icon is loaded, so a fit can show or hide it.
    private var hasIcon = false
    /// The icon last drawn, so an update only re-renders it when it changed.
    private var drawnIcon: IconRef??

    init(item: PillItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor

        label.font = Fonts.caption
        label.wantsLayer = true
        label.truncates(.byTruncatingTail)
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        iconLabel.font = NSFont.systemFont(ofSize: 13)
        iconImage.imageScaling = .scaleProportionallyDown

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3

        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "close")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.contentTintColor = Text.muted
        closeButton.toolTip = "Close tab (⌘W) · End session ends it on the server (⌥⌘W)"

        for v in [dot, iconLabel, iconImage, label, closeButton] { stack.addArrangedSubview(v) }
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13)
        trailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                   constant: -13)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),
            iconImage.widthAnchor.constraint(equalToConstant: 13),
            leading, trailing,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(item)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show a new version of the same item without rebuilding the view.
    func update(_ item: PillItem) {
        self.item = item
        label.stringValue = item.title
        toolTip = item.tooltip ?? item.title

        if drawnIcon == nil || drawnIcon! != item.icon {
            drawnIcon = .some(item.icon)
            hasIcon = false
            iconLabel.stringValue = ""
            iconImage.image = nil
            if let icon = item.icon {
                if icon.isEmoji {
                    iconLabel.stringValue = icon.value; hasIcon = true
                } else if let img = icon.image(pointSize: 12, tint: Text.secondary) {
                    iconImage.image = img; hasIcon = true
                }
            }
        }
        applyTheme()
        applyFit()
    }

    /// Measured once per title, in the active (wider) font. Measuring the
    /// label as it stands made a pill grow when selected, which shoved its
    /// neighbours sideways while the chip was still sliding.
    private var titleWidth: CGFloat = 0
    private var measuredTitle: String?
    private static let activeFont = Fonts.rounded(12.5, .semibold)

    var preferredWidth: CGFloat {
        if measuredTitle != item.title {
            measuredTitle = item.title
            titleWidth = ceil((item.title as NSString)
                .size(withAttributes: [.font: Self.activeFont]).width)
        }
        var w = titleWidth + 26
        if item.icon != nil { w += 19 }
        if item.running != nil { w += 12 }
        if item.closable { w += 19 }
        return min(max(w, 76), 200)
    }

    /// Tell the pill how wide it will be, so it can drop parts that won't fit:
    /// first the title, then — on all but the active pill — the close button.
    func fit(width: CGFloat) {
        guard width != self.width else { return }
        self.width = width
        applyFit()
    }

    private func applyFit() {
        let w = width > 0 ? width : preferredWidth
        let narrow = w < 72
        let tiny = w < 56
        let emoji = item.icon?.isEmoji ?? false

        dot.isHidden = item.running == nil
        // a narrow active pill trades its icon for the close button
        let showClose = item.closable && (!narrow || isActive || hovering)
        closeButton.isHidden = !showClose
        let showIcon = hasIcon && !(tiny && showClose)
        iconLabel.isHidden = !(showIcon && emoji)
        iconImage.isHidden = !(showIcon && !emoji)
        label.isHidden = narrow && hasIcon

        let pad: CGFloat = narrow ? 8 : 13
        leading.constant = pad
        trailing.constant = -pad
    }

    override func applyTheme() {
        label.textColor = isActive ? Text.primary : (hovering ? Text.secondary : Text.muted)
        label.font = isActive ? Self.activeFont : Fonts.caption
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

    override func mouseEntered(with event: NSEvent) { hovering = true; applyTheme(); applyFit() }
    override func mouseExited(with event: NSEvent) { hovering = false; applyTheme(); applyFit() }

    // selected on press, like a browser tab, so a drag carries the active tab
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        onPress?(event)
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onRelease?() }

    override func otherMouseUp(with event: NSEvent) {
        // middle-click closes
        if event.buttonNumber == 2, item.closable { onClose?(true) }
        else { super.otherMouseUp(with: event) }
    }

    @objc private func closeClicked() { onClose?(true) }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
}
