import AVFoundation
import Combine
import SwiftUI

/// Shared loader for a video tool: player + facts.
@MainActor
final class VideoSession: ObservableObject {
    let controller: PlayerController
    @Published var facts = MediaFacts()
    @Published var loaded = false
    private var forwarder: AnyCancellable?

    init(url: URL) {
        controller = PlayerController(url: url)
        // Re-render the tool view as the playhead moves.
        forwarder = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        Task {
            let facts = await MediaFacts.load(url)
            self.facts = facts
            controller.duration = facts.duration
            controller.frameRate = facts.frameRate
            loaded = true
        }
    }
}

// MARK: - Trim Video

struct TrimVideoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var start = 0.0
    @State private var end = 0.0

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Trim Video", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                PreviewWell(height: 380) { PlayerSurface(player: session.controller.player) }
                HStack {
                    Text("Drag the ends to trim").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ToolFormat.time(end - start)) selected").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                TrimRangeView(start: $start, end: $end, duration: max(session.facts.duration, 0.01), playhead: session.controller.time,
                              onScrub: { session.controller.seek($0) }) {
                    FilmstripView(url: context.firstURL, count: 10)
                }
                .frame(height: 84)
                TrimCaptions(start: start, end: end)
                PlaybackBar(controller: session.controller, playRange: start...end)
            }
        } footer: {
            Spacer()
            ToolButton(title: "Apply", isEnabled: session.loaded && end - start > 0.05) { save() }
        }
        .onChange(of: session.loaded) { _, _ in end = session.facts.duration }
        .onDisappear { session.controller.pause() }
    }

    private func save() {
        let (start, end) = (start, end)
        context.run("Trimming video", false) { urls, progress in
            [try await MediaTools.trim(urls[0], start: start, end: end, audioOnly: false, progress: progress)]
        }
    }
}

// MARK: - Crop Video

struct CropVideoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var rect = NormalizedRect.full
    @State private var aspect: AspectPreset = .free
    @State private var widthText = ""
    @State private var heightText = ""

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    private var sourceAspect: Double { session.facts.size.height > 0 ? session.facts.size.width / session.facts.size.height : 16.0 / 9 }

    var body: some View {
        ToolScaffold(title: "Crop Video", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    let fitted = aspectFitRect(session.facts.size == .zero ? CGSize(width: 16, height: 9) : session.facts.size, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        PlayerSurface(player: session.controller.player)
                        CropDimming(rect: rect, size: fitted.size)
                        EditableRect(rect: $rect, canvas: fitted.size, aspect: aspect.ratio, sourceAspect: sourceAspect)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                }
                .frame(height: 380)
                ToolRow(title: "Aspect ratio") {
                    Picker("", selection: $aspect) { ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack(spacing: 8) {
                    Text("W").foregroundStyle(.secondary)
                    TextField("", text: $widthText).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("H").foregroundStyle(.secondary)
                    TextField("", text: $heightText).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { session.controller.time }, set: { session.controller.seek($0) }), in: 0...max(session.facts.duration, 0.01))
                    .controlSize(.small)
                PlaybackBar(controller: session.controller, showsPlay: false)
            }
        } footer: {
            ToolButton(title: "Reset") { rect = .full; aspect = .free }
            Spacer()
            ToolButton(title: "Apply", isEnabled: session.loaded) { save() }
        }
        .onChange(of: rect) { _, newValue in syncFields(newValue) }
        .onChange(of: session.loaded) { _, _ in syncFields(rect) }
        .onChange(of: aspect) { _, newValue in rect = EditableRect.centered(aspect: newValue.ratio, sourceAspect: sourceAspect) }
        .onDisappear { session.controller.pause() }
    }

    private func syncFields(_ r: NormalizedRect) {
        widthText = "\(Int((r.width * session.facts.size.width).rounded()))"
        heightText = "\(Int((r.height * session.facts.size.height).rounded()))"
    }

    private func save() {
        let rect = rect
        let requested = CGSize(width: Double(widthText) ?? 0, height: Double(heightText) ?? 0)
        context.run("Cropping video", false) { urls, progress in
            [try await MediaTools.crop(urls[0], rect: rect, outputSize: requested.width > 1 ? requested : nil, progress: progress)]
        }
    }
}

// MARK: - Change Video Speed

struct VideoSpeedToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var stop = 2
    private let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Change Video Speed", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                PreviewWell(height: 400) { PlayerSurface(player: session.controller.player) }
                HStack {
                    Text("Playback speed").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(MediaTools.speedLabel(speeds[stop]).replacingOccurrences(of: "x", with: "×"))").font(.system(size: 15, weight: .medium))
                }
                Slider(value: Binding(get: { Double(stop) }, set: { stop = Int($0.rounded()) }), in: 0...Double(speeds.count - 1), step: 1)
                HStack {
                    ForEach(speeds.indices, id: \.self) { index in
                        Text(MediaTools.speedLabel(speeds[index]).replacingOccurrences(of: "x", with: "×"))
                            .font(.system(size: 11, weight: index == stop ? .semibold : .regular))
                            .foregroundStyle(index == stop ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Button { session.controller.isPlaying ? session.controller.pause() : session.controller.play(rate: Float(speeds[stop])) } label: {
                        Image(systemName: session.controller.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(ToolFormat.time(session.controller.time)) / \(ToolFormat.time(session.facts.duration))").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 13))
            }
        } footer: {
            Spacer()
            ToolButton(title: "Apply", isEnabled: speeds[stop] != 1) { save() }
        }
        .onChange(of: stop) { _, _ in if session.controller.isPlaying { session.controller.player.rate = Float(speeds[stop]) } }
        .onDisappear { session.controller.pause() }
    }

    private func save() {
        let speed = speeds[stop]
        context.run("Changing speed", false) { urls, progress in [try await MediaTools.changeSpeed(urls[0], speed: speed, progress: progress)] }
    }
}

// MARK: - Join Videos / Merge PDFs

struct OrderedFilesToolView: View {
    enum Kind { case videos, pdfs }
    @ObservedObject var context: ToolContext
    let kind: Kind

    var body: some View {
        ToolScaffold(title: kind == .videos ? "Join Videos" : "Merge PDFs", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == .videos ? "Playback order" : "Document order").font(.system(size: 13)).foregroundStyle(.secondary)
                ForEach(Array(context.urls.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18)
                        FileThumbnail(url: url).frame(width: 44, height: 30)
                        Text(url.lastPathComponent).lineLimit(1)
                        Spacer()
                        VStack(spacing: 4) {
                            Button { move(index, -1) } label: { Image(systemName: "chevron.up").frame(width: 40, height: 14) }.disabled(index == 0)
                            Button { move(index, 1) } label: { Image(systemName: "chevron.down").frame(width: 40, height: 14) }.disabled(index == context.urls.count - 1)
                        }
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: kind == .videos ? "Join Videos" : "Merge PDFs", isEnabled: context.urls.count > 1) { save() }
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard context.urls.indices.contains(target) else { return }
        context.urls.swapAt(index, target)
    }

    private func save() {
        switch kind {
        case .videos:
            context.run("Joining videos", true) { urls, progress in [try await FileToolRunner.joinVideos(urls)] }
        case .pdfs:
            context.run("Merging PDFs", true) { urls, _ in [try FileToolRunner.mergePDFs(urls)] }
        }
    }
}

/// Quick Look thumbnail for a file.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit) }
        }
        .task {
            let request = QLThumbnailRequestFactory.request(url)
            image = await QLThumbnailRequestFactory.thumbnail(request)
        }
    }
}

import QuickLookThumbnailing

enum QLThumbnailRequestFactory {
    static func request(_ url: URL) -> QLThumbnailGenerator.Request {
        QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 90), scale: 2, representationTypes: .thumbnail)
    }

    static func thumbnail(_ request: QLThumbnailGenerator.Request) async -> NSImage? {
        try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Video Snapshots

struct VideoSnapshotsToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var times: [Double] = []
    @State private var thumbnails: [Double: NSImage] = [:]

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Video Snapshots", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                PreviewWell(height: 380) { PlayerSurface(player: session.controller.player) }
                Slider(value: Binding(get: { session.controller.time }, set: { session.controller.seek($0) }), in: 0...max(session.facts.duration, 0.01))
                    .controlSize(.small)
                PlaybackBar(controller: session.controller, showsPlay: false)
                Divider()
                HStack {
                    Text("\(times.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    ToolButton(title: "Add Frame") { addFrame() }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(times, id: \.self) { time in
                            ZStack(alignment: .topTrailing) {
                                Group {
                                    if let image = thumbnails[time] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                                    else { Color.black }
                                }
                                .frame(width: 78, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .bottomLeading) {
                                    Text(ToolFormat.time(time)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.7))).padding(4)
                                }
                                .onTapGesture { session.controller.seek(time) }
                                Button { times.removeAll { $0 == time } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black)
                                }
                                .buttonStyle(.plain).padding(3)
                                .help("Remove frame at \(ToolFormat.time(time))")
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: times.count == 1 ? "Save 1 Frame" : "Save \(times.count) Frames", isEnabled: !times.isEmpty) { save() }
        }
        .onDisappear { session.controller.pause() }
    }

    private func addFrame() {
        let time = (session.controller.time * 1000).rounded() / 1000
        guard !times.contains(time) else { return }
        times.append(time)
        times.sort()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: context.firstURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 160)
        Task {
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                thumbnails[time] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    private func save() {
        let times = times
        context.run("Saving snapshots", false) { urls, _ in try await MediaTools.snapshots(urls[0], times: times) }
    }
}

// MARK: - Split Video

struct SplitVideoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var points: [Double] = []
    @State private var equalClips = 2

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    private var duration: Double { max(session.facts.duration, 0.01) }

    var body: some View {
        ToolScaffold(title: "Split Video", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                PreviewWell(height: 360) { PlayerSurface(player: session.controller.player) }
                HStack {
                    Text("\(points.count) split point\(points.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Spacer()
                    ToolButton(title: "Add Split", systemImage: "scissors") { addSplit(at: session.controller.time) }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        FilmstripView(url: context.firstURL, count: 10).clipShape(RoundedRectangle(cornerRadius: 8))
                            .gesture(DragGesture(minimumDistance: 0).onChanged { session.controller.seek($0.location.x / geometry.size.width * duration) })
                        ForEach(points, id: \.self) { point in
                            Rectangle().fill(Color.satsumaAccent).frame(width: 3)
                                .offset(x: geometry.size.width * point / duration - 1.5)
                                .onTapGesture(count: 2) { points.removeAll { $0 == point } }
                                .help("Double-click to remove")
                        }
                        Rectangle().fill(.white).frame(width: 2).offset(x: geometry.size.width * session.controller.time / duration - 1).allowsHitTesting(false)
                    }
                }
                .frame(height: 64)
                PlaybackBar(controller: session.controller, showsPlay: false)
                Divider()
                HStack {
                    Text("Equal clips").foregroundStyle(.secondary)
                    Spacer()
                    Stepper("\(equalClips)", value: $equalClips, in: 2...50).fixedSize()
                    ToolButton(title: "Set") { points = (1..<equalClips).map { duration * Double($0) / Double(equalClips) } }
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Split Video", isEnabled: !points.isEmpty) { save() }
        }
        .onDisappear { session.controller.pause() }
    }

    private func addSplit(at time: Double) {
        guard time > 0.05, time < duration - 0.05, !points.contains(where: { abs($0 - time) < 0.05 }) else { return }
        points.append(time)
        points.sort()
    }

    private func save() {
        let (points, duration) = (points, duration)
        context.run("Splitting video", false) { urls, progress in [try await MediaTools.split(urls[0], points: points, duration: duration, progress: progress)] }
    }
}

// MARK: - Redact Video

struct RedactVideoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: VideoSession
    @State private var rects: [NormalizedRect] = []
    @State private var selected: UUID?
    @State private var draft: NormalizedRect?
    @State private var blur = false
    @State private var color = Color.black

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: VideoSession(url: context.firstURL))
    }

    private var duration: Double { max(session.facts.duration, 0.01) }

    private var visible: Set<UUID> {
        Set(rects.filter { $0.timeRange.map { $0.contains(session.controller.time) } ?? true }.map(\.id))
    }

    var body: some View {
        ToolScaffold(title: "Redact Video", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    let fitted = aspectFitRect(session.facts.size == .zero ? CGSize(width: 16, height: 9) : session.facts.size, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        PlayerSurface(player: session.controller.player)
                        RedactionCanvas(rects: $rects, selected: $selected, draft: $draft, size: fitted.size, blur: blur, color: color, visibleIDs: visible)
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                }
                .frame(height: 360)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.1)))
                ToolRow(title: "Style") {
                    Picker("", selection: $blur) { Text("Solid").tag(false); Text("Blur").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if !blur { ToolRow(title: "Color") { ColorPicker("", selection: $color).labelsHidden() } }
                Divider()
                Text("Redactions").font(.system(size: 13, weight: .semibold))
                ForEach(Array($rects.enumerated()), id: \.element.id) { index, $rect in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 16)
                        TimeRangeTrack(range: Binding(get: { rect.timeRange ?? 0...duration }, set: { rect.timeRange = $0 }),
                                       duration: duration, label: "Box \(index + 1)", selected: selected == rect.id,
                                       playhead: session.controller.time) { selected = rect.id }
                            .frame(height: 28)
                    }
                }
                if rects.isEmpty {
                    Text("Draw rectangles over the video to cover areas. Each one gets its own time range.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "film").foregroundStyle(.secondary).frame(width: 16)
                    FilmstripView(url: context.firstURL, count: 10).frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(GeometryReader { g in
                            Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * session.controller.time / duration - 1)
                        })
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                }
                PlaybackBar(controller: session.controller)
            }
        } footer: {
            Spacer()
            ToolButton(title: "Save Redacted Copy", isEnabled: !rects.isEmpty) { save() }
        }
        .onDeleteCommand { if let selected { rects.removeAll { $0.id == selected }; self.selected = nil } }
        .onChange(of: color) { _, newValue in let c = CodableColor(newValue); for index in rects.indices { rects[index].color = c } }
        .onDisappear { session.controller.pause() }
    }

    private func save() {
        let (rects, blur) = (rects, blur)
        context.run("Redacting video", false) { urls, progress in [try await MediaTools.redactVideo(urls[0], rects: rects, blur: blur, progress: progress)] }
    }
}

/// A draggable clip on a track (`RedactionTrack`, `BleepTrack`).
struct TimeRangeTrack: View {
    @Binding var range: ClosedRange<Double>
    let duration: Double
    let label: String
    var selected = false
    var playhead: Double?
    var onSelect: () -> Void = {}
    @State private var origin: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x0 = width * range.lowerBound / duration, x1 = width * range.upperBound / duration
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 6).fill(Color.satsumaAccentSoft.opacity(selected ? 0.85 : 0.6))
                    .overlay(Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 2, height: 16).padding(.leading, 5) }
                    .overlay(alignment: .trailing) { Capsule().fill(.white).frame(width: 2, height: 16).padding(.trailing, 5) }
                    .frame(width: max(14, x1 - x0))
                    .offset(x: x0)
                    .gesture(DragGesture().onChanged { value in
                        onSelect()
                        let start = origin ?? range
                        origin = start
                        let delta = value.translation.width / width * duration
                        let length = start.upperBound - start.lowerBound
                        let edge: CGFloat = 10
                        let grabbedLeft = value.startLocation.x - x0 < edge
                        let grabbedRight = (x1 - x0) - (value.startLocation.x - x0) < edge
                        if grabbedLeft {
                            range = max(0, min(start.upperBound - 0.05, start.lowerBound + delta))...start.upperBound
                        } else if grabbedRight {
                            range = start.lowerBound...min(duration, max(start.lowerBound + 0.05, start.upperBound + delta))
                        } else {
                            let lower = max(0, min(duration - length, start.lowerBound + delta))
                            range = lower...(lower + length)
                        }
                    }.onEnded { _ in origin = nil })
                if let playhead {
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1).offset(x: width * playhead / duration).allowsHitTesting(false)
                }
            }
        }
    }
}
