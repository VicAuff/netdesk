// Draws the NetDesk icon: one glowing sparkle above a clean desk line, on a graphite tile.
// Usage: swift scripts/make-icon.swift <output.iconset> [preview.png]
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Four-pointed sparkle with concave sides, taller than wide.
func sparkle(_ center: CGPoint, rx: CGFloat, ry: CGFloat, pinch: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let points = [CGPoint(x: 0, y: ry), CGPoint(x: rx, y: 0), CGPoint(x: 0, y: -ry), CGPoint(x: -rx, y: 0)]
    path.move(to: CGPoint(x: center.x, y: center.y + ry))
    for index in 0..<4 {
        let current = points[index], next = points[(index + 1) % 4]
        path.addQuadCurve(to: CGPoint(x: center.x + next.x, y: center.y + next.y),
                          control: CGPoint(x: center.x + (current.x + next.x) * pinch, y: center.y + (current.y + next.y) * pinch))
    }
    path.closeSubpath()
    return path
}

func render(_ pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 squircle, centered, with a soft drop shadow.
    let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let u = tile.width / 100
    let radius = tile.width * 0.2237
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let accent: UInt32 = 0x2DD4BF

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * u), blur: 3 * u, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x111317))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x3B4049), color(0x111317)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY + 55 * u), options: [])

    let center = CGPoint(x: tile.midX, y: tile.minY + 58 * u)
    let glow = CGGradient(colorsSpace: space, colors: [color(accent, 0.42), color(accent, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 34 * u, options: [])

    // The desk: a thin line fading at both ends, lit from above by the sparkle.
    let lineY = tile.minY + 31 * u
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: lineY)
    ctx.scaleBy(x: 1, y: 0.18)
    let pool = CGGradient(colorsSpace: space, colors: [color(accent, 0.35), color(accent, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 30 * u, options: [])
    ctx.restoreGState()
    let line = CGRect(x: tile.minX + 20 * u, y: lineY - 0.9 * u, width: 60 * u, height: 1.8 * u)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 0.9 * u, cornerHeight: 0.9 * u, transform: nil))
    ctx.clip()
    let lineFill = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0), color(0xFFFFFF, 0.9), color(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(lineFill, start: CGPoint(x: line.minX, y: lineY), end: CGPoint(x: line.maxX, y: lineY), options: [])
    ctx.restoreGState()

    // The sparkle: white fading to a pale tint, with a soft glow.
    let star = sparkle(center, rx: 15 * u, ry: 21 * u, pinch: 0.1)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 4 * u, color: color(accent, 0.55))
    ctx.addPath(star)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(star)
    ctx.clip()
    let starFill = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xCFFBF3)] as CFArray, locations: [0.35, 1])!
    ctx.drawLinearGradient(starFill, start: CGPoint(x: center.x, y: center.y + 21 * u), end: CGPoint(x: center.x, y: center.y - 21 * u), options: [])
    ctx.restoreGState()
    ctx.addPath(sparkle(CGPoint(x: tile.minX + 72 * u, y: tile.minY + 76 * u), rx: 3.2 * u, ry: 4.4 * u, pinch: 0.12))
    ctx.setFillColor(color(0xFFFFFF, 0.75))
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline edge so the tile holds on light and dark backgrounds.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 0.25 * u, dy: 0.25 * u), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(0.5 * u)
    ctx.strokePath()

    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
