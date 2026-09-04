import AppKit

/// A text field with no bezel, sitting in its own rounded well. NSTextField's
/// stock bezel can't be made to match anything else here.
final class SoftTextField: ThemedView, NSTextFieldDelegate {
    let field: NSTextField
    var onChange: ((String) -> Void)?
    var onCommit: (() -> Void)?

    private let well = NSView()

    init(placeholder: String, secure: Bool = false, mono: Bool = false) {
        field = secure ? NSSecureTextField() : NSTextField()
        super.init(frame: .zero)

        well.softCorners(Radius.field)
        well.layer?.borderWidth = 1
        well.translatesAutoresizingMaskIntoConstraints = false
        addSubview(well)

        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = mono ? Fonts.mono(12.5) : Fonts.body
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: topAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            well.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func applyTheme() {
        well.layer?.backgroundColor = Ink.hover.cg(self)
        well.layer?.borderColor = Ink.border.cg(self)
        field.textColor = Text.primary
    }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    func controlTextDidEndEditing(_ obj: Notification) { onCommit?() }

    func focus() { window?.makeFirstResponder(field) }

    /// Draw the focus state ourselves, since the focus ring is off.
    override func becomeFirstResponder() -> Bool {
        well.layer?.borderColor = Ink.borderStrong.cg(self)
        return super.becomeFirstResponder()
    }
}

/// A rounded button in one of three weights.
final class SoftButton: ThemedView {
    enum Style { case primary, secondary, quiet, destructive }

    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let style: Style
    private var accent: NSColor
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(_ title: String, symbol: String? = nil, style: Style = .secondary,
         accent: NSColor = Pastel.color(0)) {
        self.style = style
        self.accent = accent
        super.init(frame: .zero)
        softCorners(Radius.field)
        layer?.borderWidth = 1

        label.stringValue = title
        label.font = Fonts.rounded(12.5, .medium)

        var views: [NSView] = []
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            iconView.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) ?? img
            views.append(iconView)
        }
        views.append(label)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override func applyTheme() {
        let lift: CGFloat = hovering ? 0.06 : 0
        switch style {
        case .primary:
            layer?.backgroundColor = Ink.accent.withAlphaComponent(hovering ? 0.92 : 1).cg(self)
            layer?.borderColor = accent.withAlphaComponent(0.5).cgColor
            label.textColor = Ink.onAccent
            iconView.contentTintColor = Ink.onAccent
        case .secondary:
            layer?.backgroundColor = (hovering ? Ink.hover : Ink.surface).cg(self)
            layer?.borderColor = Ink.border.cg(self)
            label.textColor = Text.primary
            iconView.contentTintColor = Text.secondary
        case .quiet:
            layer?.backgroundColor = (hovering ? Ink.hover : NSColor.clear).cg(self)
            layer?.borderColor = NSColor.clear.cg(self)
            label.textColor = Text.secondary
            iconView.contentTintColor = Text.muted
        case .destructive:
            layer?.backgroundColor = Ink.error.withAlphaComponent(hovering ? 0.20 : 0.13).cg(self)
            layer?.borderColor = Ink.error.withAlphaComponent(0.4).cg(self)
            label.textColor = Ink.error
            iconView.contentTintColor = Ink.error
        }
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
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// A labelled form row: right-aligned caption, control, optional hint beneath.
final class FormRow: NSView {
    init(_ title: String, _ control: NSView, hint: String? = nil, labelWidth: CGFloat = 110) {
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: title)
        l.alignment = .right
        l.font = Fonts.body
        l.textColor = Text.secondary
        l.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l); addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            l.widthAnchor.constraint(equalToConstant: labelWidth),
            l.leadingAnchor.constraint(equalTo: leadingAnchor),
            l.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            control.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: Space.md),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
        ]

        if let hint {
            let h = NSTextField(labelWithString: hint)
            h.font = Fonts.caption
            h.textColor = Text.muted
            h.wraps(lines: 4)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            constraints += [
                h.leadingAnchor.constraint(equalTo: control.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: control.bottomAnchor, constant: 5),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(control.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }
}

func sectionHeader(_ title: String, _ trailing: NSView? = nil) -> NSView {
    let container = NSView()
    let l = NSTextField(labelWithString: title)
    l.font = Fonts.section
    l.textColor = Text.primary
    l.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(l)
    var c = [
        l.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        l.topAnchor.constraint(equalTo: container.topAnchor),
        l.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ]
    if let trailing {
        trailing.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(trailing)
        c += [
            trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: l.centerYAnchor),
        ]
    }
    NSLayoutConstraint.activate(c)
    return container
}

/// What a page shows when it has nothing yet — a big emoji, a line, an action.
final class EmptyStateView: NSView {
    init(emoji: String, title: String, message: String, action: SoftButton? = nil) {
        super.init(frame: .zero)
        let e = NSTextField(labelWithString: emoji)
        e.font = NSFont.systemFont(ofSize: 44)
        e.alignment = .center
        let t = NSTextField(labelWithString: title)
        t.font = Fonts.title
        t.textColor = Text.primary
        t.alignment = .center
        let m = NSTextField(labelWithString: message)
        m.font = Fonts.body
        m.textColor = Text.muted
        m.alignment = .center
        m.wraps(lines: 4)

        var views: [NSView] = [e, t, m]
        if let action { views.append(action) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = Space.sm
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Space.xxl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Space.xxl),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension NSTextField {
    /// A truncating label still reports its full text as its intrinsic width and
    /// defends it at priority 750, so it widens whatever contains it instead of
    /// actually truncating. Anything holding a path or a command needs this.
    @discardableResult
    func truncates(_ mode: NSLineBreakMode = .byTruncatingMiddle) -> NSTextField {
        lineBreakMode = mode
        usesSingleLineMode = true
        cell?.truncatesLastVisibleLine = true
        // Give up width under pressure, but still take any that's going —
        // without this the label hugs its truncated text and shows "cod…" in a
        // card with plenty of room.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.init(1), for: .horizontal)
        return self
    }

    /// Real wrapping. `maximumNumberOfLines` alone does nothing on a label built
    /// with `labelWithString:` — it stays single-line and infinitely wide.
    @discardableResult
    func wraps(lines: Int = 0) -> NSTextField {
        lineBreakMode = .byWordWrapping
        usesSingleLineMode = false
        maximumNumberOfLines = lines
        cell?.wraps = true
        cell?.isScrollable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return self
    }
}

/// A dark scroll view that doesn't paint a grey slab behind its content.
func makeScrollView(_ documentView: NSView) -> NSScrollView {
    let s = NSScrollView()
    s.drawsBackground = false
    s.contentView.drawsBackground = false
    s.hasVerticalScroller = true
    s.hasHorizontalScroller = false
    s.autohidesScrollers = true
    s.scrollerStyle = .overlay
    s.verticalScroller?.knobStyle = .light
    s.documentView = documentView
    return s
}
