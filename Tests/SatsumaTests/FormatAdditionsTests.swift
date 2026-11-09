import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import Satsuma

/// Later additions: RAW input and GZIP as an archive output.
final class FormatAdditionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SatsumaFormatAdditions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Registry

    func testRawIsInputOnlyImageRightAfterBMP() {
        let cases = ConversionFormat.allCases
        XCTAssertEqual(cases[cases.firstIndex(of: .bmp)! + 1], .raw)
        XCTAssertEqual(ConversionFormat.raw.group, .images)
        XCTAssertTrue(ConversionFormat.raw.isInputOnly)
        XCTAssertFalse(ConversionFormat.gzip.isInputOnly)
        XCTAssertEqual(ConversionFormat.raw.title, "RAW")
    }

    func testEveryRawExtensionIsDetected() {
        let extensions = ["3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mos", "mrw",
                          "nef", "nrw", "orf", "pef", "ptx", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw"]
        XCTAssertEqual(ConversionFormat.rawExtensions, Set(extensions))
        for ext in extensions + ["DNG", "Nef"] {
            XCTAssertEqual(ConversionFormat.detect(URL(fileURLWithPath: "/tmp/photo.\(ext)")), .raw, ext)
        }
    }

    func testRawWheelsAreTheImageWheels() {
        XCTAssertEqual(ActionRegistry.candidates(for: .raw), [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf])
        let outputs = ActionRegistry.conversionOutputs(for: [.raw])
        XCTAssertFalse(outputs.contains(.raw))
        for format in ConversionFormat.allCases {
            XCTAssertFalse(ActionRegistry.conversionOutputs(for: [format]).contains(.raw), "\(format)")
        }
        // The original app's per-format table sends RAW, like AVIF and BMP, to QR Code alone.
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.raw]), [.readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.raw, .raw]), [.readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.raw, .jpg]), [.readQRCode])
    }

    func testArchivePetalsAndOrder() {
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.zip]), [.tar, .gzip])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.tar]), [.zip, .gzip])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.gzip]), [.zip, .tar])
        XCTAssertEqual(ActionRegistry.conversionOutputs(for: [.rar]), [.zip, .tar, .gzip])
        for source in ConversionFormat.allCases where source.group != .archives {
            XCTAssertFalse(ActionRegistry.conversionOutputs(for: [source]).contains(.gzip), "\(source)")
        }
    }

    // MARK: RAW

    /// A minimal Bayer DNG: red rises left to right and blue rises top to bottom, so every corner differs.
    private func makeDNG(_ name: String, orientation: UInt16 = 1, width: UInt32 = 320, height: UInt32 = 240) throws -> URL {
        var pixels = Data(capacity: Int(width * height) * 2)
        for y in 0..<height {
            for x in 0..<width {
                let red = 1000 + 60000 * x / (width - 1), blue = 1000 + 60000 * y / (height - 1)
                let value: UInt32 = x % 2 == 0 ? (y % 2 == 0 ? red : 20000) : (y % 2 == 0 ? 20000 : blue)
                pixels.append(le16: UInt16(value))
            }
        }
        // Tag, TIFF type, count, inline value or out-of-line bytes.
        typealias Entry = (tag: UInt16, type: UInt16, count: UInt32, value: UInt32?, data: Data?)
        func text(_ tag: UInt16, _ string: String) -> Entry {
            let bytes = Data(string.utf8) + [0]
            return (tag, 2, UInt32(bytes.count), nil, bytes)
        }
        func bytes(_ tag: UInt16, _ values: [UInt8]) -> Entry {
            (tag, 1, UInt32(values.count), UInt32(values.enumerated().reduce(0) { $0 + UInt32($1.element) << (8 * $1.offset) }), nil)
        }
        func rationals(_ tag: UInt16, signed: Bool, _ values: [Int32]) -> Entry {
            var data = Data()
            for value in values { data.append(le32: UInt32(bitPattern: value)); data.append(le32: 10000) }
            return (tag, signed ? 10 : 5, UInt32(values.count), nil, data)
        }
        var entries: [Entry] = [
            (254, 4, 1, 0, nil), (256, 4, 1, width, nil), (257, 4, 1, height, nil), (258, 3, 1, 16, nil), (259, 3, 1, 1, nil),
            (262, 3, 1, 32803, nil), text(271, "Satsuma"), text(272, "Synthetic"), (273, 4, 1, nil, Data()),
            (274, 3, 1, UInt32(orientation), nil), (277, 3, 1, 1, nil), (278, 4, 1, height, nil), (279, 4, 1, UInt32(pixels.count), nil),
            (284, 3, 1, 1, nil), (33421, 3, 2, 2 | 2 << 16, nil), bytes(33422, [0, 1, 1, 2]),
            bytes(50706, [1, 4, 0, 0]), bytes(50707, [1, 1, 0, 0]), text(50708, "Satsuma Synthetic"), bytes(50710, [0, 1, 2]),
            (50711, 3, 1, 1, nil), (50714, 3, 1, 0, nil), (50717, 4, 1, 65535, nil),
            rationals(50721, signed: true, [32405, -15371, -4985, -9693, 18760, 415, 556, -2040, 10572]),
            rationals(50728, signed: false, [10000, 10000, 10000]), (50778, 3, 1, 21, nil),
        ]
        entries.sort { $0.tag < $1.tag }
        let ifdEnd = 8 + 2 + 12 * entries.count + 4
        var extra = Data()
        var directory = Data()
        directory.append(le16: UInt16(entries.count))
        for entry in entries {
            directory.append(le16: entry.tag); directory.append(le16: entry.type); directory.append(le32: entry.count)
            if entry.tag == 273 {
                directory.append(le32: 0xFFFF_FFFF) // patched below, once `extra` is known
            } else if let data = entry.data {
                directory.append(le32: UInt32(ifdEnd + extra.count))
                extra.append(data)
                if extra.count % 2 == 1 { extra.append(0) }
            } else {
                directory.append(le32: entry.value ?? 0)
            }
        }
        directory.append(le32: 0)
        var file = Data([0x49, 0x49, 0x2A, 0x00])
        file.append(le32: 8)
        file.append(directory)
        file.append(extra)
        let offset = UInt32(file.count)
        let marker = Data([0xFF, 0xFF, 0xFF, 0xFF])
        let range = try XCTUnwrap(file.range(of: marker))
        file.replaceSubrange(range, with: withUnsafeBytes(of: offset.littleEndian) { Data($0) })
        file.append(pixels)
        let url = folder.appendingPathComponent(name)
        try file.write(to: url)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        try XCTSkipIf(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } == nil, "ImageIO cannot decode this synthetic DNG")
        return url
    }

    private func decode(_ url: URL) throws -> (width: Int, height: Int, pixel: (Int, Int) -> (Int, Int, Int)) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), url.lastPathComponent)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), url.lastPathComponent)
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let copy = buffer
        return (width, height, { x, y in
            let index = (y * width + x) * 4
            return (Int(copy[index]), Int(copy[index + 1]), Int(copy[index + 2]))
        })
    }

    private func convert(_ url: URL, to target: ConversionFormat, options: ConversionOptions = ConversionOptions()) async throws -> URL {
        try await ConversionEngine.convert(url, to: target, options: options) { _ in }
    }

    func testRawOrientationIsBakedIntoThePixels() async throws {
        let plain = try await convert(try makeDNG("plain.dng"), to: .png)
        let base = try decode(plain)
        XCTAssertEqual(base.width, 320)
        XCTAssertEqual(base.height, 240)
        // Orientation 6 is a quarter turn clockwise: the top-left corner moves to the top-right.
        let rotated = try decode(try await convert(try makeDNG("rotated.dng", orientation: 6), to: .png))
        XCTAssertEqual(rotated.width, 240)
        XCTAssertEqual(rotated.height, 320)
        func assertClose(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ label: String) {
            XCTAssertLessThanOrEqual(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2), 18, "\(label): \(a) vs \(b)")
        }
        assertClose(rotated.pixel(237, 2), base.pixel(2, 2), "top-left to top-right")
        assertClose(rotated.pixel(2, 2), base.pixel(2, 237), "bottom-left to top-left")
        let corners = [base.pixel(2, 2), base.pixel(317, 2), base.pixel(2, 237), base.pixel(317, 237)]
        XCTAssertGreaterThan(Set(corners.map { "\($0)" }).count, 3, "corners must differ for this test to mean anything")
    }

    func testRawConvertsToEveryOfferedTarget() async throws {
        let dng = try makeDNG("photo.dng", orientation: 6)
        let targets = ActionRegistry.conversionOutputs(for: [.raw])
        XCTAssertTrue(targets.contains(.jpg))
        XCTAssertTrue(targets.contains(.pdf))
        for target in targets {
            let output = try await convert(dng, to: target)
            XCTAssertEqual(output.pathExtension, target.fileExtension)
            if target == .pdf {
                XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
            } else {
                let decoded = try decode(output)
                XCTAssertEqual(decoded.width, 240, "\(target)")
                XCTAssertEqual(decoded.height, 320, "\(target)")
            }
        }
    }

    func testUndecodableRawReportsAClearError() async throws {
        let url = folder.appendingPathComponent("broken.nef")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 197) }).write(to: url)
        do {
            _ = try await convert(url, to: .jpg)
            XCTFail("A broken RAW must not convert")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The source file could not be read.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["broken.nef"], "No output left behind")
    }

    func testRawToolsWriteAFormatImageIOCanEncode() async throws {
        let dng = try makeDNG("tool.dng", orientation: 6)
        let compressed = try await FileToolRunner.run(.compress, urls: [dng], options: ConversionOptions()) { _ in }
        XCTAssertEqual(compressed[0].pathExtension, "jpg")
        XCTAssertEqual(try decode(compressed[0]).height, 320)

        let cleaned = try await FileToolRunner.run(.removeMetadata, urls: [dng], options: ConversionOptions()) { _ in }
        XCTAssertEqual(cleaned[0].pathExtension, "png")
        let tiff = ImageProcessing.properties(cleaned[0])[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake])
        XCTAssertEqual(try decode(cleaned[0]).width, 240)

        let saved = try ImageProcessing.save(try ImageProcessing.loadCGImage(dng), beside: dng, suffix: " edited")
        XCTAssertEqual(saved.pathExtension, "png")
        XCTAssertEqual(try decode(saved).height, 320)
    }

    // MARK: Archives

    private func requireTools() throws {
        for tool in ["/usr/bin/tar", "/usr/bin/gzip", "/usr/bin/ditto", "/usr/bin/find"] {
            try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: tool), "\(tool) is missing")
        }
    }

    private let expected: [String: String] = ["b.txt": "bee\n", "inner/a.txt": "hello inner\n", "odd 'q' $X/\"è\".txt": "strange name\n"]

    private func makeTree(_ name: String = "tree") throws -> URL {
        let root = folder.appendingPathComponent(name)
        for (path, contents) in expected {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        return root
    }

    /// Unpacks into a fresh folder with the system tools and returns every regular file, keyed by NFC relative path.
    private func unpack(_ archive: URL) async throws -> [String: String] {
        let out = folder.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if archive.pathExtension == "zip" {
            try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", "--norsrc", archive.path, out.path])
        } else {
            try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "-xf", archive.path, "-C", out.path])
        }
        var files: [String: String] = [:]
        // `find` rather than FileManager, which hides `._` files.
        let listing = try await ProcessRunner.run("/usr/bin/find", [out.path, "-type", "f", "-print0"])
        for path in listing.split(separator: "\0").map(String.init) {
            let relative = String(path.dropFirst(out.path.count + 1)).precomposedStringWithCanonicalMapping
            files[relative] = try String(contentsOfFile: path, encoding: .utf8)
        }
        return files
    }

    private func assertSameFiles(_ actual: [String: String], file: StaticString = #filePath, line: UInt = #line) {
        var expectedFiles: [String: String] = [:]
        for (path, contents) in expected {
            expectedFiles[path.precomposedStringWithCanonicalMapping] = contents
        }
        XCTAssertEqual(actual, expectedFiles, file: file, line: line)
    }

    /// Entry names read straight from the tar headers: `tar -t` folds `._` entries away, which would hide the junk.
    private func listing(_ archive: URL) async throws -> [String] {
        var tar = archive
        if archive.pathExtension == "gz" {
            tar = folder.appendingPathComponent("list-\(UUID().uuidString).tar")
            try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gzip -dc \"$0\" > \"$1\"", archive.path, tar.path])
        }
        let data = try Data(contentsOf: tar)
        var names: [String] = []
        var offset = 0
        func field(_ start: Int, _ length: Int) -> String {
            let bytes = data[(offset + start)..<(offset + start + length)].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        while offset + 512 <= data.count, data[offset] != 0 {
            let size = Int(field(124, 11), radix: 8) ?? 0
            let type = field(156, 1)
            if type != "x" && type != "g" { names.append(field(0, 100)) }
            offset += 512 + (size + 511) / 512 * 512
        }
        return names
    }

    private func assertNoJunk(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let junk = names.filter { $0.contains("__MACOSX") || ($0 as NSString).lastPathComponent.hasPrefix("._") }
        XCTAssertEqual(junk, [], file: file, line: line)
    }

    private func makeZip(_ name: String) async throws -> URL {
        let tree = try makeTree("zip-\(UUID().uuidString)")
        let zip = folder.appendingPathComponent(name)
        try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", tree.path, zip.path])
        return zip
    }

    private func makeTar(_ name: String, gzip: Bool = false) async throws -> URL {
        let tree = try makeTree("tar-\(UUID().uuidString)")
        let tar = folder.appendingPathComponent(name)
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", gzip ? "-czf" : "-cf", tar.path, "-C", tree.path, "."])
        return tar
    }

    func testZipToGzipIsATarGzWithTheSameFiles() async throws {
        try requireTools()
        let zip = try await makeZip("Città 'q' \"x\" $HOME.zip")
        let output = try await convert(zip, to: .gzip)
        XCTAssertEqual(output.lastPathComponent, "Città 'q' \"x\" $HOME.tar.gz")
        XCTAssertEqual(try Data(contentsOf: output).prefix(2), Data([0x1F, 0x8B]), "Must be real gzip")
        assertNoJunk(try await listing(output))
        assertSameFiles(try await unpack(output))
    }

    func testGzipOutputIsAlwaysTarGzAndDoesNotOverwrite() async throws {
        try requireTools()
        let tar = try await makeTar("bundle.tar")
        let first = try await convert(tar, to: .gzip)
        let second = try await convert(tar, to: .gzip)
        XCTAssertEqual(first.lastPathComponent, "bundle.tar.gz")
        XCTAssertEqual(second.lastPathComponent, "bundle 2.tar.gz")
        assertSameFiles(try await unpack(second))
    }

    func testGzipSourceNamesDropTheWholeTarGzSuffix() async throws {
        try requireTools()
        let tarGz = try await makeTar("sample.tar.gz", gzip: true)
        let tgz = try await makeTar("other.tgz", gzip: true)
        let zip = try await convert(tarGz, to: .zip)
        let tar = try await convert(tgz, to: .tar)
        XCTAssertEqual(zip.lastPathComponent, "sample.zip")
        XCTAssertEqual(tar.lastPathComponent, "other.tar")
        assertSameFiles(try await unpack(zip))
        // A `.tgz` used to come through as one opaque nested tar.
        assertSameFiles(try await unpack(tar))
    }

    /// One regular file as a ustar entry.
    private func tarEntry(_ name: String, _ contents: Data) -> Data {
        var header = Data(count: 512)
        func put(_ text: String, at offset: Int) { header.replaceSubrange(offset..<(offset + text.utf8.count), with: Data(text.utf8)) }
        put(name, at: 0)
        put("0000644", at: 100); put("0000000", at: 108); put("0000000", at: 116)
        put(String(format: "%011o", contents.count), at: 124)
        put("00000000000", at: 136)
        put("        ", at: 148)
        put("0", at: 156)
        put("ustar", at: 257); put("00", at: 263)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148)
        var entry = header + contents
        if contents.count % 512 != 0 { entry.append(Data(count: 512 - contents.count % 512)) }
        return entry
    }

    func testAppleDoubleAndMacOSXEntriesDoNotReachTheOutput() async throws {
        try requireTools()
        let appleDouble = Data([0x00, 0x05, 0x16, 0x07]) + Data(repeating: 0, count: 60)
        // Written by hand: macOS tar never stores a `._` file as an ordinary entry.
        var archive = Data()
        for (path, contents) in expected { archive.append(tarEntry(path, Data(contents.utf8))) }
        archive.append(tarEntry("inner/._a.txt", appleDouble))
        archive.append(tarEntry("__MACOSX/._b.txt", appleDouble))
        archive.append(Data(count: 1024))
        let tar = folder.appendingPathComponent("junk.tar")
        try archive.write(to: tar)
        let names = try await listing(tar)
        XCTAssertFalse(names.filter { $0.contains("._a.txt") }.isEmpty, "The fixture must really hold the junk")

        let gzip = try await convert(tar, to: .gzip)
        assertNoJunk(try await listing(gzip))
        assertSameFiles(try await unpack(gzip))
        let zip = try await convert(tar, to: .zip)
        assertNoJunk(try await unpack(zip).keys.map { $0 })
    }

    func testPlainGzPayloadsAndHiddenTarsConvert() async throws {
        try requireTools()
        let payload = folder.appendingPathComponent("note.backup.txt")
        try Data("plain payload\n".utf8).write(to: payload)
        try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gzip -k \"$0\"", payload.path])
        try FileManager.default.removeItem(at: payload)
        let plain = folder.appendingPathComponent("note.backup.txt.gz")
        let zip = try await convert(plain, to: .zip)
        XCTAssertEqual(zip.lastPathComponent, "note.backup.txt.zip")
        let files = try await unpack(zip)
        XCTAssertEqual(files, ["note.backup.txt": "plain payload\n"])

        let hidden = try await makeTar("hidden.tar")
        try await ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/gzip -c \"$0\" > \"$1\"", hidden.path, folder.appendingPathComponent("hidden.gz").path])
        try FileManager.default.removeItem(at: hidden)
        let tar = try await convert(folder.appendingPathComponent("hidden.gz"), to: .tar)
        XCTAssertEqual(tar.lastPathComponent, "hidden.tar")
        assertSameFiles(try await unpack(tar))
    }

    /// One stored file, `a.txt`, in a hand-assembled RAR: nothing on macOS can write one.
    private static let rarFixture = "UmFyIRoHAM+QcwAADQAAAAAAAACes3QAgCUADgAAAA4AAAAD0nkrUAAAAFoUMAUApIEAAGEudHh0U0FUU1VNQU1BUktFUgrEPXsAQAcA"

    func testRarConvertsToGzip() async throws {
        try requireTools()
        let rar = folder.appendingPathComponent("stored.rar")
        try XCTUnwrap(Data(base64Encoded: Self.rarFixture)).write(to: rar)
        let output = try await convert(rar, to: .gzip)
        XCTAssertEqual(output.lastPathComponent, "stored.tar.gz")
        let files = try await unpack(output)
        XCTAssertEqual(files.keys.sorted(), ["a.txt"])
        XCTAssertEqual(files["a.txt"]?.count, 14)
    }

    func testCompressionLevelReachesGzipAndZip() async throws {
        try requireTools()
        // Text with long-range structure, which levels 1 and 9 really do compress differently.
        var state: UInt64 = 42
        var text = ""
        for _ in 0..<120_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            text += ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"][Int((state >> 40) % 7)] + " "
        }
        let tree = folder.appendingPathComponent("levels")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: tree.appendingPathComponent("words.txt"))
        let tar = folder.appendingPathComponent("levels.tar")
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", tar.path, "-C", tree.path, "."])

        func size(_ level: CompressionLevel, _ target: ConversionFormat) async throws -> Int {
            var options = ConversionOptions()
            options.compression = level
            let output = try await convert(tar, to: target, options: options)
            defer { try? FileManager.default.removeItem(at: output) }
            return try XCTUnwrap(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        let fastGzip = try await size(.fast, .gzip), maximumGzip = try await size(.maximum, .gzip)
        XCTAssertLessThan(maximumGzip, fastGzip)
        let fastZip = try await size(.fast, .zip), maximumZip = try await size(.maximum, .zip)
        XCTAssertLessThan(maximumZip, fastZip)
    }

    func testEmptyArchiveIsRejected() async throws {
        try requireTools()
        let empty = folder.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let tar = folder.appendingPathComponent("empty.tar")
        try await ProcessRunner.run("/usr/bin/tar", ["--no-mac-metadata", "-cf", tar.path, "-C", empty.path, "."])
        do {
            _ = try await convert(tar, to: .gzip)
            XCTFail("An empty archive must not convert")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The source archive is empty.")
        }
    }
}

// MARK: - Resize Images

extension FormatAdditionsTests {
    private func size(_ width: Double, _ height: Double, _ options: ImageResizeOptions) throws -> ImagePixelSize {
        try ImageResizer.outputSize(of: CGSize(width: width, height: height), options: options)
    }

    private func percent(_ width: Double, height: Double = 100, lock: Bool = true) -> ImageResizeOptions {
        ImageResizeOptions(percentage: width, heightPercentage: height, keepsProportions: lock, target: nil)
    }

    private func target(_ goal: ImageResizeTarget) -> ImageResizeOptions {
        ImageResizeOptions(target: goal)
    }

    private func assertSizeError(_ width: Double, _ height: Double, _ options: ImageResizeOptions, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try size(width, height, options), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, message, file: file, line: line)
        }
    }

    func testResizeIsInTheToolEnumAndBothImageWheels() {
        let tools = FileTool.allCases
        XCTAssertEqual(tools[tools.firstIndex(of: .cropImage)! + 1], .resizeImage)
        XCTAssertEqual(FileTool.resizeImage.title, "RESIZE")
        XCTAssertEqual(FileTool.resizeImage.name, "Resize Images")
        XCTAssertEqual(FileTool.resizeImage.symbolName, "arrow.up.left.and.arrow.down.right")
        XCTAssertTrue(FileTool.resizeImage.opensOptionsWindow)
        for format in [ConversionFormat.jpg, .png, .webp, .heic, .tiff] {
            XCTAssertEqual(ActionRegistry.toolOutputs(for: [format]),
                           [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .resizeImage, .redactImage])
            XCTAssertEqual(ActionRegistry.toolOutputs(for: [format, format]),
                           [.compress, .removeMetadata, .cropImage, .resizeImage, .createPDF, .createCollage])
        }
    }

    func testResizeSizeTable() throws {
        let rows: [(Double, Double, ImageResizeOptions, Int, Int, String)] = [
            (4000, 3000, percent(50), 2000, 1500, "half"),
            (4000, 3000, percent(33), 1320, 990, "a third"),
            (4000, 3000, percent(150), 6000, 4500, "upscale"),
            (4000, 3000, percent(50, height: 25), 2000, 1500, "locked ignores the height percentage"),
            (4000, 3000, percent(50, height: 25, lock: false), 2000, 750, "unlocked uses both percentages"),
            (4000, 3000, target(.longEdge(800)), 800, 600, "long edge, landscape"),
            (3000, 4000, target(.longEdge(800)), 600, 800, "long edge, portrait"),
            (4000, 3000, target(.width(1000)), 1000, 750, "width priority"),
            (4000, 3000, target(.height(600)), 800, 600, "height priority"),
            (4000, 3000, target(.fit(1000, 1000)), 1000, 750, "fit, width limits"),
            (3000, 4000, target(.fit(1000, 1000)), 750, 1000, "fit, height limits"),
            (100, 100, target(.fit(1920, 1080)), 1080, 1080, "fit may enlarge"),
            (4000, 3000, target(.exact(500, 500)), 500, 500, "stretch"),
            (5, 3, percent(50), 3, 2, "halves round away from zero"),
            (3, 3, percent(50), 2, 2, "1.5 rounds up"),
            (1, 1000, percent(10), 1, 100, "sides never reach zero"),
            (1, 1, percent(1), 1, 1, "single pixel"),
            (3333, 1000, target(.longEdge(100)), 100, 30, "rounds to nearest"),
            (16384, 1, percent(100), 16384, 1, "the limit itself is allowed"),
            (8192, 8192, percent(200), 16384, 16384, "both sides at the limit"),
            (1000, 500, target(.width(16384)), 16384, 8192, "target at the limit"),
        ]
        for (width, height, options, expectedWidth, expectedHeight, name) in rows {
            XCTAssertEqual(try size(width, height, options), ImagePixelSize(width: expectedWidth, height: expectedHeight), name)
        }
    }

    func testResizeRejectsZeroNegativeNonFiniteAndHugeValues() {
        let invalid = "Enter a width and height of at least 1 pixel."
        for goal: ImageResizeTarget in [.longEdge(0), .width(0), .height(-5), .fit(0, 100), .fit(100, .nan), .exact(0, 10), .exact(10, .infinity), .width(.infinity), .height(.nan)] {
            assertSizeError(4000, 3000, target(goal), invalid)
        }
        for options in [percent(0), percent(-10), percent(.nan), percent(.infinity), percent(50, height: 0, lock: false)] {
            assertSizeError(4000, 3000, options, invalid)
        }
        let tooLarge = "Keep each side at most \(16384.formatted()) pixels."
        assertSizeError(4000, 3000, percent(410), tooLarge)
        assertSizeError(4000, 3000, target(.width(16385)), tooLarge)
        assertSizeError(1000, 4000, target(.width(5000)), tooLarge)
        assertSizeError(4000, 3000, target(.exact(16385, 10)), tooLarge)
        assertSizeError(4000, 3000, target(.width(.greatestFiniteMagnitude)), tooLarge)
        assertSizeError(4000, 3000, percent(.greatestFiniteMagnitude), tooLarge)
        for (width, height) in [(0.0, 10.0), (10.0, 0.0), (-1.0, 10.0), (Double.nan, 10.0), (10.0, Double.infinity)] {
            assertSizeError(width, height, percent(50), "The source file could not be read.")
        }
    }

    func testResizePresetsAreCompleteAndComputeOnALandscapePhoto() throws {
        let expected: [(String, String, String, Int, Int)] = [
            ("Web", "Extra Large", "2560 px long edge", 2560, 1920), ("Web", "Large", "1920 px long edge", 1920, 1440),
            ("Web", "Medium", "1280 px long edge", 1280, 960), ("Web", "Small", "800 px long edge", 800, 600),
            ("Web", "Thumbnail", "320 px long edge", 320, 240),
            ("Screens", "4K UHD", "3840 × 2160", 2880, 2160), ("Screens", "QHD", "2560 × 1440", 1920, 1440),
            ("Screens", "Full HD", "1920 × 1080", 1440, 1080), ("Screens", "HD", "1280 × 720", 960, 720),
            ("Social", "Square Post", "1080 × 1080", 1080, 810), ("Social", "Portrait Post", "1080 × 1350", 1080, 810),
            ("Social", "Story / Reel", "1080 × 1920", 1080, 810), ("Social", "Link Preview", "1200 × 630", 840, 630),
            ("Social", "Video Thumbnail", "1280 × 720", 960, 720),
            ("Icons", "App Icon", "1024 × 1024", 1024, 768), ("Icons", "Large Icon", "512 × 512", 512, 384),
            ("Icons", "Touch Icon", "180 × 180", 180, 135), ("Icons", "Favicon", "32 × 32", 32, 24),
        ]
        let flat = ImageResizePreset.groups.flatMap { group in group.presets.map { (group.name, $0) } }
        XCTAssertEqual(flat.count, expected.count)
        for ((group, preset), row) in zip(flat, expected) {
            XCTAssertEqual(group, row.0)
            XCTAssertEqual(preset.name, row.1)
            XCTAssertEqual(preset.label, row.2)
            var editor = ImageResizeEditor(sources: [CGSize(width: 4000, height: 3000)])
            editor.apply(preset)
            XCTAssertEqual(editor.currentSize, ImagePixelSize(width: row.3, height: row.4), preset.name)

            // With the lock off a W × H preset stretches to exactly that size.
            var stretched = ImageResizeEditor(sources: [CGSize(width: 4000, height: 3000)], keepsProportions: false)
            stretched.apply(preset)
            if case .box(let width, let height) = preset.size {
                XCTAssertEqual(stretched.options.target, .exact(Double(width), Double(height)))
                XCTAssertEqual(stretched.currentSize, ImagePixelSize(width: width, height: height), preset.name)
            } else {
                XCTAssertEqual(stretched.currentSize, ImagePixelSize(width: row.3, height: row.4), preset.name)
            }
        }
        XCTAssertEqual(ImageResizePreset.percentages, [10, 25, 33, 50, 75, 90])
    }

    func testResizeEditorStartsAtTheDefaultsAndAsksForAChange() {
        let source = CGSize(width: 1000, height: 500)
        var editor = ImageResizeEditor(sources: [source])
        XCTAssertTrue(editor.isAtDefaults)
        XCTAssertEqual(editor.mode, .pixels)
        XCTAssertEqual(editor.options, ImageResizeOptions(percentage: 100, heightPercentage: 100, keepsProportions: true, target: nil))
        XCTAssertEqual(editor.problem, "Change the size to resize.")
        editor.set(.width, to: 500)
        XCTAssertNil(editor.problem)
        XCTAssertFalse(editor.isAtDefaults)
        editor.reset()
        XCTAssertTrue(editor.isAtDefaults)
    }

    func testResizeEditorOneImageTypesAPercentage() {
        let source = CGSize(width: 1000, height: 500)
        var editor = ImageResizeEditor(sources: [source])
        editor.set(.width, to: 333)
        XCTAssertNil(editor.options.target)
        XCTAssertEqual(editor.options.percentage, 33.3, accuracy: 0.0001)
        XCTAssertEqual(editor.currentSize, ImagePixelSize(width: 333, height: 167))
        editor.set(.height, to: 250)
        XCTAssertEqual(editor.currentSize, ImagePixelSize(width: 500, height: 250), "Locked: the other side follows")

        var free = ImageResizeEditor(sources: [source], keepsProportions: false)
        free.set(.width, to: 100)
        free.set(.height, to: 400)
        XCTAssertEqual(free.currentSize, ImagePixelSize(width: 100, height: 400), "Unlocked: each side on its own")
        free.set(.width, to: 0)
        XCTAssertEqual(free.currentSize, ImagePixelSize(width: 100, height: 400), "Zero is ignored")
        free.set(.height, to: -3)
        XCTAssertEqual(free.currentSize, ImagePixelSize(width: 100, height: 400), "Negative is ignored")
    }

    func testResizeEditorSeveralImagesShareAPixelGoal() throws {
        let sources = [CGSize(width: 1000, height: 500), CGSize(width: 300, height: 900)]
        var locked = ImageResizeEditor(sources: sources)
        locked.set(.width, to: 600)
        XCTAssertEqual(locked.options.target, .width(600))
        XCTAssertEqual(try ImageResizer.outputSize(of: sources[0], options: locked.options), ImagePixelSize(width: 600, height: 300))
        XCTAssertEqual(try ImageResizer.outputSize(of: sources[1], options: locked.options), ImagePixelSize(width: 600, height: 1800))
        XCTAssertTrue(locked.isAutomatic(.height))
        XCTAssertFalse(locked.isAutomatic(.width))
        XCTAssertEqual(locked.fieldText(.height), "Auto")
        XCTAssertEqual(locked.matchCaption, "Every image gets the same width; heights follow each image's proportions.")

        locked.setPriority(.height)
        XCTAssertEqual(locked.options.target, .height(300))
        XCTAssertEqual(locked.matchCaption, "Every image gets the same height; widths follow each image's proportions.")
        XCTAssertTrue(locked.isAutomatic(.width))

        var free = ImageResizeEditor(sources: sources, keepsProportions: false)
        free.set(.width, to: 640)
        XCTAssertEqual(free.options.target, .exact(640, 500), "Height stays at the first image's current height")
        free.set(.height, to: 480)
        XCTAssertEqual(free.options.target, .exact(640, 480))
        XCTAssertEqual(try ImageResizer.outputSize(of: sources[1], options: free.options), ImagePixelSize(width: 640, height: 480))
        XCTAssertEqual(free.lockCaption, "Lock off: images stretch to the size.")
    }

    func testResizeEditorScaleModeCopiesThePercentageAndClearsTheTarget() {
        var editor = ImageResizeEditor(sources: [CGSize(width: 1000, height: 500), CGSize(width: 300, height: 900)])
        editor.apply(ImageResizePreset.groups[0].presets[3])
        XCTAssertEqual(editor.options.target, .longEdge(800))
        XCTAssertEqual(editor.options.percentage, 80, accuracy: 0.0001, "Stored from the first image's output")
        XCTAssertEqual(editor.matchCaption, "Each image is sized to the preset.")
        editor.setMode(.scale)
        XCTAssertEqual(editor.mode, .scale)
        XCTAssertNil(editor.options.target)
        XCTAssertEqual(editor.options.heightPercentage, editor.options.percentage)
        editor.setPercentage(25)
        XCTAssertEqual(editor.options.percentage, 25)
        XCTAssertEqual(editor.options.heightPercentage, 25)
        // In percentage mode a typed side is a percentage even for several images.
        editor.set(.width, to: 100)
        XCTAssertNil(editor.options.target)
        XCTAssertEqual(editor.options.percentage, 10, accuracy: 0.0001)
    }

    func testResizeEditorLockToggle() {
        let sources = [CGSize(width: 1000, height: 500), CGSize(width: 300, height: 900)]

        var single = ImageResizeEditor(sources: [sources[0]], keepsProportions: false)
        single.set(.width, to: 700)
        single.set(.height, to: 100)
        XCTAssertNotEqual(single.options.percentage, single.options.heightPercentage)
        single.toggleKeepsProportions()
        XCTAssertTrue(single.options.keepsProportions)
        XCTAssertNil(single.options.target)
        XCTAssertEqual(single.options.heightPercentage, single.options.percentage, "Percentage mode: both take the percentage")

        var width = ImageResizeEditor(sources: sources)
        width.set(.width, to: 600)
        width.toggleKeepsProportions()
        XCTAssertFalse(width.options.keepsProportions)
        XCTAssertEqual(width.options.target, .exact(600, 300), "A width goal becomes the current size")

        var fit = ImageResizeEditor(sources: sources)
        fit.apply(ImageResizePreset.groups[1].presets[2])
        XCTAssertEqual(fit.options.target, .fit(1920, 1080))
        XCTAssertEqual(fit.lockCaption, "Lock on: images fit inside the size.")
        fit.toggleKeepsProportions()
        XCTAssertEqual(fit.options.target, .exact(1920, 1080), "Fit becomes exact")
        fit.toggleKeepsProportions()
        XCTAssertEqual(fit.options.target, .fit(1920, 1080), "Exact on a preset size becomes fit")

        var long = ImageResizeEditor(sources: sources)
        long.apply(ImageResizePreset.groups[0].presets[0])
        long.toggleKeepsProportions()
        XCTAssertEqual(long.options.target, .longEdge(2560), "A long edge goal keeps its kind")
        XCTAssertFalse(long.options.keepsProportions)
    }

    func testResizeEditorClampsPercentagesToTheLargestImage() throws {
        let sources = [CGSize(width: 1000, height: 500), CGSize(width: 300, height: 8000)]
        var locked = ImageResizeEditor(sources: sources)
        locked.setPercentage(900)
        XCTAssertEqual(locked.options.percentage, 204.8, accuracy: 0.0001)
        for source in sources { XCTAssertLessThanOrEqual(try ImageResizer.outputSize(of: source, options: locked.options).height, 16384) }

        var one = ImageResizeEditor(sources: [CGSize(width: 1000, height: 500)])
        one.set(.width, to: 99999)
        XCTAssertEqual(one.currentSize, ImagePixelSize(width: 16384, height: 8192))
        XCTAssertNil(one.problem)

        var several = ImageResizeEditor(sources: sources)
        several.set(.width, to: 10000)
        XCTAssertEqual(several.problem, "Keep each side at most \(16384.formatted()) pixels.", "Pixel goals are refused, not clamped")
    }

    func testResizeLockPreferenceIsReadFromDefaults() {
        let key = "imageResizeKeepsProportions"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(ImageResizeEditor.storedKeepsProportions)
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(ImageResizeEditor.storedKeepsProportions)
    }

    // MARK: Files

    /// Four solid quadrants: red top-left, green top-right, blue bottom-left, white bottom-right.
    private func makeQuadrants(_ width: Int, _ height: Int, alpha: Bool = false, bits: Int = 8) throws -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue))
        let w = width / 2, h = height / 2
        for (rect, color) in [(CGRect(x: 0, y: h, width: w, height: height - h), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                              (CGRect(x: w, y: h, width: width - w, height: height - h), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                              (CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))] {
            context.setFillColor(color)
            context.fill(rect)
        }
        if alpha { context.clear(CGRect(x: w, y: 0, width: width - w, height: h)) } else {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: w, y: 0, width: width - w, height: h))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func writeImage(_ image: CGImage, _ name: String, type: String, properties: [CFString: Any] = [:]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func sipsDimensions(_ url: URL) async throws -> (Int, Int) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/sips"), "sips not available")
        let text = try await ProcessRunner.run("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", url.path])
        func value(_ key: String) throws -> Int {
            let line = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains(key) })
            return try XCTUnwrap(Int(line.components(separatedBy: ": ").last ?? ""))
        }
        return (try value("pixelWidth"), try value("pixelHeight"))
    }

    private func assertQuadrants(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try decode(url)
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) < 40 && abs(a.1 - b.1) < 40 && abs(a.2 - b.2) < 40 }
        let (w, h) = (image.width, image.height)
        XCTAssertTrue(near(image.pixel(w / 4, h / 4), (255, 0, 0)), "top-left \(image.pixel(w / 4, h / 4))", file: file, line: line)
        XCTAssertTrue(near(image.pixel(3 * w / 4, h / 4), (0, 255, 0)), "top-right \(image.pixel(3 * w / 4, h / 4))", file: file, line: line)
        XCTAssertTrue(near(image.pixel(w / 4, 3 * h / 4), (0, 0, 255)), "bottom-left \(image.pixel(w / 4, 3 * h / 4))", file: file, line: line)
    }

    func testResizeWritesEachFormatAtTheRightSize() async throws {
        let image = try makeQuadrants(800, 600)
        var sources = [try writeImage(image, "a.jpg", type: "public.jpeg"), try writeImage(image, "a.png", type: "public.png"),
                       try writeImage(image, "a.tiff", type: "public.tiff")]
        if ImageConverter.imageIOCanWrite(.heic) { sources.append(try writeImage(image, "a.heic", type: "public.heic")) }
        if ToolLocator.path("cwebp") != nil {
            // No ImageIO WebP writer: make the source the same way the app does.
            let png = sources[1]
            let webp = folder.appendingPathComponent("a.webp")
            try await ProcessRunner.run(ToolLocator.path("cwebp")!, ["-quiet", "-lossless", png.path, "-o", webp.path])
            sources.append(webp)
        }
        for source in sources {
            let before = try Data(contentsOf: source)
            let output = try await ImageResizer.resize(source, options: target(.width(400)))
            XCTAssertEqual(output.lastPathComponent, "a Resized.\(source.pathExtension)")
            XCTAssertEqual(output.deletingLastPathComponent(), source.deletingLastPathComponent())
            let dimensions = try await sipsDimensions(output)
            XCTAssertEqual(dimensions.0, 400, source.lastPathComponent)
            XCTAssertEqual(dimensions.1, 300, source.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: source), before, "The source is left alone")
            XCTAssertEqual(ImageProcessing.properties(output)[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            let sourceType = CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil)))
            let outputType = CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil)))
            XCTAssertEqual(outputType as String?, sourceType as String?, source.lastPathComponent)
            try assertQuadrants(output)
        }
    }

    func testResizeStretchAndCollisionNamesNeverOverwrite() async throws {
        let source = try writeImage(try makeQuadrants(400, 400), "photo.png", type: "public.png")
        let first = try await ImageResizer.resize(source, options: target(.exact(100, 50)))
        let second = try await ImageResizer.resize(source, options: target(.exact(100, 50)))
        let third = try await ImageResizer.resize(source, options: percent(10))
        XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["photo Resized.png", "photo Resized 2.png", "photo Resized 3.png"])
        let stretched = try await sipsDimensions(first)
        XCTAssertEqual(stretched.0, 100)
        XCTAssertEqual(stretched.1, 50)
        try assertQuadrants(first)
    }

    func testResizeKeepsTheSourceExtensionSpelling() async throws {
        let source = try writeImage(try makeQuadrants(100, 100), "PIC.JPEG", type: "public.jpeg")
        let output = try await ImageResizer.resize(source, options: percent(50))
        XCTAssertEqual(output.lastPathComponent, "PIC Resized.JPEG")
    }

    func testResizeBakesOrientationAndDropsMetadata() async throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Someone", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        // Stored sideways: orientation 6 turns these quadrants clockwise when shown.
        let source = try writeImage(try makeQuadrants(800, 600), "turned.jpg", type: "public.jpeg", properties: properties)
        let output = try await ImageResizer.resize(source, options: target(.height(400)))
        let shown = try await sipsDimensions(output)
        XCTAssertEqual(shown.0, 300)
        XCTAssertEqual(shown.1, 400)
        let image = try decode(output)
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool { abs(a.0 - b.0) < 40 && abs(a.1 - b.1) < 40 && abs(a.2 - b.2) < 40 }
        XCTAssertTrue(near(image.pixel(75, 100), (0, 0, 255)), "\(image.pixel(75, 100))")
        XCTAssertTrue(near(image.pixel(225, 100), (255, 0, 0)), "\(image.pixel(225, 100))")
        XCTAssertTrue(near(image.pixel(225, 300), (0, 255, 0)), "\(image.pixel(225, 300))")

        let written = ImageProcessing.properties(output)
        XCTAssertEqual(written[kCGImagePropertyOrientation] as? Int ?? 1, 1)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary])
        XCTAssertNil((written[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel])
        XCTAssertNil((written[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])

        // The preview reads the header only and must report the same upright size.
        XCTAssertEqual(try ImageResizer.loadSource(source).size, CGSize(width: 600, height: 800))
    }

    func testResizeKeepsTransparencyAndDepth() async throws {
        let clear = try writeImage(try makeQuadrants(200, 200, alpha: true), "clear.png", type: "public.png")
        let output = try await ImageResizer.resize(clear, options: percent(50))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil)), 0, nil))
        XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo), "The output keeps its alpha channel")
        var pixel = [UInt8](repeating: 9, count: 4)
        let probe = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        probe.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        probe.draw(cg, in: CGRect(x: -75, y: -25, width: 100, height: 100))
        XCTAssertEqual(pixel[3], 0, "The cleared quadrant stays transparent")

        let deep = try writeImage(try makeQuadrants(200, 200, bits: 16), "deep.png", type: "public.png")
        let deepOutput = try await ImageResizer.resize(deep, options: percent(50))
        let deepCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(deepOutput as CFURL, nil)), 0, nil))
        XCTAssertEqual(deepCG.bitsPerComponent, 16)
        try assertQuadrants(deepOutput)
    }

    func testResizeMakesAPNGFromRAW() async throws {
        let dng = try makeDNG("cam.dng", orientation: 6)
        let output = try await ImageResizer.resize(dng, options: percent(50))
        XCTAssertEqual(output.lastPathComponent, "cam Resized.png")
        let decoded = try decode(output)
        XCTAssertEqual(decoded.width, 120)
        XCTAssertEqual(decoded.height, 160)
        XCTAssertEqual(try ImageResizer.loadSource(dng).size, CGSize(width: 240, height: 320))
    }

    func testResizeReportsAnUnreadableFile() async throws {
        let broken = folder.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        do {
            _ = try await ImageResizer.resize(broken, options: percent(50))
            XCTFail("A broken image must not resize")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Could not read the image broken.jpg")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["broken.jpg"], "No output left behind")
        XCTAssertThrowsError(try ImageResizer.loadSource(broken))
    }

    func testResizeRefusesAnOversizedResultWithoutWriting() async throws {
        let source = try writeImage(try makeQuadrants(100, 100), "small.png", type: "public.png")
        do {
            _ = try await ImageResizer.resize(source, options: target(.width(20000)))
            XCTFail("Over the limit must not resize")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Keep each side at most \(16384.formatted()) pixels.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["small.png"])
    }

    // MARK: Review findings

    func testSVGIsAConversionTargetOnlyOfPDF() {
        XCTAssertFalse(ConversionFormat.svg.isInputOnly)
        XCTAssertTrue(ActionRegistry.conversionOutputs(for: [.pdf]).contains(.svg))
        XCTAssertFalse(ActionRegistry.conversionOutputs(for: [.png]).contains(.svg))
        XCTAssertFalse(ActionRegistry.conversionOutputs(for: [.png, .jpg]).contains(.svg))
    }

    func testImageQualityFollowsTheBinaryTable() {
        var options = ConversionOptions()
        for (quality, value) in [(ConversionQuality.compact, 0.65), (.balanced, 0.85), (.high, 0.96)] {
            options.quality = quality
            XCTAssertEqual(ImageConverter.quality(options), value)
        }
    }

    func testRealDirectoriesNamedLikeSidecarsSurvive() async throws {
        try requireTools()
        var archive = Data()
        archive.append(tarEntry("git/f", Data("tracked\n".utf8)))
        archive.append(tarEntry("._git/keep", Data("mine\n".utf8)))
        archive.append(Data(count: 1024))
        let tar = folder.appendingPathComponent("user.tar")
        try archive.write(to: tar)
        let files = try await unpack(try await convert(tar, to: .gzip))
        XCTAssertEqual(files["._git/keep"], "mine\n")
        XCTAssertEqual(files["git/f"], "tracked\n")
    }

    func testResizeFieldsSurviveEveryDigitTheyAccept() {
        var editor = ImageResizeEditor(sources: [CGSize(width: 1000, height: 2000), CGSize(width: 3000, height: 1000)], keepsProportions: false)
        editor.set(.width, to: 99999)
        XCTAssertEqual(editor.problem, ImageResizer.tooLargeMessage)
        editor.set(.width, to: 99999999999999999999)
        XCTAssertEqual(editor.problem, ImageResizer.tooLargeMessage)
        XCTAssertFalse(editor.usesPreset)
        editor.set(.height, to: 1e300)
        XCTAssertEqual(editor.problem, ImageResizer.tooLargeMessage)

        // No loaded sources yet: the percentage is shown through a 64-bit conversion.
        var empty = ImageResizeEditor()
        empty.setMode(.scale)
        empty.setPercentage(1e300)
        XCTAssertLessThan(empty.options.percentage, 1e15)
    }

    func testResizeOtherSideSurvivesAnOutOfRangeEntry() {
        var editor = ImageResizeEditor(sources: [CGSize(width: 1000, height: 2000), CGSize(width: 3000, height: 1000)], keepsProportions: false)
        editor.set(.height, to: 500)
        editor.set(.width, to: 17000)
        XCTAssertEqual(editor.options.target, .exact(17000, 500))
        XCTAssertNil(editor.currentSize)
        editor.set(.width, to: 1700)
        XCTAssertEqual(editor.options.target, .exact(1700, 500))
    }

    func testPercentageModeKeepsProportionsWithTheLockOpen() throws {
        let sources = [CGSize(width: 1000, height: 2000), CGSize(width: 3000, height: 1000), CGSize(width: 50, height: 50)]
        var editor = ImageResizeEditor(sources: sources, keepsProportions: false)
        editor.setMode(.scale)
        editor.setPercentage(1000)
        XCTAssertEqual(editor.options.percentage, editor.options.heightPercentage)
        XCTAssertNil(editor.problem)
        let first = try ImageResizer.outputSize(of: sources[0], options: editor.options)
        XCTAssertEqual(Double(first.height) / Double(first.width), 2, accuracy: 0.01)
    }

    func testWebPResizeReportsItsOwnLimitBeforeDrawing() async throws {
        try XCTSkipIf(!ImageConverter.canConvert(to: .webp), "No WebP encoder")
        let png = try writeImage(try makeQuadrants(40, 40), "big.png", type: "public.png")
        let webp = try await ImageConverter.convert(png, from: .png, to: .webp, options: ConversionOptions())
        do {
            _ = try await ImageResizer.resize(webp, options: target(.exact(16384, 100)))
            XCTFail("16,384 pixels cannot be stored in WebP")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("WebP"), error.localizedDescription)
        }
        let output = try await ImageResizer.resize(webp, options: target(.exact(16383, 100)))
        XCTAssertEqual(try decode(output).width, 16383)
    }
}

/// PDF → SVG. Every PDF is built here from raw objects, so the content streams are exact.
final class PDFToSVGTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SatsumaSVG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Assembles a PDF from object bodies (numbered from 1, the catalog is object 1).
    private func pdfData(_ objects: [Data]) -> Data {
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { out.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    private func object(_ text: String) -> Data { Data(text.utf8) }

    private func streamObject(_ dictionary: String, _ data: Data) -> Data {
        var out = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        out.append(data)
        out.append(Data("\nendstream".utf8))
        return out
    }

    private func streamObject(_ dictionary: String, _ text: String) -> Data { streamObject(dictionary, Data(text.utf8)) }

    /// A one-page PDF: catalog (1), pages (2), page (3), contents (4), then `extra` objects from 5.
    private func onePage(_ content: String, page: String = "/MediaBox [0 0 200 100]", resources: String = "", extra: [Data] = []) -> PDFDocument {
        let objects = [
            object("<< /Type /Catalog /Pages 2 0 R >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R \(page) /Resources << \(resources) >> >>"),
            streamObject("", content),
        ] + extra
        let url = folder.appendingPathComponent("doc-\(UUID().uuidString).pdf")
        try! pdfData(objects).write(to: url)
        return PDFDocument(url: url)!
    }

    private func svg(_ document: PDFDocument, page: Int = 0) throws -> XMLDocument {
        try XMLDocument(xmlString: PDFToSVG.svg(for: document.page(at: page)!))
    }

    private func nodes(_ doc: XMLDocument, _ name: String) -> [XMLElement] {
        (try! doc.nodes(forXPath: "//*[local-name()='\(name)']")).compactMap { $0 as? XMLElement }
    }

    private func attribute(_ element: XMLElement, _ name: String) -> String? { element.attribute(forName: name)?.stringValue }

    /// Numbers of a `d` attribute, in order.
    private func numbers(_ d: String?) -> [Double] {
        (d ?? "").replacingOccurrences(of: "[MLCQZ]", with: " ", options: .regularExpression).split(separator: " ").compactMap { Double($0) }
    }

    // MARK: Registry and pipeline

    func testSVGIsOnlyOfferedForPDFsInTheBinaryOrder() {
        XCTAssertEqual(ActionRegistry.candidates(for: .pdf), [.docx, .pages, .pptx, .xlsx, .jpg, .png, .svg, .epub, .txt, .md])
        XCTAssertTrue(ActionRegistry.supports(.pdf, .svg))
        for source in ConversionFormat.allCases where source != .pdf {
            XCTAssertFalse(ActionRegistry.conversionOutputs(for: [source]).contains(.svg), "\(source)")
            XCTAssertFalse(ActionRegistry.supports(source, .svg), "\(source)")
        }
        for group in [ConversionFormat.Group.images, .documents] { XCTAssertFalse(ActionRegistry.candidates(forGroup: group).contains(.svg)) }
    }

    func testSinglePagePDFWritesOneSVGBesideTheSource() async throws {
        let url = folder.appendingPathComponent("page.pdf")
        try pdfData([object("<< /Type /Catalog /Pages 2 0 R >>"), object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                     object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 50] /Contents 4 0 R /Resources << >> >>"), streamObject("", "1 0 0 rg 0 0 50 50 re f")]).write(to: url)
        let output = try await ConversionEngine.convert(url, to: .svg, options: .init(), progress: { _ in })
        XCTAssertEqual(output.lastPathComponent, "page.svg")
        XCTAssertEqual(try XMLDocument(contentsOf: output, options: []).rootElement()?.name, "svg")
        let second = try await ConversionEngine.convert(url, to: .svg, options: .init(), progress: { _ in })
        XCTAssertEqual(second.lastPathComponent, "page 2.svg", "must never overwrite")
    }

    func testMultiPagePDFGoesIntoAPagesFolder() async throws {
        let objects = [
            object("<< /Type /Catalog /Pages 2 0 R >>"), object("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 50 50] /Resources << >> >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>"), object("<< /Type /Page /Parent 2 0 R /Contents 6 0 R >>"),
            streamObject("", "1 0 0 rg 0 0 50 50 re f"), streamObject("", "0 0 1 rg 0 0 50 50 re f"),
        ]
        let url = folder.appendingPathComponent("two.pdf")
        try pdfData(objects).write(to: url)
        let pages = try await ConversionEngine.convert(url, to: .svg, options: .init(), progress: { _ in })
        XCTAssertEqual(pages.lastPathComponent, "two Pages")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pages.path).sorted(), ["Page 1.svg", "Page 2.svg"])
        let page2 = try String(contentsOf: pages.appendingPathComponent("Page 2.svg"), encoding: .utf8)
        XCTAssertTrue(page2.contains("#0000ff"), page2)
        XCTAssertFalse(try String(contentsOf: pages.appendingPathComponent("Page 1.svg"), encoding: .utf8).contains("#0000ff"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".satsuma") }, [])
        let again = try await ConversionEngine.convert(url, to: .svg, options: .init(), progress: { _ in })
        XCTAssertEqual(again.lastPathComponent, "two Pages 2", "must never overwrite")
    }

    // MARK: Geometry

    func testHeaderUsesPointsAndYDownCoordinates() throws {
        let doc = try svg(onePage("1 0 0 rg 10 20 30 40 re f"))
        let root = doc.rootElement()!
        XCTAssertEqual(attribute(root, "width"), "200"); XCTAssertEqual(attribute(root, "height"), "100")
        XCTAssertEqual(attribute(root, "viewBox"), "0 0 200 100")
        let paths = nodes(doc, "path")
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(attribute(paths[0], "fill"), "#ff0000")
        let d = numbers(attribute(paths[0], "d"))
        XCTAssertEqual(d, [10, 80, 40, 80, 40, 40, 10, 40], "y flips: 100 - 20 = 80")
    }

    func testCropBoxSetsViewportAndOrigin() throws {
        let doc = try svg(onePage("0 1 0 rg 60 40 10 10 re f", page: "/MediaBox [0 0 200 100] /CropBox [50 30 150 90]"))
        let root = doc.rootElement()!
        XCTAssertEqual(attribute(root, "width"), "100"); XCTAssertEqual(attribute(root, "height"), "60")
        XCTAssertEqual(Array(numbers(attribute(nodes(doc, "path")[0], "d")).prefix(2)), [10, 50], "60-50, 90-40")
    }

    func testRotationSwapsSizeAndMovesMarks() throws {
        for (rotation, width, height, expected) in [(90, 100.0, 200.0, [20.0, 10.0]), (180, 200.0, 100.0, [190.0, 20.0]), (270, 100.0, 200.0, [80.0, 190.0])] {
            let doc = try svg(onePage("0 0 1 rg 10 20 5 5 re f", page: "/MediaBox [0 0 200 100] /Rotate \(rotation)"))
            let root = doc.rootElement()!
            XCTAssertEqual(Double(attribute(root, "width")!), width, "\(rotation)")
            XCTAssertEqual(Double(attribute(root, "height")!), height, "\(rotation)")
            XCTAssertEqual(Array(numbers(attribute(nodes(doc, "path")[0], "d")).prefix(2)), expected, "\(rotation)")
        }
    }

    func testInvalidPageSizeFails() {
        let geometry = PageGeometry(box: CGRect(x: 0, y: 0, width: 0, height: 10), rotation: 0)
        XCTAssertNil(geometry)
        XCTAssertNil(PageGeometry(box: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), rotation: 0))
    }

    // MARK: Paths

    func testStrokeParametersAndFillRules() throws {
        let doc = try svg(onePage("5 w [6 3] 2 d 1 J 1 j 3 M 0 0 1 RG 10 10 m 50 10 l S 1 0 0 rg 60 10 20 20 re f*"))
        let paths = nodes(doc, "path")
        XCTAssertEqual(paths.count, 2)
        let stroke = paths[0]
        XCTAssertEqual(attribute(stroke, "fill"), "none")
        XCTAssertEqual(attribute(stroke, "stroke"), "#0000ff")
        XCTAssertEqual(attribute(stroke, "stroke-width"), "5")
        XCTAssertEqual(attribute(stroke, "stroke-dasharray"), "6 3")
        XCTAssertEqual(attribute(stroke, "stroke-dashoffset"), "2")
        XCTAssertEqual(attribute(stroke, "stroke-linecap"), "round")
        XCTAssertEqual(attribute(stroke, "stroke-linejoin"), "round")
        XCTAssertEqual(attribute(stroke, "stroke-miterlimit"), "3")
        XCTAssertEqual(attribute(paths[1], "fill-rule"), "evenodd")
    }

    func testAnisotropicStrokeUsesATransformAndUserSpaceWidth() throws {
        let doc = try svg(onePage("q 3 0 0 1 10 10 cm 2 w 0 0 m 10 0 l S Q"))
        let path = nodes(doc, "path")[0]
        XCTAssertEqual(attribute(path, "stroke-width"), "2")
        XCTAssertNotNil(attribute(path, "transform"))
        XCTAssertTrue(attribute(path, "transform")!.hasPrefix("matrix(3 0 0 -1 "), attribute(path, "transform")!)
    }

    func testClippingNestsAndRestoresWithQ() throws {
        let doc = try svg(onePage("q 10 10 50 50 re W n 20 20 30 30 re W* n 1 0 0 rg 0 0 200 100 re f Q 0 1 0 rg 0 0 200 100 re f"))
        XCTAssertEqual(nodes(doc, "clipPath").count, 2)
        XCTAssertEqual(attribute(nodes(doc, "clipPath")[1].child(at: 0) as! XMLElement, "clip-rule"), "evenodd")
        let groups = nodes(doc, "g")
        XCTAssertEqual(groups.count, 2, "one nested group per clip")
        let paths = nodes(doc, "path").filter { attribute($0, "fill") != nil }
        let red = paths.first { attribute($0, "fill") == "#ff0000" }!
        let green = paths.first { attribute($0, "fill") == "#00ff00" }!
        XCTAssertEqual(red.parent?.name, "g")
        XCTAssertEqual(green.parent?.name, "svg", "Q ended the clip")
    }

    func testFullPageClipIsDropped() throws {
        let doc = try svg(onePage("0 0 200 100 re W n 1 0 0 rg 10 10 20 20 re f"))
        XCTAssertEqual(nodes(doc, "clipPath").count, 0)
    }

    func testColorSpacesMapToSRGB() throws {
        let resources = "/ColorSpace << /CS1 [/Separation /Spot /DeviceRGB << /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1 >>] /CS2 [/Indexed /DeviceRGB 1 <112233 445566>] >>"
        let doc = try svg(onePage("0.5 g 0 0 10 10 re f 0 1 0 rg 10 0 10 10 re f /CS1 cs 1 scn 20 0 10 10 re f /CS2 cs 1 sc 30 0 10 10 re f 0 0 0 0 k 40 0 10 10 re f", resources: resources))
        let fills = nodes(doc, "path").map { attribute($0, "fill") ?? "" }
        XCTAssertEqual(Array(fills.prefix(4)), ["#808080", "#00ff00", "#ff0000", "#445566"])
        // CMYK goes through the system's Generic CMYK profile, whose paper white lands within a step of #ffffff.
        XCTAssertTrue(fills[4].hasPrefix("#fffff"), fills[4])
    }

    func testExtGStateAlphaAndBlend() throws {
        let doc = try svg(onePage("/G1 gs 1 0 0 rg 1 0 0 RG 10 10 20 20 re B", resources: "/ExtGState << /G1 << /ca 0.5 /CA 0.25 /BM /Multiply >> >>"))
        let path = nodes(doc, "path")[0]
        XCTAssertEqual(attribute(path, "fill-opacity"), "0.5")
        XCTAssertEqual(attribute(path, "stroke-opacity"), "0.25")
        XCTAssertEqual(attribute(path, "style"), "mix-blend-mode:multiply")
    }

    // MARK: XObjects

    func testFormsApplyMatrixAndRecursionIsGuarded() throws {
        let form = streamObject("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 20 30] /Resources << /XObject << /Fm 5 0 R >> >>", "1 0 0 rg 0 0 10 10 re f /Fm Do")
        let doc = try svg(onePage("/Fm Do", resources: "/XObject << /Fm 5 0 R >>", extra: [form]))
        let filled = nodes(doc, "path").filter { attribute($0, "fill") == "#ff0000" }
        XCTAssertEqual(filled.count, 1, "the self-referencing form must run once")
        XCTAssertEqual(Array(numbers(attribute(filled[0], "d")).prefix(2)), [20, 70])
    }

    func testTransparencyGroupGetsOneOpacity() throws {
        let form = streamObject("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency >> /Resources << >>", "1 0 0 rg 0 0 10 10 re f")
        let doc = try svg(onePage("/G gs /Fm Do", resources: "/ExtGState << /G << /ca 0.5 >> >> /XObject << /Fm 5 0 R >>", extra: [form]))
        let group = nodes(doc, "g").first { attribute($0, "opacity") != nil }
        XCTAssertEqual(group.flatMap { attribute($0, "opacity") }, "0.5")
        XCTAssertNil(attribute(nodes(doc, "path").first!, "fill-opacity"), "the group carries the alpha, not each mark")
    }

    func testRawImageIsEmbeddedAsPNGWithItsPlacement() throws {
        let pixels = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        let image = streamObject("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8", pixels)
        let doc = try svg(onePage("q 100 0 0 50 10 20 cm /Im Do Q", resources: "/XObject << /Im 5 0 R >>", extra: [image]))
        let element = nodes(doc, "image").first!
        let href = attribute(element, "xlink:href") ?? attribute(element, "href")!
        XCTAssertTrue(href.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(attribute(element, "transform"), "matrix(50 0 0 25 10 30)")
        let data = Data(base64Encoded: String(href.dropFirst("data:image/png;base64,".count)))!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(decoded.width, 2); XCTAssertEqual(decoded.height, 2)
    }

    func testJPEGPassesThroughOnlyWhenSafe() throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = streamObject("/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg as Data)
        let doc = try svg(onePage("q 80 0 0 80 10 10 cm /Im Do Q", resources: "/XObject << /Im 5 0 R >>", extra: [image]))
        let element = nodes(doc, "image").first!
        XCTAssertTrue((attribute(element, "xlink:href") ?? attribute(element, "href")!).hasPrefix("data:image/jpeg;base64,"))
    }

    func testStencilMaskTakesTheFillColor() throws {
        let image = streamObject("/Type /XObject /Subtype /Image /Width 8 /Height 1 /ImageMask true /BitsPerComponent 1", Data([0xF0]))
        let doc = try svg(onePage("0 0 1 rg q 80 0 0 10 10 10 cm /Im Do Q", resources: "/XObject << /Im 5 0 R >>", extra: [image]))
        let element = nodes(doc, "image").first!
        let href = attribute(element, "xlink:href") ?? attribute(element, "href")!
        let data = Data(base64Encoded: String(href.dropFirst("data:image/png;base64,".count)))!
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        var pixels = [UInt8](repeating: 0, count: 8 * 4)
        CGContext(data: &pixels, width: 8, height: 1, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 1))
        XCTAssertEqual(pixels[3], 0, "bit 1 is unpainted")
        XCTAssertEqual(pixels[4 * 4 + 3], 255, "bit 0 paints")
        XCTAssertEqual(pixels[4 * 4 + 2], 255, "painted in the current fill colour")
    }

    func testShadingBecomesAPatchNotACrash() throws {
        let resources = "/Shading << /Sh << /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 200 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> >> >>"
        let doc = try svg(onePage("q 10 10 50 50 re W n /Sh sh Q", resources: resources))
        XCTAssertTrue(nodes(doc, "image").contains { (attribute($0, "xlink:href") ?? attribute($0, "href") ?? "").hasPrefix("data:image/png;base64,") })
        XCTAssertFalse(nodes(doc, "clipPath").isEmpty, "the patch stays inside the clip")
    }

    func testPatternFillBecomesAPatchClippedToThePath() throws {
        let pattern = streamObject("/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>", "1 0 0 rg 0 0 5 5 re f")
        let doc = try svg(onePage("/Pattern cs /P scn 20 20 m 80 20 l 50 80 l f", resources: "/Pattern << /P 5 0 R >>", extra: [pattern]))
        XCTAssertFalse(nodes(doc, "image").isEmpty)
        XCTAssertFalse(nodes(doc, "clipPath").isEmpty)
    }

    func testHiddenOptionalContentIsSkipped() throws {
        let content = "/OC /Off BDC 1 0 0 rg 0 0 50 50 re f EMC /OC /On BDC 0 1 0 rg 50 0 50 50 re f EMC"
        let objects = [
            object("<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [5 0 R] >> >> >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 100 100] /Resources << /Properties << /Off 5 0 R /On 6 0 R >> >> >>"),
            streamObject("", content),
            object("<< /Type /OCG /Name (Off) >>"), object("<< /Type /OCG /Name (On) >>"),
        ]
        let url = folder.appendingPathComponent("layers.pdf")
        try pdfData(objects).write(to: url)
        let doc = try svg(PDFDocument(url: url)!)
        let fills = nodes(doc, "path").map { attribute($0, "fill") }
        XCTAssertEqual(fills, ["#00ff00"], "\(fills)")
    }

    // MARK: Text

    func testStandardFontTextIsOutlinesAndAdvances() throws {
        let doc = try svg(onePage("BT /F1 20 Tf 10 30 Td (AB) Tj ET", resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>"))
        XCTAssertEqual(nodes(doc, "text").count, 0, "text is emitted as outlines")
        let paths = nodes(doc, "path")
        XCTAssertEqual(paths.count, 1)
        let xs = numbers(attribute(paths[0], "d")).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        XCTAssertLessThan(xs.min()!, 15, "first glyph starts near x = 10")
        XCTAssertGreaterThan(xs.max()!, 30, "second glyph is placed after the first")
    }

    func testInvisibleTextPaintsNothing() throws {
        let doc = try svg(onePage("BT /F1 20 Tf 3 Tr 10 30 Td (Hello) Tj ET", resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>"))
        XCTAssertEqual(nodes(doc, "path").count, 0)
    }

    func testTJAdjustmentsMoveFollowingGlyphs() throws {
        let plain = try svg(onePage("BT /F1 10 Tf 0 0 Td (AA) Tj ET", resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Courier >> >>"))
        let shifted = try svg(onePage("BT /F1 10 Tf 0 0 Td [(A) -1000 (A)] TJ ET", resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Courier >> >>"))
        func maxX(_ doc: XMLDocument) -> Double { nodes(doc, "path").flatMap { numbers(attribute($0, "d")).enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }.max()! }
        XCTAssertEqual(maxX(shifted) - maxX(plain), 10, accuracy: 0.01, "-1000/1000 × 10 pt")
    }

    func testEmbeddedTrueTypeFontDrawsGlyphs() throws {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 18) ?? NSFont.systemFont(ofSize: 18)]
        let url = folder.appendingPathComponent("text.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Embed", attributes: attributes)), context)
        context.endPDFPage()
        context.closePDF()
        let doc = try svg(PDFDocument(url: url)!)
        XCTAssertEqual(nodes(doc, "image").count, 0, "real glyph outlines, not a patch")
        XCTAssertFalse(nodes(doc, "path").isEmpty)
    }

    func testType1FontProgramIsReadWithoutQuartz() throws {
        func encrypt(_ bytes: [UInt8], key: UInt16) -> [UInt8] {
            var r = key
            return bytes.map { byte in
                let cipher = byte ^ UInt8(r >> 8)
                r = (UInt16(cipher) &+ r) &* 52845 &+ 22719
                return cipher
            }
        }
        func number(_ value: Int) -> [UInt8] {
            let v = UInt32(bitPattern: Int32(value))
            return [255, UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
        }
        var charString: [UInt8] = number(0) + number(700) + [13]
        charString += number(100) + number(0) + [21]
        charString += number(500) + number(0) + [5]
        charString += number(0) + number(700) + [5]
        charString += number(-500) + number(0) + [5, 9, 14]
        // Complete enough that Quartz renders it too, so the page also passes the render check.
        func charEntry(_ name: String, _ code: [UInt8]) -> Data {
            let encrypted = encrypt([0, 0, 0, 0] + code, key: 4330)
            var entry = Data("/\(name) \(encrypted.count) RD ".utf8)
            entry.append(contentsOf: encrypted)
            entry.append(Data(" ND\n".utf8))
            return entry
        }
        var privateText = Data("""
        dup /Private 8 dict dup begin
        /RD {string currentfile exch readstring pop} executeonly def
        /ND {noaccess def} executeonly def
        /NP {noaccess put} executeonly def
        /BlueValues [] def
        /MinFeature {16 16} def
        /password 5839 def
        /lenIV 4 def
        2 index /CharStrings 2 dict dup begin

        """.utf8)
        privateText.append(charEntry(".notdef", number(0) + number(700) + [13, 14]))
        privateText.append(charEntry("A", charString))
        privateText.append(Data("end end readonly put noaccess put\ndup /FontName get exch definefont pop\nmark currentfile closefile\n".utf8))
        let eexec = encrypt([1, 2, 3, 4] + [UInt8](privateText), key: 55665)
        let clear = Data("""
        %!PS-AdobeFont-1.0: Test 1.0
        12 dict begin
        /FontInfo 1 dict dup begin end readonly def
        /FontName /Test def
        /PaintType 0 def
        /FontType 1 def
        /FontMatrix [0.001 0 0 0.001 0 0] readonly def
        /Encoding 256 array 0 1 255 {1 index exch /.notdef put} for dup 65 /A put readonly def
        /FontBBox {0 0 1000 1000} readonly def
        currentdict end
        currentfile eexec

        """.utf8)
        var font = clear
        font.append(contentsOf: eexec)
        let tail = Data((String(repeating: String(repeating: "0", count: 64) + "\n", count: 8) + "cleartomark\n").utf8)
        font.append(tail)
        let descriptor = object("<< /Type /FontDescriptor /FontName /Test /FontFile 7 0 R /Flags 4 /FontBBox [0 0 1000 1000] /ItalicAngle 0 /Ascent 800 /Descent 0 /CapHeight 700 /StemV 80 >>")
        let fontDict = object("<< /Type /Font /Subtype /Type1 /BaseFont /Test /FirstChar 65 /LastChar 65 /Widths [700] /FontDescriptor 5 0 R >>")
        let stream = streamObject("/Length1 \(clear.count) /Length2 \(eexec.count) /Length3 \(tail.count)", font)
        let doc = try svg(onePage("BT /F 100 Tf 10 10 Td (A) Tj ET", resources: "/Font << /F 6 0 R >>", extra: [descriptor, fontDict, stream]))
        XCTAssertEqual(nodes(doc, "image").count, 0, "the font must be read, not patched")
        let path = try XCTUnwrap(nodes(doc, "path").first, "the render check rejected the outline")
        let d = numbers(attribute(path, "d"))
        XCTAssertEqual(Array(d.prefix(2)), [20, 90], "100 units at 100 pt from x = 10; y = 100 - 10")
        XCTAssertEqual(d.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).max()!, 70, accuracy: 0.01, "500 units wide")
    }

    // MARK: Safety

    func testUnknownAndMalformedOperatorsDoNotCrash() throws {
        let garbage = "q ( unterminated string \\\n ] >> 1 2 3 foo /Bar baz BT ET BT Tj Td Q Q Q Q 1 0 0 rg 10 10 20 20 re f"
        let xml = try PDFToSVG.svg(for: onePage(garbage).page(at: 0)!)
        XCTAssertNoThrow(try XMLDocument(xmlString: xml), xml)
    }

    func testResultIsWellFormedAndContainsNoUnescapedText() throws {
        let doc = onePage("BT /F1 12 Tf 10 10 Td (a < b & c) Tj ET", resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >>")
        let xml = try PDFToSVG.svg(for: doc.page(at: 0)!)
        XCTAssertNoThrow(try XMLDocument(xmlString: xml), xml)
        XCTAssertFalse(xml.contains("<text"))
    }

    // MARK: Convert to PDF/A-2b

    private func pdfaSource(_ name: String, objects: [Data]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try pdfData(objects).write(to: url)
        return url
    }

    /// Text in an embedded TrueType font, with an alpha fill on the second page when `pages` is 2.
    private func pdfaTextSource(_ name: String, pages: Int = 1, title: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18)]
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "PDFAMARK\(page + 1)", attributes: attributes)), context)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.4))
            context.fill(CGRect(x: 10, y: 10, width: 40, height: 40))
            context.endPDFPage()
        }
        context.closePDF()
        if let title {
            let document = try XCTUnwrap(PDFDocument(url: url))
            document.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.authorAttribute: "Ann (A)"]
            XCTAssertTrue(document.write(to: url))
        }
        return url
    }

    private func pdfaBytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    private func contains(_ bytes: [UInt8], _ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard needle.count <= bytes.count else { return false }
        return (0...(bytes.count - needle.count)).contains { bytes[$0] == needle[0] && Array(bytes[$0..<($0 + needle.count)]) == needle }
    }

    private func replacing(_ data: Data, _ old: String, _ new: String) throws -> Data {
        XCTAssertEqual(old.utf8.count, new.utf8.count, "keep offsets valid")
        var copy = data
        let range = try XCTUnwrap(copy.range(of: Data(old.utf8)), "\(old) not found")
        copy.replaceSubrange(range, with: Data(new.utf8))
        return copy
    }

    func testConvertPDFAIsAToolInBothPDFWheelsAndOpensNoWindow() {
        let tools = FileTool.allCases
        XCTAssertEqual(tools.count, 29)
        XCTAssertEqual(tools[tools.firstIndex(of: .organizePDF)! + 1], .convertPDFA)
        XCTAssertEqual(FileTool.convertPDFA.title, "PDF/A-2B")
        XCTAssertEqual(FileTool.convertPDFA.name, "Convert to PDF/A-2b")
        XCTAssertEqual(FileTool.convertPDFA.symbolName, "checkmark.seal")
        XCTAssertFalse(FileTool.convertPDFA.opensOptionsWindow)
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.pdf]), [.compress, .removeMetadata, .splitPDF, .organizePDF, .convertPDFA, .readQRCode])
        XCTAssertEqual(ActionRegistry.toolOutputs(for: [.pdf, .pdf]), [.compress, .removeMetadata, .splitPDF, .mergePDF, .convertPDFA, .readQRCode])
    }

    func testPDFAKeepsPagesAndTextAndNamesTheOutput() async throws {
        let source = try pdfaTextSource("Report.pdf", pages: 2)
        let original = try Data(contentsOf: source)
        let first = try await FileToolRunner.run(.convertPDFA, urls: [source], options: ConversionOptions(), progress: { _ in })
        XCTAssertEqual(first.map { $0.lastPathComponent }, ["Report PDF-A.pdf"])
        let second = try await FileToolRunner.run(.convertPDFA, urls: [source], options: ConversionOptions(), progress: { _ in })
        XCTAssertEqual(second.map { $0.lastPathComponent }, ["Report 2 PDF-A.pdf"])
        XCTAssertEqual(try Data(contentsOf: source), original, "the source is never rewritten")
        let converted = try XCTUnwrap(PDFDocument(url: first[0]))
        XCTAssertEqual(converted.pageCount, 2)
        XCTAssertFalse(converted.isLocked)
        XCTAssertEqual(converted.page(at: 0)?.string?.contains("PDFAMARK1"), true)
        XCTAssertEqual(converted.page(at: 1)?.string?.contains("PDFAMARK2"), true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".satsuma") }
        XCTAssertEqual(leftovers, [], "temporary files are removed")
    }

    func testPDFAFileStructure() throws {
        let source = try pdfaTextSource("Doc.pdf", title: "Città & <b>")
        let output = try PDFAWriter.convert(source)
        let bytes = try pdfaBytes(output)
        XCTAssertEqual(Array(bytes.prefix(15)), Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        XCTAssertEqual(Array(bytes.suffix(5)), Array("%%EOF".utf8), "nothing follows the final marker")
        for required in ["/GTS_PDFA1", "/OutputIntents", "/DestOutputProfile", "<pdfaid:part>2</pdfaid:part>", "<pdfaid:conformance>B</pdfaid:conformance>",
                         "/ID [<", "\nxref\n0 ", "/FontFile2", "<xmp:CreatorTool>Satsuma</xmp:CreatorTool>"] {
            XCTAssertTrue(contains(bytes, required), required)
        }
        for forbidden in ["/Encrypt", "/ObjStm", "/Type /XRef", "/StructTreeRoot", "/JavaScript"] {
            XCTAssertFalse(contains(bytes, forbidden), forbidden)
        }
        XCTAssertNoThrow(try PDFAWriter.validate(Data(bytes), expectedPages: 1))
        // Info and XMP carry the same metadata, the Unicode title as UTF-16.
        let xml = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(xml.contains("<rdf:li xml:lang=\"x-default\">Città &amp; &lt;b&gt;</rdf:li>"))
        XCTAssertTrue(contains(bytes, "<rdf:li>Ann (A)</rdf:li>"))
        XCTAssertTrue(contains(bytes, "/Author (Ann \\(A\\))"))
        XCTAssertTrue(contains(bytes, "/Title <FEFF00430069007400740"))
    }

    func testPDFAMakesDeviceCMYKDeviceIndependent() throws {
        let source = try pdfaSource("Cmyk.pdf", objects: [
            object("<< /Type /Catalog /Pages 2 0 R >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 200 200] /Resources << /XObject << /Im 5 0 R >> >> >>"),
            streamObject("", "0.1 0.2 0.3 0 k 10 10 50 50 re f /DeviceCMYK cs 1 0 0 0 sc 70 10 50 50 re f q 50 0 0 50 10 100 cm /Im Do Q"),
            streamObject("/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceCMYK", Data([200, 30, 10, 0])),
        ])
        let output = try PDFAWriter.convert(source)
        let bytes = try pdfaBytes(output)
        XCTAssertFalse(contains(bytes, "/DeviceCMYK"))
        XCTAssertTrue(contains(bytes, "/DefaultCMYK"))
        XCTAssertTrue(contains(bytes, "/N 4"))
        XCTAssertNoThrow(try PDFAWriter.validate(Data(bytes), expectedPages: 1))
    }

    func testPDFADropsActiveContent() throws {
        let source = try pdfaSource("Active.pdf", objects: [
            object("<< /Type /Catalog /Pages 2 0 R /OpenAction 5 0 R >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 200 200] /Annots [6 0 R] >>"),
            streamObject("", "0 0 1 rg 10 10 50 50 re f"),
            object("<< /S /JavaScript /JS (app.alert\\(1\\);) >>"),
            object("<< /Type /Annot /Subtype /Widget /Rect [50 50 90 70] /A 5 0 R >>"),
        ])
        let bytes = try pdfaBytes(try PDFAWriter.convert(source))
        for name in ["/JavaScript", "/JS", "/OpenAction", "/Annots", "/AcroForm", "/AA"] {
            XCTAssertFalse(contains(bytes, name), name)
        }
    }

    func testPDFAErrorsAreTheOriginalMessages() throws {
        func page(_ box: String) throws -> URL {
            try pdfaSource("Page\(UUID().uuidString).pdf", objects: [
                object("<< /Type /Catalog /Pages 2 0 R >>"),
                object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                object("<< /Type /Page /Parent 2 0 R /MediaBox [\(box)] >>"),
            ])
        }
        XCTAssertThrowsError(try PDFAWriter.convert(try page("0 0 15000 100"))) {
            XCTAssertEqual($0.localizedDescription, "PDF page 1 is outside the page sizes PDF/A allows (3 to 14,400 points per side).")
        }
        XCTAssertThrowsError(try PDFAWriter.convert(try page("0 0 2 100"))) {
            XCTAssertEqual($0.localizedDescription, "PDF page 1 is outside the page sizes PDF/A allows (3 to 14,400 points per side).")
        }
        XCTAssertNoThrow(try PDFAWriter.convert(try page("0 0 14400 3")))

        let encrypted = folder.appendingPathComponent("Secret.pdf")
        let plain = try XCTUnwrap(PDFDocument(url: try pdfaTextSource("Plain.pdf")))
        XCTAssertTrue(plain.write(to: encrypted, withOptions: [.userPasswordOption: "x", .ownerPasswordOption: "y"]))
        XCTAssertTrue(PDFDocument(url: encrypted)!.isLocked)
        XCTAssertThrowsError(try PDFAWriter.convert(encrypted)) {
            XCTAssertEqual($0.localizedDescription, "The source file could not be read.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Secret PDF-A.pdf").path))
    }

    /// The final check must reject a file whose structure has been damaged, so no false PDF/A can be saved.
    func testPDFAValidatorRejectsDamagedFiles() throws {
        let output = try PDFAWriter.convert(try pdfaTextSource("Valid.pdf"))
        let good = try Data(contentsOf: output)
        XCTAssertNoThrow(try PDFAWriter.validate(good, expectedPages: 1))
        func rejected(_ data: Data, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try PDFAWriter.validate(data, expectedPages: 1), line: line) {
                XCTAssertEqual($0.localizedDescription, message, line: line)
            }
        }
        let verify = "The PDF/A file could not be verified."
        rejected(try replacing(good, "/Type /Pages", "/Annots /Pag"), "This PDF could not be made PDF/A: it still contains the unsupported feature /Annots.")
        rejected(try replacing(good, "/Type /Metadata", "/DeviceCMYK /Me"), "This PDF could not be made PDF/A: it still contains the unsupported feature /DeviceCMYK.")
        rejected(try replacing(good, "/FontFile2", "/FontFilX2"), "This PDF could not be made PDF/A: a font could not be embedded.")
        rejected(try replacing(good, "/Filter /FlateDecode", "/Filter /LZWDecode  "), "This PDF could not be made PDF/A: it still contains the unsupported feature /LZWDecode.")
        rejected(try replacing(good, "%PDF-1.7", "%PDF-1.9"), verify)
        rejected(good + Data("\njunk".utf8), verify)
        rejected(try replacing(good, "<pdfaid:part>2", "<pdfaid:part>1"), verify)
        rejected(try replacing(good, "<pdfaid:conformance>B", "<pdfaid:conformance>U"), verify)
        rejected(try replacing(good, "/S /GTS_PDFA1", "/S /GTS_PDFX1"), verify)
        rejected(try replacing(good, "<xmp:ModifyDate>2", "<xmp:ModifyDate>1"), verify)
        rejected(try replacing(good, "/Metadata /Subtype /XML", "/Metadata /Filter  /XML"), verify)
        // A wrong offset in the cross-reference table.
        let table = try XCTUnwrap(good.range(of: Data("\nxref\n".utf8)))
        var shifted = good
        let digit = table.upperBound + "0 ".utf8.count + 32
        shifted[digit] = shifted[digit] == 0x31 ? 0x32 : 0x31
        rejected(shifted, verify)
    }

    func testPDFAContentScanFindsCMYKOnlyInOperators() {
        XCTAssertTrue(PDFAContentScan(Array("0 0 0 1 k".utf8)).usesCMYK)
        XCTAssertTrue(PDFAContentScan(Array("/DeviceCMYK cs".utf8)).usesCMYK)
        XCTAssertFalse(PDFAContentScan(Array("(k) Tj (K) Tj <6b> Tj".utf8)).usesCMYK, "text is not an operator")
        XCTAssertFalse(PDFAContentScan(Array("1 w BT ET".utf8)).usesCMYK)
        XCTAssertEqual(PDFAContentScan(Array("q q Q q".utf8)).maxDepth, 2)
        XCTAssertTrue(PDFAContentScan(Array("/Foo ri".utf8)).badRenderingIntent)
        XCTAssertFalse(PDFAContentScan(Array("/Perceptual ri".utf8)).badRenderingIntent)
        XCTAssertTrue(PDFAContentScan(Array("BI /W 1 /H 1 /CS /RGB /BPC 8 /F /LZW ID xxx EI".utf8)).badInlineImage)
        XCTAssertTrue(PDFAContentScan(Array("BI /W 1 /H 1 /CS /CMYK /BPC 8 ID xxxx EI".utf8)).usesCMYK)
    }

    // MARK: Review findings

    func testOutOfRangeNumbersDoNotCrashTheSVGInterpreter() throws {
        let huge = "100000000000000000000.0"
        for content in ["\(huge) J 0 0 10 10 re S", "\(huge) j 0 0 10 10 re S", "\(huge) Tr 0 0 10 10 re S", "-\(huge) J 0 0 10 10 re S"] {
            XCTAssertFalse(nodes(try svg(onePage(content)), "path").isEmpty, content)
        }
        let state = onePage("/G0 gs 0 0 10 10 re S", resources: "/ExtGState << /G0 << /LC \(huge) /LJ \(huge) >> >>")
        XCTAssertFalse(nodes(try svg(state), "path").isEmpty)
        let annotated = onePage("0 0 10 10 re S", page: "/MediaBox [0 0 200 100] /Annots [<< /Type /Annot /Subtype /Square /Rect [10 10 50 50] /F \(huge) >>]")
        XCTAssertNoThrow(try svg(annotated))
        let mask = onePage("q 9 0 0 9 0 0 cm /I Do Q", resources: "/XObject << /I 5 0 R >>", extra: [
            streamObject("/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Mask 6 0 R", Data([255, 0, 0])),
            streamObject("/Type /XObject /Subtype /Image /ImageMask true /Width 9223372036854775807 /Height 9223372036854775807 /BitsPerComponent 1", Data([0])),
        ])
        XCTAssertNoThrow(try svg(mask))
    }

    func testInlineImagesEachKeepTheirOwnPixels() throws {
        let colors = ["ff0000", "00ff00", "0000ff", "ffff00"]
        let content = colors.enumerated().map { "q 10 0 0 10 \(10 * $0.offset) 0 cm BI /W 1 /H 1 /CS /RGB /BPC 8 /F /AHx ID \($0.element)> EI Q" }.joined(separator: " ")
        let images = nodes(try svg(onePage(content)), "image")
        XCTAssertEqual(images.count, 4)
        XCTAssertEqual(Set(images.compactMap { attribute($0, "xlink:href") ?? attribute($0, "href") }).count, 4)
    }

    func testPartialDifferencesKeepStandardEncodingForTheOtherCodes() throws {
        func glyph(_ encoding: String) throws -> String? {
            let doc = onePage("BT /F1 40 Tf 10 20 Td (Z) Tj ET", resources: "/Font << /F1 5 0 R >>", extra: [
                object("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman \(encoding) >>")])
            return nodes(try svg(doc), "path").first.flatMap { attribute($0, "d") }
        }
        let plain = try XCTUnwrap(try glyph(""))
        XCTAssertEqual(try glyph("/Encoding << /Differences [97 /Euro] >>"), plain)
    }

    func testFormFanOutIsRefusedBeforeAnythingDrawsIt() throws {
        func nested(_ levels: Int) -> PDFDocument {
            let forms = (0..<levels).map { level -> Data in
                let resources = level + 1 < levels ? "/Resources << /XObject << /N \(level + 6) 0 R >> >>" : ""
                let body = level + 1 < levels ? String(repeating: "/N Do ", count: 10) : "0 0 1 1 re f"
                return streamObject("/Type /XObject /Subtype /Form /BBox [0 0 10 10] \(resources)", body)
            }
            return onePage("/N Do", resources: "/XObject << /N 5 0 R >>", extra: forms)
        }
        XCTAssertFalse(FormFanOut.exceedsLimit(nested(3).page(at: 0)!))
        let bomb = nested(9)
        XCTAssertTrue(FormFanOut.exceedsLimit(bomb.page(at: 0)!))
        XCTAssertThrowsError(try PDFToSVG.svg(for: bomb.page(at: 0)!))
        XCTAssertThrowsError(try PDFAWriter.convert(try XCTUnwrap(bomb.documentURL)))
    }

    /// A page painted in `spaces`, whose function objects start at 5.
    private func pdfaSpotSource(_ name: String, spaces: [String], operands: String, functions: [Data]) throws -> URL {
        let resources = spaces.enumerated().map { "/C\($0.offset) \($0.element)" }.joined(separator: " ")
        let content = spaces.indices.map { "/C\($0) cs \(operands) scn \(10 + $0 * 60) 10 50 50 re f" }.joined(separator: " ")
        return try pdfaSource(name, objects: [
            object("<< /Type /Catalog /Pages 2 0 R >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 200 200] /Resources << /ColorSpace << \(resources) >> >> >>"),
            streamObject("", content),
        ] + functions)
    }

    private func tint(_ color: String) -> Data { object("<< /FunctionType 2 /Domain [0 1] /N 1 /C0 [1 1 1] /C1 [\(color)] >>") }

    private func assertPDFARefused(_ source: URL, _ feature: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PDFAWriter.convert(source), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, "This PDF could not be made PDF/A: it still contains the unsupported feature /\(feature).", file: file, line: line)
        }
    }

    func testPDFAKeepsNamesThatOnlyLookForbidden() throws {
        let blend = try pdfaSource("Blend.pdf", objects: [
            object("<< /Type /Catalog /Pages 2 0 R >>"),
            object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            object("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 200 200] /Resources << /ExtGState << /G0 << /BM /Screen >> >> >> >>"),
            streamObject("", "/G0 gs 1 0 0 rg 10 10 50 50 re f"),
        ])
        XCTAssertNoThrow(try PDFAWriter.convert(blend))
        let spot = try pdfaSpotSource("Spot.pdf", spaces: ["[ /Separation /Ref /DeviceRGB 5 0 R ]"], operands: "0.5", functions: [tint("1 0 0")])
        XCTAssertNoThrow(try PDFAWriter.convert(spot))
        XCTAssertEqual(PDFAValue.dict({ var d = PDFADict(); d["TR"] = .name("Identity"); return d }()).checkedNames.first, "TR", "still refused in a graphics state")
        XCTAssertEqual(PDFAValue.dict({ var d = PDFADict(); d["S"] = .name("Luminosity"); d["G"] = .ref(1); d["TR"] = .name("Identity"); return d }()).checkedNames.contains("TR"), false)
    }

    func testPDFARefusesSpotColorsTheStandardForbids() throws {
        let function = streamObject("/FunctionType 4 /Domain [0 1 0 1] /Range [0 1 0 1 0 1]", "{ pop pop 1 0 0 }")
        let deviceN = try pdfaSpotSource("DeviceN.pdf", spaces: ["[ /DeviceN [ /SpotA /SpotB ] /DeviceRGB 5 0 R ]"], operands: "0.5 0.5", functions: [function])
        assertPDFARefused(deviceN, "DeviceN")
        let clashing = try pdfaSpotSource("Clash.pdf", spaces: ["[ /Separation /Same /DeviceRGB 5 0 R ]", "[ /Separation /Same /DeviceRGB 6 0 R ]"],
                                          operands: "0.5", functions: [tint("1 0 0"), tint("0 0 1")])
        assertPDFARefused(clashing, "Separation")
        let identical = try pdfaSpotSource("Same.pdf", spaces: ["[ /Separation /Same /DeviceRGB 5 0 R ]", "[ /Separation /Same /DeviceRGB 6 0 R ]"],
                                           operands: "0.5", functions: [tint("1 0 0"), tint("1 0 0")])
        XCTAssertNoThrow(try PDFAWriter.convert(identical))
    }

    func testPDFAContentScanFindsNotdefAndLongStrings() {
        let identity: Set<String> = ["F1"]
        func notdef(_ text: String) -> Bool { PDFAContentScan(Array(text.utf8), identityFonts: identity).showsNotdef }
        XCTAssertTrue(notdef("/F1 12 Tf [<00240000> 120 <0025>] TJ"))
        XCTAssertTrue(notdef("/F1 12 Tf <0000> Tj"))
        XCTAssertFalse(notdef("/F1 12 Tf <00240025> Tj"))
        XCTAssertFalse(notdef("/F2 12 Tf <0000> Tj"), "not an Identity font")
        XCTAssertFalse(notdef("/F2 1 Tf q /F1 1 Tf Q <0000> Tj"), "Q restores the font")
        XCTAssertFalse(notdef("/F1 1 Tf /P << /X <0000> >> BDC EMC"), "not shown text")
        func long(_ count: Int) -> Bool { PDFAContentScan(Array("(\(String(repeating: "a", count: count))) Tj".utf8)).hasLongString }
        XCTAssertFalse(long(32767))
        XCTAssertTrue(long(32768))
        XCTAssertTrue(PDFAContentScan(Array("<\(String(repeating: "41", count: 40000))> Tj".utf8)).hasLongString)
    }

    func testPDFAMetadataSurvivesByteOrderMarksAndLongNonBMPTitles() throws {
        for (name, title) in [("Mark.pdf", "A\u{FEFF}B"), ("Emoji.pdf", String(repeating: "\u{1F600}", count: 16_500))] {
            let source = try pdfaTextSource(name, title: title)
            let output = try PDFAWriter.convert(source)
            let saved = try XCTUnwrap(PDFDocument(url: output)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            XCTAssertFalse(saved.unicodeScalars.contains("\u{FEFF}"))
            XCTAssertLessThanOrEqual(saved.utf16.count, 16_000)
        }
    }
}
