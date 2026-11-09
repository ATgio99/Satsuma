import AppKit
import ImageIO
import PDFKit
import Quartz
import Vision

/// File tools that run straight from the wheel; the others open a window in `Tools/`.
enum FileToolRunner {
    struct QRResult { var source: String; var page: Int?; var text: String }

    static func run(_ tool: FileTool, urls: [URL], options: ConversionOptions,
                    progress: @escaping (Double) -> Void) async throws -> [URL] {
        switch tool {
        case .compress: return try await mapEach(urls, progress) { try await compress($0) }
        case .removeMetadata: return try await mapEach(urls, progress) { try await removeMetadata($0) }
        case .muteVideo: return try await mapEach(urls, progress) { try await ffmpeg($0, suffix: " muted", ["-c:v", "copy", "-an"]) }
        case .normalizeAudio:
            return try await mapEach(urls, progress) { try await ffmpeg($0, suffix: " normalized", ["-af", "loudnorm=I=-16:LRA=11:TP=-1.5"]) }
        case .splitPDF: return try await mapEach(urls, progress) { try splitPDF($0) }
        case .convertPDFA: return try await mapEach(urls, progress) { try PDFAWriter.convert($0) }
        case .extractArchive: return try await mapEach(urls, progress) { try await ArchiveConverter.extractBeside($0) }
        case .createPDF: return [try createPDF(from: urls)]
        case .mergePDF: return [try mergePDFs(urls)]
        case .joinVideos: return [try await joinVideos(urls)]
        case .createCollage: return [try createCollage(urls)]
        case .readQRCode:
            let results = try readQRCodes(urls)
            await MainActor.run { QRCodeResultsPresenter.present(results) }
            return []
        default:
            throw ConversionError.fileToolUnavailable(tool.title.capitalized)
        }
    }

    private static func mapEach(_ urls: [URL], _ progress: @escaping (Double) -> Void, _ body: (URL) async throws -> URL) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, url) in urls.enumerated() {
            outputs.append(try await body(url))
            progress(Double(index + 1) / Double(urls.count))
        }
        return outputs
    }

    // MARK: Compress

    static func compress(_ url: URL) async throws -> URL {
        guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        switch format.group {
        case .images:
            var options = SettingsModel.shared.defaultOptions
            options.quality = .compact
            options.preserveMetadata = false
            let target: ConversionFormat = [.png, .bmp, .tiff, .raw].contains(format) ? .jpg : (format == .svg ? .png : format)
            let output = OutputNaming.destination(for: url, extension: target.fileExtension, suffix: " compressed")
            let (images, _) = try ImageConverter.loadImages(url, format: format)
            if target == .webp {
                let converted = try await ImageConverter.convert(url, from: format, to: .webp, options: options)
                try FileManager.default.moveItem(at: converted, to: output)
            } else {
                try ImageConverter.write([images[0]], properties: [nil], to: output, format: target, options: options)
            }
            return try keepSmaller(output, than: url)
        case .documents where format == .pdf:
            guard let document = PDFDocument(url: url) else { throw ConversionError.sourceCannotBeRead }
            let output = OutputNaming.destination(for: url, extension: "pdf", suffix: " compressed")
            guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else {
                throw ConversionError.encodingFailed("The macOS PDF compression filter is unavailable.")
            }
            guard document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw ConversionError.encodingFailed("Could not create the compressed PDF.")
            }
            return try keepSmaller(output, than: url)
        case .video:
            return try keepSmaller(try await ffmpeg(url, suffix: " compressed", ["-c:v", "libx264", "-crf", "28", "-preset", "slow", "-pix_fmt", "yuv420p", "-vf", MediaConverter.evenSize, "-c:a", "aac", "-b:a", "128k"], ext: "mp4"), than: url)
        case .audio:
            return try keepSmaller(try await ffmpeg(url, suffix: " compressed", ["-vn", "-c:a", "aac", "-b:a", "96k"], ext: "m4a"), than: url)
        default:
            throw ConversionError.fileToolUnavailable("Compress")
        }
    }

    private static func keepSmaller(_ output: URL, than source: URL) throws -> URL {
        let new = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let old = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if new >= old && old > 0 {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.encodingFailed("Compressed output would exceed the original or target file size.")
        }
        return output
    }

    // MARK: Metadata

    static func removeMetadata(_ url: URL) async throws -> URL {
        guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        switch format.group {
        case .images where format == .raw:
            // ImageIO cannot write camera RAW, so the clean copy is a PNG of the decoded image.
            let output = OutputNaming.destination(for: url, extension: "png", suffix: " no metadata")
            try ImageConverter.write([try ImageProcessing.loadCGImage(url)], properties: [nil], to: output, format: .png, options: ConversionOptions())
            return output
        case .images where format != .svg:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
                throw ConversionError.sourceCannotBeRead
            }
            let output = OutputNaming.destination(for: url, extension: url.pathExtension, suffix: " no metadata")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, CGImageSourceGetCount(source), nil) else {
                throw ConversionError.encodingFailed("ImageIO could not create the output image.")
            }
            // Copy pixels and orientation only; drop EXIF, GPS, IPTC and XMP.
            let removals: [CFString: Any] = [kCGImagePropertyExifDictionary: kCFNull!, kCGImagePropertyGPSDictionary: kCFNull!,
                                             kCGImagePropertyIPTCDictionary: kCFNull!, kCGImagePropertyTIFFDictionary: kCFNull!,
                                             kCGImageDestinationMetadata: kCFNull!]
            for index in 0..<CGImageSourceGetCount(source) {
                CGImageDestinationAddImageFromSource(destination, source, index, removals as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed("The image could not be verified. No output was saved.") }
            return output
        case .documents where format == .pdf:
            guard let document = PDFDocument(url: url) else { throw ConversionError.sourceCannotBeRead }
            document.documentAttributes = [:]
            let output = OutputNaming.destination(for: url, extension: "pdf", suffix: " no metadata")
            guard document.write(to: output) else { throw ConversionError.encodingFailed("PDFKit could not write the cleaned PDF.") }
            return output
        case .audio, .video:
            return try await ffmpeg(url, suffix: " no metadata", ["-map_metadata", "-1", "-c", "copy"])
        default:
            throw ConversionError.fileToolUnavailable("Remove Metadata")
        }
    }

    // MARK: PDF

    static func splitPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw ConversionError.encodingFailed("This PDF has no pages.") }
        let folder = OutputNaming.unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " pages"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: folder.appendingPathComponent(String(format: "Page %03d.pdf", index + 1)))
        }
        return folder
    }

    static func createPDF(from urls: [URL]) throws -> URL {
        let document = PDFDocument()
        for url in urls {
            guard let format = ConversionFormat.detect(url) else { continue }
            for image in try ImageConverter.loadImages(url, format: format).images {
                if let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) {
                    document.insert(page, at: document.pageCount)
                }
            }
        }
        let output = OutputNaming.destination(for: urls[0], extension: "pdf", suffix: urls.count > 1 ? " and \(urls.count - 1) more" : "")
        guard document.pageCount > 0, document.write(to: output) else { throw ConversionError.encodingFailed("Could not create the PDF.") }
        return output
    }

    static func mergePDFs(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { throw ConversionError.sourceCannotBeRead }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let output = OutputNaming.destination(for: urls[0], extension: "pdf", suffix: " merged")
        guard merged.write(to: output) else { throw ConversionError.encodingFailed("PDFKit could not write the combined PDF.") }
        return output
    }

    // MARK: Media

    static func ffmpeg(_ url: URL, suffix: String, _ arguments: [String], ext: String? = nil) async throws -> URL {
        guard let ffmpeg = ToolLocator.ffmpeg else { throw ConversionError.missingTool("ffmpeg") }
        let output = OutputNaming.destination(for: url, extension: ext ?? url.pathExtension, suffix: suffix)
        try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url.path] + arguments + [output.path])
        return output
    }

    /// anullsrc options matching a clip's first audio stream, nil when it has none.
    /// Asks ffprobe because AVFoundation (MediaFacts) cannot see inside MKV or WebM clips.
    private static func silenceFormat(of url: URL, ffprobe: String) async throws -> String? {
        let text = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate,channels",
                                                         "-of", "csv=p=0", url.path])
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
        guard fields.count >= 2 else { return nil }
        return "r=\(fields[0]):cl=\(fields[1])c"
    }

    static func joinVideos(_ urls: [URL]) async throws -> URL {
        guard urls.count >= 2 else { throw ConversionError.invalidFileToolOptions("Select at least two videos to join.") }
        guard let ffmpeg = ToolLocator.ffmpeg else { throw ConversionError.missingTool("ffmpeg") }
        guard let ffprobe = ToolLocator.ffprobe else { throw ConversionError.missingTool("ffprobe") }
        var formats: [String?] = []
        for url in urls { formats.append(try await silenceFormat(of: url, ffprobe: ffprobe)) }
        // Clips without sound get silence as long as the clip, so later audio stays in sync. No sound anywhere: no audio stream.
        let silenceOptions = formats.compactMap { $0 }.first
        var silence = ""
        var audioLabels = urls.indices.map { _ in "" }
        if let silenceOptions {
            for index in urls.indices {
                audioLabels[index] = "[\(index):a:0]"
                guard formats[index] == nil else { continue }
                // Piped WebM has no duration in its header; concat pads a short stream to the clip's video anyway.
                let duration = await MediaConverter.duration(of: urls[index]).flatMap { $0 > 0 ? $0 : nil } ?? 0.04
                silence += "anullsrc=\(silenceOptions),atrim=duration=\(duration)[a\(index)];"
                audioLabels[index] = "[a\(index)]"
            }
        }
        let hasAudio = silenceOptions != nil
        let output = OutputNaming.destination(for: urls[0], extension: "mp4", suffix: " joined")
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
        for url in urls { arguments += ["-i", url.path] }
        let inputs = urls.indices.map { "[\($0):v:0]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[v\($0)];" }.joined()
        let concat = urls.indices.map { "[v\($0)]\(audioLabels[$0])" }.joined() + "concat=n=\(urls.count):v=1:a=\(hasAudio ? 1 : 0)[v]\(hasAudio ? "[a]" : "")"
        arguments += ["-filter_complex", inputs + silence + concat, "-map", "[v]"] + (hasAudio ? ["-map", "[a]"] : [])
        arguments += ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p"] + (hasAudio ? ["-c:a", "aac"] : []) + [output.path]
        do {
            try await ProcessRunner.run(ffmpeg, arguments)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: Collage (grid style defaults)

    static func createCollage(_ urls: [URL]) throws -> URL {
        let images = try urls.compactMap { url -> CGImage? in
            guard let format = ConversionFormat.detect(url) else { return nil }
            return try ImageConverter.loadImages(url, format: format).images.first
        }
        guard !images.isEmpty else { throw ConversionError.sourceCannotBeRead }
        let columns = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let width = 2400.0, spacing = 16.0, padding = 16.0
        let cell = (width - padding * 2 - spacing * Double(columns - 1)) / Double(columns)
        let height = padding * 2 + cell * Double(rows) + spacing * Double(rows - 1)
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.encodingFailed("Could not create the collage canvas.")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let frame = CGRect(x: padding + Double(column) * (cell + spacing), y: height - padding - Double(row + 1) * cell - Double(row) * spacing, width: cell, height: cell)
            // Fill cells (crop edges).
            let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.saveGState()
            context.clip(to: frame)
            context.draw(image, in: CGRect(x: frame.midX - drawSize.width / 2, y: frame.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height))
            context.restoreGState()
        }
        guard let collage = context.makeImage() else { throw ConversionError.encodingFailed("Could not render the collage.") }
        let output = OutputNaming.destination(for: urls[0], extension: "png", suffix: " collage")
        try ImageConverter.write([collage], properties: [nil], to: output, format: .png, options: ConversionOptions())
        return output
    }

    // MARK: QR codes (Vision)

    static func readQRCodes(_ urls: [URL]) throws -> [QRResult] {
        var results: [QRResult] = []
        func scan(_ image: CGImage, name: String, page: Int?) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            for observation in request.results ?? [] {
                if let text = observation.payloadStringValue { results.append(QRResult(source: name, page: page, text: text)) }
            }
        }
        for url in urls {
            guard let format = ConversionFormat.detect(url) else { continue }
            if format == .pdf, let document = PDFDocument(url: url) {
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index), let image = PDFPageExporter.image(of: page, scale: 2) {
                        scan(image, name: url.lastPathComponent, page: index + 1)
                    }
                }
            } else {
                for image in try ImageConverter.loadImages(url, format: format).images { scan(image, name: url.lastPathComponent, page: nil) }
            }
        }
        return results
    }
}
