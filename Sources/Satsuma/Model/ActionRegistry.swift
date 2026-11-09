import Foundation

/// Decides which petals a wheel shows for the dropped files.
enum ActionRegistry {
    // MARK: Conversion outputs, in petal order

    static func candidates(for source: ConversionFormat) -> [ConversionFormat] {
        switch source {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp, .raw:
            return [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
        case .pdf:
            return [.docx, .pages, .pptx, .xlsx, .jpg, .png, .svg, .epub, .txt, .md]
        case .docx, .pages, .txt, .md, .rtf, .rtfd, .textClipping, .html:
            return [.docx, .pages, .pdf, .txt, .md, .html, .epub, .png, .jpg]
        case .epub:
            return [.pdf, .docx, .pages, .txt, .md, .html]
        case .ppt, .pptx:
            return [.pdf, .jpg, .png]
        case .xlsx, .xls, .ods, .csv, .tsv:
            return [.xlsx, .xls, .ods, .csv, .tsv, .pdf]
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            return [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
        case .gif:
            return [.mp4, .mov, .mkv, .webm, .avi, .wmv]
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            return [.mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma]
        case .zip:
            return [.tar, .gzip]
        case .tar:
            return [.zip, .gzip]
        case .gzip:
            return [.zip, .tar]
        case .rar:
            return [.zip, .tar, .gzip]
        case .srt:
            return [.vtt, .txt]
        case .vtt:
            return [.srt, .txt]
        }
    }

    /// Group-level candidates used when the files have different formats in one group.
    static func candidates(forGroup group: ConversionFormat.Group) -> [ConversionFormat] {
        switch group {
        case .images: return [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf]
        case .audio: return candidates(for: .mp3)
        case .video: return [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3]
        case .documents: return [.pdf, .docx, .pages, .txt, .md, .html]
        case .spreadsheets: return candidates(for: .csv)
        case .archives: return [.zip, .tar, .gzip]
        case .subtitles: return [.srt, .vtt]
        }
    }

    /// Pair-support predicates.
    static func supports(_ source: ConversionFormat, _ target: ConversionFormat) -> Bool {
        guard source != target, !target.isInputOnly else { return false }
        return ConverterAvailability.isAvailable(source: source, target: target)
    }

    static func conversionOutputs(for formats: [ConversionFormat]) -> [ConversionFormat] {
        guard let first = formats.first else { return [] }
        if formats.allSatisfy({ $0 == first }) {
            return candidates(for: first).filter { supports(first, $0) }
        }
        guard formats.allSatisfy({ $0.group == first.group }) else { return [] }
        return candidates(forGroup: first.group).filter { target in
            formats.allSatisfy { $0 == target || supports($0, target) } && !formats.allSatisfy { $0 == target }
        }
    }

    // MARK: Tools

    static func tools(for format: ConversionFormat, count: Int) -> [FileTool] {
        switch format {
        case .jpg, .png, .webp, .heic, .tiff:
            return count > 1
                ? [.compress, .removeMetadata, .cropImage, .resizeImage, .createPDF, .createCollage]
                : [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .resizeImage, .redactImage]
        case .avif, .bmp, .raw: return []
        case .svg: return count > 1 ? [.createPDF, .createCollage, .readQRCode] : []
        case .pdf:
            return count > 1
                ? [.compress, .removeMetadata, .splitPDF, .mergePDF, .convertPDFA, .readQRCode]
                : [.compress, .removeMetadata, .splitPDF, .organizePDF, .convertPDFA, .readQRCode]
        case .mp3, .m4a, .wav, .flac:
            return [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio]
        case .mp4, .mov, .mkv:
            return count > 1
                ? [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos]
                : [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .videoSnapshots, .splitVideo, .redactVideo]
        case .gif: return [.removeMetadata]
        case .zip, .tar, .gzip, .rar: return [.extractArchive]
        default: return []
        }
    }

    static func toolOutputs(for formats: [ConversionFormat]) -> [FileTool] {
        guard let first = formats.first else { return [] }
        var result = tools(for: first, count: formats.count)
        for format in formats.dropFirst() {
            let other = Set(tools(for: format, count: formats.count))
            result = result.filter(other.contains)
        }
        // Mixed images, GIFs and PDFs still share QR reading (fallback).
        if result.isEmpty, formats.allSatisfy({ $0.group == .images || $0 == .gif || $0 == .pdf }) {
            result = [.readQRCode]
        }
        return result
    }

    // MARK: Entry point

    static func actions(for formats: [ConversionFormat], mode: ConversionFanMode) -> [ConversionFanAction] {
        switch mode {
        case .conversions: return conversionOutputs(for: formats).map { .convert($0) }
        case .fileTools: return toolOutputs(for: formats).map { .fileTool($0) }
        case .fileActions: return ConversionFanAction.fileActions
        }
    }
}
