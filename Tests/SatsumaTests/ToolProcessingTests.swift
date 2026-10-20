import AppKit
import PDFKit
import XCTest
@testable import Satsuma

/// Runs every tool's processing path on real generated media (needs ffmpeg).
final class ToolProcessingTests: XCTestCase {
    private var folder: URL!
    private var video: URL!
    private var audio: URL!
    private var photo: URL!
    private var pdf: URL!

    override func setUp() async throws {
        try XCTSkipIf(ToolLocator.ffmpeg == nil, "ffmpeg not installed")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SatsumaTools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        video = folder.appendingPathComponent("clip.mp4")
        audio = folder.appendingPathComponent("voice.wav")
        photo = folder.appendingPathComponent("photo.png")
        pdf = folder.appendingPathComponent("doc.pdf")
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x240:rate=24", "-f", "lavfi", "-i", "sine=frequency=440",
                                     "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-f", "lavfi", "-i", "sine=frequency=300",
                                     "-filter_complex", "[0:a]atrim=0:0.5[s];[1:a]atrim=0:1,aformat=channel_layouts=stereo[t];[s][t]concat=n=2:v=0:a=1[a]",
                                     "-map", "[a]", audio.path])
        try await MediaTools.ffmpeg(["-f", "lavfi", "-i", "testsrc=size=400x300", "-frames:v", "1", photo.path])
        let document = PDFDocument()
        for _ in 0..<3 {
            let image = NSImage(contentsOf: photo)!
            document.insert(PDFPage(image: image)!, at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: pdf))
    }

    override func tearDown() async throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func assertFile(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), "\(url.lastPathComponent) missing", file: file, line: line)
        if !isDirectory.boolValue { XCTAssertGreaterThan(ToolFormat.fileSize(url) ?? 0, 0, file: file, line: line) }
    }

    func testImageTools() throws {
        let image = try ImageProcessing.loadCGImage(photo)
        assertFile(try ImageProcessing.save(ImageProcessing.crop(image, to: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))!, beside: photo, suffix: " cropped"))
        let redacted = ImageProcessing.redact(image, rects: [NormalizedRect(x: 0, y: 0, width: 0.3, height: 0.3)], blur: true)!
        assertFile(try ImageProcessing.save(redacted, beside: photo, suffix: " redacted"))
        var values = ImageAdjustmentValues()
        values.exposure = 0.5; values.vignette = 40; values.grain = 30; values.hue = 20
        let edited = ImageProcessing.render(ImageProcessing.adjusted(CIImage(cgImage: image), values))!
        XCTAssertEqual(edited.width, image.width)
        let framed = FrameRenderer.render(image, background: .gradient(0), padding: 40, corners: 20, shadow: 20, ratio: .square)!
        XCTAssertEqual(framed.width, framed.height)
        let collage = CollageRenderer.render([image, image, image], settings: CollageSettings())!
        XCTAssertEqual(collage.width, 2048)
        let annotations = [Annotation(tool: .arrow, start: .zero, end: CGPoint(x: 0.5, y: 0.5), color: .black),
                           Annotation(tool: .number, start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.5, y: 0.5), number: 1, color: .black),
                           Annotation(tool: .magnifier, start: CGPoint(x: 0.3, y: 0.3), end: CGPoint(x: 0.3, y: 0.3), color: .black)]
        XCTAssertNotNil(AnnotationRenderer.render(image, annotations: annotations))
        assertFile(try ImageProcessing.compressImage(photo, plan: .init(strong: true, maxDimension: 200)))
        assertFile(try ImageProcessing.compressPDF(pdf, plan: .init(strong: true)))
    }

    func testVideoTrimCropSpeed() async throws {
        assertFile(try await MediaTools.trim(video, start: 0.5, end: 1.5, audioOnly: false) { _ in })
        assertFile(try await MediaTools.crop(video, rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), outputSize: nil) { _ in })
        assertFile(try await MediaTools.changeSpeed(video, speed: 2) { _ in })
    }

    func testVideoSnapshotsAndSplit() async throws {
        let frames = try await MediaTools.snapshots(video, times: [0.2, 1.0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: frames[0].path).count, 2)
        let clips = try await MediaTools.split(video, points: [1.0], duration: 2) { _ in }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clips.path).count, 2)
    }

    func testVideoRedactSolid() async throws {
        var box = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        box.timeRange = 0.2...1.2
        assertFile(try await MediaTools.redactVideo(video, rects: [box], blur: false) { _ in })
    }

    func testVideoRedactBlurAndJoin() async throws {
        var box = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        box.timeRange = 0.2...1.2
        assertFile(try await MediaTools.redactVideo(video, rects: [box], blur: true) { _ in })
        assertFile(try await FileToolRunner.joinVideos([video, video]))
    }

    func testAudioTools() async throws {
        assertFile(try await MediaTools.normalize(audio, loudness: -16, range: 11, truePeak: -1.5) { _ in })
        assertFile(try await MediaTools.visualize(audio, waveform: true, image: nil, shape: .square) { _ in })
        assertFile(try await MediaTools.trim(audio, start: 0.2, end: 1.2, audioOnly: true) { _ in })
        assertFile(try await MediaTools.channels(audio, stereo: false, left: 1, right: 0.5))
        assertFile(try await MediaTools.bleep(audio, ranges: [0.6...0.9]) { _ in })
        let silence = await MediaTools.detectSilence(audio, thresholdDB: -40, duration: 1.5)
        XCTAssertNotNil(silence)
        XCTAssertGreaterThan(silence?.0 ?? 0, 0.3, "leading silence detected")
        let waveform = await WaveformLoader.load(audio, bins: 100)
        XCTAssertEqual(waveform.first?.count, 100)
    }

    func testMetadataReadAndRemove() async throws {
        try XCTSkipIf(MetadataTool.exiftool == nil, "exiftool not installed")
        let fields = try await MetadataTool.read(photo)
        XCTAssertFalse(fields.isEmpty)
        assertFile(try await MetadataTool.write(photo, fields: fields, removeAll: true))
    }
}
