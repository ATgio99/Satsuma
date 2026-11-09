import ImageIO
import PDFKit
import XCTest
@testable import Satsuma

/// Behaviour that once broke, exercised on real generated media.
final class RegressionTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try XCTSkipIf(ToolLocator.ffmpeg == nil || ToolLocator.ffprobe == nil, "ffmpeg not installed")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SatsumaRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func makeClip(_ name: String, size: String, codec: [String] = []) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc=size=\(size):rate=10", "-t", "0.5"] + codec + [url.path])
        return url
    }

    /// "codec,width,height" of the first video stream, as ffprobe reads it back.
    private func probe(_ url: URL) async throws -> String {
        let text = try await ProcessRunner.run(ToolLocator.ffprobe!, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                                     "stream=codec_name,width,height", "-of", "csv=p=0", url.path])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convert(_ url: URL, from source: ConversionFormat, to target: ConversionFormat,
                         options: ConversionOptions = ConversionOptions()) async throws -> String {
        try await probe(try await MediaConverter.convert(url, from: source, to: target, options: options) { _ in })
    }

    func testGIFConvertsToWebM() async throws {
        let gif = try await makeClip("even.gif", size: "320x240")
        let result = try await convert(gif, from: .gif, to: .webm)
        XCTAssertEqual(result, "vp9,320,240")
    }

    func testOddGIFConvertsToEveryVideoFormat() async throws {
        let gif = try await makeClip("odd.gif", size: "321x241")
        for (target, expected) in [(ConversionFormat.mp4, "h264,320,240"), (.mov, "h264,320,240"), (.mkv, "h264,320,240"),
                                   (.wmv, "wmv2,320,240"), (.webm, "vp9,321,241"), (.avi, "mpeg4,321,241")] {
            let result = try await convert(gif, from: .gif, to: target)
            XCTAssertEqual(result, expected, "\(target)")
        }
    }

    func testOddVideoConvertsToEvenOnlyFormats() async throws {
        let clip = try await makeClip("odd.avi", size: "321x241", codec: ["-c:v", "mpeg4"])
        for (target, expected) in [(ConversionFormat.mp4, "h264,320,240"), (.mkv, "h264,320,240"), (.wmv, "wmv2,320,240")] {
            let result = try await convert(clip, from: .avi, to: target)
            XCTAssertEqual(result, expected, "\(target)")
        }
    }

    func testEvenVideoKeepsItsDimensions() async throws {
        let clip = try await makeClip("even.mov", size: "322x242", codec: ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
        for (target, expected) in [(ConversionFormat.mp4, "h264,322,242"), (.mkv, "h264,322,242"), (.wmv, "wmv2,322,242")] {
            let result = try await convert(clip, from: .mov, to: target)
            XCTAssertEqual(result, expected, "\(target)")
        }
    }

    func testMaximumVideoHeightStaysEven() async throws {
        var options = ConversionOptions()
        let clip = try await makeClip("large.mov", size: "640x480", codec: ["-c:v", "libx264", "-pix_fmt", "yuv420p"])
        let oddClip = try await makeClip("oddsmall.gif", size: "321x241")

        options.videoMaxHeight = 241   // an odd limit must not reach the encoder as an odd height
        let limited = try await convert(clip, from: .mov, to: .mp4, options: options)
        XCTAssertEqual(limited, "h264,320,240")
        let limitedWMV = try await convert(clip, from: .mov, to: .wmv, options: options)
        XCTAssertEqual(limitedWMV, "wmv2,320,240")

        options.videoMaxHeight = 720   // a limit above the source leaves min(H,ih) odd
        let unlimited = try await convert(oddClip, from: .gif, to: .mp4, options: options)
        XCTAssertEqual(unlimited, "h264,320,240")
        let evenUnlimited = try await convert(clip, from: .mov, to: .mkv, options: options)
        XCTAssertEqual(evenUnlimited, "h264,640,480")
    }

    func testVideoArgumentsCarryExactlyOneFilter() {
        var options = ConversionOptions()
        for height in [0, 480] {
            options.videoMaxHeight = height
            for target in [ConversionFormat.mp4, .mov, .mkv, .wmv] {
                let args = MediaConverter.arguments(to: target, from: .gif, options: options)
                XCTAssertEqual(args.filter { $0 == "-vf" }.count, 1, "\(target) at \(height)")
            }
        }
    }

    // MARK: Spreadsheets

    private func writeText(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func odsContent(_ url: URL) async throws -> String {
        try await ProcessRunner.run("/usr/bin/unzip", ["-p", url.path, "content.xml"])
    }

    /// An `.ods` holding exactly this body inside `office:spreadsheet`.
    private func makeODS(_ name: String, spreadsheet: String) throws -> URL {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:spreadsheet>\(spreadsheet)</office:spreadsheet></office:body></office:document-content>"
        var zip = ZipWriter()
        zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet")
        zip.add("content.xml", xml)
        return try writeText(name, zip.finish())
    }

    func testODSWriterProducesATypedPackageThatReadsBackIdentically() async throws {
        let rows = [["Name", "Value", "Note"],
                    ["a<b & \"c\", d", "", "12.5"],
                    ["", "-3", "007"],
                    ["", "", ""],
                    ["tail", "", ""],
                    ["  two  spaces ", "line one\nline two", "tab\there"]]
        let csv = try writeText("typed.csv", Data(SpreadsheetConverter.serialize(rows, separator: ",").utf8))
        let ods = try await SpreadsheetConverter.convert(csv, from: .csv, to: .ods)

        let bytes = try Data(contentsOf: ods)
        XCTAssertEqual(bytes.subdata(in: 8..<10), Data([0, 0]), "first entry must be stored")
        let expectedHead = "mimetypeapplication/vnd.oasis.opendocument.spreadsheet"
        XCTAssertEqual(String(decoding: bytes.subdata(in: 30..<(30 + expectedHead.utf8.count)), as: UTF8.self), expectedHead)
        let manifest = try await ProcessRunner.run("/usr/bin/unzip", ["-p", ods.path, "META-INF/manifest.xml"])
        XCTAssertTrue(manifest.contains("manifest:full-path=\"content.xml\""))

        let content = try await odsContent(ods)
        XCTAssertTrue(content.contains("office:value-type=\"float\" office:value=\"12.5\""))
        XCTAssertTrue(content.contains("a&lt;b &amp; &quot;c&quot;, d"))
        XCTAssertFalse(content.contains("office:value=\"007\""), "leading zeros must stay text")
        XCTAssertNoThrow(try XMLDocument(xmlString: content, options: []))

        let back = try ODS.read(ods)
        XCTAssertEqual(back, rows)
    }

    func testODSReaderHandlesRepeatsCoveredCellsAndRichText() throws {
        let ods = try makeODS("rich.ods", spreadsheet: """
        <table:table table:name="One"><table:table-column table:number-columns-repeated="1024"/>\
        <table:table-header-rows><table:table-row>\
        <table:table-cell office:value-type="string" table:number-columns-spanned="2"><text:p>merged</text:p></table:table-cell>\
        <table:covered-table-cell><text:p>hidden</text:p></table:covered-table-cell>\
        <table:table-cell table:number-columns-repeated="2"/>\
        <table:table-cell office:value-type="float" office:value="0.5"><text:p>50%</text:p></table:table-cell>\
        <table:table-cell table:number-columns-repeated="1048570"/>\
        </table:table-row></table:table-header-rows>\
        <table:table-row table:number-rows-repeated="2"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>\
        <table:table-row table:number-rows-repeated="2">\
        <table:table-cell office:value-type="string" table:number-columns-repeated="2"><text:p>x<text:s text:c="3"/>y</text:p><text:p>second <text:span>span</text:span></text:p>\
        <office:annotation><text:p>a comment</text:p></office:annotation></table:table-cell>\
        </table:table-row>\
        <table:table-row table:number-rows-repeated="1048570"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>\
        </table:table><table:table table:name="Two"><table:table-row><table:table-cell office:value-type="string"><text:p>other sheet</text:p></table:table-cell></table:table-row></table:table>
        """)
        let cell = "x   y\nsecond span"
        XCTAssertEqual(try ODS.read(ods), [["merged", "", "", "", "0.5"], ["", "", "", "", ""], ["", "", "", "", ""],
                                         [cell, cell, "", "", ""], [cell, cell, "", "", ""]])
    }

    func testODSReaderCapsRepeatedValues() throws {
        let ods = try makeODS("huge.ods", spreadsheet: """
        <table:table><table:table-row table:number-rows-repeated="1000000000">\
        <table:table-cell office:value-type="string" table:number-columns-repeated="1000000000"><text:p>x</text:p></table:table-cell>\
        </table:table-row></table:table>
        """)
        XCTAssertThrowsError(try ODS.read(ods))
    }

    func testDelimitedTextFallsBackFromUTF8AndDropsTheBOM() async throws {
        let latin = try writeText("latin.csv", Data([0x43, 0x69, 0x74, 0x74, 0xE0, 0x2C, 0x50, 0x65, 0x72, 0x63, 0x68, 0xE9, 0x0A]))
        let latinRows = try await SpreadsheetConverter.readRows(latin, format: .csv)
        XCTAssertEqual(latinRows, [["Città", "Perché"]])

        let cp1252 = try writeText("win.tsv", Data([0x80, 0x09, 0x31, 0x0A]))
        let windowsRows = try await SpreadsheetConverter.readRows(cp1252, format: .tsv)
        XCTAssertEqual(windowsRows, [["€", "1"]])

        let bom = try writeText("bom.csv", Data([0xEF, 0xBB, 0xBF]) + Data("\"Città\",b\n".utf8))
        let bomRows = try await SpreadsheetConverter.readRows(bom, format: .csv)
        XCTAssertEqual(bomRows, [["Città", "b"]])
        XCTAssertEqual(bomRows[0][0].unicodeScalars.first, "C")
    }

    func testSpreadsheetPetalsFollowTheOriginalOrder() {
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.csv]), [.xlsx, .ods, .tsv, .pdf])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.tsv]), [.xlsx, .ods, .csv, .pdf])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.xlsx]), [.ods, .csv, .tsv, .pdf])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.ods]), [.xlsx, .csv, .tsv, .pdf])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.xls]),
                       ToolLocator.hasNumbers ? [.xlsx, .ods, .csv, .tsv, .pdf] : [])
    }

    // MARK: Images: orientation and target size

    private func realSize(_ url: URL) throws -> Int { try Data(contentsOf: url).count }

    private func image(of url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Re-saves a JPEG through ImageIO carrying `orientation`.
    private func tagged(_ image: CGImage, orientation: Int, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func orientedPhoto(_ name: String = "photo.jpg") async throws -> URL {
        let raw = folder.appendingPathComponent("raw-\(name)")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x480", "-frames:v", "1", "-q:v", "2", raw.path])
        return try tagged(try image(of: raw), orientation: 6, name: name)
    }

    /// Red / green over blue / white quadrants, so every flip and turn is visible.
    private func quadrants(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let (w, h) = (CGFloat(width) / 2, CGFloat(height) / 2)
        for (x, y, rgb) in [(0, 1, (1.0, 0.0, 0.0)), (1, 1, (0.0, 1.0, 0.0)), (0, 0, (0.0, 0.0, 1.0)), (1, 0, (1.0, 1.0, 1.0))] {
            context.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(x) * w, y: CGFloat(y) * h, width: w, height: h))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// RGB of the four corners, top-left first, each rounded to 0 or 1.
    private func corners(_ image: CGImage) throws -> [[Int]] {
        let (width, height) = (image.width, image.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [(8, 8), (width - 9, 8), (8, height - 9), (width - 9, height - 9)].map { x, y in
            (0..<3).map { Int(pixels[y * width * 4 + x * 4 + $0]) > 127 ? 1 : 0 }
        }
    }

    private func orientationTag(_ url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return ImageConverter.orientation(of: try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]))
    }

    private func assertUpright(_ url: URL, width: Int, height: Int, _ message: String, line: UInt = #line) throws {
        let decoded = try image(of: url)
        XCTAssertEqual(decoded.width, width, message, line: line)
        XCTAssertEqual(decoded.height, height, message, line: line)
        XCTAssertEqual(try orientationTag(url), 1, message, line: line)
    }

    func testEveryOrientationDecodesTheWayImageIODisplaysIt() throws {
        let raw = try quadrants(width: 80, height: 60)
        for orientation in 1...8 {
            let url = try tagged(raw, orientation: orientation, name: "o\(orientation).jpg")
            let loaded = try ImageProcessing.loadCGImage(url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let expected = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 80] as CFDictionary))
            XCTAssertEqual(loaded.width, expected.width, "orientation \(orientation)")
            XCTAssertEqual(loaded.height, expected.height, "orientation \(orientation)")
            XCTAssertEqual(try corners(loaded), try corners(expected), "orientation \(orientation)")
        }
    }

    func testSourcesWithoutOrientationKeepTheirPixels() throws {
        let url = try tagged(try quadrants(width: 80, height: 60), orientation: 1, name: "plain.jpg")
        let loaded = try ImageProcessing.loadCGImage(url)
        XCTAssertEqual([loaded.width, loaded.height], [80, 60])
        XCTAssertEqual(try corners(loaded), [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 1]])
    }

    func testOrientedPhotoIsUprightInEveryConversion() async throws {
        let photo = try await orientedPhoto()
        for target in [ConversionFormat.png, .webp, .heic, .tiff, .avif, .bmp, .jpg] where ImageConverter.canConvert(to: target) {
            let output = try await ImageConverter.convert(photo, from: .jpg, to: target, options: ConversionOptions())
            try assertUpright(output, width: 480, height: 640, "\(target)")
        }
        let pdf = try await ImageConverter.convert(photo, from: .jpg, to: .pdf, options: ConversionOptions())
        let page = try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual([page.width, page.height], [480, 640])
    }

    func testOrientedPhotoIsUprightThroughTheTools() async throws {
        let photo = try await orientedPhoto()
        try assertUpright(try await FileToolRunner.compress(photo), width: 480, height: 640, "compress")
        let plan = ImageProcessing.CompressionPlan(strong: true)
        try assertUpright(try ImageProcessing.compressImage(photo, plan: plan), width: 480, height: 640, "compress window")
        let page = try XCTUnwrap(PDFDocument(url: try FileToolRunner.createPDF(from: [photo]))?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual([page.width, page.height], [480, 640])
        let saved = try ImageProcessing.save(try ImageProcessing.loadCGImage(photo), beside: photo, suffix: " edited")
        try assertUpright(saved, width: 480, height: 640, "save keeping metadata")
    }

    func testCollageDrawsTheUprightPhoto() throws {
        // Tag 6 turns the raw quadrants clockwise: blue / red over white / green.
        let url = try tagged(try quadrants(width: 80, height: 60), orientation: 6, name: "cell.jpg")
        let collage = try image(of: try FileToolRunner.createCollage([url]))
        XCTAssertEqual(try corners(collage)[0], [1, 1, 1], "padding")
        let cell = try XCTUnwrap(collage.cropping(to: CGRect(x: 16, y: 16, width: collage.width - 32, height: collage.height - 32)))
        XCTAssertEqual(try corners(cell), [[0, 0, 1], [1, 0, 0], [1, 1, 1], [0, 1, 0]])
    }

    func testCropRectFollowsTheUprightPreview() throws {
        // Tag 6 turns the raw blue quadrant (bottom-left) to the top-left of what the user sees.
        let url = try tagged(try quadrants(width: 80, height: 60), orientation: 6, name: "crop.jpg")
        let image = try ImageProcessing.loadCGImage(url)
        XCTAssertEqual([image.width, image.height], [60, 80])
        let cropped = try XCTUnwrap(ImageProcessing.crop(image, to: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual([cropped.width, cropped.height], [30, 40])
        XCTAssertEqual(try corners(cropped)[0], [0, 0, 1])
        let right = try XCTUnwrap(ImageProcessing.crop(image, to: NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual(try corners(right)[0], [1, 0, 0])
    }

    func testCompressReachesTargetSizeOnDisk() async throws {
        let jpeg = folder.appendingPathComponent("a.jpg")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1600x1200", "-frames:v", "1", "-q:v", "2", jpeg.path])
        for target in [100_000, 40_000] {
            let plan = ImageProcessing.CompressionPlan(targetBytes: Int64(target))
            let output = try ImageProcessing.compressImage(jpeg, plan: plan)
            XCTAssertLessThanOrEqual(try realSize(output), target)
            XCTAssertEqual(ToolFormat.fileSize(output).map(Int.init), try realSize(output))
            XCTAssertNoThrow(try image(of: output))
        }
    }

    func testCompressReachesTargetSizeForPNGByDownscaling() async throws {
        let png = folder.appendingPathComponent("a.png")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1600x1200", "-frames:v", "1", png.path])
        let target = 40_000
        XCTAssertGreaterThan(try realSize(png), target)
        let output = try ImageProcessing.compressImage(png, plan: .init(targetBytes: Int64(target)))
        XCTAssertLessThanOrEqual(try realSize(output), target)
        XCTAssertLessThan(try image(of: output).width, 1600)
    }

    func testImpossibleTargetFailsAndLeavesNoFile() async throws {
        let jpeg = folder.appendingPathComponent("a.jpg")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240", "-frames:v", "1", "-q:v", "2", jpeg.path])
        XCTAssertThrowsError(try ImageProcessing.compressImage(jpeg, plan: .init(targetBytes: 100)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.jpg"])
    }

    // MARK: Join Videos

    /// A one-second clip; with sound it carries a 440 Hz tone.
    private func makeJoinClip(_ name: String, sound: Bool, soundFormat: [String] = ["-ar", "44100", "-ac", "1"]) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        var arguments = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=10"]
        if sound { arguments += ["-f", "lavfi", "-i", "sine=frequency=440"] + soundFormat }
        try await MediaTools.ffmpeg(arguments + ["-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path])
        return url
    }

    private func audioStreamCount(_ url: URL) async throws -> Int {
        let text = try await ProcessRunner.run(ToolLocator.ffprobe!, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                                                     "-of", "csv=p=0", url.path])
        return text.split(separator: "\n").count
    }

    /// Peak level (0...1) of the decoded audio between two times, read from the samples themselves.
    private func peak(_ url: URL, from start: Double, to end: Double) async throws -> Double {
        let pcm = folder.appendingPathComponent("\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: pcm) }
        try await MediaTools.ffmpeg(["-i", url.path, "-vn", "-ss", "\(start)", "-t", "\(end - start)", "-f", "s16le", "-ac", "1", "-ar", "8000", pcm.path])
        let samples = try Data(contentsOf: pcm).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertGreaterThan(samples.count, 1000, "no decoded audio in \(start)-\(end)")
        return Double(samples.map { abs(Int($0)) }.max() ?? 0) / 32768
    }

    private func assertDuration(_ url: URL, about expected: Double, line: UInt = #line) async throws {
        let duration = await MediaConverter.duration(of: url)
        XCTAssertEqual(duration ?? 0, expected, accuracy: 0.2, line: line)
    }

    func testJoinKeepsAudioWhenEveryClipHasIt() async throws {
        let output = try await FileToolRunner.joinVideos([try await makeJoinClip("a.mp4", sound: true), try await makeJoinClip("b.mov", sound: true)])
        XCTAssertEqual(output.lastPathComponent, "a joined.mp4")
        let streams = try await audioStreamCount(output)
        XCTAssertEqual(streams, 1)
        try await assertDuration(output, about: 2)
        for (start, end) in [(0.2, 0.8), (1.2, 1.8)] {
            let level = try await peak(output, from: start, to: end)
            XCTAssertGreaterThan(level, 0.05, "\(start)-\(end)")
        }
    }

    func testJoinWithoutAnyAudioProducesVideoOnly() async throws {
        let output = try await FileToolRunner.joinVideos([try await makeJoinClip("a.mp4", sound: false), try await makeJoinClip("b.mp4", sound: false)])
        XCTAssertEqual(output.lastPathComponent, "a joined.mp4")
        let streams = try await audioStreamCount(output)
        XCTAssertEqual(streams, 0)
        try await assertDuration(output, about: 2)
    }

    func testJoinFillsSilentClipWithSilenceInEitherOrder() async throws {
        let loud = try await makeJoinClip("loud.mp4", sound: true), quiet = try await makeJoinClip("quiet.mp4", sound: false)
        for (clips, loudRange, quietRange) in [([loud, quiet], (0.2, 0.8), (1.2, 1.8)), ([quiet, loud], (1.2, 1.8), (0.2, 0.8))] {
            let output = try await FileToolRunner.joinVideos(clips)
            let streams = try await audioStreamCount(output)
            XCTAssertEqual(streams, 1)
            try await assertDuration(output, about: 2)
            let inLoud = try await peak(output, from: loudRange.0, to: loudRange.1)
            let inQuiet = try await peak(output, from: quietRange.0, to: quietRange.1)
            XCTAssertGreaterThan(inLoud, 0.05, clips[0].lastPathComponent)
            XCTAssertLessThan(inQuiet, 0.001, clips[0].lastPathComponent)
        }
    }

    func testJoinSilenceMatchesTheOtherClipsFormat() async throws {
        let stereo = try await makeJoinClip("stereo.mp4", sound: true, soundFormat: ["-ar", "48000", "-ac", "2"])
        let output = try await FileToolRunner.joinVideos([try await makeJoinClip("quiet.mp4", sound: false), stereo])
        let text = try await ProcessRunner.run(ToolLocator.ffprobe!, ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=sample_rate,channels",
                                                                     "-of", "csv=p=0", output.path])
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "48000,2")
    }

    func testJoinHearsAudioInContainersAVFoundationCannotRead() async throws {
        let mkv = try await makeJoinClip("loud.mkv", sound: true), quiet = try await makeJoinClip("quiet.mp4", sound: false)
        let output = try await FileToolRunner.joinVideos([mkv, quiet])
        let level = try await peak(output, from: 0.2, to: 0.8)
        XCTAssertGreaterThan(level, 0.05)
    }

    func testFailedJoinLeavesNoFile() async throws {
        let video = try await makeJoinClip("a.mp4", sound: true)
        let audioOnly = folder.appendingPathComponent("b.m4a")
        try await MediaTools.ffmpeg(["-i", video.path, "-vn", "-c:a", "copy", audioOnly.path])
        do {
            _ = try await FileToolRunner.joinVideos([video, audioOnly])
            XCTFail("joining an audio-only file must fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["a.mp4", "b.m4a"])
    }

    // MARK: Second review

    func testUTF16DelimitedTextIsDecoded() async throws {
        let text = "nome,citt\u{E0}\n\u{65E5}\u{672C}\u{8A9E},\u{1F600}\n"
        let little = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let big = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        for (name, data) in [("le.csv", little), ("be.csv", big)] {
            let rows = try await SpreadsheetConverter.readRows(try writeText(name, data), format: .csv)
            XCTAssertEqual(rows, [["nome", "citt\u{E0}"], ["\u{65E5}\u{672C}\u{8A9E}", "\u{1F600}"]], name)
        }
    }

    func testBytesOnlyReadableAsGarbageAreRefused() async throws {
        let noBOM = "a,b\n1,2\n".data(using: .utf16LittleEndian)!
        let accentedNoBOM = "citt\u{E0},b\n".data(using: .utf16LittleEndian)!
        let truncated = Data("citt\u{E0},perch\u{E9},caff\u{E8}\n".utf8) + Data([0xC3])
        for (name, data) in [("a.csv", noBOM), ("b.csv", accentedNoBOM), ("c.csv", truncated)] {
            let url = try writeText(name, data)
            do {
                let rows = try await SpreadsheetConverter.readRows(url, format: .csv)
                XCTFail("\(name) decoded as \(rows)")
            } catch {}
        }
    }

    func testOddSourcesSurviveEveryCompressPath() async throws {
        let gif = try await makeClip("odd.gif", size: "321x241")
        let quick = try await FileToolRunner.compress(gif)
        let quickResult = try await probe(quick)
        XCTAssertEqual(quickResult, "h264,320,240")
        for plan in [ImageProcessing.CompressionPlan(), .init(strong: true), .init(targetBytes: 2_000_000)] {
            let output = try await MediaTools.compressVideo(gif, plan: plan) { _ in }
            let result = try await probe(output)
            XCTAssertEqual(result, "h264,320,240", "\(plan)")
            try FileManager.default.removeItem(at: output)
        }
    }

    func testOddSourcesSurviveTheVideoTools() async throws {
        let clip = try await makeClip("odd.mov", size: "321x241", codec: ["-c:v", "mpeg4"])
        let trimmed = try await MediaTools.trim(clip, start: 0, end: 0.3, audioOnly: false) { _ in }
        let speed = try await MediaTools.changeSpeed(clip, speed: 2) { _ in }
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let solid = try await MediaTools.redactVideo(clip, rects: [box], blur: false) { _ in }
        let blurred = try await MediaTools.redactVideo(clip, rects: [box], blur: true) { _ in }
        for output in [trimmed, speed, solid, blurred] {
            let result = try await probe(output)
            XCTAssertEqual(result, "h264,320,240", output.lastPathComponent)
        }
        let clips = try await MediaTools.split(clip, points: [0.2], duration: 0.5) { _ in }
        let first = clips.appendingPathComponent("odd 01.mov")
        let splitResult = try await probe(first)
        XCTAssertEqual(splitResult, "h264,320,240")
    }

    func testMaximumHeightHandlesHairlineSources() async throws {
        var options = ConversionOptions()
        options.videoMaxHeight = 480
        let gif = try await makeClip("thin.gif", size: "1x101")
        for (target, expected) in [(ConversionFormat.wmv, "wmv2,2,100"), (.mp4, "h264,2,100"), (.mkv, "h264,2,100")] {
            let result = try await convert(gif, from: .gif, to: target, options: options)
            XCTAssertEqual(result, expected, "\(target)")
        }
    }

    func testTargetSizeStillTriesImagesTooSmallToDownscale() async throws {
        for (name, size) in [("s1.png", "1x1"), ("s2.png", "10x10"), ("s3.jpg", "15x8")] {
            let url = folder.appendingPathComponent(name)
            try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc=size=\(size)", "-frames:v", "1", url.path])
            let output = try ImageProcessing.compressImage(url, plan: .init(targetBytes: 1_000_000))
            let decoded = try image(of: output)
            XCTAssertEqual("\(decoded.width)x\(decoded.height)", size, name)
        }
    }

    func testCompressWritesRealWebP() async throws {
        try XCTSkipIf(ToolLocator.path("cwebp") == nil, "cwebp not installed")
        let png = folder.appendingPathComponent("a.png")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x480", "-frames:v", "1", png.path])
        let webp = try await ImageConverter.convert(png, from: .png, to: .webp, options: ConversionOptions())
        for plan in [ImageProcessing.CompressionPlan(targetBytes: 6_000), .init(strong: true)] {
            let output = try ImageProcessing.compressImage(webp, plan: plan)
            XCTAssertEqual(output.pathExtension, "webp")
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(String(decoding: bytes.subdata(in: 8..<12), as: UTF8.self), "WEBP")
            if let target = plan.targetBytes { XCTAssertLessThanOrEqual(bytes.count, Int(target)) }
            XCTAssertNoThrow(try image(of: output))
            try FileManager.default.removeItem(at: output)
        }
    }

    func testRotatedOutputDeclaresTheRotatedSizeInEXIF() async throws {
        let url = folder.appendingPathComponent("sized.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifPixelXDimension: 80, kCGImagePropertyExifPixelYDimension: 60]
        CGImageDestinationAddImage(destination, try quadrants(width: 80, height: 60),
                                   [kCGImagePropertyOrientation: 6, kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for target in [ConversionFormat.heic, .avif] where ImageConverter.canConvert(to: target) {
            let output = try await ImageConverter.convert(url, from: .jpg, to: target, options: ConversionOptions())
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
            let written = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any], "\(target)")
            XCTAssertEqual(written[kCGImagePropertyExifPixelXDimension] as? Int, 60, "\(target)")
            XCTAssertEqual(written[kCGImagePropertyExifPixelYDimension] as? Int, 80, "\(target)")
        }
    }

    /// Grey levels (0...255) of the four quadrant centres, top-left first, as ImageIO displays them.
    private func greyLevels(_ image: CGImage) throws -> [Int] {
        let (width, height) = (image.width, image.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [(width / 4, height / 4), (width * 3 / 4, height / 4), (width / 4, height * 3 / 4), (width * 3 / 4, height * 3 / 4)].map {
            Int(pixels[$0.1 * width * 4 + $0.0 * 4])
        }
    }

    func testRotatedSixteenBitGreyKeepsItsTones() async throws {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 16, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for (x, y, grey) in [(0, 1, 0.2), (1, 1, 0.5), (0, 0, 0.97), (1, 0, 0.85)] as [(CGFloat, CGFloat, CGFloat)] {
            canvas.setFillColor(CGColor(gray: grey, alpha: 1))
            canvas.fill(CGRect(x: x * 32, y: y * 24, width: 32, height: 24))
        }
        let url = folder.appendingPathComponent("grey.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let expected = try greyLevels(try ImageProcessing.loadCGImage(url))
        let output = try await ImageConverter.convert(url, from: .png, to: .heic, options: ConversionOptions())
        let levels = try greyLevels(try image(of: output))
        for (level, want) in zip(levels, expected) { XCTAssertEqual(Double(level), Double(want), accuracy: 12, "\(levels) vs \(expected)") }
        XCTAssertEqual(try image(of: output).width, 48)
    }

    func testJoinFillsSilentClipThatHasNoDurationHeader() async throws {
        let piped = folder.appendingPathComponent("piped.webm")
        try await ProcessRunner.run("/bin/sh", ["-c", "\"$0\" -hide_banner -loglevel error -nostdin -f lavfi -i testsrc=size=320x240:rate=25:d=1 -c:v libvpx-vp9 -b:v 200k -f webm - | cat > \"$1\"",
                                                ToolLocator.ffmpeg!, piped.path])
        let reported = await MediaConverter.duration(of: piped)
        XCTAssertNil(reported, "the fixture must carry no container duration")
        let loud = try await makeJoinClip("loud.mp4", sound: true)
        let output = try await FileToolRunner.joinVideos([piped, loud])
        try await assertDuration(output, about: 2)
        let inQuiet = try await peak(output, from: 0.2, to: 0.8)
        let inLoud = try await peak(output, from: 1.2, to: 1.8)
        XCTAssertLessThan(inQuiet, 0.001)
        XCTAssertGreaterThan(inLoud, 0.05)
        let reversed = try await FileToolRunner.joinVideos([loud, piped])
        try await assertDuration(reversed, about: 2)
    }

    private func firstSheet(_ body: String) -> String { "<table:table>\(body)</table:table>" }

    func testODSLimitCountsBytesAndReportsTheOverrun() throws {
        let long = String(repeating: "x", count: 200)
        let wide = try makeODS("wide.ods", spreadsheet: firstSheet("""
        <table:table-row table:number-rows-repeated="1048576"><table:table-cell office:value-type="string" table:number-columns-repeated="16384"><text:p>\(long)</text:p></table:table-cell></table:table-row>
        """))
        XCTAssertThrowsError(try ODS.read(wide))
        let spaces = String(repeating: "<text:s text:c=\"4096\"/>", count: 200_000)
        let padded = try makeODS("spaces.ods", spreadsheet: firstSheet("""
        <table:table-row><table:table-cell office:value-type="string"><text:p>\(spaces)</text:p></table:table-cell></table:table-row>
        """))
        XCTAssertThrowsError(try ODS.read(padded))
    }

    func testODSWithManyOrdinaryRepeatsKeepsItsLastRow() throws {
        let cells = (0..<6).map { "<table:table-cell office:value-type=\"float\" office:value=\"\($0)\"><text:p>\($0)</text:p></table:table-cell>" }.joined()
        let ods = try makeODS("long.ods", spreadsheet: firstSheet("""
        <table:table-row table:number-rows-repeated="900000">\(cells)</table:table-row>\
        <table:table-row><table:table-cell office:value-type="string"><text:p>TOTAL</text:p></table:table-cell></table:table-row>
        """))
        let rows = try ODS.read(ods)
        XCTAssertEqual(rows.count, 900_001)
        guard rows.count == 900_001 else { return }
        XCTAssertEqual(rows[899_999], ["0", "1", "2", "3", "4", "5"])
        XCTAssertEqual(rows.last?.first, "TOTAL")
    }

    func testODSTypedCellsWithoutParagraphsKeepTheirValues() throws {
        let ods = try makeODS("bare.ods", spreadsheet: firstSheet("""
        <table:table-row>\
        <table:table-cell office:value-type="date" office:date-value="2026-11-09"/>\
        <table:table-cell office:value-type="boolean" office:boolean-value="true"/>\
        <table:table-cell office:value-type="time" office:time-value="PT13H45M00S"/>\
        <table:table-cell office:value-type="float" office:value="5"/>\
        <table:table-cell office:value-type="date" office:date-value="2026-01-02"><text:p>02/01/26</text:p></table:table-cell>\
        </table:table-row>
        """))
        XCTAssertEqual(try ODS.read(ods), [["2026-11-09", "true", "PT13H45M00S", "5", "02/01/26"]])
    }

    func testODSWriterTypesOnlyWhatAFloatCanHold() async throws {
        let rows = [["999999999999999.99", "0.12345678901234567890123", "1\u{0662}\u{0663}", "0.\u{0662}\u{0663}", "123456.789", "-0.5", "a\u{FFFE}b\u{FFFF}c"]]
        let csv = try writeText("w.csv", Data(SpreadsheetConverter.serialize(rows, separator: ",").utf8))
        let ods = try await SpreadsheetConverter.convert(csv, from: .csv, to: .ods)
        let content = try await odsContent(ods)
        XCTAssertNoThrow(try XMLDocument(xmlString: content, options: []))
        XCTAssertEqual(content.components(separatedBy: "value-type=\"float\"").count - 1, 2)
        XCTAssertTrue(content.contains("office:value=\"123456.789\""))
        XCTAssertTrue(content.contains("office:value=\"-0.5\""))
        XCTAssertEqual(try ODS.read(ods)[0].last, "abc")
    }

    func testODSExponentValueStaysNumericInXLSX() async throws {
        let ods = try makeODS("n.ods", spreadsheet: firstSheet("""
        <table:table-row>\
        <table:table-cell office:value-type="float" office:value="1E+020"><text:p>1E+20</text:p></table:table-cell>\
        <table:table-cell office:value-type="float" office:value="1.5E-007"><text:p>1.5E-07</text:p></table:table-cell>\
        </table:table-row>
        """))
        let xlsx = try await SpreadsheetConverter.convert(ods, from: .ods, to: .xlsx)
        let sheet = try await ProcessRunner.run("/usr/bin/unzip", ["-p", xlsx.path, "xl/worksheets/sheet1.xml"])
        XCTAssertFalse(sheet.contains("inlineStr"), sheet)
        XCTAssertEqual(try XLSX.read(xlsx)[0].compactMap(Double.init), [1e20, 1.5e-7])
    }

}
