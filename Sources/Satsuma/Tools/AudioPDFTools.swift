import AVFoundation
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Loader shared by the audio tools: player, facts and waveform.
@MainActor
final class AudioSession: ObservableObject {
    let controller: PlayerController
    let waveform = WaveformModel()
    @Published var facts = MediaFacts()
    private var forwarders: Set<AnyCancellable> = []

    init(url: URL) {
        controller = PlayerController(url: url)
        // Re-render the tool view when the waveform or playhead changes.
        waveform.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &forwarders)
        controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &forwarders)
        waveform.load(url)
        Task {
            let facts = await MediaFacts.load(url)
            self.facts = facts
            controller.duration = facts.duration
        }
    }

    /// Plays a rendered preview file through a second player.
    private var previewPlayer: AVPlayer?
    func playPreview(_ url: URL?) {
        guard let url else { return }
        previewPlayer = AVPlayer(url: url)
        previewPlayer?.play()
    }
    func stopPreview() { previewPlayer?.pause() }
}

/// Grey rounded well with orange bars and a playhead.
struct WaveformWell: View {
    let samples: [Float]
    var playhead: Double?
    var duration: Double = 1
    var color: Color = .satsumaAccent
    var onScrub: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                WaveformBars(samples: samples, color: color).padding(.horizontal, 8).padding(.vertical, 16)
                if let playhead {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2)
                        .offset(x: geometry.size.width * playhead / max(duration, 0.001))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onScrub?(max(0, min(duration, value.location.x / geometry.size.width * duration)))
            })
        }
    }
}

// MARK: - Normalize Volume

struct NormalizeAudioToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: AudioSession
    @State private var loudness = -16.0
    @State private var range = 11.0
    @State private var truePeak = -1.5

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: AudioSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Normalize Volume", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(context.firstURL.lastPathComponent).foregroundStyle(.secondary)
                    Spacer()
                    Text(ToolFormat.time(session.facts.duration)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 12))
                WaveformWell(samples: session.waveform.mono, playhead: session.controller.time, duration: session.facts.duration,
                             onScrub: { session.controller.seek($0) })
                    .frame(height: 220)
                PlaybackBar(controller: session.controller, showsSteps: false)
                slider("Target loudness", $loudness, -36...(-6), 1, "\(Int(loudness)) LUFS")
                slider("Loudness range", $range, 1...20, 1, "\(Int(range)) LU")
                slider("True peak limit", $truePeak, -9...0, 0.5, String(format: "%.1f dBTP", truePeak))
                Text("–16 LUFS is a balanced default for spoken audio and music. The true peak limit helps prevent clipping after encoding.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } footer: {
            Spacer()
            ToolButton(title: "Normalize Audio") { save() }
        }
        .onDisappear { session.controller.pause() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(label).monospacedDigit() }.font(.system(size: 13))
            Slider(value: value, in: range, step: step).controlSize(.small)
        }
    }

    private func save() {
        let (loudness, range, truePeak) = (loudness, range, truePeak)
        context.run("Normalizing volume", false) { urls, progress in
            [try await MediaTools.normalize(urls[0], loudness: loudness, range: range, truePeak: truePeak, progress: progress)]
        }
    }
}

// MARK: - Audio Visualizer

struct AudioVisualizerToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: AudioSession
    @State private var waveform = true
    @State private var shape: MediaTools.VisualizerShape = .landscape
    @State private var image: URL?

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: AudioSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Audio Visualizer", onClose: context.close) {
            VStack(alignment: .leading, spacing: 14) {
                GeometryReader { geometry in
                    let (w, h) = shape.size
                    let fitted = aspectFitRect(CGSize(width: w, height: h), in: geometry.size)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.black)
                        if waveform {
                            WaveformBars(samples: session.waveform.mono, barWidth: 4, spacing: 5).padding(fitted.width * 0.04)
                                .frame(height: fitted.height * 0.8)
                        } else if let image, let nsImage = NSImage(contentsOf: image) {
                            Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text("Choose a static image").foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .offset(x: fitted.minX, y: fitted.minY)
                }
                .frame(height: 420)
                ToolRow(title: "Style") {
                    Picker("", selection: $waveform) { Text("Waveform").tag(true); Text("Static Image").tag(false) }.labelsHidden().fixedSize()
                }
                if !waveform {
                    ToolRow(title: "Image") {
                        Button(image?.lastPathComponent ?? "Choose…") { chooseImage() }
                    }
                }
                ToolRow(title: "Shape") {
                    Picker("", selection: $shape) { ForEach(MediaTools.VisualizerShape.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Create Visualization", isEnabled: waveform || image != nil) { save() }
        }
        .onChange(of: waveform) { _, isWaveform in if !isWaveform && image == nil { chooseImage() } }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a visualization image"
        if panel.runModal() == .OK { image = panel.url }
    }

    private func save() {
        let (waveform, image, shape) = (waveform, image, shape)
        context.run("Creating visualization", false) { urls, progress in
            [try await MediaTools.visualize(urls[0], waveform: waveform, image: image, shape: shape, progress: progress)]
        }
    }
}

// MARK: - Trim Audio

struct TrimAudioToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: AudioSession
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var autoTrim = false
    @State private var detecting = false
    @State private var message: String?

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: AudioSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Trim Audio", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Drag the ends to trim").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(ToolFormat.time(end - start)) selected").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                TrimRangeView(start: $start, end: $end, duration: max(session.facts.duration, 0.01), playhead: session.controller.time,
                              onScrub: { session.controller.seek($0) }) {
                    ZStack {
                        Color.satsumaAccent.opacity(0.12)
                        WaveformBars(samples: session.waveform.mono).padding(.vertical, 12).padding(.horizontal, 16)
                    }
                }
                .frame(height: 96)
                TrimCaptions(start: start, end: end)
                Toggle(detecting ? "Detecting silence" : "Trim silent ends automatically", isOn: $autoTrim).toggleStyle(.checkbox)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    ToolButton(title: session.controller.isPlaying ? "Pause" : "Play Selected Range",
                               systemImage: session.controller.isPlaying ? "pause.fill" : "play.fill") {
                        session.controller.isPlaying ? session.controller.pause() : session.controller.play(range: start...end)
                    }
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Apply", isEnabled: end - start > 0.05) { save() }
        }
        .onChange(of: session.facts.duration) { _, duration in if end == 0 { end = duration } }
        .onChange(of: autoTrim) { _, enabled in if enabled { detectSilence() } else { start = 0; end = session.facts.duration } }
        .onDisappear { session.controller.pause() }
    }

    private func detectSilence() {
        detecting = true
        let (url, duration) = (context.firstURL, session.facts.duration)
        Task {
            if let found = await MediaTools.detectSilence(url, thresholdDB: -40, duration: duration) {
                start = found.0; end = found.1; message = nil
            } else {
                message = "The selected range is silent at this threshold. Lower the threshold or turn off automatic trimming."
            }
            detecting = false
        }
    }

    private func save() {
        let (start, end) = (start, end)
        context.run("Trimming audio", false) { urls, progress in
            [try await MediaTools.trim(urls[0], start: start, end: end, audioOnly: true, progress: progress)]
        }
    }
}

// MARK: - Convert Audio Channels

struct AudioChannelsToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: AudioSession
    @State private var stereo = true
    @State private var left = 1.0
    @State private var right = 1.0

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: AudioSession(url: context.firstURL))
    }

    var body: some View {
        ToolScaffold(title: "Convert Audio Channels", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Output channel preview").font(.system(size: 13)).foregroundStyle(.secondary)
                channelRow("L", samples: session.waveform.channels.first ?? [], volume: left, channel: 0)
                channelRow("R", samples: session.waveform.channels.count > 1 ? session.waveform.channels[1] : (session.waveform.channels.first ?? []),
                           volume: right, channel: 1)
                Divider()
                ToolRow(title: "Output") {
                    Picker("", selection: $stereo) { Text("Mono").tag(false); Text("Stereo").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                ToolSliderRow(title: "Left volume", value: $left, range: 0...1, format: { "\(Int($0 * 100))%" })
                ToolSliderRow(title: "Right volume", value: $right, range: 0...1, format: { "\(Int($0 * 100))%" })
                ToolRow(title: "Preview") {
                    ToolButton(title: "Play Output", systemImage: "play.fill") { playOutput() }
                        .help("Play the complete Mono or Stereo output with the selected volume balance")
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Apply") { save() }
        }
        .onDisappear { session.stopPreview() }
    }

    private func channelRow(_ label: String, samples: [Float], volume: Double, channel: Int) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                .background(Circle().fill(Color.satsumaAccent.opacity(0.15)))
            WaveformWell(samples: samples.map { $0 * Float(volume) }, color: .secondary).frame(height: 44)
                .overlay(alignment: .leading) { Rectangle().fill(Color.satsumaAccent).frame(width: 2) }
            Button { playChannel(channel) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain)
        }
    }

    private func playChannel(_ channel: Int) {
        let url = context.firstURL
        Task { session.playPreview(await MediaTools.preview(url, filter: "pan=mono|c0=c\(channel)")) }
    }

    private func playOutput() {
        let url = context.firstURL
        let filter = stereo ? "pan=stereo|c0=\(left)*c0|c1=\(right)*c1" : "pan=mono|c0=\(left * 0.5)*c0+\(right * 0.5)*c1"
        Task { session.playPreview(await MediaTools.preview(url, filter: filter)) }
    }

    private func save() {
        let (stereo, left, right) = (stereo, left, right)
        context.run("Converting channels", false) { urls, _ in [try await MediaTools.channels(urls[0], stereo: stereo, left: left, right: right)] }
    }
}

// MARK: - Bleep Audio

struct BleepAudioToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var session: AudioSession
    @State private var ranges: [IdentifiedRange] = []
    @State private var selected: UUID?
    @State private var draftStart: Double?

    struct IdentifiedRange: Identifiable, Equatable { var id = UUID(); var range: ClosedRange<Double> }

    init(context: ToolContext) {
        self.context = context
        _session = StateObject(wrappedValue: AudioSession(url: context.firstURL))
    }

    private var duration: Double { max(session.facts.duration, 0.01) }

    var body: some View {
        ToolScaffold(title: "Bleep Audio", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) { Text("Bleeps").font(.system(size: 13, weight: .semibold)); Text("\(ranges.count)").foregroundStyle(.secondary) }
                HStack(spacing: 10) {
                    Text("Bleep").foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                    let a = value.startLocation.x / geometry.size.width * duration
                                    let b = value.location.x / geometry.size.width * duration
                                    draftStart = draftStart ?? a
                                    let lower = max(0, min(a, b)), upper = min(duration, max(a, b))
                                    if let index = ranges.firstIndex(where: { $0.id == selected }), draftStart == a, ranges[index].range.lowerBound == lower || true,
                                       selected != nil, ranges[index].id == selected, ranges.last?.id == selected {
                                        ranges[index].range = lower...max(upper, lower + 0.05)
                                    } else {
                                        let item = IdentifiedRange(range: lower...max(upper, lower + 0.05))
                                        ranges.append(item)
                                        selected = item.id
                                    }
                                }.onEnded { _ in draftStart = nil })
                            ForEach($ranges) { $item in
                                TimeRangeTrack(range: $item.range, duration: duration, label: "Bleep", selected: selected == item.id) { selected = item.id }
                            }
                        }
                    }
                    .frame(height: 34)
                }
                HStack(spacing: 10) {
                    Text("Audio").foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    WaveformWell(samples: session.waveform.mono, playhead: session.controller.time, duration: duration, color: .satsumaAccentSoft,
                                 onScrub: { session.controller.seek($0) })
                        .frame(height: 80)
                }
                HStack {
                    Spacer().frame(width: 58)
                    Text(ToolFormat.time(0)); Spacer(); Text(ToolFormat.time(session.facts.duration))
                }
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Text("Drag across the Bleep layer to add a section, then drag a clip or either edge to adjust it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                ToolRow(title: "Preview") {
                    HStack {
                        ToolButton(title: "Original") { session.stopPreview(); session.controller.play() }
                        ToolButton(title: "With Bleeps", systemImage: "play.fill", isEnabled: !ranges.isEmpty) { playWithBleeps() }
                    }
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Save Bleeped Copy", isEnabled: !ranges.isEmpty) { save() }
        }
        .onDeleteCommand { if let selected { ranges.removeAll { $0.id == selected }; self.selected = nil } }
        .onDisappear { session.controller.pause(); session.stopPreview() }
    }

    private func playWithBleeps() {
        session.controller.pause()
        let url = context.firstURL, ranges = ranges.map(\.range), duration = duration
        let between = ranges.map { "between(t,\($0.lowerBound),\($0.upperBound))" }.joined(separator: "+")
        let graph = "[0:a]volume=0:enable='\(between)'[m];sine=f=1000:sample_rate=48000:d=\(duration),volume=0.25,volume=0:enable='not(\(between))'[t];[m][t]amix=inputs=2:duration=first:normalize=0[a]"
        Task { session.playPreview(await MediaTools.preview(url, filter: graph, complex: true)) }
    }

    private func save() {
        let ranges = ranges.map(\.range)
        context.run("Bleeping audio", false) { urls, progress in [try await MediaTools.bleep(urls[0], ranges: ranges, progress: progress)] }
    }
}

// MARK: - Organize PDF

struct OrganizePDFToolView: View {
    @ObservedObject var context: ToolContext
    @State private var pages: [PageItem] = []
    @State private var equalizeWidths = false
    @State private var dragged: UUID?

    struct PageItem: Identifiable, Equatable {
        let id = UUID()
        let originalIndex: Int
        var rotation: Int
        let thumbnail: NSImage
    }

    var body: some View {
        ToolScaffold(title: "Organize PDF", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(pages.count) pages").foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Order") { pages.sort { $0.originalIndex < $1.originalIndex }; for i in pages.indices { pages[i].rotation = 0 } }
                        .disabled(pages.map(\.originalIndex) == Array(pages.indices) && pages.allSatisfy { $0.rotation == 0 })
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 14)], spacing: 14) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { position, page in
                        pageCard(page, position: position)
                            .onDrag { dragged = page.id; return NSItemProvider(object: page.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: PageDropDelegate(target: page.id, pages: $pages, dragged: $dragged))
                    }
                }
                Divider()
                Toggle("Make all pages the same width", isOn: $equalizeWidths).toggleStyle(.checkbox)
                Text("Pages are scaled proportionally to match the narrowest page; their heights may still differ.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } footer: {
            Spacer()
            ToolButton(title: "Save Organized PDF", isEnabled: !pages.isEmpty) { save() }
        }
        .task { load() }
    }

    private func pageCard(_ page: PageItem, position: Int) -> some View {
        ZStack(alignment: .top) {
            Image(nsImage: page.thumbnail).resizable().aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(page.rotation)))
                .padding(10)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)).shadow(color: .black.opacity(0.08), radius: 3, y: 1))
            HStack {
                Text("\(position + 1)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(Circle().fill(Color.satsumaAccent))
                Spacer()
                Button { rotate(page.id) } label: {
                    Image(systemName: "rotate.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.black.opacity(0.65)))
                }
                .buttonStyle(.plain)
                .help("Drag to change its position, or use Rotate to turn it clockwise")
            }
            .padding(6)
        }
        .opacity(dragged == page.id ? 0.4 : 1)
        .contextMenu {
            Button("Duplicate Page") { if let index = pages.firstIndex(of: page) { pages.insert(PageItem(originalIndex: page.originalIndex, rotation: page.rotation, thumbnail: page.thumbnail), at: index + 1) } }
            Button("Remove Page", role: .destructive) { pages.removeAll { $0.id == page.id } }.disabled(pages.count <= 1)
        }
    }

    private func rotate(_ id: UUID) {
        if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].rotation = (pages[index].rotation + 90) % 360 }
    }

    private func load() {
        guard let document = PDFDocument(url: context.firstURL) else { return }
        pages = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return PageItem(originalIndex: index, rotation: 0, thumbnail: page.thumbnail(of: NSSize(width: 240, height: 320), for: .mediaBox))
        }
    }

    private func save() {
        let order = pages.map { ($0.originalIndex, $0.rotation) }
        let equalize = equalizeWidths
        context.run("Organizing PDF", false) { urls, _ in
            guard let document = PDFDocument(url: urls[0]) else { throw ConversionError.encodingFailed("This PDF cannot be read or is password-protected.") }
            let output = PDFDocument()
            let narrowest = order.compactMap { document.page(at: $0.0)?.bounds(for: .mediaBox).width }.min() ?? 0
            for (index, rotation) in order {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                page.rotation = (page.rotation + rotation) % 360
                if equalize, narrowest > 0 {
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = narrowest / bounds.width
                    if scale < 0.999, let image = PDFPageExporter.image(of: page, scale: 2 * scale) {
                        let nsImage = NSImage(cgImage: image, size: NSSize(width: bounds.width * scale, height: bounds.height * scale))
                        if let scaled = PDFPage(image: nsImage) { output.insert(scaled, at: output.pageCount); continue }
                    }
                }
                output.insert(page, at: output.pageCount)
            }
            let url = OutputNaming.destination(for: urls[0], extension: "pdf", suffix: " organized")
            guard output.pageCount > 0, output.write(to: url) else { throw ConversionError.encodingFailed("PDFKit could not write the organized PDF.") }
            return [url]
        }
    }
}

struct PageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var pages: [OrganizePDFToolView.PageItem]
    @Binding var dragged: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = pages.firstIndex(where: { $0.id == dragged }), let to = pages.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }

    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
