import AppKit
import CoreImage
import SwiftUI

// MARK: - Add BG (`FrameImageOptions`)

/// Background choices: mesh-style gradients first, then solid colors (`FrameBackgroundPreset`).
enum FrameBackground: Hashable {
    case gradient(Int)
    case solid(Int)
    case custom(CodableColorKey)
    case image(URL)

    struct CodableColorKey: Hashable { var red: Double, green: Double, blue: Double }

    /// Radial "mesh" gradients: base color + blobs (x, y, color).
    static let gradients: [(base: NSColor, blobs: [(CGFloat, CGFloat, NSColor)])] = [
        (rgb(0.98, 0.55, 0.35), [(0.0, 0.0, rgb(0.96, 0.45, 0.62)), (1, 0, rgb(0.98, 0.85, 0.30)), (1, 1, rgb(0.45, 0.35, 0.95))]),   // citrus
        (rgb(0.95, 0.96, 1.00), [(0.1, 0.1, rgb(0.55, 0.65, 1.0)), (0.9, 0.2, rgb(1.0, 0.75, 0.75)), (0.5, 1, .white)]),             // whisper
        (rgb(0.85, 0.95, 0.55), [(0, 0, rgb(0.6, 0.95, 0.4)), (1, 0.3, rgb(1.0, 0.6, 0.85)), (0.5, 1, rgb(1, 0.9, 0.3))]),            // meadow
        (rgb(0.99, 0.95, 0.96), [(0.2, 0.3, rgb(0.95, 0.75, 0.82)), (0.9, 0.9, .white)]),                                            // frost
        (rgb(0.90, 0.65, 0.95), [(0.1, 0.9, rgb(1.0, 0.7, 0.6)), (0.9, 0.1, rgb(0.7, 0.55, 1.0))]),                                  // orchid
        (rgb(0.20, 0.45, 0.40), [(0, 0, rgb(0.9, 0.35, 0.35)), (1, 1, rgb(0.25, 0.35, 0.85)), (1, 0, rgb(0.95, 0.75, 0.3))]),        // mesh
        (rgb(0.55, 0.75, 1.00), [(0, 1, rgb(0.6, 0.95, 0.85)), (1, 0, rgb(0.45, 0.45, 1.0))]),                                       // lagoon
        (rgb(0.30, 0.75, 0.90), [(0, 0, rgb(0.5, 0.95, 0.9)), (1, 1, rgb(0.2, 0.55, 0.95))]),                                         // aqua
        (rgb(0.92, 0.88, 1.00), [(0, 0, rgb(0.8, 0.7, 1.0)), (1, 1, rgb(1, 0.85, 0.95))]),                                           // dream
    ]

    static let solids: [NSColor] = [
        rgb(0.98, 0.98, 0.97), rgb(0.95, 0.78, 0.33), rgb(0.68, 0.83, 0.33), rgb(0.33, 0.65, 0.43), rgb(0.27, 0.60, 0.58),
        rgb(0.42, 0.78, 0.87), rgb(0.25, 0.38, 0.85), rgb(0.15, 0.20, 0.32), rgb(0.47, 0.30, 0.78),
    ]

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// Draws the background into `rect` of a CGContext.
    func draw(in context: CGContext, rect: CGRect) {
        switch self {
        case .solid(let index):
            context.setFillColor(Self.solids[index].cgColor)
            context.fill(rect)
        case .custom(let key):
            context.setFillColor(NSColor(srgbRed: key.red, green: key.green, blue: key.blue, alpha: 1).cgColor)
            context.fill(rect)
        case .gradient(let index):
            let definition = Self.gradients[index]
            context.setFillColor(definition.base.cgColor)
            context.fill(rect)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            for (x, y, color) in definition.blobs {
                let center = CGPoint(x: rect.minX + x * rect.width, y: rect.minY + (1 - y) * rect.height)
                let radius = max(rect.width, rect.height) * 0.85
                let colors = [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
                }
            }
        case .image(let url):
            guard let image = try? ImageProcessing.loadCGImage(url) else { return }
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.saveGState()
            context.clip(to: rect)
            context.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
    }

    /// Small swatch for the picker.
    @ViewBuilder var swatch: some View {
        switch self {
        case .gradient(let index):
            let definition = Self.gradients[index]
            ZStack {
                Color(nsColor: definition.base)
                ForEach(Array(definition.blobs.enumerated()), id: \.offset) { _, blob in
                    RadialGradient(colors: [Color(nsColor: blob.2), Color(nsColor: blob.2).opacity(0)],
                                   center: UnitPoint(x: blob.0, y: blob.1), startRadius: 0, endRadius: 40)
                }
            }
        case .solid(let index): Color(nsColor: Self.solids[index])
        case .custom(let key): Color(red: key.red, green: key.green, blue: key.blue)
        case .image: Color.gray
        }
    }
}

enum FrameRatio: String, CaseIterable, Identifiable {
    case automatic = "Auto", square = "1:1", landscape = "16:9", portrait = "4:5"
    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .automatic: return nil
        case .square: return 1
        case .landscape: return 16.0 / 9
        case .portrait: return 4.0 / 5
        }
    }
}

enum FrameRenderer {
    /// Image on a background with padding, rounded corners and shadow (all in source pixels).
    static func render(_ image: CGImage, background: FrameBackground, padding: CGFloat, corners: CGFloat,
                       shadow: CGFloat, ratio: FrameRatio) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        var canvas = CGSize(width: imageSize.width + padding * 2, height: imageSize.height + padding * 2)
        if let target = ratio.value {
            if canvas.width / canvas.height > target { canvas.height = canvas.width / target } else { canvas.width = canvas.height * target }
        }
        guard canvas.width * canvas.height < 400_000_000,
              let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvasRect = CGRect(origin: .zero, size: canvas)
        background.draw(in: context, rect: canvasRect)
        let imageRect = CGRect(x: (canvas.width - imageSize.width) / 2, y: (canvas.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height)
        let path = CGPath(roundedRect: imageRect, cornerWidth: min(corners, imageRect.width / 2), cornerHeight: min(corners, imageRect.height / 2), transform: nil)
        if shadow > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow / 3), blur: shadow, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }
}

// MARK: - Collage (`CollageOptions`)

enum CollageStyleChoice: String, CaseIterable, Identifiable {
    case grid = "Grid", horizontal = "Row", vertical = "Column", featured = "Featured"
    var id: String { rawValue }
}

enum CollageCanvas: String, CaseIterable, Identifiable {
    case square = "Square · 1:1", landscape = "Landscape · 16:9", portrait = "Portrait · 4:5", automatic = "Fit images"
    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .square: return 1
        case .landscape: return 16.0 / 9
        case .portrait: return 4.0 / 5
        case .automatic: return nil
        }
    }
}

enum CollageBackgroundChoice: String, CaseIterable, Identifiable {
    case white = "White", black = "Black", transparent = "Transparent"
    var id: String { rawValue }
}

struct CollageSettings: Equatable {
    var style: CollageStyleChoice = .grid
    var columns = 2
    var canvas: CollageCanvas = .square
    var width = 2048
    var fillImages = true
    var spacing: Double = 8
    var padding: Double = 8
    var cornerRadius: Double = 0
    var background: CollageBackgroundChoice = .white
}

enum CollageRenderer {
    static func cells(count: Int, settings: CollageSettings, canvas: CGSize, aspects: [CGFloat]) -> [CGRect] {
        let inner = CGRect(origin: .zero, size: canvas).insetBy(dx: settings.padding, dy: settings.padding)
        let spacing = settings.spacing
        switch settings.style {
        case .horizontal:
            let width = (inner.width - spacing * CGFloat(count - 1)) / CGFloat(max(count, 1))
            return (0..<count).map { CGRect(x: inner.minX + CGFloat($0) * (width + spacing), y: inner.minY, width: width, height: inner.height) }
        case .vertical:
            let height = (inner.height - spacing * CGFloat(count - 1)) / CGFloat(max(count, 1))
            return (0..<count).map { CGRect(x: inner.minX, y: inner.minY + CGFloat($0) * (height + spacing), width: inner.width, height: height) }
        case .featured:
            guard count > 1 else { return [inner] }
            let mainWidth = (inner.width - spacing) * 0.62
            var rects = [CGRect(x: inner.minX, y: inner.minY, width: mainWidth, height: inner.height)]
            let rest = count - 1
            let height = (inner.height - spacing * CGFloat(rest - 1)) / CGFloat(rest)
            for index in 0..<rest {
                rects.append(CGRect(x: inner.minX + mainWidth + spacing, y: inner.minY + CGFloat(index) * (height + spacing),
                                    width: inner.width - mainWidth - spacing, height: height))
            }
            return rects
        case .grid:
            let columns = max(1, min(settings.columns, count))
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = (inner.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (inner.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            return (0..<count).map { index in
                CGRect(x: inner.minX + CGFloat(index % columns) * (width + spacing), y: inner.minY + CGFloat(index / columns) * (height + spacing),
                       width: width, height: height)
            }
        }
    }

    static func canvasSize(settings: CollageSettings, images: [CGImage]) -> CGSize {
        let width = CGFloat(settings.width)
        if let ratio = settings.canvas.ratio { return CGSize(width: width, height: (width / ratio).rounded()) }
        // Fit images: height follows the grid of average aspect.
        let average = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }.reduce(0, +) / CGFloat(max(images.count, 1))
        let columns = settings.style == .grid ? max(1, min(settings.columns, images.count)) : (settings.style == .horizontal ? images.count : 1)
        let rows = settings.style == .grid ? Int(ceil(Double(images.count) / Double(columns))) : (settings.style == .vertical ? images.count : 1)
        let cellWidth = width / CGFloat(columns)
        return CGSize(width: width, height: (cellWidth / max(average, 0.1) * CGFloat(rows)).rounded())
    }

    static func render(_ images: [CGImage], settings: CollageSettings) -> CGImage? {
        let canvas = canvasSize(settings: settings, images: images)
        guard images.count > 0,
              let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        switch settings.background {
        case .white: context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(origin: .zero, size: canvas))
        case .black: context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(origin: .zero, size: canvas))
        case .transparent: break
        }
        let rects = cells(count: images.count, settings: settings, canvas: canvas, aspects: [])
        for (image, cell) in zip(images, rects) {
            // Cells are top-left based; CGContext is bottom-left.
            let flipped = CGRect(x: cell.minX, y: canvas.height - cell.maxY, width: cell.width, height: cell.height)
            let scale = settings.fillImages
                ? max(flipped.width / CGFloat(image.width), flipped.height / CGFloat(image.height))
                : min(flipped.width / CGFloat(image.width), flipped.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.saveGState()
            let radius = min(settings.cornerRadius, min(flipped.width, flipped.height) / 2)
            context.addPath(CGPath(roundedRect: flipped, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.draw(image, in: CGRect(x: flipped.midX - size.width / 2, y: flipped.midY - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
        return context.makeImage()
    }
}

// MARK: - Annotations (`ImageAnnotation`)

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, freehand, text, rectangle, ellipse, highlighter, number, magnifier, image
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.left"
        case .freehand: return "scribble"
        case .text: return "textformat"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlighter: return "highlighter"
        case .number: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"
        case .image: return "photo.badge.plus"
        }
    }

    /// Hints from the binary's strings.
    var hint: String {
        switch self {
        case .arrow: return "Drag from the tail toward the arrowhead. Drag an annotation to move it."
        case .freehand: return "Drag to draw. Use Clear Drawing to remove all drawn strokes."
        case .text: return "Press Text to add another box. Drag its border to move it and its side handles to change width."
        case .rectangle, .ellipse: return "Drag on the image to draw. Drag an annotation to move it."
        case .highlighter: return "Drag over the image to highlight."
        case .number: return "Click to add numbered callouts; drag to move them. Their size stays fixed."
        case .magnifier: return "Choose a zoom level, then click the detail to place a magnifier bubble."
        case .image: return "Press Image to choose files, or press ⌘V to paste an image. Drag to move or resize it."
        }
    }
}

struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var tool: AnnotationTool
    var start: CGPoint          // normalized, top-left origin
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var number = 0
    var color: CodableColor
    var lineWidth: CGFloat = 0.006   // relative to image width
    var magnification: CGFloat = 2
    var imageURL: URL?

    func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var copy = self
        copy.start.x += dx; copy.start.y += dy; copy.end.x += dx; copy.end.y += dy
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    var bounds: CGRect {
        let all = points + [start, end]
        let xs = all.map(\.x), ys = all.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

enum AnnotationRenderer {
    /// Draws annotations into a context whose size is `size` (y-down coordinates must already be set up).
    static func draw(_ annotations: [Annotation], in context: CGContext, size: CGSize, source: CGImage?) {
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * size.width, y: point.y * size.height) }
        for item in annotations {
            let color = item.color.nsColor.cgColor
            let width = max(1.5, item.lineWidth * size.width)
            context.saveGState()
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let a = p(item.start), b = p(item.end)
            switch item.tool {
            case .arrow:
                context.move(to: a); context.addLine(to: b); context.strokePath()
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = width * 4.5
                context.move(to: b)
                context.addLine(to: CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7)))
                context.move(to: b)
                context.addLine(to: CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7)))
                context.strokePath()
            case .freehand, .highlighter:
                if item.tool == .highlighter {
                    context.setStrokeColor(item.color.nsColor.withAlphaComponent(0.4).cgColor)
                    context.setLineWidth(width * 4)
                    context.setBlendMode(.multiply)
                }
                let points = item.points.map(p)
                guard let first = points.first else { break }
                context.move(to: first)
                points.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            case .rectangle:
                context.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            case .ellipse:
                context.strokeEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            case .number:
                let radius = size.width * 0.022
                context.fillEllipse(in: CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2))
                drawText("\(item.number)", at: CGPoint(x: a.x, y: a.y), size: radius * 1.2, color: .white, context: context, centered: true)
            case .text:
                drawText(item.text, at: a, size: size.width * 0.035, color: item.color.nsColor, context: context, centered: false)
            case .magnifier:
                guard let source else { break }
                let radius = size.width * 0.08
                let circle = CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2)
                context.saveGState()
                context.addEllipse(in: circle)
                context.clip()
                let zoom = item.magnification
                // Source drawn so that point `a` stays centered, magnified.
                context.translateBy(x: a.x, y: a.y)
                context.scaleBy(x: zoom, y: zoom)
                context.translateBy(x: -a.x, y: -a.y)
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(source, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
                context.setLineWidth(width)
                context.strokeEllipse(in: circle)
            case .image:
                guard let url = item.imageURL, let image = try? ImageProcessing.loadCGImage(url) else { break }
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                context.saveGState()
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: rect)
                context.restoreGState()
            }
            context.restoreGState()
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, context: CGContext, centered: Bool) {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let origin = centered ? CGPoint(x: point.x - bounds.width / 2, y: point.y + bounds.height / 2 - bounds.maxY * 0.2)
                              : CGPoint(x: point.x, y: point.y + bounds.height)
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Full-resolution export.
    static func render(_ image: CGImage, annotations: [Annotation]) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Switch to y-down for annotations.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(annotations, in: context, size: size, source: image)
        return context.makeImage()
    }
}
