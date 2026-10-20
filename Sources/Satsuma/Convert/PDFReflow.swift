import AppKit
import PDFKit
import Vision

/// PDF → structured blocks, rebuilt from the original app's reflow pipeline:
/// text extraction, block building and the heading
/// classifier.
enum PDFReflow {
    struct TextLine {
        var text: String
        var bounds: CGRect
        var fontSize: CGFloat
        var isBold: Bool
        var page: Int
    }

    struct Artwork {
        var bounds: CGRect
        var page: Int
        var png: Data
        var pixelSize: CGSize
    }

    enum Block {
        case heading(level: Int, text: String, anchor: String)
        case paragraph(String)
        case listItem(ordered: Bool, text: String)
        case image(png: Data, size: CGSize, label: String)
        /// One `TableCell` per grid slot in every row, column `widths` in points, and how many leading rows
        /// are headers (`SDTable`).
        case table(rows: [[TableCell]], widths: [Double], headers: Int)
        case pageBreak
    }

    /// A grid slot of a table (`SDCell`): an origin cell with its spans, or a slot `covered` by one.
    struct TableCell: Equatable {
        var text: String
        var rowSpan = 1
        var columnSpan = 1
        var covered = false
    }

    struct PageTable {
        var table: PDFTableDetector.Table
        var page: Int
    }

    struct Result {
        var blocks: [Block]
        var pageSize: CGSize
        var usedOCR: Bool
        var title: String
    }

    // MARK: Regexes from the binary

    static let numberedHeading = try! NSRegularExpression(pattern: #"^\d+(?:\.\d+)*[.)]?\s+(?=\S*\p{L})\S"#)
    static let chapterHeading = try! NSRegularExpression(pattern: #"^(chapter|part|book)\s+"#, options: .caseInsensitive)
    static let caption = try! NSRegularExpression(pattern: #"^(figure|table)\s+\d"#, options: .caseInsensitive)
    static let formulaLike = try! NSRegularExpression(pattern: #"^[A-Za-z]{1,4}\([^)]{1,20}\)$"#)
    static let bullet = try! NSRegularExpression(pattern: #"^[•●▪◦–-]\s+"#)
    static let orderedItem = try! NSRegularExpression(pattern: #"^\d+[.)]\s+"#)

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Entry point

    static func analyze(_ document: PDFDocument, extractArtwork: Bool, progress: (Double) -> Void) throws -> Result {
        guard document.pageCount > 0 else { throw ConversionError.encodingFailed("The PDF cannot be read, is empty, or is password-protected.") }
        if !document.allowsCopying { throw ConversionError.encodingFailed("This PDF does not allow copying its content.") }
        var lines: [TextLine] = []
        var artwork: [Artwork] = []
        var tables: [PageTable] = []
        var usedOCR = false
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var pageLines = textLines(of: page, index: index)
            let ocrLines = try recognizeText(on: page, index: index, existing: pageLines)
            if !ocrLines.isEmpty { usedOCR = true; pageLines += ocrLines }
            // Tables first: the lines inside a table become its cells, not paragraphs.
            let pageTables = PDFTableDetector.tables(on: page)
            if !pageTables.isEmpty {
                let areas = pageTables.map { $0.bounds.insetBy(dx: -2, dy: -2) }
                pageLines.removeAll { line in areas.contains { $0.contains(CGPoint(x: line.bounds.midX, y: line.bounds.midY)) } }
                tables += pageTables.map { PageTable(table: $0, page: index) }
            }
            lines += mergeBaselineFragments(pageLines)
            if extractArtwork { artwork += ArtworkScanner.scan(page: page, index: index) }
            // Extraction is the first 25 % of the progress bar.
            progress(Double(index + 1) / Double(document.pageCount) * 0.25)
        }
        if lines.isEmpty && artwork.isEmpty && tables.isEmpty {
            throw ConversionError.encodingFailed("The PDF contains no text or page artwork that can be exported.")
        }
        let firstPage = document.page(at: 0)!.bounds(for: .mediaBox).size
        lines = removeRunningHeadersAndFooters(lines, pageCount: document.pageCount, pageHeight: firstPage.height)
        let blocks = buildBlocks(lines: lines, artwork: artwork, tables: tables, pageCount: document.pageCount)
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? blocks.lazy.compactMap { if case .heading(_, let text, _) = $0 { return text } else { return nil } }.first
            ?? "Document"
        return Result(blocks: blocks, pageSize: firstPage, usedOCR: usedOCR, title: title)
    }

    // MARK: Text extraction (PDFKit)

    static func textLines(of page: PDFPage, index: Int) -> [TextLine] {
        guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        var lines: [TextLine] = []
        for line in selection.selectionsByLine() {
            guard let string = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { continue }
            let bounds = line.bounds(for: page)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
            var size: CGFloat = 0
            var bold = true
            if let attributed = line.attributedString {
                var counts: [CGFloat: Int] = [:]
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    guard let font = value as? NSFont else { return }
                    counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
                    let name = font.fontName.lowercased()
                    if !(name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")) { bold = false }
                }
                size = counts.max { $0.value < $1.value }?.key ?? 0
            }
            if size <= 0 { size = bounds.height * 0.8; bold = false }
            lines.append(TextLine(text: string, bounds: bounds, fontSize: size, isBold: bold, page: index))
        }
        return lines
    }

    // MARK: OCR fallback (Vision)

    static func recognizeText(on page: PDFPage, index: Int, existing: [TextLine]) throws -> [TextLine] {
        let pageBounds = page.bounds(for: .mediaBox)
        let textArea = existing.reduce(0) { $0 + $1.bounds.width * $1.bounds.height }
        // Pages with plenty of real text skip OCR.
        if !existing.isEmpty && textArea > pageBounds.width * pageBounds.height * 0.02 { return [] }
        guard let image = PDFPageExporter.image(of: page, scale: 2) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.encodingFailed("Text recognition could not read a scanned PDF page: \(error.localizedDescription)")
        }
        var result: [TextLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.25 else { continue }
            let box = observation.boundingBox
            let rect = CGRect(x: pageBounds.minX + box.minX * pageBounds.width, y: pageBounds.minY + box.minY * pageBounds.height,
                              width: box.width * pageBounds.width, height: box.height * pageBounds.height)
            // Skip regions that overlap existing PDF text by 65 % or more.
            let overlapsText = existing.contains { line in
                let intersection = line.bounds.intersection(rect)
                return !intersection.isNull && intersection.width * intersection.height >= rect.width * rect.height * 0.65
            }
            if overlapsText { continue }
            result.append(TextLine(text: candidate.string, bounds: rect, fontSize: rect.height * 0.78, isBold: false, page: index))
        }
        return result
    }

    /// Joins fragments that sit on the same baseline (bullet + text, tab-separated runs, OCR pieces),
    /// then returns the page's lines top to bottom.
    static func mergeBaselineFragments(_ fragments: [TextLine]) -> [TextLine] {
        // Group into rows by vertical overlap, then read each row left to right.
        var rows: [[TextLine]] = []
        for fragment in fragments.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let index = rows.firstIndex(where: { row in
                let reference = row[0].bounds
                let tolerance = min(reference.height, fragment.bounds.height) * 0.5
                return abs(reference.midY - fragment.bounds.midY) < tolerance
            }) {
                rows[index].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        var merged: [TextLine] = []
        for row in rows {
            var current: TextLine?
            for fragment in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                guard var line = current else { current = fragment; continue }
                let gap = fragment.bounds.minX - line.bounds.maxX
                if gap > -1 && gap < max(line.fontSize, fragment.fontSize) * 4 {
                    line.text += " " + fragment.text
                    line.bounds = line.bounds.union(fragment.bounds)
                    // A leading bullet glyph shouldn't decide the size or weight of the line.
                    if line.text.count <= 3 || fragment.text.count > line.text.count / 2 {
                        line.fontSize = max(line.fontSize, fragment.fontSize)
                    }
                    line.isBold = line.isBold && fragment.isBold
                    current = line
                } else {
                    merged.append(line)
                    current = fragment
                }
            }
            if let current { merged.append(current) }
        }
        return merged.sorted { ($0.bounds.maxY, -$0.bounds.minX) > ($1.bounds.maxY, -$1.bounds.minX) }
    }

    // MARK: Running headers, footers and folios

    static func removeRunningHeadersAndFooters(_ lines: [TextLine], pageCount: Int, pageHeight: CGFloat) -> [TextLine] {
        func key(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let margin = pageHeight * 0.08
        func isMarginal(_ line: TextLine) -> Bool { line.bounds.minY < margin || line.bounds.maxY > pageHeight - margin }
        var pagesPerKey: [String: Set<Int>] = [:]
        for line in lines where isMarginal(line) { pagesPerKey[key(line.text), default: []].insert(line.page) }
        return lines.filter { line in
            guard isMarginal(line) else { return true }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^(page\s+)?\d+(\s+(of|/)\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
            return pageCount < 3 || (pagesPerKey[key(line.text)]?.count ?? 0) < max(2, pageCount / 2)
        }
    }

    // MARK: Block building

    static func bodyFontSize(_ lines: [TextLine]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[(line.fontSize * 2).rounded() / 2, default: 0] += line.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 13
    }

    /// Heading level for a line.
    static func headingLevel(_ line: TextLine, body: CGFloat) -> Int? {
        let text = line.text
        guard (4...140).contains(text.count) else { return nil }
        if matches(caption, text) || matches(formulaLike, text) { return nil }
        if line.fontSize > body * 1.7 || (line.fontSize > body * 1.25 && matches(chapterHeading, text)) { return 1 }
        if line.fontSize > body * 1.25 { return 2 }
        if line.isBold && matches(numberedHeading, text) && !text.hasSuffix(".") {
            let depth = text.prefix(while: { $0.isNumber || $0 == "." }).filter { $0 == "." }.count
            return min(3, depth + 2)
        }
        return nil
    }

    static func buildBlocks(lines: [TextLine], artwork: [Artwork], tables: [PageTable] = [], pageCount: Int) -> [Block] {
        let body = bodyFontSize(lines)
        var blocks: [Block] = []
        var paragraph: [TextLine] = []
        var headingIndex = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            var text = ""
            for line in paragraph {
                if text.hasSuffix("-"), let first = line.text.first, first.isLowercase {
                    text.removeLast()
                    text += line.text
                } else {
                    text += (text.isEmpty ? "" : " ") + line.text
                }
            }
            if matches(bullet, text) {
                blocks.append(.listItem(ordered: false, text: text.replacingOccurrences(of: #"^[•●▪◦–-]\s+"#, with: "", options: .regularExpression)))
            } else if matches(orderedItem, text) {
                blocks.append(.listItem(ordered: true, text: text.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)))
            } else {
                blocks.append(.paragraph(text))
            }
            paragraph = []
        }

        for page in 0..<pageCount {
            let pageLines = lines.filter { $0.page == page }
            // Artwork and tables sit between text lines, ordered from the top of the page.
            var floats: [(bounds: CGRect, block: () -> Block)] = []
            for art in artwork where art.page == page {
                floats.append((art.bounds, { .image(png: art.png, size: art.bounds.size, label: "PDF illustration \(blocks.count + 1)") }))
            }
            for item in tables where item.page == page {
                floats.append((item.table.bounds, { .table(rows: item.table.rows, widths: item.table.widths, headers: item.table.headers) }))
            }
            floats.sort { $0.bounds.maxY > $1.bounds.maxY }
            if page > 0 && (!pageLines.isEmpty || !floats.isEmpty) { flush() }
            for line in pageLines {
                // Emit artwork and tables that sit above this line.
                while let item = floats.first, item.bounds.midY > line.bounds.maxY {
                    flush()
                    blocks.append(item.block())
                    floats.removeFirst()
                }
                if let level = headingLevel(line, body: body) {
                    flush()
                    headingIndex += 1
                    let anchor = String(format: "heading-%04d-%03d", page + 1, headingIndex)
                    if case .heading(let previousLevel, let previousText, let previousAnchor)? = blocks.last, previousLevel == level,
                       blocks.count > 0, paragraph.isEmpty, previousText.count + line.text.count < 140 {
                        // Multi-line headings merge into one.
                        blocks[blocks.count - 1] = .heading(level: level, text: previousText + " " + line.text, anchor: previousAnchor)
                    } else {
                        blocks.append(.heading(level: level, text: line.text, anchor: anchor))
                    }
                    continue
                }
                let startsItem = matches(bullet, line.text) || matches(orderedItem, line.text)
                if let previous = paragraph.last, let first = paragraph.first {
                    let gap = previous.bounds.minY - line.bounds.maxY
                    let lineHeight = max(previous.bounds.height, line.bounds.height)
                    let sameSize = abs(previous.fontSize - line.fontSize) < 1
                    // A list item only continues on lines indented past its marker (hanging indent).
                    let inItem = matches(bullet, first.text) || matches(orderedItem, first.text)
                    let leavesItem = inItem && line.bounds.minX < first.bounds.minX + 4
                    if startsItem || leavesItem || gap > lineHeight * 0.9 || gap < -lineHeight || !sameSize { flush() }
                }
                paragraph.append(line)
            }
            flush()
            for item in floats { blocks.append(item.block()) }
        }
        return blocks
    }

    // MARK: Whole-page mode (`preservePages`)

    static func pageImages(_ document: PDFDocument, progress: (Double) -> Void) throws -> [(png: Data, size: CGSize)] {
        var pages: [(Data, CGSize)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let image = PDFPageExporter.image(of: page, scale: 2) else {
                throw ConversionError.encodingFailed("A PDF page could not be rendered.")
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw ConversionError.encodingFailed("Could not create the PNG image.") }
            pages.append((png, page.bounds(for: .mediaBox).size))
            progress(Double(index + 1) / Double(document.pageCount) * 0.6)
        }
        return pages
    }
}

/// Finds placed raster images on a page by scanning its content stream (cm/q/Q/Do), like
/// The original app's `PDFArtworkScanner`, and crops them from a rendered page.
enum ArtworkScanner {
    final class State {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
        var xobjects: CGPDFDictionaryRef?
    }

    static func scan(page: PDFPage, index: Int) -> [PDFReflow.Artwork] {
        guard let cgPage = page.pageRef else { return [] }
        let state = State()
        if let resources = cgPage.dictionary.flatMap({ dict -> CGPDFDictionaryRef? in
            var res: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dict, "Resources", &res)
            return res
        }) {
            var xobjects: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects)
            state.xobjects = xobjects
        }
        guard state.xobjects != nil, let table = CGPDFOperatorTableCreate() else { return [] }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            state.stack.append(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            if let last = state.stack.popLast() { state.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for slot in (0..<6).reversed() { CGPDFScannerPopNumber(scanner, &values[slot]) }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.ctm = matrix.concatenating(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let xobjects = state.xobjects else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return }
            state.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm))
        }
        let contents = CGPDFContentStreamCreateWithPage(cgPage)
        let scanner = CGPDFScannerCreate(contents, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contents)
        CGPDFOperatorTableRelease(table)

        let pageBounds = page.bounds(for: .mediaBox)
        let pageArea = pageBounds.width * pageBounds.height
        let candidates = state.rects
            .map { $0.standardized.intersection(pageBounds) }
            .filter { !$0.isNull && $0.width > 24 && $0.height > 24 && $0.width * $0.height < pageArea * 0.92 }
        guard !candidates.isEmpty, let rendered = PDFPageExporter.image(of: page, scale: 2) else { return [] }
        return candidates.compactMap { rect in
            let scale: CGFloat = 2
            let crop = CGRect(x: (rect.minX - pageBounds.minX) * scale,
                              y: (pageBounds.maxY - rect.maxY) * scale,
                              width: rect.width * scale, height: rect.height * scale).integral
            guard let image = rendered.cropping(to: crop),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            return PDFReflow.Artwork(bounds: rect, page: index, png: png, pixelSize: CGSize(width: image.width, height: image.height))
        }
    }
}
