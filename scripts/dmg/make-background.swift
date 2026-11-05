// Draws the picture behind the window people see when they open Unearth.dmg, in the colors of the app's layers.
// The sky is a mid-tone on purpose: Finder writes icon names in black or white depending on the Mac's appearance, and
// both have to be readable on it. Run it from anywhere; it writes background.png and background@2x.png next to itself.
import AppKit

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// A little more picture than the window shows, so it reaches the edges however tall Finder makes the title bar.
let (width, height) = (700.0, 460.0)
/// Where the window's own middle is: the settings give it a width of 660.
let middle = 330.0

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// `top` counts down from the top of the picture, as the icon positions do.
func flipped(_ top: Double) -> Double { height - top }

func layer(_ hex: UInt32, top: Double, swell: Double, phase: Double) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 0, y: 0))
    for x in stride(from: 0.0, through: width, by: 2) {
        let wave = sin(x / 170 + phase) * swell + sin(x / 67 + phase * 2) * swell * 0.28
        path.line(to: CGPoint(x: x, y: flipped(top + wave)))
    }
    path.line(to: CGPoint(x: width, y: 0))
    path.close()
    color(hex).setFill()
    path.fill()
}

func draw() {
    NSGradient(starting: color(0x5A7088), ending: color(0x6E879F))?.draw(in: CGRect(x: 0, y: flipped(310), width: width, height: 310), angle: -90)
    color(0x6E879F).setFill()
    CGRect(x: 0, y: 0, width: width, height: flipped(310)).fill()
    layer(0xC9B596, top: 304, swell: 7, phase: 0.4)
    layer(0xE3AD48, top: 328, swell: 8, phase: 2.1)
    layer(0xD4865A, top: 354, swell: 7, phase: 3.9)
    layer(0x5C6371, top: 380, swell: 6, phase: 5.2)

    let words = NSAttributedString(string: "Drag Unearth to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor.white,
    ])
    let size = words.size()
    words.draw(at: CGPoint(x: middle - size.width / 2, y: flipped(68)))

    // The arrow, from the app to Applications, with a little lift in the middle. The head follows the curve's last direction.
    let (start, end) = (CGPoint(x: middle - 66, y: flipped(170)), CGPoint(x: middle + 66, y: flipped(170)))
    let pull = CGPoint(x: middle + 30, y: flipped(156))
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: CGPoint(x: middle - 30, y: flipped(156)), controlPoint2: pull)
    let heading = atan2(end.y - pull.y, end.x - pull.x)
    let head = NSBezierPath()
    for (index, side) in [Double.pi * 5 / 6, -Double.pi * 5 / 6].enumerated() {
        let tip = CGPoint(x: end.x + 26 * cos(heading + side), y: end.y + 26 * sin(heading + side))
        if index == 0 { head.move(to: tip); head.line(to: end) } else { head.line(to: tip) }
    }
    for path in [arrow, head] {
        path.lineWidth = 7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
    color(0xFFF6E6).setStroke()
    arrow.stroke()
    head.stroke()
}

for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
    let context = CGContext(data: nil, width: Int(width) * scale, height: Int(height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    bitmap.size = NSSize(width: width, height: height)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
