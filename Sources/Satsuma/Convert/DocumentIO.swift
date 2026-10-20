import AppKit
import CoreText
import PDFKit

/// Reads and writes rich-text documents through NSAttributedString, the way the original app's
/// text/RTF/DOCX/HTML paths do, plus CoreText pagination for PDF output.
@MainActor
enum DocumentIO {
    static let pageSize = CGSize(width: 612, height: 792)   // US Letter, 1 in margins
    static let margin: CGFloat = 72

    // MARK: Loading

    static func load(_ url: URL, format: ConversionFormat) async throws -> NSAttributedString {
        switch format {
        case .txt:
            var encoding = String.Encoding.utf8
            let text = (try? String(contentsOf: url, usedEncoding: &encoding)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            guard let text else { throw ConversionError.sourceCannotBeRead }
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case .md:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ConversionError.sourceCannotBeRead }
            return try fromHTML(Markdown.html(from: text))
        case .html:
            return try readAttributed(url, type: .html)
        case .rtf:
            return try readAttributed(url, type: .rtf)
        case .rtfd:
            return try readAttributed(url, type: .rtfd)
        case .docx:
            return try readAttributed(url, type: .officeOpenXML)
        case .textClipping:
            return try loadClipping(url)
        case .epub:
            return try fromHTML(try EPUBReader.html(from: url))
        case .pages:
            let docx = try await IWorkBridge.exportPagesToDOCX(url)
            defer { try? FileManager.default.removeItem(at: docx.deletingLastPathComponent()) }
            return try readAttributed(docx, type: .officeOpenXML)
        default:
            throw ConversionError.unsupportedSource
        }
    }

    static func readAttributed(_ url: URL, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil)
        } catch {
            throw ConversionError.sourceCannotBeRead
        }
    }

    static func fromHTML(_ html: String) throws -> NSAttributedString {
        guard let data = html.data(using: .utf8),
              let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                     .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil)
        else { throw ConversionError.sourceCannotBeRead }
        return text
    }

    /// Modern `.textClipping` files are property lists with a `UTI-Data` dictionary.
    static func loadClipping(_ url: URL) throws -> NSAttributedString {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let utiData = plist["UTI-Data"] as? [String: Any]
        else { throw ConversionError.encodingFailed("This text clipping has an unsupported or malformed format.") }
        if let rtf = utiData["public.rtf"] as? Data,
           let text = NSAttributedString(rtf: rtf, documentAttributes: nil) { return text }
        if let html = utiData["public.html"] as? String { return try fromHTML(html) }
        if let plain = utiData["public.utf8-plain-text"] as? String ?? utiData["public.utf16-plain-text"] as? String {
            return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        throw ConversionError.encodingFailed("The clipping contains no supported text.")
    }

    // MARK: Writing

    static func write(_ text: NSAttributedString, to target: ConversionFormat, beside source: URL, title: String) async throws -> URL {
        switch target {
        case .pdf:
            let output = OutputNaming.destination(for: source, extension: "pdf")
            try renderPDF(text, to: output)
            return output
        case .docx:
            let output = OutputNaming.destination(for: source, extension: "docx")
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: output)
            return output
        case .txt:
            let output = OutputNaming.destination(for: source, extension: "txt")
            try text.string.write(to: output, atomically: true, encoding: .utf8)
            return output
        case .html:
            let output = OutputNaming.destination(for: source, extension: "html")
            try html(from: text, title: title).write(to: output, atomically: true, encoding: .utf8)
            return output
        case .md:
            let output = OutputNaming.destination(for: source, extension: "md")
            try Markdown.markdown(from: text).write(to: output, atomically: true, encoding: .utf8)
            return output
        case .epub:
            let output = OutputNaming.destination(for: source, extension: "epub")
            try EPUBWriter.write(title: title, bodyHTML: bodyHTML(from: text), to: output)
            return output
        case .png, .jpg:
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-doc-")
            defer { try? FileManager.default.removeItem(at: folder) }
            let pdf = folder.appendingPathComponent("render.pdf")
            try renderPDF(text, to: pdf)
            return try PDFPageExporter.export(pdf, format: target, beside: source, scale: 2)
        case .pages:
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-doc-")
            defer { try? FileManager.default.removeItem(at: folder) }
            let docx = folder.appendingPathComponent("\(title).docx")
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: docx)
            return try await IWorkBridge.convertToPages(docx, beside: source)
        default:
            throw ConversionError.unsupportedPair(.txt, target)
        }
    }

    static func html(from text: NSAttributedString, title: String) throws -> String {
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                      .title: title])
        return String(decoding: data, as: UTF8.self)
    }

    /// Body markup only, for EPUB chapters (XHTML-safe).
    static func bodyHTML(from text: NSAttributedString) -> String {
        Markdown.xhtmlBody(from: text)
    }

    /// Paginates with CoreText into a PDF (`Document to PDF`).
    static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.encodingFailed("Could not create the PDF.")
        }
        let content = text.length > 0 ? text : NSAttributedString(string: " ")
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        let frameRect = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        var location = 0
        var pages = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            pages += 1
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < content.length && pages < 5000
        context.closePDF()
    }
}

/// Renders PDF pages to PNG/JPEG files beside the source (one file per page, numbered when several).
enum PDFPageExporter {
    static func export(_ pdfURL: URL, format: ConversionFormat, beside source: URL, scale: CGFloat) throws -> URL {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else {
            throw ConversionError.encodingFailed("The PDF cannot be read, is empty, or is password-protected.")
        }
        var first: URL?
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let suffix = document.pageCount > 1 ? " \(index + 1)" : ""
            let output = OutputNaming.destination(for: source, extension: format.fileExtension, suffix: suffix)
            try render(page, to: output, format: format, scale: scale)
            if first == nil { first = output }
        }
        guard let first else { throw ConversionError.outputMissing }
        return first
    }

    static func image(of page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: (rotated ? bounds.height : bounds.width) * scale, height: (rotated ? bounds.width : bounds.height) * scale)
        guard size.width > 0, size.height > 0, size.width < 20000, size.height < 20000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func render(_ page: PDFPage, to url: URL, format: ConversionFormat, scale: CGFloat) throws {
        guard let image = image(of: page, scale: scale) else {
            throw ConversionError.encodingFailed("A PDF page could not be rendered.")
        }
        try ImageConverter.write([image], properties: [nil], to: url, format: format, options: SettingsModel.shared.defaultOptions)
    }
}
