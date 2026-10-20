import Foundation

/// Hand-built WordprocessingML package (the original app's `SDDOCXWriter` concatenates XML the same way).
struct DOCXWriter {
    var pageSize: CGSize                 // points
    var title: String
    private var body: [String] = []
    private var media: [(name: String, data: Data)] = []
    private var relationships: [String] = []
    private var drawingIndex = 0
    private var usesBullets = false
    private var usesNumbers = false

    static let emuPerPoint = 12700.0
    var marginPoints: Double = 72

    init(pageSize: CGSize, title: String) {
        self.pageSize = pageSize
        self.title = title
    }

    private var contentWidthPoints: Double { max(72, Double(pageSize.width) - marginPoints * 2) }

    private func run(_ text: String) -> String {
        "<w:r><w:t xml:space=\"preserve\">\(text.xmlEscaped)</w:t></w:r>"
    }

    mutating func addHeading(_ text: String, level: Int, bookmark: String?) {
        let id = drawingIndex + 1000 + body.count
        let start = bookmark.map { "<w:bookmarkStart w:id=\"\(id)\" w:name=\"\($0)\"/>" } ?? ""
        let end = bookmark == nil ? "" : "<w:bookmarkEnd w:id=\"\(id)\"/>"
        body.append("<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(max(level, 1), 3))\"/></w:pPr>\(start)\(run(text))\(end)</w:p>")
    }

    mutating func addParagraph(_ text: String) {
        body.append("<w:p><w:pPr><w:spacing w:after=\"160\"/></w:pPr>\(run(text))</w:p>")
    }

    mutating func addListItem(_ text: String, ordered: Bool) {
        if ordered { usesNumbers = true } else { usesBullets = true }
        body.append("<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(ordered ? 2 : 1)\"/></w:numPr></w:pPr>\(run(text))</w:p>")
    }

    /// Table as the original app writes it for PDF→DOCX: single grey `B8B8B8` borders, header rows repeated on
    /// each page (`w:tblHeader`) and shaded `EDEDED`, then a 1 pt spacer so adjacent tables stay apart.
    /// PDF→DOCX tables with merged cells: the cell
    /// that starts a span gets the summed `tcW`, `gridSpan` and `vMerge restart`; a slot covered from above
    /// becomes an empty `vMerge` continuation; a slot covered from the left is skipped.
    mutating func addTable(rows: [[PDFReflow.TableCell]], widths: [Double], headers: Int) {
        let columns = widths.count
        guard columns > 0, !rows.isEmpty else { return }
        let scale = min(1, contentWidthPoints / max(widths.reduce(0, +), 1))
        let twips = widths.map { max(1, Int(($0 * scale * 20).rounded())) }
        let borders = ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/>" }.joined()
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(twips.reduce(0, +))\" w:type=\"dxa\"/><w:tblBorders>\(borders)</w:tblBorders></w:tblPr><w:tblGrid>"
        xml += twips.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        func slot(_ row: Int, _ column: Int) -> PDFReflow.TableCell {
            column < rows[row].count ? rows[row][column] : PDFReflow.TableCell(text: "")
        }
        for index in rows.indices {
            let header = index < headers
            let shading = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EDEDED\"/>" : ""
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            var column = 0
            while column < columns {
                let cell = slot(index, column)
                var origin = cell
                var continuation = false
                if cell.covered {
                    // Covered from above when a cell in an earlier row spans down into this slot.
                    guard let above = (0..<index).reversed().first(where: { r in
                        let candidate = slot(r, column)
                        return !candidate.covered && r + candidate.rowSpan > index
                    }) else { column += 1; continue }
                    origin = slot(above, column)
                    continuation = true
                }
                let span = max(1, min(origin.columnSpan, columns - column))
                let width = twips[column..<column + span].reduce(0, +)
                var properties = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if span > 1 { properties += "<w:gridSpan w:val=\"\(span)\"/>" }
                if continuation { properties += "<w:vMerge/>" } else if cell.rowSpan > 1 { properties += "<w:vMerge w:val=\"restart\"/>" }
                properties += shading
                let text = continuation ? "" : cell.text
                let content = text.isEmpty ? "" : "<w:r>\(header ? "<w:rPr><w:b/></w:rPr>" : "")<w:t xml:space=\"preserve\">\(text.xmlEscaped)</w:t></w:r>"
                xml += "<w:tc><w:tcPr>\(properties)</w:tcPr><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr>\(content)</w:p></w:tc>"
                column += span
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>"
        body.append(xml)
    }

    mutating func addPageBreak() {
        body.append("<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>")
    }

    /// Inline picture scaled to fit the text column.
    mutating func addImage(png: Data, size: CGSize, label: String, fullPage: Bool = false) {
        drawingIndex += 1
        let name = "image\(drawingIndex).png"
        let rid = "rIdImg\(drawingIndex)"
        media.append((name, png))
        relationships.append("<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>")
        var width = Double(size.width), height = Double(size.height)
        let maxWidth = fullPage ? Double(pageSize.width) : contentWidthPoints
        let maxHeight = fullPage ? Double(pageSize.height) : Double(pageSize.height) - marginPoints * 2
        let scale = min(1, maxWidth / max(width, 1), maxHeight / max(height, 1))
        width *= scale; height *= scale
        let cx = Int(width * Self.emuPerPoint), cy = Int(height * Self.emuPerPoint)
        let spacing = fullPage ? "<w:spacing w:before=\"0\" w:after=\"0\"/>" : "<w:spacing w:after=\"160\"/><w:jc w:val=\"center\"/>"
        body.append("""
        <w:p><w:pPr>\(spacing)</w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(drawingIndex)" name="\(label.xmlEscaped)" descr="\(label.xmlEscaped)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(drawingIndex)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """)
    }

    func data() -> Data {
        let twipsW = Int(Double(pageSize.width) * 20), twipsH = Int(Double(pageSize.height) * 20)
        let margin = Int(marginPoints * 20)
        let orientation = pageSize.width > pageSize.height ? " w:orient=\"landscape\"" : ""
        let sectPr = "<w:sectPr><w:pgSz w:w=\"\(twipsW)\" w:h=\"\(twipsH)\"\(orientation)/><w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body.joined())\(sectPr)</w:body></w:document>
        """
        let headingStyles = (1...3).map { level -> String in
            let size = [0, 40, 32, 28][level]
            return "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
        }.joined()
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\(headingStyles)<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style></w:styles>
        """
        let numbering = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="hybridMultilevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num></w:numbering>
        """
        let settings = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"
        let created = ISO8601DateFormatter().string(from: Date())
        let core = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>\(title.xmlEscaped)</dc:title><dcterms:created xsi:type=\"dcterms:W3CDTF\">\(created)</dcterms:created></cp:coreProperties>"
        let docRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"settings\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/><Relationship Id=\"numbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>\(relationships.joined())</Relationships>"
        let rootRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"main\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"core\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"
        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("docProps/core.xml", core)
        zip.add("word/document.xml", document)
        zip.add("word/styles.xml", styles)
        zip.add("word/settings.xml", settings)
        zip.add("word/numbering.xml", numbering)
        zip.add("word/_rels/document.xml.rels", docRels)
        for item in media { zip.add("word/media/\(item.name)", item.data) }
        return zip.finish()
    }
}
