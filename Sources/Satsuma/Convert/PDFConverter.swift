import AppKit
import PDFKit

/// PDF → docx/pages/pptx/xlsx/jpg/png/svg/epub/txt/md (`PDFOfficeConverter.reflow` and friends).
enum PDFConverter {
    static func convert(_ url: URL, to target: ConversionFormat, options: ConversionOptions,
                        progress: @escaping (Double) -> Void) async throws -> URL {
        guard let document = PDFDocument(url: url), document.pageCount > 0, !document.isLocked else {
            throw ConversionError.encodingFailed("The PDF cannot be read or is password-protected.")
        }
        let title = url.deletingPathExtension().lastPathComponent
        switch target {
        case .jpg, .png:
            return try PDFPageExporter.export(url, format: target, beside: url, scale: 2)
        case .svg:
            return try PDFToSVG.export(document, beside: url, progress: progress)
        case .pptx:
            let pages = try PDFReflow.pageImages(document, progress: progress)
            let output = OutputNaming.destination(for: url, extension: "pptx")
            try PPTXWriter.write(slides: pages, to: output)
            return output
        case .xlsx:
            let output = OutputNaming.destination(for: url, extension: "xlsx")
            try XLSX.write(rows: tableRows(document), to: output)
            return output
        case .docx, .pages:
            let docx = try docxData(document, title: title, options: options, progress: progress)
            if target == .docx {
                let output = OutputNaming.destination(for: url, extension: "docx")
                try docx.write(to: output)
                progress(1)
                return output
            }
            let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-reflow-")
            defer { try? FileManager.default.removeItem(at: folder) }
            let temporary = folder.appendingPathComponent("\(title).docx")
            try docx.write(to: temporary)
            return try await IWorkBridge.convertToPages(temporary, beside: url)
        case .epub:
            let output = OutputNaming.destination(for: url, extension: "epub")
            try writeEPUB(document, title: title, options: options, to: output, progress: progress)
            return output
        case .txt, .md:
            let result = try PDFReflow.analyze(document, extractArtwork: false, progress: progress)
            let output = OutputNaming.destination(for: url, extension: target.fileExtension)
            let text = target == .md ? markdown(result.blocks) : plainText(result.blocks)
            try text.write(to: output, atomically: true, encoding: .utf8)
            return output
        default:
            throw ConversionError.unsupportedPair(.pdf, target)
        }
    }

    /// `pdfOfficeLayout`: `.editable` reflows blocks; `.preservePages` keeps each page as an image.
    static func docxData(_ document: PDFDocument, title: String, options: ConversionOptions,
                         progress: @escaping (Double) -> Void) throws -> Data {
        let firstSize = document.page(at: 0)!.bounds(for: .mediaBox).size
        // Word's page limit is 22 inches.
        guard firstSize.width <= 22 * 72, firstSize.height <= 22 * 72 else {
            throw ConversionError.encodingFailed("A PDF page has invalid dimensions or exceeds Word's 22-inch page limit.")
        }
        var writer = DOCXWriter(pageSize: firstSize, title: title)
        if options.pdfOfficeLayout == .preservePages {
            writer.marginPoints = 0
            for (index, page) in try PDFReflow.pageImages(document, progress: progress).enumerated() {
                if index > 0 { writer.addPageBreak() }
                writer.addImage(png: page.png, size: page.size, label: "Page \(index + 1)", fullPage: true)
            }
        } else {
            let result = try PDFReflow.analyze(document, extractArtwork: true, progress: progress)
            for block in result.blocks {
                switch block {
                case .heading(let level, let text, let anchor): writer.addHeading(text, level: level, bookmark: anchor)
                case .paragraph(let text): writer.addParagraph(text)
                case .listItem(let ordered, let text): writer.addListItem(text, ordered: ordered)
                case .image(let png, let size, let label): writer.addImage(png: png, size: size, label: label)
                case .table(let rows, let widths, let headers): writer.addTable(rows: rows, widths: widths, headers: headers)
                case .pageBreak: writer.addPageBreak()
                }
            }
        }
        progress(0.95)
        return writer.data()
    }

    static func writeEPUB(_ document: PDFDocument, title: String, options: ConversionOptions, to url: URL,
                          progress: @escaping (Double) -> Void) throws {
        if options.epubLayout == .preservePages {
            let pages = try PDFReflow.pageImages(document, progress: progress)
            var assets: [EPUBWriter.Asset] = []
            var chapters: [EPUBWriter.Chapter] = []
            for (index, page) in pages.enumerated() {
                let path = "images/page-\(index + 1).png"
                assets.append(.init(path: path, mediaType: "image/png", data: page.png))
                chapters.append(.init(title: "Page \(index + 1)", bodyHTML: "<img src=\"\(path)\" alt=\"Page \(index + 1)\" style=\"width:100%;height:auto\"/>"))
            }
            try EPUBWriter.write(title: title, chapters: chapters, assets: assets, fixedLayout: true, pageSize: pages.first?.size, to: url)
            return
        }
        let result = try PDFReflow.analyze(document, extractArtwork: true, progress: progress)
        var chapters: [EPUBWriter.Chapter] = []
        var assets: [EPUBWriter.Asset] = []
        var current = EPUBWriter.Chapter(title: title, bodyHTML: "")
        var openList: String?
        func closeList() { if let tag = openList { current.bodyHTML += "</\(tag)>"; openList = nil } }
        for block in result.blocks {
            switch block {
            case .heading(let level, let text, let anchor):
                closeList()
                if level == 1 && !current.bodyHTML.isEmpty { chapters.append(current); current = .init(title: text, bodyHTML: "") }
                if level == 1 && current.bodyHTML.isEmpty { current.title = text }
                current.bodyHTML += "<h\(level) id=\"\(anchor)\">\(text.xmlEscaped)</h\(level)>"
                current.anchors.append((anchor, text, level))
            case .paragraph(let text):
                closeList(); current.bodyHTML += "<p>\(text.xmlEscaped)</p>"
            case .listItem(let ordered, let text):
                let tag = ordered ? "ol" : "ul"
                if openList != tag { closeList(); current.bodyHTML += "<\(tag)>"; openList = tag }
                current.bodyHTML += "<li>\(text.xmlEscaped)</li>"
            case .image(let png, _, let label):
                closeList()
                let path = "images/image-\(assets.count + 1).png"
                assets.append(.init(path: path, mediaType: "image/png", data: png))
                current.bodyHTML += "<p><img src=\"\(path)\" alt=\"\(label.xmlEscaped)\"/></p>"
            case .table(let rows, let widths, let headers):
                closeList(); current.bodyHTML += tableHTML(rows: rows, widths: widths, headers: headers)
            case .pageBreak: break
            }
        }
        closeList()
        chapters.append(current)
        try EPUBWriter.write(title: result.title, chapters: chapters, assets: assets, to: url)
    }

    static func markdown(_ blocks: [PDFReflow.Block]) -> String {
        var counter = 0
        return blocks.compactMap { block -> String? in
            switch block {
            case .heading(let level, let text, _): counter = 0; return String(repeating: "#", count: level) + " " + text
            case .paragraph(let text): counter = 0; return text
            case .listItem(let ordered, let text):
                counter += 1
                return ordered ? "\(counter). \(text)" : "- \(text)"
            case .image(_, _, let label): return "*[\(label)]*"
            case .table(let rows, _, let headers):
                counter = 0
                let columns = rows.map(\.count).max() ?? 0
                func line(_ cells: [String]) -> String {
                    "| " + (0..<columns).map { $0 < cells.count ? cells[$0].replacingOccurrences(of: "|", with: "\\|") : "" }.joined(separator: " | ") + " |"
                }
                // Markdown needs exactly one header row; a table without one gets an empty header.
                // Pipe tables can't merge cells: the text stays in the spanning cell, covered slots are empty.
                let texts = rows.map { $0.map(\.text) }
                let head = headers > 0 ? line(texts[0]) : line([])
                let separator = "|" + String(repeating: " --- |", count: columns)
                return ([head, separator] + texts.dropFirst(headers > 0 ? 1 : 0).map(line)).joined(separator: "\n")
            case .pageBreak: return nil
            }
        }.joined(separator: "\n\n") + "\n"
    }

    /// Same markup as the original app's EPUB tables: `<table><colgroup>` with relative widths, `<thead>` for header rows.
    static func tableHTML(rows: [[PDFReflow.TableCell]], widths: [Double], headers: Int) -> String {
        let total = max(widths.reduce(0, +), 1)
        var html = "<table><colgroup>" + widths.map { String(format: "<col style=\"width:%.1f%%\"/>", $0 / total * 100) }.joined() + "</colgroup>"
        func row(_ cells: [PDFReflow.TableCell], tag: String) -> String {
            "<tr>" + cells.filter { !$0.covered }.map { cell in
                let spans = (cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : "") + (cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : "")
                return "<\(tag)\(spans)>\(cell.text.xmlEscaped)</\(tag)>"
            }.joined() + "</tr>"
        }
        if headers > 0 { html += "<thead>" + rows.prefix(headers).map { row($0, tag: "th") }.joined() + "</thead>" }
        html += "<tbody>" + rows.dropFirst(headers).map { row($0, tag: "td") }.joined() + "</tbody></table>"
        return html
    }

    static func plainText(_ blocks: [PDFReflow.Block]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, let text, _), .paragraph(let text): return text
            case .listItem(let ordered, let text): return (ordered ? "" : "• ") + text
            case .table(let rows, _, _): return rows.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
            case .image, .pageBreak: return nil
            }
        }.joined(separator: "\n\n") + "\n"
    }

    /// PDF → spreadsheet rows: one row per text line, cells split on wide horizontal gaps.
    static func tableRows(_ document: PDFDocument) throws -> [[String]] {
        var rows: [[String]] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let selection = page.selection(for: page.bounds(for: .cropBox)) else { continue }
            for line in selection.selectionsByLine() {
                guard let text = line.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let cells = text.components(separatedBy: CharacterSet(charactersIn: "\t"))
                    .flatMap { $0.components(separatedBy: "   ") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                rows.append(cells)
            }
        }
        guard !rows.isEmpty else { throw ConversionError.encodingFailed("This PDF has no selectable text. Scanned pages need OCR before text can be exported.") }
        return rows
    }
}
