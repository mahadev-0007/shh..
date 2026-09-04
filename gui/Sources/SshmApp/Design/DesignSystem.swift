import AppKit
import SwiftTerm

// The rule this system is built on: large surfaces stay neutral, small
// components carry colour, and colour means state — not category.

enum ThemeMode: String, Codable, CaseIterable {
    case system, light, dark

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
}

/// A colour that resolves per appearance, so one palette drives both themes.
func dynamicColor(_ name: String, light: String, dark: String) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? dark : light)
    }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s += "FF" }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
                  green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255,
                  alpha: CGFloat(v & 0xFF) / 255)
    }

    /// Resolve to a CGColor under a specific view's appearance. A dynamic
    /// NSColor read outside an appearance context silently picks the wrong one,
    /// which is the classic way dark-mode layers end up light.
    func cg(_ view: NSView) -> CGColor {
        var out: CGColor = NSColor.clear.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

enum Ink {
    static let bg      = dynamicColor("bg",      light: "#F7F7F8", dark: "#171719")
    static let sidebar = dynamicColor("sidebar", light: "#FFFFFF", dark: "#151517")
    static let surface = dynamicColor("surface", light: "#FFFFFF", dark: "#1E1E21")
    static let hover   = dynamicColor("hover",   light: "#F1F1F3", dark: "#242428")
    static let border  = dynamicColor("border",  light: "#E4E4E7", dark: "#303035")
    static let borderStrong = dynamicColor("borderStrong", light: "#CFCFD4", dark: "#4A4A50")

    /// One accent for interaction: primary actions, selection, focus.
    static let accent    = dynamicColor("accent",   light: "#0E9F7C", dark: "#A7E3D1")
    /// Text/icon colour that sits legibly on top of `accent`.
    static let onAccent  = dynamicColor("onAccent", light: "#FFFFFF", dark: "#0E2A23")

    // colour as state, nothing else
    static let success = dynamicColor("success", light: "#12925C", dark: "#63D69A")
    static let warning = dynamicColor("warning", light: "#A9701A", dark: "#E5B75D")
    static let error   = dynamicColor("error",   light: "#C24450", dark: "#E4727B")
    static let info    = dynamicColor("info",    light: "#3B6FD4", dark: "#7FA7FF")
    /// Reserved for terminal / agent things, so pink means one thing only.
    static let terminal = dynamicColor("terminal", light: "#A85067", dark: "#D995A6")
    static let neutral  = dynamicColor("neutralTone", light: "#6B6B73", dark: "#9A9AA2")
}

enum Text {
    static let primary   = dynamicColor("textPrimary",   light: "#18181B", dark: "#F1F1F2")
    static let secondary = dynamicColor("textSecondary", light: "#52525B", dark: "#A4A4A9")
    static let muted     = dynamicColor("textMuted",     light: "#8A8A93", dark: "#707076")
}

enum Radius {
    static let card: CGFloat  = 14
    static let tile: CGFloat  = 12
    static let pill: CGFloat  = 9
    static let chip: CGFloat  = 10
    static let field: CGFloat = 10
    static let badge: CGFloat = 6
}

enum Space {
    static let xs: CGFloat = 4,  sm: CGFloat = 8,  md: CGFloat = 12
    static let lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    static let page: CGFloat = 32
    /// Content stops widening past this; a full-width row on a 27" display has
    /// no compositional relationship to anything.
    static let maxContent: CGFloat = 1320
}

enum Fonts {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded),
              let f = NSFont(descriptor: d, size: size) else { return base }
        return f
    }
    static func sys(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Hierarchy comes from size and weight, not from shouting in uppercase.
    static var display: NSFont  { rounded(27, .bold) }
    static var section: NSFont  { sys(15, .semibold) }
    static var title: NSFont    { sys(15, .semibold) }
    static var metric: NSFont   { rounded(29, .semibold) }
    static var body: NSFont     { sys(13, .regular) }
    static var bodyMed: NSFont  { sys(13, .medium) }
    static var caption: NSFont  { sys(12, .regular) }
    static var micro: NSFont    { sys(11, .medium) }
    static var badge: NSFont    { sys(11, .semibold) }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Base view that re-applies its colours when the appearance flips, which is
/// what makes light/dark switching work for layer-backed views.
class ThemedView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Paint at construction, not only when the window or appearance
        // changes — otherwise a view that is built and shown without either
        // event never gets a background at all.
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyTheme() }
    }

    /// Subclasses set every layer colour here, and only here.
    func applyTheme() {}
}

extension NSView {
    /// Squircle, not stadium.
    func softCorners(_ radius: CGFloat) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
}

enum Theme {
    static var terminalFontSize: CGFloat = 13

    static func apply(mode: ThemeMode) {
        NSApp.appearance = mode.appearance
    }

    /// Terminals keep a faint wash of the project's accent so the machine you
    /// are on stays identifiable — the one place a per-item colour earns itself.
    static func wash(_ hue: NSColor, dark: Bool) -> NSColor {
        let h = hue.usingColorSpace(.sRGB) ?? hue
        if dark {
            return NSColor(srgbRed: 0.055 + h.redComponent * 0.10,
                           green: 0.045 + h.greenComponent * 0.10,
                           blue: 0.062 + h.blueComponent * 0.10, alpha: 1)
        }
        return NSColor(srgbRed: 0.99 - (1 - h.redComponent) * 0.06,
                       green: 0.99 - (1 - h.greenComponent) * 0.06,
                       blue: 0.99 - (1 - h.blueComponent) * 0.06, alpha: 1)
    }

    static func apply(to view: TerminalView, hue: NSColor) {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        view.font = Fonts.mono(terminalFontSize)
        view.nativeBackgroundColor = wash(hue, dark: dark)
        view.nativeForegroundColor = dark ? NSColor(hex: "#DEDEE2") : NSColor(hex: "#26262B")
        view.caretColor = hue
        view.caretTextColor = dark ? .black : .white
        view.selectedTextBackgroundColor = hue.withAlphaComponent(0.3)
        view.installColors(dark ? ansiDark : ansiLight)
    }

    private static func ansi(_ list: [(Int, Int, Int)]) -> [SwiftTerm.Color] {
        list.map { SwiftTerm.Color(red: UInt16($0.0 * 257), green: UInt16($0.1 * 257),
                                   blue: UInt16($0.2 * 257)) }
    }
    static let ansiDark = ansi([
        (58, 58, 66),   (240, 150, 150), (160, 216, 170), (238, 208, 150),
        (158, 178, 240), (198, 168, 236), (150, 212, 210), (206, 206, 214),
        (96, 96, 108),  (248, 176, 176), (184, 232, 194), (248, 224, 176),
        (184, 200, 248), (218, 194, 244), (176, 230, 228), (238, 238, 244),
    ])
    static let ansiLight = ansi([
        (60, 60, 67),   (183, 61, 68),  (28, 130, 76),  (150, 100, 20),
        (48, 92, 190),  (128, 74, 168), (24, 122, 130), (90, 90, 98),
        (120, 120, 130), (200, 82, 88), (40, 150, 92),  (170, 122, 30),
        (66, 112, 210), (150, 96, 190), (40, 140, 148), (30, 30, 36),
    ])
}

/// The per-item hues survive, but only as small accents (icon tiles, terminal
/// wash) — never as a card's whole background.
enum Pastel {
    static let rgb: [(Int, Int, Int)] = [
        (129, 140, 248), (56, 189, 248), (52, 211, 153), (251, 191, 36),
        (244, 114, 182), (14, 165, 233), (163, 230, 53), (217, 70, 239),
        (251, 146, 60), (45, 212, 191), (139, 92, 246), (248, 113, 113),
    ]
    static let names = ["indigo", "sky", "emerald", "amber", "pink", "blue",
                        "lime", "fuchsia", "orange", "teal", "violet", "red"]

    static func color(_ i: Int) -> NSColor {
        let (r, g, b) = rgb[((i % rgb.count) + rgb.count) % rgb.count]
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }
    static let emoji = ["🌙", "🐳", "🍃", "🍋", "🌸", "🔮",
                        "🌿", "🌺", "🍑", "🫧", "💜", "🏺"]
}
