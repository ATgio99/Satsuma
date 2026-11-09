import Foundation
import UniformTypeIdentifiers

/// The 47 formats the original app knows, in the binary's enum order (raw value = file extension).
enum ConversionFormat: String, CaseIterable, Codable, Hashable {
    case jpg, png, webp, heic, tiff, svg, avif, bmp, raw, pdf
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    case mp4, mov, mkv, webm, avi, wmv, gif
    case docx, pages, ppt, pptx, txt, md, rtf, rtfd, textClipping, html, epub
    case xlsx, xls, ods, csv, tsv
    case srt, vtt
    case zip, tar, gzip, rar

    enum Group: Int { case images = 0, audio, video, documents, spreadsheets, archives, subtitles }

    /// Group of each format.
    var group: Group {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .svg, .avif, .bmp, .raw: return .images
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .gif: return .video
        case .pdf, .docx, .pages, .ppt, .pptx, .txt, .md, .rtf, .rtfd, .textClipping, .html, .epub: return .documents
        case .xlsx, .xls, .ods, .csv, .tsv: return .spreadsheets
        case .zip, .tar, .gzip, .rar: return .archives
        case .srt, .vtt: return .subtitles
        }
    }

    var fileExtension: String {
        switch self {
        case .textClipping: return "textClipping"
        case .gzip: return "gz"
        default: return rawValue
        }
    }

    /// Label shown on a petal and in the center label.
    var title: String {
        switch self {
        case .gzip: return "GZIP"
        case .textClipping: return "CLIPPING"
        default: return rawValue.uppercased()
        }
    }

    /// Formats that appear only as sources.
    var isInputOnly: Bool { [.raw, .rar, .ppt, .xls, .rtf, .rtfd, .textClipping].contains(self) }

    /// Camera RAW extensions, decoded by ImageIO.
    static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mos", "mrw",
        "nef", "nrw", "orf", "pef", "ptx", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw",
    ]

    /// Package directories that count as files when dropped.
    static let packageExtensions: Set<String> = ["rtfd", "pages", "key", "numbers"]

    private static let extensionMap: [String: ConversionFormat] = {
        var map: [String: ConversionFormat] = [:]
        for format in allCases { map[format.fileExtension.lowercased()] = format }
        map["jpeg"] = .jpg; map["jpe"] = .jpg; map["tif"] = .tiff; map["heif"] = .heic
        map["markdown"] = .md; map["htm"] = .html; map["xhtml"] = .html; map["text"] = .txt
        map["aif"] = .aiff; map["aifc"] = .aiff; map["oga"] = .ogg; map["m4v"] = .mp4
        map["tgz"] = .gzip; map["textclipping"] = .textClipping; map["vtt"] = .vtt
        for ext in rawExtensions { map[ext] = .raw }
        return map
    }()

    /// Detects the format of a file: extension first, then the UTType.
    static func detect(_ url: URL) -> ConversionFormat? {
        let ext = url.pathExtension.lowercased()
        if let format = extensionMap[ext] { return format }
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return nil }
        let probes: [(UTType, ConversionFormat)] = [
            (.jpeg, .jpg), (.png, .png), (.heic, .heic), (.tiff, .tiff), (.bmp, .bmp), (.gif, .gif),
            (.pdf, .pdf), (.mp3, .mp3), (.wav, .wav), (.aiff, .aiff), (.mpeg4Movie, .mp4),
            (.quickTimeMovie, .mov), (.html, .html), (.rtf, .rtf), (.rtfd, .rtfd), (.epub, .epub),
            (.commaSeparatedText, .csv), (.tabSeparatedText, .tsv), (.zip, .zip), (.plainText, .txt),
        ]
        for (probe, format) in probes where type.conforms(to: probe) { return format }
        return nil
    }
}
