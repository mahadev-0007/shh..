import AppKit

// Draws the app icon at every size macOS wants and writes an .iconset.
// Run through `iconutil` afterwards to get the .icns.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icons leave a margin; the artwork sits in the middle ~82%
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225        // Big Sur-ish squircle
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // deep charcoal ground with a mint rim, so it reads on light and dark docks
    ctx.saveGState()
    squircle.addClip()
    let bg = NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.15, blue: 0.16, alpha: 1),
                                NSColor(srgbRed: 0.06, green: 0.07, blue: 0.08, alpha: 1)])
    bg?.draw(in: rect, angle: -90)

    // A mint glow from the top-left, picking up the app's accent. It has to be
    // drawn over the whole rect: confining a radial gradient to a sub-rect
    // leaves a hard edge where the sub-rect stops.
    let glow = NSGradient(colors: [NSColor(srgbRed: 0.65, green: 0.89, blue: 0.82, alpha: 0.34),
                                   NSColor(srgbRed: 0.65, green: 0.89, blue: 0.82, alpha: 0.0)])
    glow?.draw(in: rect, relativeCenterPosition: NSPoint(x: -0.45, y: 0.55))
    ctx.restoreGState()

    // the shushing face is the brand — it's what ssh has always been telling you
    let glyph = "🤫" as NSString
    let fontSize = rect.width * 0.62
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize)
    ]
    let textSize = glyph.size(withAttributes: attrs)
    glyph.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                           y: rect.midY - textSize.height / 2 + rect.height * 0.02),
               withAttributes: attrs)

    // a hairline rim so the icon has an edge against a dark dock
    NSColor(white: 1, alpha: 0.10).setStroke()
    squircle.lineWidth = max(1, size / 256)
    squircle.stroke()

    image.unlockFocus()
    return image
}

// the set macOS expects, including @2x variants
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                           (256, 1), (256, 2), (512, 1), (512, 2)]
for (pt, scale) in sizes {
    let px = CGFloat(pt * scale)
    let img = draw(size: px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(outDir)")
