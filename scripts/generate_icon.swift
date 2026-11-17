import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(filename: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context

    let s = CGFloat(pixels)
    let inset = s * 0.08
    let cardRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225

    // Background squircle with monochrome dark gradient
    let path = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(
        starting: NSColor(calibratedWhite: 0.17, alpha: 1.0),
        ending: NSColor(calibratedWhite: 0.05, alpha: 1.0)
    )
    gradient?.draw(in: path, angle: -90)

    // Subtle crisp inner light edge
    NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
    path.lineWidth = max(1.0, s * 0.015)
    path.stroke()

    // Centered crisp white SF Symbol (memorychip.fill)
    if let symbol = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: nil) {
        let pointSize = s * 0.44
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let configured = symbol.withSymbolConfiguration(config) {
            let symSize = configured.size
            let drawRect = NSRect(
                x: (s - symSize.width) / 2.0,
                y: (s - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for spec in specs {
    if let data = renderIcon(pixels: spec.pixels) {
        try data.write(to: iconsetURL.appendingPathComponent(spec.filename))
    }
}
