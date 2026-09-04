import AppKit

/// Custom icons live as files in ~/.config/sshm/icons/. An IconRef of kind
/// .image stores just the filename, so the JSON stays small and the config
/// directory stays portable.
enum IconStore {
    static var dir: URL { ConfigPaths.dir.appendingPathComponent("icons") }

    private static var cache: [String: NSImage] = [:]

    static func ensureDir() {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }

    /// Copy an image in, normalised to a 256px PNG. Anything AppKit can open
    /// works — png, jpeg, heic, tiff, gif, pdf, even an .icns.
    static func importImage(from url: URL) -> IconRef? {
        guard let src = NSImage(contentsOf: url) else { return nil }
        return store(src, suggestedName: url.deletingPathExtension().lastPathComponent)
    }

    static func importImage(_ image: NSImage, name: String = "icon") -> IconRef? {
        store(image, suggestedName: name)
    }

    private static func store(_ src: NSImage, suggestedName: String) -> IconRef? {
        guard let png = pngData(from: src, side: 256) else { return nil }
        ensureDir()
        let safe = Slug.make(suggestedName)
        let filename = "\(safe)-\(UUID().uuidString.prefix(6)).png"
        let dest = dir.appendingPathComponent(filename)
        guard (try? png.write(to: dest)) != nil else { return nil }
        return IconRef(kind: .image, value: filename)
    }

    /// Square, aspect-fit, transparent margin — so a wide wordmark and a square
    /// glyph both sit correctly in the same chip.
    private static func pngData(from src: NSImage, side: CGFloat) -> Data? {
        let target = NSSize(width: side, height: side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSRect(origin: .zero, size: target).fill()

        let s = src.size
        let scale = min(side / max(s.width, 1), side / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    static func image(named filename: String) -> NSImage? {
        if let c = cache[filename] { return c }
        let url = dir.appendingPathComponent(filename)
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache[filename] = img
        return img
    }

    /// Every custom icon on disk, newest first.
    static func all() -> [IconRef] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return names
            .filter { ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return a > b
            }
            .map { IconRef(kind: .image, value: $0.lastPathComponent) }
    }

    static func delete(_ ref: IconRef) {
        guard ref.kind == .image else { return }
        cache.removeValue(forKey: ref.value)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(ref.value))
    }

    /// The file types the picker and drag-and-drop accept.
    static let acceptedTypes = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "pdf", "icns", "svg"]
}
