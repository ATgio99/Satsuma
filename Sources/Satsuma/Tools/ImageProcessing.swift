import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

/// Pixel work behind the image tools.
enum ImageProcessing {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func loadCGImage(_ url: URL) throws -> CGImage {
        guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        return try ImageConverter.loadImages(url, format: format).images[0]
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return props
    }

    /// Writes `image` beside `source` in the source's own format (PNG for SVG/BMP sources with alpha).
    static func save(_ image: CGImage, beside source: URL, suffix: String, quality: Double = 0.92, keepMetadata: Bool = true) throws -> URL {
        let format = ConversionFormat.detect(source) ?? .png
        let target: ConversionFormat = [.svg, .avif, .bmp, .webp, .raw].contains(format) ? .png : format
        let output = OutputNaming.destination(for: source, extension: target.fileExtension, suffix: suffix)
        var options = ConversionOptions()
        options.quality = quality > 0.9 ? .high : quality > 0.7 ? .balanced : .compact
        options.preserveMetadata = keepMetadata
        let props: CFDictionary? = keepMetadata ? (properties(source) as CFDictionary) : nil
        try ImageConverter.write([image], properties: [props], to: output, format: target, options: options)
        return output
    }

    static func render(_ image: CIImage, extent: CGRect? = nil) -> CGImage? {
        ciContext.createCGImage(image, from: extent ?? image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Resize

    static func resized(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return render(ci) ?? image
    }

    // MARK: Crop

    static func crop(_ image: CGImage, to rect: NormalizedRect, outputSize: CGSize? = nil) -> CGImage? {
        let pixel = CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height),
                           width: rect.width * Double(image.width), height: rect.height * Double(image.height)).integral
        guard let cropped = image.cropping(to: pixel) else { return nil }
        guard let outputSize, outputSize.width > 0, outputSize.height > 0,
              Int(outputSize.width) != cropped.width || Int(outputSize.height) != cropped.height else { return cropped }
        let ci = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: outputSize.width / CGFloat(cropped.width),
                                                                              y: outputSize.height / CGFloat(cropped.height)))
        return render(ci)
    }

    // MARK: Photo adjustments (`ImageAdjustments`)

    static func adjusted(_ input: CIImage, _ a: ImageAdjustmentValues) -> CIImage {
        var image = input
        let extent = input.extent
        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness / 400, kCIInputContrastKey: 1 + a.contrast / 200, kCIInputSaturationKey: 1 + a.saturation / 100])
        }
        if a.highlights != 0 || a.shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - max(0, -a.highlights) / 100 + max(0, a.highlights) / 200, "inputShadowAmount": a.shadows / 100])
        }
        if a.whites != 0 || a.blacks != 0 {
            let lift = a.blacks / 400, top = 1 + a.whites / 400
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: max(0, lift)), "inputPoint1": CIVector(x: 0.25, y: 0.25 + lift * 0.6),
                "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: min(1, 0.75 * top)), "inputPoint4": CIVector(x: 1, y: min(1, top))])
        }
        if a.gamma != 0 { image = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -a.gamma / 100)]) }
        if a.temperature != 0 || a.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 30, y: a.tint)])
        }
        if a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance / 100]) }
        if a.hue != 0 { image = image.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180]) }
        if a.dehaze != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + a.dehaze / 250, kCIInputSaturationKey: 1 + a.dehaze / 300])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -a.dehaze / 300])
        }
        if a.clarity != 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 20, kCIInputIntensityKey: a.clarity / 150])
        }
        if a.texture != 0 {
            image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 4, kCIInputIntensityKey: a.texture / 120])
        }
        if a.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness / 50]) }
        if a.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": a.noiseReduction / 2500, kCIInputSharpnessKey: 0.4])
        }
        if a.fade > 0 {
            let f = a.fade / 300
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - f, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1 - f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - f, w: 0), "inputBiasVector": CIVector(x: f, y: f, z: f, w: 0)])
        }
        if a.blur > 0 { image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: a.blur / 4]).cropped(to: extent) }
        if a.vignette != 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette / 50, kCIInputRadiusKey: max(extent.width, extent.height) / 900])
        }
        if a.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a.grain / 500),
                    "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
                .cropped(to: extent)
            image = noise.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
        }
        return image.cropped(to: extent)
    }

    // MARK: Redaction

    static func redact(_ image: CGImage, rects: [NormalizedRect], blur: Bool) -> CGImage? {
        var output = CIImage(cgImage: image)
        let size = CGSize(width: image.width, height: image.height)
        for rect in rects {
            // CoreImage is bottom-left origin.
            var r = rect.rect(in: size)
            r.origin.y = size.height - r.maxY
            if blur {
                let radius = max(r.width, r.height) / 6
                let blurred = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, radius / 2), kCIInputCenterKey: CIVector(x: r.midX, y: r.midY)])
                    .cropped(to: r)
                output = blurred.composited(over: output)
            } else {
                output = CIImage(color: CIColor(cgColor: rect.color.nsColor.cgColor)).cropped(to: r).composited(over: output)
            }
        }
        return render(output, extent: CGRect(origin: .zero, size: size))
    }

    /// Vision face / text detection, returned as normalized top-left rects.
    static func detect(_ kind: PhotoDetection, in image: CGImage) -> [NormalizedRect] {
        let request: VNImageBasedRequest
        switch kind {
        case .faces: request = VNDetectFaceRectanglesRequest()
        case .text:
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            request = text
        }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let boxes: [CGRect] = (request.results as? [VNDetectedObjectObservation])?.map(\.boundingBox) ?? []
        return boxes.map { box in
            let pad = 0.12
            let width = box.width * (1 + pad), height = box.height * (1 + pad * 2)
            return NormalizedRect(x: max(0, box.midX - width / 2), y: max(0, 1 - box.midY - height / 2),
                                  width: min(1, width), height: min(1, height))
        }
    }

    enum PhotoDetection { case faces, text }

    // MARK: Compression

    struct CompressionPlan {
        var strong = false
        var maxDimension: CGFloat?
        var targetBytes: Int64?
    }

    static func compressImage(_ url: URL, plan: CompressionPlan) throws -> URL {
        guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        var image = try loadCGImage(url)
        if let maxDimension = plan.maxDimension { image = resized(image, maxDimension: maxDimension) }
        let target: ConversionFormat = format == .raw ? .jpg : [.png, .bmp, .tiff, .svg].contains(format) && plan.targetBytes == nil && format != .png ? .jpg : (format == .svg || format == .bmp ? .png : format)
        let output = OutputNaming.destination(for: url, extension: target.fileExtension, suffix: " compressed")
        func encode(_ img: CGImage, quality: Double) throws -> Int64 {
            var options = ConversionOptions()
            options.preserveMetadata = false
            if target == .png {
                try ImageConverter.write([img], properties: [nil], to: output, format: .png, options: options)
            } else if target == .webp && !ImageConverter.imageIOCanWrite(.webp) {
                try encodeWebP(img, quality: quality, to: output)
            } else {
                guard let type = ImageConverter.utType(for: target),
                      let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
                    throw ConversionError.encodingFailed("ImageIO could not create the compressed JPEG.")
                }
                CGImageDestinationAddImage(destination, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed("ImageIO could not finish the compressed JPEG.") }
            }
            return ToolFormat.fileSize(output) ?? 0
        }
        if let targetBytes = plan.targetBytes {
            // Lower the quality, then the dimensions, until the file fits.
            // Quality does nothing for lossless formats, so one encode per size is enough there.
            let attempts = [.jpg, .heic, .avif, .webp].contains(target) ? 7 : 1
            var current = image
            for _ in 0..<20 {
                var low = 0.05, high = 0.95, best: Double?
                for _ in 0..<attempts {
                    let mid = (low + high) / 2
                    if try encode(current, quality: mid) <= targetBytes { best = mid; low = mid } else { high = mid }
                }
                if let best { _ = try encode(current, quality: best); return output }
                guard max(current.width, current.height) >= 16 else { break }
                current = resized(current, maxDimension: CGFloat(max(current.width, current.height)) * 0.75)
            }
            let smallest = ToolFormat.fileSize(output) ?? 0
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.encodingFailed("Could not reach the target size. Smallest attempt was \(ToolFormat.bytes(smallest)).")
        }
        let size = try encode(image, quality: plan.strong ? 0.5 : 0.72)
        if let original = ToolFormat.fileSize(url), size >= original, plan.maxDimension == nil {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.encodingFailed("Compressed output would exceed the original or target file size.")
        }
        return output
    }

    /// ImageIO has no WebP writer on current macOS, so this goes through cwebp like `ImageConverter`.
    private static func encodeWebP(_ image: CGImage, quality: Double, to output: URL) throws {
        guard let cwebp = ToolLocator.path("cwebp") else { throw ConversionError.missingTool("cwebp") }
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-img-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("frame.png")
        try ImageConverter.write([image], properties: [nil], to: png, format: .png, options: ConversionOptions())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cwebp)
        process.arguments = ["-quiet", "-q", String(Int(quality * 100)), png.path, "-o", output.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ConversionError.encodingFailed("cwebp could not create the compressed WebP.") }
    }

    static func compressPDF(_ url: URL, plan: CompressionPlan) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConversionError.encodingFailed("This PDF cannot be read or is password-protected.") }
        let output = OutputNaming.destination(for: url, extension: "pdf", suffix: " compressed")
        if !plan.strong && plan.targetBytes == nil {
            guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else {
                throw ConversionError.encodingFailed("The macOS PDF compression filter is unavailable.")
            }
            guard document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw ConversionError.encodingFailed("Could not create the compressed PDF.")
            }
            return output
        }
        // Strong / target size: re-render pages as JPEG.
        for (scale, quality) in [(1.5, 0.6), (1.25, 0.45), (1.0, 0.35), (0.8, 0.3), (0.6, 0.25)] {
            let rebuilt = PDFDocument()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let image = PDFPageExporter.image(of: page, scale: scale) else { continue }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                CGImageDestinationFinalize(destination)
                guard let jpeg = NSImage(data: data as Data) else { continue }
                jpeg.size = page.bounds(for: .mediaBox).size
                if let newPage = PDFPage(image: jpeg) { rebuilt.insert(newPage, at: rebuilt.pageCount) }
            }
            guard rebuilt.write(to: output) else { throw ConversionError.encodingFailed("Could not create the compressed PDF.") }
            if let target = plan.targetBytes, let size = ToolFormat.fileSize(output), size > target { continue }
            return output
        }
        if plan.targetBytes != nil {
            throw ConversionError.encodingFailed("Could not reach the target size. Smallest attempt was \(ToolFormat.bytes(ToolFormat.fileSize(output) ?? 0)).")
        }
        return output
    }
}

/// Values for Edit Photo (`ImageAdjustments`).
struct ImageAdjustmentValues: Equatable {
    var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0, gamma = 0.0
    var temperature = 0.0, tint = 0.0, saturation = 0.0, vibrance = 0.0, hue = 0.0
    var clarity = 0.0, texture = 0.0, sharpness = 0.0, dehaze = 0.0, noiseReduction = 0.0
    var fade = 0.0, vignette = 0.0, grain = 0.0, blur = 0.0
}

/// exiftool bridge for the Metadata window (the original app bundles ExifTool; Satsuma uses the installed one).
enum MetadataTool {
    struct Field: Identifiable, Equatable {
        var id: String { key }
        let group: String
        let name: String
        let key: String         // "Group:Tag"
        let original: String
        var value: String
        var editable: Bool
        var removed = false
    }

    static var exiftool: String? { ToolLocator.path("exiftool") }

    static let readOnlyGroups: Set<String> = ["File", "System", "Composite", "ExifTool"]

    static func read(_ url: URL) async throws -> [Field] {
        guard let exiftool else { throw ConversionError.missingTool("ExifTool") }
        let json = try await ProcessRunner.run(exiftool, ["-j", "-G1", "-a", "-s", "-api", "LargeFileSupport=1", url.path])
        guard let data = json.data(using: .utf8),
              let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let first = objects.first else { return [] }
        return first.compactMap { key, value -> Field? in
            guard key != "SourceFile" else { return nil }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let group = parts.count == 2 ? parts[0] : "Other"
            let tag = parts.last ?? key
            let text = "\(value)"
            if text.hasPrefix("(Binary data") { return nil }
            let name = tag.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            return Field(group: group, name: name, key: key, original: text, value: text, editable: !readOnlyGroups.contains(group))
        }
        .sorted { ($0.group, $0.name) < ($1.group, $1.name) }
    }

    static func write(_ url: URL, fields: [Field], removeAll: Bool) async throws -> URL {
        guard let exiftool else { throw ConversionError.missingTool("ExifTool") }
        let suffix = removeAll ? " no metadata" : " edited"
        let output = OutputNaming.destination(for: url, extension: url.pathExtension, suffix: suffix)
        var arguments = ["-o", output.path]
        if removeAll {
            arguments += ["-all=", "-tagsfromfile", "@", "-ColorSpaceTags", "-Orientation"]
        } else {
            for field in fields where field.editable {
                if field.removed { arguments.append("-\(field.key)=") }
                else if field.value != field.original { arguments.append("-\(field.key)=\(field.value)") }
            }
        }
        try await ProcessRunner.run(exiftool, arguments + [url.path])
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
        return output
    }
}
