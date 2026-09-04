import AppKit

/// Base class for everything that fills the content area: a big title, an
/// optional back chevron, an optional trailing action, a pill slot, and a
/// scrolling body.
class PageViewController: NSViewController {
    /// Sub-view pills shown in the shell's bar while this page is on top.
    var pillItems: [PillItem] { [] }
    var selectedPill: String? { nil }
    func pillSelected(_ id: String) {}

    /// Where the shell should put keyboard focus when this page appears.
    var initialResponder: NSView? { nil }

    /// How wide this page's content may get. Forms want to stay narrow; card
    /// grids want the room.
    var contentWidthLimit: CGFloat { Space.maxContent }

    var pageTitle: String = "" { didSet { titleLabel.stringValue = pageTitle } }
    var pageSubtitle: String = "" {
        didSet {
            subtitleLabel.stringValue = pageSubtitle
            subtitleLabel.isHidden = pageSubtitle.isEmpty
        }
    }

    /// Set by ShellViewController when this page is pushed onto a stack.
    var onBack: (() -> Void)?
    /// Rebuild pills in the shell — call after changing `pillItems`.
    var onPillsChanged: (() -> Void)?

    let body = PageStack()
    /// Fills the page edge to edge when set — used by a terminal, which wants
    /// every pixel and none of the page furniture.
    private let fullBleed = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let header = NSView()
    private let actionSlot = NSStackView()
    private var backButton: SoftButton?
    private var scroll: NSScrollView!
    private var scrollView: NSScrollView { scroll }

    /// "As wide as the container allows", yielding to the required max-width.
    private func preferFull(_ view: NSView, in container: NSView,
                            inset: CGFloat) -> NSLayoutConstraint {
        let c = view.widthAnchor.constraint(equalTo: container.widthAnchor,
                                            constant: -inset * 2)
        c.priority = .defaultHigh
        return c
    }

    override func loadView() {
        let root = ThemedCanvas()

        titleLabel.font = Fonts.display
        titleLabel.textColor = Text.primary
        subtitleLabel.font = Fonts.body
        subtitleLabel.textColor = Text.muted
        subtitleLabel.isHidden = true

        actionSlot.orientation = .horizontal
        actionSlot.spacing = Space.sm
        actionSlot.alignment = .centerY

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        for v in [titles, actionSlot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        header.translatesAutoresizingMaskIntoConstraints = false

        // An unflipped document view pins short content to the *bottom* of the
        // clip view, which reads as a huge gap under the header.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)

        scroll = makeScrollView(doc)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        fullBleed.translatesAutoresizingMaskIntoConstraints = false
        fullBleed.isHidden = true

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(fullBleed)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: Space.lg),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Space.page),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                             constant: -Space.page),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: Space.maxContent),
            preferFull(header, in: root, inset: Space.page),

            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titles.topAnchor.constraint(equalTo: header.topAnchor),
            titles.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            actionSlot.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actionSlot.centerYAnchor.constraint(equalTo: titles.centerYAnchor),
            actionSlot.leadingAnchor.constraint(greaterThanOrEqualTo: titles.trailingAnchor,
                                                constant: Space.lg),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Space.lg),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            fullBleed.topAnchor.constraint(equalTo: root.topAnchor),
            fullBleed.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            fullBleed.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            fullBleed.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            body.topAnchor.constraint(equalTo: doc.topAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Space.page),
            body.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor,
                                           constant: -Space.page),
            // Content stops widening past maxContent, but still needs a
            // definite width: `<=` alone leaves the stack sized to its content,
            // which collapses every hand-laid-out grid inside it to one column.
            body.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidthLimit),
            preferFull(body, in: doc, inset: Space.page),
            body.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Space.xxl),
        ])
        view = root
    }

    /// Hand the whole page to one view, or pass nil to go back to the normal
    /// header-plus-scroll layout.
    func setFullBleed(_ view: NSView?) {
        fullBleed.subviews.forEach { $0.removeFromSuperview() }
        guard let view else {
            fullBleed.isHidden = true
            header.isHidden = false
            scrollView.isHidden = false
            return
        }
        header.isHidden = true
        scrollView.isHidden = true
        fullBleed.isHidden = false
        view.translatesAutoresizingMaskIntoConstraints = false
        fullBleed.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: fullBleed.topAnchor),
            view.leadingAnchor.constraint(equalTo: fullBleed.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: fullBleed.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: fullBleed.bottomAnchor),
        ])
    }

    /// Buttons shown at the top right of the page.
    func setActions(_ views: [NSView]) {
        actionSlot.arrangedSubviews.forEach {
            actionSlot.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        views.forEach { actionSlot.addArrangedSubview($0) }
    }

    /// Adds a back chevron ahead of the title. Called by the shell on push.
    func installBackButton() {
        guard backButton == nil, onBack != nil else { return }
        let b = SoftButton("Back", symbol: "chevron.left", style: .quiet)
        b.onClick = { [weak self] in self?.onBack?() }
        backButton = b
        // sits with the actions rather than pushing the title around
        actionSlot.insertArrangedSubview(b, at: 0)
    }

    func clearBody() {
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0); $0.removeFromSuperview()
        }
    }

    /// Rebuilt whenever the model changes. Subclasses fill `body` here.
    func reload() {}

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(modelChanged), name: .sshmDidChange, object: nil)
    }

    @objc private func modelChanged() { reload() }
}


/// The neutral canvas every page sits on.
final class ThemedCanvas: ThemedView {
    override func applyTheme() { layer?.backgroundColor = Ink.bg.cg(self) }
}


/// Top-anchored coordinate space for scroll content.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
