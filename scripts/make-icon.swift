// Renders the app icon to an .iconset directory: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.36, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.14, alpha: 1)])!.draw(in: path, angle: -90)
    // take rows: timecode block + text bar
    let left = rect.minX + s * 0.13, width = rect.width - s * 0.26
    let rowH = s * 0.075, gap = s * 0.04
    let fractions: [CGFloat] = [0.95, 0.55, 0.55, 0.55, 0.8]
    for (i, f) in fractions.enumerated() {
        let y = rect.maxY - s * 0.17 - CGFloat(i) * (rowH + gap)
        let split = i >= 1 && i <= 3
        NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.22, alpha: split ? 1 : 0.55).setFill()
        NSBezierPath(roundedRect: NSRect(x: left, y: y, width: s * 0.13, height: rowH), xRadius: s * 0.015, yRadius: s * 0.015).fill()
        NSColor(calibratedWhite: 0.94, alpha: split ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: left + s * 0.16, y: y, width: (width - s * 0.16) * f, height: rowH), xRadius: s * 0.015, yRadius: s * 0.015).fill()
    }
    // bracket marking the split takes
    let top = rect.maxY - s * 0.17 - (rowH + gap) + rowH
    let bottom = rect.maxY - s * 0.17 - 3 * (rowH + gap)
    let br = NSBezierPath()
    let bx = left - s * 0.05
    br.move(to: NSPoint(x: bx + s * 0.03, y: top)); br.line(to: NSPoint(x: bx, y: top))
    br.line(to: NSPoint(x: bx, y: bottom)); br.line(to: NSPoint(x: bx + s * 0.03, y: bottom))
    br.lineWidth = max(1, s * 0.018)
    NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.22, alpha: 1).setStroke()
    br.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
