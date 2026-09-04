import AppKit

/// A wrapping grid that sizes itself to its content. NSCollectionView without a
/// nib is fiddly and its selection model fights the cards' own hover handling;
/// with items in the tens, laying out by hand is simpler and faster.
final class FlowStackView: NSView {
    var itemWidth: CGFloat = 260 { didSet { relayout() } }
    var itemHeight: CGFloat = 116 { didSet { relayout() } }
    var gap: CGFloat = Space.md { didSet { relayout() } }
    /// Stretch items to fill the row evenly instead of leaving a ragged edge.
    var stretches = true

    private(set) var items: [NSView] = []
    /// Height is driven by a constraint we own, not by intrinsicContentSize:
    /// the height depends on the width, and an intrinsic size read before the
    /// first real width sticks at the wrong number of columns forever.
    private var heightConstraint: NSLayoutConstraint!

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ views: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }
        relayout()
    }

    private func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Auto Layout does not mark a hand-laid-out view dirty when only its width
    /// changes, so the grid would keep whatever column count it first guessed.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    private func columns(for width: CGFloat) -> Int {
        max(1, Int((width + gap) / (itemWidth + gap)))
    }

    override func layout() {
        super.layout()
        guard !items.isEmpty else { heightConstraint.constant = 0; return }
        let width = bounds.width
        guard width > 1 else { return }        // wait for a real width

        let cols = columns(for: width)
        let w = stretches ? (width - gap * CGFloat(cols - 1)) / CGFloat(cols) : itemWidth
        for (i, v) in items.enumerated() {
            let r = i / cols, c = i % cols
            v.frame = NSRect(x: CGFloat(c) * (w + gap),
                             y: CGFloat(r) * (itemHeight + gap),
                             width: w, height: itemHeight)
        }
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        heightConstraint.constant = CGFloat(rows) * itemHeight + CGFloat(rows - 1) * gap
    }
}

/// A vertical stack that fills its container's width — the body of every page.
final class PageStack: NSStackView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = Space.xl
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Add a row that spans the full width of the stack.
    func addWide(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
