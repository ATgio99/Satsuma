import AVFoundation
import AVKit
import SwiftUI

// MARK: - Media info

/// Basic facts about a media file (`MediaInfo`).
struct MediaFacts {
    var duration: Double = 0
    var size: CGSize = .zero          // display size (after rotation)
    var frameRate: Double = 30
    var hasAudio = false
    var hasVideo = false
    var audioChannels = 0

    static func load(_ url: URL) async -> MediaFacts {
        let asset = AVURLAsset(url: url)
        var facts = MediaFacts()
        if let duration = try? await asset.load(.duration) { facts.duration = duration.seconds.isFinite ? duration.seconds : 0 }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            facts.hasVideo = true
            if let natural = try? await video.load(.naturalSize), let transform = try? await video.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                facts.size = CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            if let rate = try? await video.load(.nominalFrameRate), rate > 0 { facts.frameRate = Double(rate) }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            facts.hasAudio = true
            if let descriptions = try? await audio.load(.formatDescriptions), let first = descriptions.first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                facts.audioChannels = Int(basic.pointee.mChannelsPerFrame)
            }
        }
        if facts.duration == 0, let seconds = await MediaConverter.duration(of: url) { facts.duration = seconds }
        return facts
    }
}

// MARK: - Player

/// AVPlayer wrapper with a published playhead (`PlayheadControls`).
@MainActor
final class PlayerController: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var isPlaying = false
    @Published var duration: Double = 0
    var frameRate: Double = 30
    var playRange: ClosedRange<Double>?
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                if let range = self.playRange, time.seconds >= range.upperBound { self.pause() }
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    deinit { if let observer { player.removeTimeObserver(observer) } }

    func seek(_ seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int) { pause(); seek(time + Double(frames) / max(frameRate, 1)) }

    func toggle() { isPlaying ? pause() : play() }

    func play(range: ClosedRange<Double>? = nil, rate: Float = 1) {
        playRange = range
        if let range, time < range.lowerBound || time >= range.upperBound - 0.01 { seek(range.lowerBound) }
        else if duration > 0, time >= duration - 0.01 { seek(0) }
        player.rate = rate
        isPlaying = true
    }

    func pause() { player.pause(); isPlaying = false }
}

/// Video surface without controls.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

/// ⏮ ▶ ⏭ and "0:01.60 / 0:04.00".
struct PlaybackBar: View {
    @ObservedObject var controller: PlayerController
    var showsPlay = true
    var showsSteps = true
    var playRange: ClosedRange<Double>? = nil

    var body: some View {
        HStack(spacing: 18) {
            if showsSteps {
                Button { controller.step(-1) } label: { Image(systemName: "backward.frame") }.buttonStyle(.plain)
            }
            if showsPlay {
                Button { controller.isPlaying ? controller.pause() : controller.play(range: playRange) } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
            }
            if showsSteps {
                Button { controller.step(1) } label: { Image(systemName: "forward.frame") }.buttonStyle(.plain)
            }
            Spacer()
            Text("\(ToolFormat.time(controller.time)) / \(ToolFormat.time(controller.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }
}

// MARK: - Filmstrip

@MainActor
final class FilmstripLoader: ObservableObject {
    @Published var frames: [NSImage] = []

    func load(_ url: URL, count: Int, height: CGFloat = 80) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 3, height: height * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        Task {
            guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return }
            var images: [NSImage] = []
            for index in 0..<count {
                let time = CMTime(seconds: duration.seconds * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
            }
            self.frames = images
        }
    }
}

struct FilmstripView: View {
    @StateObject private var loader = FilmstripLoader()
    let url: URL
    var count = 10

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(loader.frames.enumerated()), id: \.offset) { _, frame in
                    Image(nsImage: frame).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width / CGFloat(max(count, 1)), height: geometry.size.height)
                        .clipped()
                }
            }
        }
        .background(Color.black.opacity(0.8))
        .onAppear { loader.load(url, count: count) }
    }
}

// MARK: - Waveform

enum WaveformLoader {
    /// Peak amplitude per bin (0…1) for each channel (up to 2), via AVAssetReader or ffmpeg fallback.
    static func load(_ url: URL, bins: Int) async -> [[Float]] {
        if let channels = readWithAVFoundation(url, bins: bins) { return channels }
        guard let ffmpeg = ToolLocator.ffmpeg else { return [] }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-wave-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-vn", "-ac", "2", "-ar", "22050", temporary.path])) != nil else { return [] }
        return readWithAVFoundation(temporary, bins: bins) ?? []
    }

    private static func readWithAVFoundation(_ url: URL, bins: Int) -> [[Float]]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { return nil }
        let channelCount = max(1, track.formatDescriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)?.pointee.mChannelsPerFrame
        }.map(Int.init) ?? 2)
        var samples: [[Int16]] = Array(repeating: [], count: min(channelCount, 2))
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let count = length / 2
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { values in
                // Keep every 8th frame to bound memory.
                var index = 0
                while index + channelCount <= count {
                    for channel in 0..<samples.count { samples[channel].append(values[index + channel]) }
                    index += channelCount * 8
                }
            }
        }
        guard let first = samples.first, !first.isEmpty else { return nil }
        return samples.map { channel in
            let perBin = max(1, channel.count / bins)
            return (0..<bins).map { bin in
                let start = bin * perBin
                guard start < channel.count else { return 0 }
                let slice = channel[start..<min(channel.count, start + perBin)]
                let peak = slice.reduce(Int16(0)) { max($0, $1 == Int16.min ? Int16.max : abs($1)) }
                return Float(peak) / Float(Int16.max)
            }
        }
    }
}

/// Bars like the reference: tall bars for sound, dotted baseline for silence.
struct WaveformBars: View {
    let samples: [Float]
    var color: Color = .satsumaAccent
    var barWidth: CGFloat = 2
    var spacing: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = barWidth + spacing
            let count = max(1, Int(size.width / step))
            for index in 0..<count {
                let sample = samples[min(samples.count - 1, index * samples.count / count)]
                let height = max(2, CGFloat(sample) * size.height * 0.95)
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
    }
}

@MainActor
final class WaveformModel: ObservableObject {
    @Published var channels: [[Float]] = []
    @Published var isLoading = true

    func load(_ url: URL, bins: Int = 400) {
        Task {
            channels = await WaveformLoader.load(url, bins: bins)
            isLoading = false
        }
    }

    var mono: [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        return zip(first, channels[1]).map { max($0, $1) }
    }
}

// MARK: - Trim range with orange handles

/// Orange frame with grip handles over a filmstrip or waveform (`TrimEndpointHandle`).
struct TrimRangeView<Background: View>: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    var playhead: Double?
    var minimumLength: Double = 0.05
    var onScrub: ((Double) -> Void)?
    @ViewBuilder var background: () -> Background
    @State private var dragOrigin: (start: Double, end: Double)?

    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x0 = width * start / max(duration, 0.001)
            let x1 = width * end / max(duration, 0.001)
            ZStack(alignment: .leading) {
                background()
                    .frame(width: width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        onScrub?(max(0, min(duration, value.location.x / width * duration)))
                    })
                // Dim outside the selection.
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, x0)).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: max(0, width - x1)).offset(x: x1).allowsHitTesting(false)
                // Selection frame.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.satsumaAccent, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, x1 - x0))
                    .offset(x: x0)
                    .allowsHitTesting(false)
                handle(leading: true).offset(x: x0)
                    .gesture(DragGesture().onChanged { value in
                        let origin = dragOrigin ?? (start, end)
                        dragOrigin = origin
                        start = max(0, min(end - minimumLength, origin.start + value.translation.width / width * duration))
                        onScrub?(start)
                    }.onEnded { _ in dragOrigin = nil })
                handle(leading: false).offset(x: x1 - handleWidth)
                    .gesture(DragGesture().onChanged { value in
                        let origin = dragOrigin ?? (start, end)
                        dragOrigin = origin
                        end = min(duration, max(start + minimumLength, origin.end + value.translation.width / width * duration))
                        onScrub?(end)
                    }.onEnded { _ in dragOrigin = nil })
                if let playhead {
                    Rectangle().fill(Color.white).frame(width: 2)
                        .offset(x: width * playhead / max(duration, 0.001) - 1)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func handle(leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 8 : 0, bottomLeadingRadius: leading ? 8 : 0,
                               bottomTrailingRadius: leading ? 0 : 8, topTrailingRadius: leading ? 0 : 8, style: .continuous)
            .fill(Color.satsumaAccent)
            .frame(width: handleWidth)
            .overlay(Capsule().fill(.white).frame(width: 3, height: 22))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}

/// Start/End captions in monospaced text under a trim bar.
struct TrimCaptions: View {
    let start: Double
    let end: Double
    var body: some View {
        HStack {
            Text("Start \(ToolFormat.time(start))")
            Spacer()
            Text("End \(ToolFormat.time(end))")
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Crop / redaction rectangles

/// A rectangle in normalized image coordinates (0…1, top-left origin).
struct NormalizedRect: Equatable, Identifiable, Codable {
    var id = UUID()
    var x: Double, y: Double, width: Double, height: Double
    var color: CodableColor = .black
    var timeRange: ClosedRange<Double>?

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    func rect(in size: CGSize) -> CGRect { CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height) }

    enum CodingKeys: String, CodingKey { case id, x, y, width, height, color }
    init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double, color: CodableColor = .black, timeRange: ClosedRange<Double>? = nil) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.color = color; self.timeRange = timeRange
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        color = try c.decode(CodableColor.self, forKey: .color); timeRange = nil
    }
}

struct CodableColor: Equatable, Codable {
    var red: Double, green: Double, blue: Double
    static let black = CodableColor(red: 0, green: 0, blue: 0)
    var color: Color { Color(red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = ns.redComponent; green = ns.greenComponent; blue = ns.blueComponent
    }
}

enum CropHandle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }

/// Editable rectangle with eight orange handles (`CropResizeHandle`).
struct EditableRect: View {
    @Binding var rect: NormalizedRect
    let canvas: CGSize
    var aspect: Double?            // width / height in pixels of the source, nil = free
    var sourceAspect: Double = 1   // source width / height
    var fill: Color? = nil
    var isSelected = true
    var onSelect: (() -> Void)?
    @State private var origin: NormalizedRect?

    var body: some View {
        let frame = rect.rect(in: canvas)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(fill ?? Color.clear)
                .overlay(Rectangle().stroke(Color.satsumaAccent, lineWidth: isSelected ? 2.5 : 0))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .offset(x: frame.minX, y: frame.minY)
                .gesture(drag(.move))
                .onTapGesture { onSelect?() }
            if isSelected {
                ForEach(Array(CropHandle.allCases.dropLast().enumerated()), id: \.offset) { _, handle in
                    handleView(handle)
                        .position(position(of: handle, in: frame))
                        .gesture(drag(handle))
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
    }

    @ViewBuilder private func handleView(_ handle: CropHandle) -> some View {
        switch handle {
        case .top, .bottom: Capsule().fill(Color.satsumaAccent).frame(width: 22, height: 6)
        case .left, .right: Capsule().fill(Color.satsumaAccent).frame(width: 6, height: 22)
        default: RoundedRectangle(cornerRadius: 2).fill(Color.satsumaAccent).frame(width: 11, height: 11)
        }
    }

    private func position(of handle: CropHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .move: return CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    private func drag(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            onSelect?()
            let start = origin ?? rect
            origin = start
            let dx = value.translation.width / max(canvas.width, 1)
            let dy = value.translation.height / max(canvas.height, 1)
            var r = start
            let minSize = 0.02
            switch handle {
            case .move:
                r.x = min(max(0, start.x + dx), 1 - start.width)
                r.y = min(max(0, start.y + dy), 1 - start.height)
            default:
                var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
                if [.topLeft, .left, .bottomLeft].contains(handle) { left = min(max(0, left + dx), right - minSize) }
                if [.topRight, .right, .bottomRight].contains(handle) { right = max(min(1, right + dx), left + minSize) }
                if [.topLeft, .top, .topRight].contains(handle) { top = min(max(0, top + dy), bottom - minSize) }
                if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(min(1, bottom + dy), top + minSize) }
                r.x = left; r.y = top; r.width = right - left; r.height = bottom - top
                if let aspect { r = Self.constrain(r, aspect: aspect, sourceAspect: sourceAspect, anchor: handle) }
            }
            rect = r
        }
        .onEnded { _ in origin = nil }
    }

    /// Forces width/height (in source pixels) to `aspect`, keeping the opposite edge fixed.
    static func constrain(_ r: NormalizedRect, aspect: Double, sourceAspect: Double, anchor: CropHandle = .bottomRight) -> NormalizedRect {
        var out = r
        // In normalized units, pixel aspect = (w * srcW) / (h * srcH) = (w / h) * sourceAspect.
        let targetRatio = aspect / sourceAspect
        if out.width / max(out.height, 0.0001) > targetRatio { out.width = out.height * targetRatio } else { out.height = out.width / targetRatio }
        if out.width > 1 { out.width = 1; out.height = 1 / targetRatio }
        if out.height > 1 { out.height = 1; out.width = targetRatio }
        if [.topLeft, .left, .bottomLeft].contains(anchor) { out.x = r.x + r.width - out.width }
        if [.topLeft, .top, .topRight].contains(anchor) { out.y = r.y + r.height - out.height }
        out.x = min(max(0, out.x), 1 - out.width)
        out.y = min(max(0, out.y), 1 - out.height)
        return out
    }

    /// Largest centered rect with `aspect`.
    static func centered(aspect: Double?, sourceAspect: Double) -> NormalizedRect {
        guard let aspect else { return .full }
        let ratio = aspect / sourceAspect
        var r = NormalizedRect.full
        if ratio > 1 { r.height = 1 / ratio } else { r.width = ratio }
        r.x = (1 - r.width) / 2
        r.y = (1 - r.height) / 2
        return r
    }
}

/// Fits content of `size` into `container`, returning the displayed rect.
func aspectFitRect(_ size: CGSize, in container: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: container) }
    let scale = min(container.width / size.width, container.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
}

/// Aspect presets ("Free", "1:1", "16:9", "9:16", "4:3", "3:4").
enum AspectPreset: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", classic = "4:3", portrait = "3:4"
    var id: String { rawValue }
    var ratio: Double? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        case .classic: return 4.0 / 3
        case .portrait: return 3.0 / 4
        }
    }
}
