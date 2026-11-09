import AppKit
import PDFKit
import XCTest
@testable import Satsuma

final class RegistryTests: XCTestCase {
    func testPetalOrderMatchesBinaryArrays() {
        XCTAssertEqual(ActionRegistry.candidates(for: .pdf), [.docx, .pages, .pptx, .xlsx, .jpg, .png, .svg, .epub, .txt, .md])
        XCTAssertEqual(ActionRegistry.candidates(for: .heic), [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf])
        XCTAssertEqual(ActionRegistry.candidates(for: .mov), [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3])
    }

    func testSourceFormatIsExcludedFromItsOwnWheel() {
        let outputs = ActionRegistry.conversionOutputs(for: [.png])
        XCTAssertFalse(outputs.contains(.png))
        XCTAssertTrue(outputs.contains(.jpg))
        XCTAssertTrue(outputs.contains(.pdf))
    }

    func testInputOnlyFormatsNeverAppearAsOutputs() {
        for source in ConversionFormat.allCases {
            // SVG is output only for PDF pages; everywhere else it stays input-only.
            for output in ActionRegistry.conversionOutputs(for: [source]) where !(source == .pdf && output == .svg) {
                XCTAssertFalse(output.isInputOnly, "\(source) offers input-only \(output)")
            }
        }
    }

    func testMixedGroupsHaveNoSharedConversions() {
        XCTAssertTrue(ActionRegistry.conversionOutputs(for: [.png, .mp3]).isEmpty)
    }

    func testToolsIntersectAndFallBackToQRCode() {
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.pdf]), [.compress, .removeMetadata, .splitPDF, .organizePDF, .convertPDFA, .readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.pdf, .pdf]), [.compress, .removeMetadata, .splitPDF, .mergePDF, .convertPDFA, .readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.svg, .pdf]), [.readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.svg, .svg]), [.createPDF, .createCollage, .readQRCode])
    }

    func testActionsWheelIsStatic() {
        XCTAssertEqual(ActionRegistry.actions(for: [], mode: .fileActions), ConversionFanAction.fileActions)
    }
}

final class FanGeometryTests: XCTestCase {
    func testFirstPetalIsAtTopAndThreePetalsStartAtPi() {
        XCTAssertEqual(PetalGeometry.centerAngle(slot: 0, count: 6), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(PetalGeometry.centerAngle(slot: 0, count: 3), .pi, accuracy: 1e-9)
        XCTAssertEqual(PetalGeometry.centerAngle(slot: 1, count: 4), 0, accuracy: 1e-9)
    }

    func testRadiiMatchTheBinary() {
        XCTAssertEqual(PetalGeometry.innerRadius, 48.64, accuracy: 1e-9)
        XCTAssertEqual(PetalGeometry.outerRadius, 119.52, accuracy: 1e-9)
        XCTAssertEqual(PetalGeometry.labelRadius, 84.5312, accuracy: 1e-9)
    }

    /// The first segment of the original app's published PNG petal (7 petals): M 22.6358 -51.6132 L 41.3000 -90.3699.
    func testPetalPathMatchesPublishedGeometry() {
        var points: [CGPoint] = []
        PetalGeometry.petalPath(center: .zero, slot: 0, count: 7).applyWithBlock { element in
            if points.count < 2 { points.append(element.pointee.points[0]) }
        }
        XCTAssertEqual(points[0].x, 22.6358, accuracy: 1e-3)
        XCTAssertEqual(points[0].y, -51.6132, accuracy: 1e-3)
        XCTAssertEqual(points[1].x, 41.3000, accuracy: 1e-3)
        XCTAssertEqual(points[1].y, -90.3699, accuracy: 1e-3)
    }

    func testHitTesting() {
        XCTAssertEqual(PetalGeometry.slot(atOffset: 0, -84, count: 6), 0, "top petal")
        XCTAssertNil(PetalGeometry.slot(atOffset: 0, -30, count: 6), "hub")
        XCTAssertNil(PetalGeometry.slot(atOffset: 0, -130, count: 6), "outside")
        XCTAssertEqual(PetalGeometry.slot(atOffset: 84, 0, count: 4), 1, "clockwise: right is slot 1 of 4")
    }

    func testLabelPosition() {
        let point = PetalGeometry.labelCenter(center: CGPoint(x: 100, y: 100), angle: .pi / 2)
        XCTAssertEqual(100 - point.y, PetalGeometry.labelRadius, accuracy: 1e-6)
    }
}

final class SettingsTests: XCTestCase {
    func testModifierDefaultsAndExactMatch() {
        let defaults = UserDefaults(suiteName: "SatsumaTests-\(UUID().uuidString)")!
        let model = SettingsModel(defaults: defaults)
        XCTAssertEqual(model.conversionMask, 8)
        XCTAssertEqual(model.toolsMask, 1)
        XCTAssertEqual(model.actionsMask, 4)
        XCTAssertEqual(model.mode(for: [.shift]), .conversions)
        XCTAssertEqual(model.mode(for: [.command]), .fileTools)
        XCTAssertEqual(model.mode(for: [.control]), .fileActions)
        XCTAssertNil(model.mode(for: [.shift, .command]))
    }

    func testCenterLabels() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        XCTAssertEqual(ConversionOverlayController.idleLabel(urls: urls, formats: [.png, .png], folders: 0, unknown: 0), "2 PNG FILES")
        XCTAssertEqual(ConversionOverlayController.idleLabel(urls: urls, formats: [.png, .jpg], folders: 0, unknown: 0), "2 MIXED FILES")
        XCTAssertEqual(ConversionOverlayController.idleLabel(urls: urls, formats: [], folders: 2, unknown: 0), "2 FOLDERS")
    }
}

final class ConverterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SatsumaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testSubtitleRoundTrip() throws {
        let srt = folder.appendingPathComponent("clip.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try SubtitleConverter.convert(srt, to: .vtt)
        let text = try String(contentsOf: vtt, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("WEBVTT"))
        XCTAssertTrue(text.contains("00:00:01.000 --> 00:00:02.500"))
    }

    func testCSVParsingHandlesQuotes() {
        let rows = SpreadsheetConverter.parseDelimited("a,\"b,c\",\"d \"\"q\"\"\"\n1,2,3\n", separator: ",")
        XCTAssertEqual(rows, [["a", "b,c", "d \"q\""], ["1", "2", "3"]])
    }

    func testOutputNamingNeverOverwrites() throws {
        let source = folder.appendingPathComponent("photo.png")
        try Data().write(to: source)
        try Data().write(to: folder.appendingPathComponent("photo.jpg"))
        XCTAssertEqual(OutputNaming.destination(for: source, extension: "jpg").lastPathComponent, "photo 2.jpg")
    }

    /// Builds a PDF with a big heading, body text and a bullet, then runs the reflow pipeline.
    func testPDFReflowFindsHeadingsAndLists() throws {
        let pdfURL = folder.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        func draw(_ text: String, size: CGFloat, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(line, context)
        }
        draw("Annual Report Overview", size: 26, y: 700)
        draw("This is the body text of the document, written at the normal size.", size: 12, y: 660)
        draw("It continues on a second line of the same paragraph here.", size: 12, y: 645)
        draw("• First bullet item", size: 12, y: 610)
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let result = try PDFReflow.analyze(document, extractArtwork: false) { _ in }
        guard case .heading(1, let title, _)? = result.blocks.first else { return XCTFail("expected an H1, got \(result.blocks)") }
        XCTAssertEqual(title, "Annual Report Overview")
        XCTAssertTrue(result.blocks.contains { if case .paragraph(let text) = $0 { return text.contains("second line") } else { return false } })
        XCTAssertTrue(result.blocks.contains { if case .listItem(false, "First bullet item") = $0 { return true } else { return false } })

        // DOCX package must unzip cleanly and contain the heading.
        let docx = try PDFConverter.docxData(document, title: "sample", options: ConversionOptions()) { _ in }
        let docxURL = folder.appendingPathComponent("sample.docx")
        try docx.write(to: docxURL)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", docxURL.path, "word/document.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertTrue(xml.contains("Heading1"))
        XCTAssertTrue(xml.contains("Annual Report Overview"))
    }

    /// A ruled table (stroked grid) and a borderless one (aligned columns) become `.table` blocks and `w:tbl`.
    func testPDFTablesBecomeWordTables() throws {
        let pdfURL = folder.appendingPathComponent("tables.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat, bold: Bool = false) {
            let font = bold ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        draw("The quarterly figures are summarised in the table below for each region.", x: 72, y: 720)
        // Ruled table: 3 columns × 4 rows, rules at x 72/222/372/522 and y 700/680/660/640/620.
        let xs: [CGFloat] = [72, 222, 372, 522], ys: [CGFloat] = [700, 680, 660, 640, 620]
        context.setLineWidth(0.75)
        for y in ys { context.move(to: CGPoint(x: xs.first!, y: y)); context.addLine(to: CGPoint(x: xs.last!, y: y)) }
        for x in xs { context.move(to: CGPoint(x: x, y: ys.first!)); context.addLine(to: CGPoint(x: x, y: ys.last!)) }
        context.strokePath()
        let ruled = [["Region", "Revenue", "Growth"], ["North", "1,200", "4%"], ["South", "980", "2%"], ["West", "1,450", "7%"]]
        for (row, cells) in ruled.enumerated() {
            for (column, text) in cells.enumerated() { draw(text, x: xs[column] + 6, y: ys[row] - 14, bold: row == 0) }
        }
        draw("A second table lists the team without any borders at all.", x: 72, y: 580)
        // Borderless table: aligned columns at x 72 / 260 / 420.
        let plain = [["Name", "Role", "City"], ["Alice Moore", "Designer", "Milan"], ["Bruno Ricci", "Engineer", "Rome"], ["Carla Neri", "Manager", "Turin"]]
        for (row, cells) in plain.enumerated() {
            for (column, text) in cells.enumerated() { draw(text, x: [72, 260, 420][column], y: 550 - CGFloat(row) * 18) }
        }
        draw("The document ends with this closing paragraph of ordinary text.", x: 72, y: 450)
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let result = try PDFReflow.analyze(document, extractArtwork: false) { _ in }
        let tables: [([[String]], [Double], Int)] = result.blocks.compactMap {
            if case .table(let rows, let widths, let headers) = $0 { return (rows.map { $0.map(\.text) }, widths, headers) } else { return nil }
        }
        XCTAssertEqual(tables.count, 2, "blocks: \(result.blocks)")
        guard tables.count == 2 else { return }
        XCTAssertEqual(tables[0].0, ruled)
        XCTAssertEqual(tables[0].1, [150, 150, 150])
        XCTAssertEqual(tables[0].2, 1)
        XCTAssertEqual(tables[1].0, plain)
        XCTAssertEqual(tables[1].2, 1)
        // Order: paragraph, table, paragraph, table, paragraph; no cell text leaks into paragraphs.
        let kinds = result.blocks.map { block -> String in
            switch block { case .table: return "table"; case .paragraph: return "p"; default: return "other" }
        }
        XCTAssertEqual(kinds, ["p", "table", "p", "table", "p"])

        let docx = try PDFConverter.docxData(document, title: "tables", options: ConversionOptions()) { _ in }
        let docxURL = folder.appendingPathComponent("tables.docx")
        try docx.write(to: docxURL)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", docxURL.path, "word/document.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        XCTAssertEqual(xml.components(separatedBy: "<w:tbl>").count - 1, 2)
        XCTAssertTrue(xml.contains("w:color=\"B8B8B8\""))
        XCTAssertTrue(xml.contains("<w:tblHeader/>"))
        XCTAssertTrue(xml.contains("w:fill=\"EDEDED\""))
        XCTAssertTrue(xml.contains("Bruno Ricci"))
    }

    /// Missing rules merge grid slots: a header spanning two rows and one spanning two columns
    /// become `w:vMerge` and `w:gridSpan`, like the original app's `SDCell` writer.
    func testPDFTableMergedCells() throws {
        let pdfURL = folder.appendingPathComponent("merged.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
        func rule(_ a: CGPoint, _ b: CGPoint) { context.move(to: a); context.addLine(to: b) }
        draw("Sales by region are shown below with grouped column headings.", x: 72, y: 720)
        context.setLineWidth(0.75)
        for y: CGFloat in [700, 660, 640, 620] { rule(CGPoint(x: 72, y: y), CGPoint(x: 522, y: y)) }
        rule(CGPoint(x: 222, y: 680), CGPoint(x: 522, y: 680))   // not under "Region": it spans two rows
        for x: CGFloat in [72, 222, 522] { rule(CGPoint(x: x, y: 700), CGPoint(x: x, y: 620)) }
        rule(CGPoint(x: 372, y: 680), CGPoint(x: 372, y: 620))   // not in the first row: "Results" spans two columns
        context.strokePath()
        draw("Region", x: 78, y: 666)
        draw("Results", x: 228, y: 686)
        draw("Revenue", x: 228, y: 666)
        draw("Growth", x: 378, y: 666)
        for (row, cells) in [["North", "1,200", "4%"], ["South", "980", "2%"]].enumerated() {
            for (column, text) in cells.enumerated() { draw(text, x: [78, 228, 378][column], y: 646 - CGFloat(row) * 20) }
        }
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(PDFDocument(url: pdfURL))
        let result = try PDFReflow.analyze(document, extractArtwork: false) { _ in }
        guard let (rows, headers) = result.blocks.lazy.compactMap({ block -> ([[PDFReflow.TableCell]], Int)? in
            if case .table(let rows, _, let headers) = block { return (rows, headers) } else { return nil }
        }).first else { return XCTFail("no table in \(result.blocks)") }
        typealias Cell = PDFReflow.TableCell
        XCTAssertEqual(rows, [
            [Cell(text: "Region", rowSpan: 2), Cell(text: "Results", columnSpan: 2), Cell(text: "", covered: true)],
            [Cell(text: "", covered: true), Cell(text: "Revenue"), Cell(text: "Growth")],
            [Cell(text: "North"), Cell(text: "1,200"), Cell(text: "4%")],
            [Cell(text: "South"), Cell(text: "980"), Cell(text: "2%")],
        ])
        XCTAssertEqual(headers, 2)

        let docx = try PDFConverter.docxData(document, title: "merged", options: ConversionOptions()) { _ in }
        let docxURL = folder.appendingPathComponent("merged.docx")
        try docx.write(to: docxURL)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", docxURL.path, "word/document.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        XCTAssertTrue(xml.contains("<w:tcW w:w=\"6000\" w:type=\"dxa\"/><w:gridSpan w:val=\"2\"/>"), xml)
        XCTAssertTrue(xml.contains("<w:vMerge w:val=\"restart\"/>"))
        XCTAssertTrue(xml.contains("<w:vMerge/>"))
        // Row 1 has three grid slots but only two cells, row 2 three: 2 + 3 + 3 + 3 cells.
        XCTAssertEqual(xml.components(separatedBy: "<w:tc>").count - 1, 11)

        let html = PDFConverter.tableHTML(rows: rows, widths: [150, 150, 150], headers: headers)
        XCTAssertTrue(html.contains("<th rowspan=\"2\">Region</th><th colspan=\"2\">Results</th>"))
    }
}

final class HighlightClickTests: XCTestCase {
    func testClickIsShortBrightAndValidWAV() throws {
        let samples = HighlightClick.samples()
        XCTAssertEqual(samples.count, 2_880)                       // 60 ms at 48 kHz, like the original
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.5, accuracy: 0.001)
        let energy = samples.map { $0 * $0 }
        let head = energy[0..<480].reduce(0, +), rest = energy[480...].reduce(0, +)
        XCTAssertGreaterThan(head, rest * 4)                       // nearly all of it in the first 10 ms
        let data = HighlightClick.wavData()
        XCTAssertEqual(data.count, 44 + 2_880 * 4)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        if let url = ProcessInfo.processInfo.environment["SATSUMA_CLICK_OUT"] { try data.write(to: URL(fileURLWithPath: url)) }
    }
}
