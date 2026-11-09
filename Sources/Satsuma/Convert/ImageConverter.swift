import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Image ↔ image and image → PDF conversions (ImageIO first, ffmpeg for encoders ImageIO lacks).
enum ImageConverter {
    static func utType(for format: ConversionFormat) -> UTType? {
        switch format {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .webp: return .webP
        case .avif: return UTType("public.avif")
        default: return nil
        }
    }

    static func imageIOCanWrite(_ format: ConversionFormat) -> Bool {
        guard let type = utType(for: format) else { return false }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return writable.contains(type.identifier)
    }

    static func canConvert(to target: ConversionFormat) -> Bool {
        if target == .pdf { return true }
        if target == .webp { return imageIOCanWrite(.webp) || ToolLocator.path("cwebp") != nil }
        return imageIOCanWrite(target)
    }

    static func quality(_ options: ConversionOptions) -> Double {
        switch options.quality {
        case .compact: return 0.65
        case .balanced: return 0.85
        case .high: return 0.96
        }
    }

    /// EXIF orientation of a frame, 1 when it has none.
    static func orientation(of properties: [CFString: Any]) -> Int {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return ((properties[kCGImagePropertyOrientation] ?? tiff?[kCGImagePropertyTIFFOrientation]) as? NSNumber)?.intValue ?? 1
    }

    /// Redraws `image` so its pixels already look the way `orientation` asks for.
    static func upright(_ image: CGImage, orientation: Int) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        let width = orientation >= 5 ? image.height : image.width, height = orientation >= 5 ? image.width : image.height
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? sRGB
        let alpha: CGImageAlphaInfo = !opaque ? .premultipliedLast : (space.model == .rgb ? .noneSkipLast : .none)
        func canvas(_ space: CGColorSpace, _ bits: Int, _ alpha: CGImageAlphaInfo, order: CGBitmapInfo = []) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue | order.rawValue)
        }
        // The HEIC encoder misreads 16-bit samples in any byte order other than the decoder's.
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        // Keeps the source's colour space and depth; the sRGB fallback covers layouts CGContext cannot draw into (grey + alpha, indexed).
        guard let context = canvas(space, bits, alpha, order: bits == 16 ? image.bitmapInfo.intersection(.byteOrderMask) : [])
                ?? canvas(space, bits, alpha)
                ?? canvas(sRGB, 8, opaque ? .noneSkipLast : .premultipliedLast) else { return image }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    /// Loads every frame of the source, upright; SVG is rasterised through NSImage.
    static func loadImages(_ url: URL, format: ConversionFormat) throws -> (images: [CGImage], properties: [CFDictionary?]) {
        if format == .svg {
            guard let image = NSImage(contentsOf: url) else { throw ConversionError.sourceCannotBeRead }
            let scale: CGFloat = 2
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ConversionError.sourceCannotBeRead }
            return ([cg], [nil])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError.sourceCannotBeRead }
        // Further images inside a RAW file are only its embedded previews.
        let count = format == .raw ? min(CGImageSourceGetCount(source), 1) : CGImageSourceGetCount(source)
        var images: [CGImage] = []
        var properties: [CFDictionary?] = []
        for index in 0..<count {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let image = CGImageSourceCreateImageAtIndex(source, index, options) {
                let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                images.append(upright(image, orientation: orientation(of: frameProperties as? [CFString: Any] ?? [:])))
                properties.append(frameProperties)
            }
        }
        guard !images.isEmpty else { throw ConversionError.sourceCannotBeRead }
        return (images, properties)
    }

    static func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat,
                        options: ConversionOptions) async throws -> URL {
        let output = OutputNaming.destination(for: url, extension: target.fileExtension)
        if target == .pdf {
            try writePDF(images: try loadImages(url, format: source).images, to: output)
            return output
        }
        if imageIOCanWrite(target) {
            let (images, properties) = try loadImages(url, format: source)
            // Single-frame targets keep only the first frame.
            let frames = target == .gif || target == .tiff || target == .heic ? images : [images[0]]
            try write(frames, properties: properties, to: output, format: target, options: options)
            return output
        }
        // WebP goes through cwebp, as in the original app (Resources/Tools/cwebp).
        guard target == .webp, let cwebp = ToolLocator.path("cwebp") else { throw ConversionError.unsupportedPair(source, target) }
        var input = url
        var temporary: URL?
        // cwebp would keep the raw pixels of a rotated source, so hand it the upright ones.
        let rotated = source != .svg && orientation(of: ImageProcessing.properties(url)) != 1
        if rotated || ![.png, .jpg, .tiff, .webp].contains(source) {
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-img-")
            let png = folder.appendingPathComponent("frame.png")
            let loaded = try loadImages(url, format: source)
            try write([loaded.images[0]], properties: [rotated ? loaded.properties[0] : nil], to: png, format: .png, options: options)
            input = png
            temporary = folder
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        var arguments = ["-quiet", "-q", String(Int(quality(options) * 100))]
        if options.preserveMetadata { arguments += ["-metadata", "all"] }
        try await ProcessRunner.run(cwebp, arguments + [input.path, "-o", output.path])
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
        return output
    }

    static func write(_ images: [CGImage], properties: [CFDictionary?], to url: URL, format: ConversionFormat,
                      options: ConversionOptions) throws {
        guard let type = utType(for: format),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)
        else { throw ConversionError.encodingFailed("ImageIO could not create the output image.") }
        for (index, image) in images.enumerated() {
            var frameProperties: [CFString: Any] = [:]
            if options.preserveMetadata, index < properties.count, let props = properties[index] as? [CFString: Any] {
                frameProperties = props
            }
            if [.jpg, .heic, .avif, .webp].contains(format) {
                frameProperties[kCGImageDestinationLossyCompressionQuality] = quality(options)
            }
            // `loadImages` already applied the orientation; a surviving tag would rotate the pixels twice.
            if orientation(of: frameProperties) != 1 {
                frameProperties[kCGImagePropertyOrientation] = 1
                if var tiff = frameProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    frameProperties[kCGImagePropertyTIFFDictionary] = tiff
                }
                if var exif = frameProperties[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifPixelXDimension] != nil {
                    exif[kCGImagePropertyExifPixelXDimension] = image.width
                    exif[kCGImagePropertyExifPixelYDimension] = image.height
                    frameProperties[kCGImagePropertyExifDictionary] = exif
                }
            }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed("ImageIO could not finish the image.") }
    }

    static func writePDF(images: [CGImage], to url: URL) throws {
        let document = PDFDocument()
        for image in images {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            if let page = PDFPage(image: nsImage) { document.insert(page, at: document.pageCount) }
        }
        guard document.pageCount > 0, document.write(to: url) else { throw ConversionError.encodingFailed("Could not create the PDF.") }
    }
}
