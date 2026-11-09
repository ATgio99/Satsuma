import Foundation

/// Minimal PPTX writer: one full-bleed picture per slide (PDF → PPTX).
enum PPTXWriter {
    static func write(slides: [(png: Data, size: CGSize)], to url: URL) throws {
        guard let first = slides.first else { throw ConversionError.outputMissing }
        let emu = 12700.0
        let cx = Int(Double(first.size.width) * emu), cy = Int(Double(first.size.height) * emu)
        var zip = ZipWriter()
        var overrides = ""
        var presRels = "<Relationship Id=\"rIdMaster\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/><Relationship Id=\"rIdTheme\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        var slideIds = ""
        for (index, slide) in slides.enumerated() {
            let n = index + 1
            overrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            presRels += "<Relationship Id=\"rIdSlide\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
            slideIds += "<p:sldId id=\"\(255 + n)\" r:id=\"rIdSlide\(n)\"/>"
            zip.add("ppt/media/image\(n).png", slide.png)
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdLayout\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rIdImg\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image\(n).png\"/></Relationships>")
            zip.add("ppt/slides/slide\(n).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rIdImg"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
        }
        zip.add("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>\(overrides)</Types>")
        zip.add("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        zip.add("ppt/_rels/presentation.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(presRels)</Relationships>")
        zip.add("ppt/presentation.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdMaster\"/></p:sldMasterIdLst><p:sldIdLst>\(slideIds)</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"\(cy)\" cy=\"\(cx)\"/></p:presentation>")
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/></Relationships>")
        zip.add("ppt/slideMasters/slideMaster1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>")
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>")
        zip.add("ppt/slideLayouts/slideLayout1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\"><p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        zip.add("ppt/theme/theme1.xml", theme)
        try zip.finish().write(to: url)
    }

    private static let theme: String = {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F1F1F"), ("lt2", "EEEEEE"), ("accent1", "FF8500"), ("accent2", "ED7D31"),
                      ("accent3", "A5A5A5"), ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Satsuma\"><a:themeElements><a:clrScheme name=\"Satsuma\">\(scheme)</a:clrScheme><a:fontScheme name=\"Satsuma\"><a:majorFont><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"Satsuma\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"
    }()
}

/// Minimal XLSX reader/writer (first sheet, strings and numbers).
enum XLSX {
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    static func write(rows: [[String]], sheetName: String = "Sheet1", to url: URL) throws {
        var sheetRows = ""
        for (r, row) in rows.enumerated() {
            sheetRows += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                if let number = Double(value), value.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
                    sheetRows += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                } else {
                    sheetRows += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(value.xmlEscaped)</t></is></c>"
                }
            }
            sheetRows += "</row>"
        }
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        zip.add("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        zip.add("xl/workbook.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"\(sheetName.xmlEscaped)\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        zip.add("xl/worksheets/sheet1.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheetRows)</sheetData></worksheet>")
        try zip.finish().write(to: url)
    }

    static func read(_ url: URL) throws -> [[String]] {
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-xlsx-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw ConversionError.sourceCannotBeRead }
        var shared: [String] = []
        if let sst = try? XMLDocument(contentsOf: folder.appendingPathComponent("xl/sharedStrings.xml"), options: []) {
            shared = (try? sst.nodes(forXPath: "//*[local-name()='si']"))?.map { node in
                ((try? node.nodes(forXPath: ".//*[local-name()='t']")) ?? []).compactMap(\.stringValue).joined()
            } ?? []
        }
        let sheetsFolder = folder.appendingPathComponent("xl/worksheets")
        let sheetFile = (try? FileManager.default.contentsOfDirectory(atPath: sheetsFolder.path))?.filter { $0.hasSuffix(".xml") }.sorted().first
        guard let sheetFile, let sheet = try? XMLDocument(contentsOf: sheetsFolder.appendingPathComponent(sheetFile), options: []) else {
            throw ConversionError.encodingFailed("The spreadsheet is empty or exceeds the 128 MB conversion limit.")
        }
        var rows: [[String]] = []
        for rowNode in try sheet.nodes(forXPath: "//*[local-name()='row']") {
            var row: [String] = []
            for cellNode in try rowNode.nodes(forXPath: "./*[local-name()='c']") {
                guard let cell = cellNode as? XMLElement else { continue }
                let ref = cell.attribute(forName: "r")?.stringValue ?? ""
                let letters = ref.prefix { $0.isLetter }
                let column = letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1
                while row.count < max(column, 0) { row.append("") }
                let type = cell.attribute(forName: "t")?.stringValue
                var value = (try? cell.nodes(forXPath: "./*[local-name()='v']").first?.stringValue) ?? nil
                if type == "s", let index = value.flatMap(Int.init), index < shared.count { value = shared[index] }
                if type == "inlineStr" { value = (try? cell.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()) ?? "" }
                row.append(value ?? "")
            }
            rows.append(row)
        }
        return rows
    }
}

/// Minimal ODS reader/writer (first sheet, strings and numbers).
enum ODS {
    private static let mediaType = "application/vnd.oasis.opendocument.spreadsheet"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"

    static func write(rows: [[String]], sheetName: String = "Sheet1", to url: URL) throws {
        var table = "<table:table table:name=\"\(sheetName.xmlEscaped)\"><table:table-column table:number-columns-repeated=\"\(max(rows.map(\.count).max() ?? 1, 1))\"/>"
        for row in rows {
            table += "<table:table-row>"
            table += row.isEmpty ? "<table:table-cell/>" : row.map(cellXML).joined()
            table += "</table:table-row>"
        }
        table += "</table:table>"
        var zip = ZipWriter()
        zip.add("mimetype", mediaType)   // must stay the first entry, and ZipWriter stores it uncompressed
        zip.add("META-INF/manifest.xml", "\(header)<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"\(mediaType)\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")
        zip.add("content.xml", "\(header)<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:spreadsheet>\(table)</office:spreadsheet></office:body></office:document-content>")
        try zip.finish().write(to: url)
    }

    private static func cellXML(_ value: String) -> String {
        guard !value.isEmpty else { return "<table:table-cell/>" }
        // Leading zeros and numbers beyond Double's precision (15 significant digits) stay text, or they would be silently altered.
        let significant = value.drop { "-0.".contains($0) }.filter { $0 != "." }.count
        if significant <= 15, value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil {
            return "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(value)</text:p></table:table-cell>"
        }
        let paragraphs = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { paragraphXML(String($0)) }
        return "<table:table-cell office:value-type=\"string\">\(paragraphs.joined())</table:table-cell>"
    }

    /// ODF collapses runs of white space inside `text:p`, so anything that must survive is spelled out.
    private static func paragraphXML(_ line: String) -> String {
        var body = ""
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == " " {
                let run = line[index...].prefix { $0 == " " }
                let isolated = run.count == 1 && run.startIndex != line.startIndex && run.endIndex != line.endIndex
                body += isolated ? " " : "<text:s text:c=\"\(run.count)\"/>"
                index = run.endIndex
            } else if line[index] == "\t" {
                body += "<text:tab/>"
                index = line.index(after: index)
            } else {
                let run = line[index...].prefix { $0 != " " && $0 != "\t" }
                body += String(run).xmlEscaped
                index = run.endIndex
            }
        }
        return "<text:p>\(body)</text:p>"
    }

    static func read(_ url: URL) throws -> [[String]] {
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-ods-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, let parser = XMLParser(contentsOf: folder.appendingPathComponent("content.xml")) else {
            throw ConversionError.sourceCannotBeRead
        }
        let content = ODSContentReader()
        parser.delegate = content
        guard parser.parse() || content.isFinished else { throw ConversionError.sourceCannotBeRead }
        guard !content.exceededLimit else { throw ConversionError.encodingFailed("The spreadsheet is empty or exceeds the 128 MB conversion limit.") }
        return content.rectangularRows
    }
}

/// Collects the first sheet of an ODS `content.xml`. Calc pads every sheet to its full size with repeated empty
/// cells and rows, so blanks stay counters until a value follows them and trailing ones are simply never written.
private final class ODSContentReader: NSObject, XMLParserDelegate {
    private static let maxColumns = 16_384, maxRows = 1_048_576, maxSpaces = 4_096
    /// What one more cell costs on top of its text: its separator and its slot in memory.
    private static let cellCost = 8

    private(set) var rows: [[String]] = []
    private(set) var isFinished = false
    /// Bytes that repeat attributes and `text:s` may still create; a file that runs out is refused instead of exhausting memory.
    private var expansionBudget = 128 * 1024 * 1024
    private(set) var exceededLimit = false
    private var row: [String] = []
    private var rowRepeat = 1
    private var blankRows = 0
    private var blankColumns = 0
    private var cellDepth = 0
    private var cellRepeat = 1
    private var isCovered = false
    private var numericValue: String?
    private var stringValue: String?
    private var paragraphs: [String] = []
    private var paragraph: String?

    /// Trailing blanks were not kept, so short rows are filled back to the used width (blank rows included).
    var rectangularRows: [[String]] {
        let width = rows.map(\.count).max() ?? 0
        guard rows.reduce(0, { $0 + width - $1.count }) * Self.cellCost <= expansionBudget else { return rows }
        return rows.map { $0.count == width ? $0 : $0 + repeatElement("", count: width - $0.count) }
    }

    private static func count(_ text: String?, limit: Int) -> Int { max(1, min(text.flatMap(Int.init) ?? 1, limit)) }

    /// LibreOffice stores very large or small numbers as "1E+020", which the writers would take for text.
    private static func plainNumber(_ value: String?) -> String? {
        guard let value, value.contains(where: { $0 == "E" || $0 == "e" }), let decimal = Decimal(string: value), !decimal.isNaN else { return value }
        return decimal.description
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if cellDepth > 0 {
            cellDepth += 1
            if paragraph == nil {
                // Only direct children: comments and shapes in a cell hold `text:p` elements of their own.
                if cellDepth == 2, name == "text:p", !isCovered { paragraph = "" }
            } else if name == "text:s" {
                let spaces = Self.count(attributes["text:c"], limit: Self.maxSpaces)
                guard spend(spaces, parser) else { return }
                paragraph! += String(repeating: " ", count: spaces)
            } else if name == "text:tab" {
                paragraph! += "\t"
            } else if name == "text:line-break" {
                paragraph! += "\n"
            }
        } else if name == "table:table-row" {
            row = []
            blankColumns = 0
            rowRepeat = Self.count(attributes["table:number-rows-repeated"], limit: Self.maxRows)
        } else if name == "table:table-cell" || name == "table:covered-table-cell" {
            cellDepth = 1
            isCovered = name == "table:covered-table-cell"
            cellRepeat = Self.count(attributes["table:number-columns-repeated"], limit: Self.maxColumns)
            let type = attributes["office:value-type"]
            numericValue = type == "float" || type == "percentage" || type == "currency" ? Self.plainNumber(attributes["office:value"]) : nil
            stringValue = attributes["office:string-value"] ?? attributes["office:date-value"] ?? attributes["office:time-value"] ?? attributes["office:boolean-value"]
            paragraphs = []
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraph != nil else { return }
        for character in string {
            if character == " " || character == "\t" || character.isNewline {
                if let last = paragraph!.last, last != " " { paragraph!.append(" ") }
            } else {
                paragraph!.append(character)
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if cellDepth > 0 {
            if cellDepth == 2, name == "text:p", let paragraph {
                paragraphs.append(paragraph)
                self.paragraph = nil
            }
            cellDepth -= 1
            if cellDepth == 0 { finishCell(parser) }
        } else if name == "table:table-row" {
            finishRow(parser)
        } else if name == "table:table" {
            finish(parser)     // like XLSX.read, only the first sheet
        }
    }

    private func finish(_ parser: XMLParser) {
        isFinished = true
        parser.abortParsing()
    }

    private func spend(_ bytes: Int, _ parser: XMLParser) -> Bool {
        guard bytes <= expansionBudget else {
            exceededLimit = true
            finish(parser)
            return false
        }
        expansionBudget -= bytes
        return true
    }

    private func finishCell(_ parser: XMLParser) {
        let value = isCovered ? "" : numericValue ?? (paragraphs.isEmpty ? stringValue ?? "" : paragraphs.joined(separator: "\n"))
        guard !value.isEmpty else {
            blankColumns = min(blankColumns + cellRepeat, Self.maxColumns)
            return
        }
        guard row.count + blankColumns < Self.maxColumns else { return }
        guard spend(blankColumns * Self.cellCost + (cellRepeat - 1) * (value.utf8.count + Self.cellCost), parser) else { return }
        row.append(contentsOf: repeatElement("", count: blankColumns))
        row.append(contentsOf: repeatElement(value, count: min(cellRepeat, Self.maxColumns - row.count)))
        blankColumns = 0
    }

    private func finishRow(_ parser: XMLParser) {
        guard !row.isEmpty else {
            blankRows = min(blankRows + rowRepeat, Self.maxRows)
            return
        }
        guard rows.count + blankRows < Self.maxRows else { finish(parser); return }
        guard spend(blankRows, parser) else { return }
        rows.append(contentsOf: repeatElement([], count: blankRows))
        blankRows = 0
        let copies = min(rowRepeat, Self.maxRows - rows.count)
        guard spend((copies - 1) * row.reduce(0) { $0 + $1.utf8.count + Self.cellCost }, parser) else { return }
        rows.append(contentsOf: repeatElement(row, count: copies))
        if copies < rowRepeat || rows.count == Self.maxRows { finish(parser) }
    }
}
