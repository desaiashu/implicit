// Renders an SF Symbol into a macOS .iconset (white glyph on a rounded-rect
// gradient). Usage: swift make-icon.swift <output-iconset-dir> [symbol-name]
// Then: iconutil -c icns <output-iconset-dir> -o AppIcon.icns
import AppKit

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "AppIcon.iconset"
let symbolName = args.count > 2 ? args[2] : "ear.badge.waveform"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()

    // Rounded-rect background with a teal → deep-blue vertical gradient.
    let rect = NSRect(origin: .zero, size: size)
    let radius = CGFloat(px) * 0.2237 // macOS squircle-ish corner ratio
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.60, blue: 0.78, alpha: 1.0),
        NSColor(srgbRed: 0.07, green: 0.24, blue: 0.44, alpha: 1.0),
    ])
    gradient?.draw(in: bg, angle: -90)

    // White symbol, centered at ~52% of the canvas.
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.52, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size.width - s.width) / 2,
                               y: (size.height - s.height) / 2,
                               width: s.width, height: s.height))
    } else {
        FileHandle.standardError.write(Data("symbol '\(symbolName)' not found\n".utf8))
    }

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = size
    return rep.representation(using: .png, properties: [:])
}

// Standard macOS iconset slots.
let slots: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in slots {
    guard let png = render(px) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(slots.count) sizes to \(outDir)")
