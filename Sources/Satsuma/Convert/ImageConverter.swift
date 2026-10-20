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
        case .compact: return 0.6
        case .balanced: return 0.82
        case .high: return 0.94
        }
    }

    /// Loads every frame of the source; SVG is rasterised through NSImage.
    static func loadImages(_ url: URL, format: ConversionFormat) throws -> (images: [CGImage], properties: [CFDictionary?]) {
        if format == .svg {
            guard let image = NSImage(contentsOf: url) else { throw ConversionError.sourceCannotBeRead }
            let scale: CGFloat = 2
            var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ConversionError.sourceCannotBeRead }
            return ([cg], [nil])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError.sourceCannotBeRead }
        let count = CGImageSourceGetCount(source)
        var images: [CGImage] = []
        var properties: [CFDictionary?] = []
        for index in 0..<count {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let image = CGImageSourceCreateImageAtIndex(source, index, options) {
                images.append(image)
                properties.append(CGImageSourceCopyPropertiesAtIndex(source, index, nil))
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
        if ![.png, .jpg, .tiff, .webp].contains(source) {
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-img-")
            let png = folder.appendingPathComponent("frame.png")
            try write([try loadImages(url, format: source).images[0]], properties: [nil], to: png, format: .png, options: options)
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
            frameProperties[kCGImagePropertyOrientation] = nil
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
