// Builds AppIcon.iconset from a square artwork: crops the rounded tile, masks it to the macOS
// icon shape (824 pt body on a 1024 canvas) and writes every required size.
// usage: swift make_icon.swift <artwork.png> <out.iconset> [cropInset]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let source = NSImage(contentsOfFile: arguments[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make_icon.swift artwork.png out.iconset [cropInset]"); exit(1)
}
let inset = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
let side = Double(min(cg.width, cg.height))
let crop = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
guard let tile = cg.cropping(to: crop) else { exit(1) }

func render(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.2237, cornerHeight: body.width * 0.2237, transform: nil)
    context.addPath(path)
    context.clip()
    context.interpolationQuality = .high
    context.draw(tile, in: body)
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let out = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale)?.write(to: out.appendingPathComponent(name))
    }
}
print("ok")
