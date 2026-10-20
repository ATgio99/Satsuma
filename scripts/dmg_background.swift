// Draws the DMG window background (760×440 pt) at 1× and 2×: usage `swift dmg_background.swift out.png out@2x.png`.
// Icon centers used by make_dmg.sh: Satsuma at (200, 210), Applications at (560, 210), in points from the top left.
import AppKit

let size = NSSize(width: 760, height: 440)
let accent = NSColor(srgbRed: 1, green: 0x52 / 255, blue: 0, alpha: 1)

func draw() {
    // Warm paper gradient.
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.975, blue: 0.945, alpha: 1),
                        NSColor(srgbRed: 1, green: 0.925, blue: 0.86, alpha: 1)])!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Soft glows behind the two icon slots.
    for x in [200.0, 560.0] {
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)])!
        glow.draw(fromCenter: NSPoint(x: x, y: 210), radius: 0, toCenter: NSPoint(x: x, y: 210), radius: 115, options: [])
    }

    // Title.
    let rounded = NSFont.systemFont(ofSize: 30, weight: .bold).fontDescriptor.withDesign(.rounded)
    let titleFont = rounded.flatMap { NSFont(descriptor: $0, size: 30) } ?? .boldSystemFont(ofSize: 30)
    let title = NSAttributedString(string: "Satsuma", attributes: [.font: titleFont, .foregroundColor: accent])
    title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: 38))

    // Curved arrow from the app to Applications.
    let tip = NSPoint(x: 468, y: 208)
    let control2 = NSPoint(x: 432, y: 166)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 292, y: 208))
    arrow.curve(to: tip, controlPoint1: NSPoint(x: 328, y: 166), controlPoint2: control2)
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    accent.withAlphaComponent(0.9).setStroke()
    arrow.stroke()

    // Arrowhead wings: 20 pt long, 38° either side of the curve's direction at the tip.
    let angle = atan2(tip.y - control2.y, tip.x - control2.x)
    func wing(_ offset: CGFloat) -> NSPoint {
        let a = angle + .pi + offset
        return NSPoint(x: tip.x + 20 * cos(a), y: tip.y + 20 * sin(a))
    }
    let head = NSBezierPath()
    head.move(to: wing(0.66))
    head.line(to: tip)
    head.line(to: wing(-0.66))
    head.lineWidth = 7
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Hint.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let hint = NSAttributedString(string: "Drag Satsuma onto Applications to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(white: 0.35, alpha: 1),
        .paragraphStyle: style,
    ])
    hint.draw(in: NSRect(x: 0, y: 360, width: size.width, height: 22))
}

func render(scale: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    // The rep's size is in points, so the context already maps points to pixels; only flip it so the
    // coordinates above read from the top left, like Finder's icon positions.
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
render(scale: 1, to: arguments[1])
render(scale: 2, to: arguments[2])
