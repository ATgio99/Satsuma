import Foundation

/// Which pairs can actually run on this Mac.
enum ConverterAvailability {
    static func isAvailable(source: ConversionFormat, target: ConversionFormat) -> Bool {
        switch (source.group, target.group) {
        case (.images, .images): return ImageConverter.canConvert(to: target)
        case (.images, .documents): return target == .pdf
        case (.audio, .audio), (.video, .video), (.video, .audio): return MediaConverter.isAvailable
        case (.archives, .archives): return true
        case (.subtitles, _): return [.srt, .vtt, .txt].contains(target)
        case (.spreadsheets, _):
            if source == .xls || source == .ods { return ToolLocator.hasNumbers && [.xlsx, .csv, .tsv, .pdf].contains(target) }
            return [.xlsx, .csv, .tsv, .pdf].contains(target)
        case (.documents, _):
            return documentPair(source, target)
        default:
            return false
        }
    }

    static func documentPair(_ source: ConversionFormat, _ target: ConversionFormat) -> Bool {
        if target == .pages && !ToolLocator.hasPages { return false }
        if source == .pages && !ToolLocator.hasPages { return false }
        switch source {
        case .pdf: return [.docx, .pages, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md].contains(target)
        case .ppt, .pptx: return ToolLocator.hasKeynote && [.pdf, .jpg, .png].contains(target)
        case .epub: return [.pdf, .docx, .pages, .txt, .md, .html].contains(target)
        case .docx, .pages, .txt, .md, .rtf, .rtfd, .textClipping, .html:
            return [.docx, .pages, .pdf, .txt, .md, .html, .epub, .png, .jpg].contains(target)
        default: return false
        }
    }
}

/// Runs one conversion and returns the output URL (saved beside the original).
enum ConversionEngine {
    static func convert(_ url: URL, to target: ConversionFormat, options: ConversionOptions,
                        progress: @escaping (Double) -> Void) async throws -> URL {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ConversionError.sourceCannotBeRead }
        guard let source = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
        guard ActionRegistry.supports(source, target) else { throw ConversionError.unsupportedPair(source, target) }

        switch (source.group, target.group) {
        case (.images, _):
            return try await ImageConverter.convert(url, from: source, to: target, options: options)
        case (.audio, _), (.video, _):
            return try await MediaConverter.convert(url, from: source, to: target, options: options, progress: progress)
        case (.archives, _):
            return try await ArchiveConverter.convert(url, from: source, to: target)
        case (.subtitles, _):
            return try SubtitleConverter.convert(url, to: target)
        case (.spreadsheets, _):
            return try await SpreadsheetConverter.convert(url, from: source, to: target)
        case (.documents, _):
            if source == .pdf {
                return try await PDFConverter.convert(url, to: target, options: options, progress: progress)
            }
            if source == .ppt || source == .pptx {
                let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-slides-")
                defer { try? FileManager.default.removeItem(at: folder) }
                let pdf = target == .pdf ? OutputNaming.destination(for: url, extension: "pdf") : folder.appendingPathComponent("slides.pdf")
                try await IWorkBridge.keynoteToPDF(url, output: pdf)
                if target == .pdf { return pdf }
                return try PDFPageExporter.export(pdf, format: target, beside: url, scale: 2)
            }
            return try await convertDocument(url, from: source, to: target)
        default:
            throw ConversionError.unsupportedPair(source, target)
        }
    }

    @MainActor
    private static func convertDocument(_ url: URL, from source: ConversionFormat, to target: ConversionFormat) async throws -> URL {
        let text = try await DocumentIO.load(url, format: source)
        guard text.length > 0 else { throw ConversionError.encodingFailed("The document is empty or exceeds the 128 MB import limit.") }
        let output = try await DocumentIO.write(text, to: target, beside: url, title: url.deletingPathExtension().lastPathComponent)
        guard FileManager.default.fileExists(atPath: output.path) else { throw ConversionError.outputMissing }
        return output
    }
}
