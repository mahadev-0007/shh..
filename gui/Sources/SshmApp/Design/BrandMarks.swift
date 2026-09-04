import AppKit

/// Vector marks for the agents that ship seeded, drawn in code so there are no
/// image assets to bundle and they stay crisp at any size.
///
/// These are simplified, recognisable marks — not official artwork. For an exact
/// logo, drop the real file in through the icon picker's Custom tab.
enum BrandMarks {
    static let ids = ["claude", "openai", "gemini", "command", "cursor",
                      "terminal", "tmux", "editor", "aider", "opencode"]

    static func name(for id: String) -> String {
        switch id {
        case "claude":   return "Claude"
        case "openai":   return "OpenAI / Codex"
        case "gemini":   return "Gemini"
        case "command":  return "Command Code"
        case "cursor":   return "Cursor"
        case "terminal": return "Terminal"
        case "tmux":     return "tmux"
        case "editor":   return "Editor"
        case "aider":    return "Aider"
        case "opencode": return "opencode"
        default:         return id
        }
    }

    /// Brand-ish tint, used when the mark is drawn on a light chip.
    static func tint(for id: String) -> NSColor {
        switch id {
        case "claude":   return NSColor(srgbRed: 0.85, green: 0.44, blue: 0.28, alpha: 1)
        case "openai":   return NSColor(srgbRed: 0.06, green: 0.65, blue: 0.53, alpha: 1)
        case "gemini":   return NSColor(srgbRed: 0.32, green: 0.53, blue: 0.96, alpha: 1)
        case "command":  return NSColor(srgbRed: 0.78, green: 0.72, blue: 0.96, alpha: 1)
        case "cursor":   return NSColor(white: 0.85, alpha: 1)
        default:         return NSColor(white: 0.85, alpha: 1)
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(for id: String, side: CGFloat = 128) -> NSImage? {
        let key = "\(id)@\(Int(side))"
        if let c = cache[key] { return c }
        guard ids.contains(id) else { return nil }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(id: id, in: rect)
            return true
        }
        img.isTemplate = false
        cache[key] = img
        return img
    }

    private static func draw(id: String, in rect: NSRect) {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        tint(for: id).setFill()
        tint(for: id).setStroke()

        switch id {
        case "claude":  drawBurst(center: c, radius: r * 0.92, rays: 11)
        case "openai":  drawKnot(center: c, radius: r * 0.86)
        case "gemini":  drawSparkle(center: c, radius: r * 0.95)
        case "command": drawCommandGlyph(center: c, radius: r * 0.92)
        case "cursor":  drawChevronCube(center: c, radius: r * 0.8)
        case "tmux":    drawPanes(center: c, radius: r * 0.82)
        case "editor":  drawCaret(center: c, radius: r * 0.8)
        case "aider":   drawWrench(center: c, radius: r * 0.8)
        case "opencode": drawBraces(center: c, radius: r * 0.85)
        default:        drawPrompt(center: c, radius: r * 0.8)
        }
    }

    // MARK: - marks

    /// A radial burst of tapered rays — the Claude mark. Each ray is a wedge
    /// that is widest at the rim and converges to a point near the centre, which
    /// is what makes it read as a burst rather than a sparkler.
    private static func drawBurst(center: NSPoint, radius: CGFloat, rays: Int) {
        let path = NSBezierPath()
        let halfWidth: CGFloat = (.pi / CGFloat(rays)) * 0.46   // leave a gap between rays
        let apex = radius * 0.06
        for i in 0..<rays {
            let a = (CGFloat(i) / CGFloat(rays)) * .pi * 2 - .pi / 2
            let tipL = NSPoint(x: center.x + cos(a - halfWidth) * radius,
                               y: center.y + sin(a - halfWidth) * radius)
            let tipR = NSPoint(x: center.x + cos(a + halfWidth) * radius,
                               y: center.y + sin(a + halfWidth) * radius)
            let root = NSPoint(x: center.x + cos(a) * apex, y: center.y + sin(a) * apex)
            path.move(to: root)
            path.line(to: tipL)
            path.line(to: tipR)
            path.close()
        }
        path.fill()
    }

    /// A simplified interlaced hexagonal knot, in the spirit of the OpenAI mark.
    private static func drawKnot(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = radius * 0.17
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for i in 0..<3 {
            let rot = CGFloat(i) * (.pi * 2 / 3)
            let lobe = NSBezierPath()
            var first = true
            // three overlapping rounded lobes, each a 240° arc offset outward
            for step in 0...36 {
                let t = CGFloat(step) / 36
                let a = -.pi / 3 + t * (.pi * 4 / 3) + rot
                let rr = radius * (0.62 + 0.20 * cos(t * .pi))
                let p = NSPoint(x: center.x + cos(a) * rr, y: center.y + sin(a) * rr)
                if first { lobe.move(to: p); first = false } else { lobe.line(to: p) }
            }
            path.append(lobe)
        }
        path.stroke()
    }

    /// The four-pointed star used by Gemini.
    private static func drawSparkle(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath()
        let pts = 4
        for i in 0..<pts {
            let a = (CGFloat(i) / CGFloat(pts)) * .pi * 2 - .pi / 2
            let next = a + (.pi * 2 / CGFloat(pts))
            let mid = a + (.pi / CGFloat(pts))
            let tip = NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            let waist = NSPoint(x: center.x + cos(mid) * radius * 0.14,
                                y: center.y + sin(mid) * radius * 0.14)
            let tip2 = NSPoint(x: center.x + cos(next) * radius,
                               y: center.y + sin(next) * radius)
            if i == 0 { path.move(to: tip) }
            path.curve(to: tip2,
                       controlPoint1: waist, controlPoint2: waist)
        }
        path.close()
        path.fill()
    }

    /// The ⌘ glyph: a square whose four corners curl into 3/4 loops. Traversed
    /// clockwise, every corner is the same 270° clockwise arc, and appendArc
    /// draws the connecting edges for us.
    private static func drawCommandGlyph(center: NSPoint, radius: CGFloat) {
        // the straight edge between two loops wants to be about a loop-diameter
        // long, or the four loops merge into a clover instead of reading as ⌘
        let r = radius * 0.23      // loop radius
        let a = radius * 0.46      // half-width of the inner square
        let corners = [
            NSPoint(x: center.x + a, y: center.y + a),   // top right
            NSPoint(x: center.x + a, y: center.y - a),   // bottom right
            NSPoint(x: center.x - a, y: center.y - a),   // bottom left
            NSPoint(x: center.x - a, y: center.y + a),   // top left
        ]
        // where each loop is entered and left, in degrees
        let spans: [(CGFloat, CGFloat)] = [(180, 270), (90, 180), (0, 90), (270, 0)]

        let path = NSBezierPath()
        path.lineWidth = radius * 0.155
        path.lineJoinStyle = .round
        for (i, c) in corners.enumerated() {
            let (start, end) = spans[i]
            path.appendArc(withCenter: c, radius: r,
                           startAngle: start, endAngle: end, clockwise: true)
        }
        path.close()
        path.stroke()
    }

    private static func drawChevronCube(center: NSPoint, radius: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = radius * 0.18
        p.lineJoinStyle = .round
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: center.x, y: center.y + radius))
        p.line(to: NSPoint(x: center.x - radius * 0.86, y: center.y - radius * 0.5))
        p.line(to: NSPoint(x: center.x, y: center.y - radius))
        p.line(to: NSPoint(x: center.x + radius * 0.86, y: center.y - radius * 0.5))
        p.close()
        p.stroke()
        let inner = NSBezierPath()
        inner.lineWidth = radius * 0.16
        inner.move(to: NSPoint(x: center.x, y: center.y + radius))
        inner.line(to: NSPoint(x: center.x, y: center.y - radius))
        inner.stroke()
    }

    private static func drawPanes(center: NSPoint, radius: CGFloat) {
        let r = NSRect(x: center.x - radius, y: center.y - radius * 0.78,
                       width: radius * 2, height: radius * 1.56)
        let outer = NSBezierPath(roundedRect: r, xRadius: radius * 0.18, yRadius: radius * 0.18)
        outer.lineWidth = radius * 0.15
        outer.stroke()
        let split = NSBezierPath()
        split.lineWidth = radius * 0.15
        split.move(to: NSPoint(x: center.x, y: r.minY))
        split.line(to: NSPoint(x: center.x, y: r.maxY))
        split.stroke()
    }

    private static func drawCaret(center: NSPoint, radius: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = radius * 0.2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: center.x - radius * 0.75, y: center.y + radius * 0.6))
        p.line(to: NSPoint(x: center.x + radius * 0.2, y: center.y + radius * 0.6))
        p.move(to: NSPoint(x: center.x - radius * 0.75, y: center.y))
        p.line(to: NSPoint(x: center.x + radius * 0.55, y: center.y))
        p.move(to: NSPoint(x: center.x - radius * 0.75, y: center.y - radius * 0.6))
        p.line(to: NSPoint(x: center.x, y: center.y - radius * 0.6))
        p.stroke()
    }

    private static func drawWrench(center: NSPoint, radius: CGFloat) {
        // a hammer: a diagonal handle with a slab head, which stays readable at
        // sidebar sizes where an open-jaw wrench turns to mush
        let handle = NSBezierPath()
        handle.lineWidth = radius * 0.24
        handle.lineCapStyle = .round
        handle.move(to: NSPoint(x: center.x - radius * 0.62, y: center.y - radius * 0.72))
        handle.line(to: NSPoint(x: center.x + radius * 0.24, y: center.y + radius * 0.16))
        handle.stroke()

        let head = NSBezierPath(roundedRect:
            NSRect(x: center.x - radius * 0.02, y: center.y + radius * 0.16,
                   width: radius * 0.92, height: radius * 0.46),
            xRadius: radius * 0.12, yRadius: radius * 0.12)
        let t = NSAffineTransform()
        t.translateX(by: center.x + radius * 0.44, yBy: center.y + radius * 0.39)
        t.rotate(byDegrees: 45)
        t.translateX(by: -(center.x + radius * 0.44), yBy: -(center.y + radius * 0.39))
        head.transform(using: t as AffineTransform)
        head.fill()
    }

    private static func drawBraces(center: NSPoint, radius: CGFloat) {
        for sign in [CGFloat(-1), 1] {
            let p = NSBezierPath()
            p.lineWidth = radius * 0.17
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            let x = center.x + sign * radius * 0.52
            p.move(to: NSPoint(x: x - sign * radius * 0.28, y: center.y + radius * 0.82))
            p.line(to: NSPoint(x: x, y: center.y + radius * 0.42))
            p.line(to: NSPoint(x: x + sign * radius * 0.26, y: center.y))
            p.line(to: NSPoint(x: x, y: center.y - radius * 0.42))
            p.line(to: NSPoint(x: x - sign * radius * 0.28, y: center.y - radius * 0.82))
            p.stroke()
        }
    }

    private static func drawPrompt(center: NSPoint, radius: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = radius * 0.2
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: center.x - radius * 0.7, y: center.y + radius * 0.45))
        p.line(to: NSPoint(x: center.x - radius * 0.1, y: center.y - radius * 0.05))
        p.line(to: NSPoint(x: center.x - radius * 0.7, y: center.y - radius * 0.55))
        p.stroke()
        let bar = NSBezierPath()
        bar.lineWidth = radius * 0.2
        bar.lineCapStyle = .round
        bar.move(to: NSPoint(x: center.x + radius * 0.1, y: center.y - radius * 0.55))
        bar.line(to: NSPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.55))
        bar.stroke()
    }
}
