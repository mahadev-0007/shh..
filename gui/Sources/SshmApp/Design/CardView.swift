import AppKit

/// Kept as a thin wrapper so the pages that were written against the old card
/// API keep working; the look now comes entirely from `Surface`.
class CardView: Surface {
    /// The old API nested content inside a clipping subview. Surfaces don't
    /// clip, so content goes straight on.
    var content: NSView { self }

    /// Retained for call sites that still pass a per-item hue. Large surfaces
    /// are neutral now, so this only tints the border when the card is
    /// selected — it no longer fills anything.
    var accent: NSColor = Ink.accent
    var tintStrength: CGFloat = 0
    var isDimmed = false {
        didSet { alphaValue = isDimmed ? 0.55 : 1 }
    }

    init(radius: CGFloat = Radius.card) {
        super.init(radius: radius, showsArrow: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var onClick: ((NSEvent) -> Void)? {
        didSet { isInteractive = onClick != nil }
    }
}

/// The old name for IconTile.
typealias IconChip = IconTile

extension IconTile {
    /// `filled:` is ignored — tiles are always a quiet tinted plate now.
    func configure(icon: IconRef, accent: NSColor, filled: Bool) {
        configure(icon: icon, accent: accent)
    }
    convenience init(size: CGFloat, radius: CGFloat? = nil) {
        self.init(side: size, radius: radius)
    }
}

/// A menu-sized rendering of an icon, for NSPopUpButton rows.
func menuIcon(_ icon: IconRef, side: CGFloat = 16) -> NSImage? {
    if icon.isEmoji {
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let s = icon.value as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.85)
            ]
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: rect.midX - size.width / 2,
                               y: rect.midY - size.height / 2), withAttributes: attrs)
            return true
        }
    }
    guard let img = icon.image(pointSize: side, tint: Text.secondary) else { return nil }
    let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    out.isTemplate = img.isTemplate
    return out
}
