import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Compress

struct CompressToolView: View {
    @ObservedObject var context: ToolContext
    @State private var strong = false
    @State private var size: ImageSizeChoice = .original
    @State private var targetEnabled = false
    @State private var targetMode: TargetMode = .fileSize
    @State private var targetText = ""
    @State private var targetUnit: SizeUnit = .mb
    @State private var reduction = 50.0

    enum ImageSizeChoice: String, CaseIterable, Identifiable {
        case original = "Keep original dimensions", large = "Large · 2048 px", medium = "Medium · 1280 px", small = "Small · 800 px"
        var id: String { rawValue }
        var maxDimension: CGFloat? { switch self { case .original: return nil; case .large: return 2048; case .medium: return 1280; case .small: return 800 } }
    }

    enum TargetMode: String, CaseIterable, Identifiable { case fileSize = "Target file size", percentage = "File size reduction"; var id: String { rawValue } }
    enum SizeUnit: String, CaseIterable, Identifiable { case kb = "KB", mb = "MB"; var id: String { rawValue } }

    private var formats: [ConversionFormat] { context.urls.compactMap(ConversionFormat.detect) }
    private var isImageSelection: Bool { formats.allSatisfy { $0.group == .images } }
    private var totalSize: Int64 { context.urls.compactMap(ToolFormat.fileSize).reduce(0, +) }

    var body: some View {
        ToolScaffold(title: "Compress", onClose: context.close) {
            VStack(alignment: .leading, spacing: 14) {
                Text(context.fileName).font(.system(size: 12)).foregroundStyle(.secondary)
                    .onAppear(perform: loadDefaults)
                Text("Original size: \(ToolFormat.bytes(totalSize))").font(.system(size: 14, weight: .medium))
                Text("Compression preset").font(.system(size: 15, weight: .semibold))
                Picker("", selection: $strong) {
                    Text("Balanced").tag(false)
                    Text("Strong").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(targetEnabled)
                Text(strong ? "Smaller files with more quality loss." : "Smaller files with less quality loss.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if isImageSelection {
                    HStack {
                        Text("Image size").font(.system(size: 14))
                        Picker("", selection: $size) { ForEach(ImageSizeChoice.allCases) { Text($0.rawValue).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                }
                Divider()
                Toggle("Compress to target file size", isOn: $targetEnabled).toggleStyle(.checkbox)
                if targetEnabled {
                    Picker("Compression mode", selection: $targetMode) { ForEach(TargetMode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    if targetMode == .fileSize {
                        HStack {
                            TextField("Size", text: $targetText).textFieldStyle(.roundedBorder).frame(width: 90)
                            Picker("", selection: $targetUnit) { ForEach(SizeUnit.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                        }
                        Text("The target is calculated separately from each original file.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ToolSliderRow(title: "Reduction", value: $reduction, range: 1...99, step: 1, format: { "\(Int($0))%" })
                        Text("Output will be at most \(ToolFormat.bytes(Int64(Double(totalSize) * (1 - reduction / 100)))).")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Compress", isEnabled: validTarget) { start() }
        }
    }

    /// Starts from the presets chosen in Settings → Compression.
    private func loadDefaults() {
        let settings = SettingsModel.shared
        strong = (isImageSelection ? settings.imageCompressionStrength : settings.videoCompressionStrength) == .strong
        size = ImageSizeChoice.allCases.first { $0.maxDimension == settings.imageCompressionSize.maxDimension } ?? .original
    }

    private var validTarget: Bool {
        guard targetEnabled, targetMode == .fileSize else { return true }
        return (Double(targetText.replacingOccurrences(of: ",", with: ".")) ?? 0) > 0
    }

    private func targetBytes(for url: URL) -> Int64? {
        guard targetEnabled else { return nil }
        if targetMode == .percentage { return ToolFormat.fileSize(url).map { Int64(Double($0) * (1 - reduction / 100)) } }
        let value = Double(targetText.replacingOccurrences(of: ",", with: ".")) ?? 0
        return Int64(value * (targetUnit == .mb ? 1_000_000 : 1_000))
    }

    private func start() {
        let strong = strong, maxDimension = size.maxDimension
        let targets = Dictionary(uniqueKeysWithValues: context.urls.map { ($0, targetBytes(for: $0)) })
        context.run("Compressing", false) { urls, progress in
            let url = urls[0]
            let plan = ImageProcessing.CompressionPlan(strong: strong, maxDimension: maxDimension, targetBytes: targets[url] ?? nil)
            guard let format = ConversionFormat.detect(url) else { throw ConversionError.unsupportedSource }
            switch format.group {
            case .images: return [try ImageProcessing.compressImage(url, plan: plan)]
            case .documents where format == .pdf: return [try ImageProcessing.compressPDF(url, plan: plan)]
            case .video: return [try await MediaTools.compressVideo(url, plan: plan, progress: progress)]
            case .audio: return [try await MediaTools.compressAudio(url, plan: plan)]
            default: throw ConversionError.fileToolUnavailable("Compress")
            }
        }
    }
}

// MARK: - Metadata

struct MetadataToolView: View {
    @ObservedObject var context: ToolContext
    @State private var fields: [MetadataTool.Field] = []
    @State private var search = ""
    @State private var error: String?
    @State private var loading = true

    private var grouped: [(String, [Binding<MetadataTool.Field>])] {
        let visible = $fields.filter { binding in
            let field = binding.wrappedValue
            return search.isEmpty || field.name.localizedCaseInsensitiveContains(search) || field.value.localizedCaseInsensitiveContains(search)
        }
        var order: [String] = []
        var groups: [String: [Binding<MetadataTool.Field>]] = [:]
        for binding in visible {
            let group = binding.wrappedValue.group
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(binding)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        ToolScaffold(title: "Metadata", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(context.firstURL.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Search metadata", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
                if !loading && fields.isEmpty && error == nil { Text("No readable metadata found.").foregroundStyle(.secondary) }
                ForEach(grouped, id: \.0) { group, items in
                    Divider()
                    Text(group).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(items, id: \.wrappedValue.key) { $field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(field.name):").frame(width: 150, alignment: .trailing).lineLimit(1)
                            if field.editable && !field.removed {
                                TextField("", text: $field.value).textFieldStyle(.roundedBorder)
                            } else {
                                Text(field.removed ? "Removed" : field.value).foregroundStyle(field.removed ? .secondary : .primary)
                                    .lineLimit(2).textSelection(.enabled)
                                Spacer()
                            }
                            Button { field.removed.toggle() } label: { Image(systemName: field.removed ? "arrow.uturn.backward.circle" : "minus.circle") }
                                .buttonStyle(.plain)
                                .foregroundStyle(field.editable ? .primary : .tertiary)
                                .disabled(!field.editable)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("For photos, Remove All also clears hidden camera and processing data. HDR and portrait effects may change.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    ToolButton(title: "Remove All") { save(removeAll: true) }
                    ToolButton(title: "Save", isEnabled: fields.contains { $0.removed || $0.value != $0.original }) { save(removeAll: false) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { fields = try await MetadataTool.read(context.firstURL) } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func save(removeAll: Bool) {
        let fields = fields
        context.run(removeAll ? "Removing Metadata" : "Saving Metadata", false) { urls, _ in
            [try await MetadataTool.write(urls[0], fields: fields, removeAll: removeAll)]
        }
    }
}

// MARK: - Image preview helper

@MainActor
final class ImageSource: ObservableObject {
    @Published var image: CGImage?
    @Published var preview: CGImage?
    @Published var error: String?

    func load(_ url: URL, previewSize: CGFloat = 1400) {
        Task {
            do {
                let image = try ImageProcessing.loadCGImage(url)
                self.image = image
                self.preview = ImageProcessing.resized(image, maxDimension: previewSize)
            } catch { self.error = "Could not read the image." }
        }
    }

    var aspect: Double { image.map { Double($0.width) / Double(max($0.height, 1)) } ?? 1 }
    var pixelSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
}

/// Image fitted into a well, exposing the fitted rect to an overlay.
struct FittedImage<Overlay: View>: View {
    let image: CGImage?
    var height: CGFloat = 380
    var dark = true
    var inset: CGFloat = 0
    @ViewBuilder var overlay: (CGSize) -> Overlay

    var body: some View {
        PreviewWell(height: height, dark: dark) {
            GeometryReader { geometry in
                if let image {
                    let container = CGSize(width: geometry.size.width - inset * 2, height: geometry.size.height - inset * 2)
                    let rect = aspectFitRect(CGSize(width: image.width, height: image.height), in: container).offsetBy(dx: inset, dy: inset)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        overlay(rect.size)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Edit Photo

struct EditPhotoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var source = ImageSource()
    @State private var values = ImageAdjustmentValues()
    @State private var rendered: CGImage?
    @State private var showsOriginal = false
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        ToolScaffold(title: "Edit Photo", onClose: context.close) {
            VStack(alignment: .leading, spacing: 8) {
                FittedImage(image: showsOriginal ? source.preview : (rendered ?? source.preview), height: 300) { _ in EmptyView() }
                    .overlay(alignment: .topTrailing) {
                        Button(showsOriginal ? "Edited" : "Original") { showsOriginal.toggle() }
                            .controlSize(.small).padding(8)
                    }
                section("Light", [
                    ("Exposure", \.exposure, -5...5, { String(format: "%.2f EV", $0) }),
                    ("Brightness", \.brightness, -100...100, nil), ("Contrast", \.contrast, -100...100, nil),
                    ("Highlights", \.highlights, -100...100, nil), ("Shadows", \.shadows, -100...100, nil),
                    ("Whites", \.whites, -100...100, nil), ("Blacks", \.blacks, -100...100, nil), ("Gamma", \.gamma, -100...100, nil)])
                section("Color", [
                    ("Temperature", \.temperature, -100...100, nil), ("Tint", \.tint, -100...100, nil),
                    ("Saturation", \.saturation, -100...100, nil), ("Vibrance", \.vibrance, -100...100, nil),
                    ("Hue", \.hue, -180...180, { "\(Int($0))°" })])
                section("Detail", [
                    ("Clarity", \.clarity, -100...100, nil), ("Texture", \.texture, -100...100, nil),
                    ("Sharpness", \.sharpness, 0...100, nil), ("Dehaze", \.dehaze, -100...100, nil),
                    ("Noise Reduction", \.noiseReduction, 0...100, nil)])
                section("Effects", [
                    ("Fade", \.fade, 0...100, nil), ("Vignette", \.vignette, -100...100, nil),
                    ("Grain", \.grain, 0...100, nil), ("Blur", \.blur, 0...100, nil)])
            }
        } footer: {
            ToolButton(title: "Reset", isEnabled: values != ImageAdjustmentValues()) { values = ImageAdjustmentValues() }
            Spacer()
            ToolButton(title: "Save Edited Copy", isEnabled: values != ImageAdjustmentValues()) { save() }
        }
        .onAppear { source.load(context.firstURL, previewSize: 1200) }
        .onChange(of: values) { _, _ in scheduleRender() }
    }

    private func section(_ title: String, _ rows: [(String, WritableKeyPath<ImageAdjustmentValues, Double>, ClosedRange<Double>, ((Double) -> String)?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ToolSectionTitle(text: title)
            ForEach(rows, id: \.0) { row in
                ToolSliderRow(title: row.0, value: $values[dynamicMember: row.1], range: row.2,
                              format: row.3 ?? { String(format: "%+.0f", $0) }, resetValue: 0, labelWidth: 110)
            }
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let values = values
        guard let preview = source.preview else { return }
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let output = await Task.detached { ImageProcessing.render(ImageProcessing.adjusted(CIImage(cgImage: preview), values)) }.value
            if !Task.isCancelled { rendered = output }
        }
    }

    private func save() {
        let values = values
        context.run("Saving Edited Copy", false) { urls, _ in
            let image = try ImageProcessing.loadCGImage(urls[0])
            guard let output = ImageProcessing.render(ImageProcessing.adjusted(CIImage(cgImage: image), values)) else {
                throw ConversionError.encodingFailed("Could not render the photo adjustments.")
            }
            return [try ImageProcessing.save(output, beside: urls[0], suffix: " edited")]
        }
    }
}

// MARK: - Annotate

struct AnnotateToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var source = ImageSource()
    @State private var tool: AnnotationTool = .arrow
    @State private var annotations: [Annotation] = []
    @State private var history: [[Annotation]] = []
    @State private var selected: UUID?
    @State private var draft: Annotation?
    @State private var dragOrigin: (id: UUID, annotation: Annotation)?
    @State private var color = Color(red: 0.93, green: 0.23, blue: 0.23)
    @State private var editingText: UUID?
    @State private var textValue = ""
    @State private var magnification: CGFloat = 2

    var body: some View {
        ToolScaffold(title: "Annotate Photo", onClose: context.close) {
            VStack(alignment: .leading, spacing: 10) {
                FittedImage(image: source.preview, height: 400) { size in
                    canvas(size: size)
                }
                HStack(spacing: 6) {
                    ForEach(AnnotationTool.allCases) { item in
                        Button { select(item) } label: {
                            Image(systemName: item.symbol)
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .foregroundStyle(tool == item ? .white : .primary)
                                .background(RoundedRectangle(cornerRadius: 7).fill(tool == item ? Color.satsumaAccent : Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue.capitalized)
                    }
                }
                HStack {
                    ColorPicker("", selection: $color).labelsHidden()
                    if tool == .magnifier {
                        Picker("Zoom", selection: $magnification) { ForEach([1.5, 2, 3, 4], id: \.self) { Text("\($0, specifier: "%g")×").tag(CGFloat($0)) } }
                            .labelsHidden().fixedSize()
                    }
                    if tool == .freehand {
                        Button("Clear Drawing") { commit { $0.removeAll { $0.tool == .freehand } } }.controlSize(.small)
                    }
                    Spacer()
                    Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(history.isEmpty).help("Undo last annotation")
                    Button { deleteSelected() } label: { Image(systemName: "trash") }.disabled(selected == nil).help("Delete selected annotation")
                        .keyboardShortcut(.delete, modifiers: [])
                }
                if let editingText {
                    HStack {
                        TextField("Enter text for the text box.", text: $textValue, onCommit: { finishText(editingText) })
                            .textFieldStyle(.roundedBorder)
                        Button("Done") { finishText(editingText) }
                    }
                }
                Text(tool.hint).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } footer: {
            ToolButton(title: "Reset", isEnabled: !annotations.isEmpty) { commit { $0.removeAll() } }
            Spacer()
            ToolButton(title: "Save Annotated Copy", isEnabled: !annotations.isEmpty) { save() }
        }
        .onAppear { source.load(context.firstURL) }
    }

    private func select(_ item: AnnotationTool) {
        tool = item
        if item == .image { chooseImage() }
    }

    private func canvas(size: CGSize) -> some View {
        Canvas { graphics, canvasSize in
            graphics.withCGContext { cg in
                AnnotationRenderer.draw(annotations + (draft.map { [$0] } ?? []), in: cg, size: canvasSize, source: source.preview)
            }
            if let selected, let item = annotations.first(where: { $0.id == selected }) {
                let bounds = item.bounds
                let rect = CGRect(x: bounds.minX * canvasSize.width - 6, y: bounds.minY * canvasSize.height - 6,
                                  width: bounds.width * canvasSize.width + 12, height: bounds.height * canvasSize.height + 12)
                graphics.stroke(Path(rect), with: .color(.satsumaAccent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in dragChanged(value, size: size) }
            .onEnded { value in dragEnded(value, size: size) })
    }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    private func hit(_ point: CGPoint) -> Annotation? {
        annotations.last { $0.bounds.insetBy(dx: -0.02, dy: -0.02).contains(point) }
    }

    private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
        let start = normalized(value.startLocation, size), current = normalized(value.location, size)
        if draft == nil, dragOrigin == nil, let existing = hit(start), value.translation != .zero || true {
            if tool != .freehand && tool != .highlighter {
                dragOrigin = (existing.id, existing)
                selected = existing.id
            }
        }
        if let origin = dragOrigin {
            let moved = origin.annotation.offsetBy(current.x - start.x, current.y - start.y)
            if let index = annotations.firstIndex(where: { $0.id == origin.id }) { annotations[index] = moved }
            return
        }
        var item = draft ?? Annotation(tool: tool, start: start, end: start, color: CodableColor(color))
        item.end = current
        if tool == .freehand || tool == .highlighter { item.points.append(current) }
        item.magnification = magnification
        draft = item
    }

    private func dragEnded(_ value: DragGesture.Value, size: CGSize) {
        defer { draft = nil; dragOrigin = nil }
        if let origin = dragOrigin {
            let moved = annotations.first { $0.id == origin.id }
            if let moved, moved != origin.annotation {
                history.append(annotations.map { $0.id == origin.id ? origin.annotation : $0 })
            }
            return
        }
        guard var item = draft else { return }
        let tap = hypot(value.translation.width, value.translation.height) < 4
        switch tool {
        case .number:
            item.number = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
        case .text:
            item.text = ""
            commit { $0.append(item) }
            editingText = item.id
            textValue = ""
            selected = item.id
            return
        case .magnifier:
            break
        case .image:
            return
        default:
            if tap { selected = nil; return }
        }
        commit { $0.append(item) }
        selected = item.id
    }

    private func finishText(_ id: UUID) {
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if textValue.isEmpty { annotations.remove(at: index) } else { annotations[index].text = textValue }
        }
        editingText = nil
    }

    private func commit(_ change: (inout [Annotation]) -> Void) {
        history.append(annotations)
        change(&annotations)
    }

    private func undo() { if let last = history.popLast() { annotations = last; selected = nil } }

    private func deleteSelected() {
        guard let selected else { return }
        commit { $0.removeAll { $0.id == selected } }
        self.selected = nil
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to place on the canvas."
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageProcessing.loadCGImage(url) else { return }
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1)) / CGFloat(source.aspect)
        let width: CGFloat = 0.3
        let item = Annotation(tool: .image, start: CGPoint(x: 0.35, y: 0.35), end: CGPoint(x: 0.35 + width, y: 0.35 + width / aspect),
                              color: CodableColor(color), imageURL: url)
        commit { $0.append(item) }
        selected = item.id
    }

    private func save() {
        let annotations = annotations
        context.run("Annotating photo", false) { urls, _ in
            let image = try ImageProcessing.loadCGImage(urls[0])
            guard let output = AnnotationRenderer.render(image, annotations: annotations) else {
                throw ConversionError.encodingFailed("Could not prepare the annotated image.")
            }
            return [try ImageProcessing.save(output, beside: urls[0], suffix: " annotated")]
        }
    }
}

// MARK: - Add BG

struct FrameImageToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var source = ImageSource()
    @State private var background: FrameBackground = .gradient(0)
    @State private var customColor = Color(red: 0.25, green: 0.38, blue: 0.85)
    @State private var padding = 160.0
    @State private var corners = 24.0
    @State private var shadow = 24.0
    @State private var ratio: FrameRatio = .automatic
    @State private var preview: CGImage?

    var body: some View {
        ToolScaffold(title: "Add BG", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                FittedImage(image: preview ?? source.preview, height: 320, dark: false) { _ in EmptyView() }
                HStack(alignment: .top) {
                    Text("Background").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        swatchRow(FrameBackground.gradients.indices.map { .gradient($0) }) {
                            Button { chooseBackgroundImage() } label: { Image(systemName: "photo.badge.plus").frame(width: 30, height: 30) }
                                .help("Choose an image background")
                        }
                        swatchRow(FrameBackground.solids.indices.map { .solid($0) }) {
                            ColorPicker("", selection: $customColor).labelsHidden().help("Choose a custom background color")
                        }
                    }
                }
                ToolSliderRow(title: "Padding", value: $padding, range: 0...600, step: 4, format: { "\(Int($0)) px" }, labelWidth: 84)
                ToolSliderRow(title: "Corners", value: $corners, range: 0...200, step: 2, format: { "\(Int($0)) px" }, labelWidth: 84)
                ToolSliderRow(title: "Shadow", value: $shadow, range: 0...120, step: 2, format: { "\(Int($0)) px" }, labelWidth: 84)
                ToolRow(title: "Ratio") {
                    Picker("", selection: $ratio) { ForEach(FrameRatio.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        } footer: {
            ToolButton(title: "Reset") { background = .gradient(0); padding = 160; corners = 24; shadow = 24; ratio = .automatic }
            Spacer()
            ToolButton(title: "Save with Background") { save() }
        }
        .onAppear { source.load(context.firstURL, previewSize: 900) }
        .onChange(of: source.preview) { _, _ in refresh() }
        .onChange(of: padding) { _, _ in refresh() }
        .onChange(of: corners) { _, _ in refresh() }
        .onChange(of: shadow) { _, _ in refresh() }
        .onChange(of: ratio) { _, _ in refresh() }
        .onChange(of: background) { _, _ in refresh() }
        .onChange(of: customColor) { _, newValue in
            let c = CodableColor(newValue)
            background = .custom(.init(red: c.red, green: c.green, blue: c.blue))
        }
    }

    private func swatchRow<Extra: View>(_ items: [FrameBackground], @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                item.swatch
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(background == item ? Color.satsumaAccent : Color.primary.opacity(0.12),
                                                                       lineWidth: background == item ? 2.5 : 1))
                    .onTapGesture { background = item }
            }
            extra()
        }
    }

    /// Preview scale: the preview image is downsized, so scale pixel values with it.
    private func refresh() {
        guard let preview = source.preview, let full = source.image else { return }
        let scale = CGFloat(preview.width) / CGFloat(max(full.width, 1))
        let output = FrameRenderer.render(preview, background: background, padding: padding * scale, corners: corners * scale,
                                          shadow: shadow * scale, ratio: ratio)
        self.preview = output
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image"
        if panel.runModal() == .OK, let url = panel.url { background = .image(url) }
    }

    private func save() {
        let (background, padding, corners, shadow, ratio) = (background, padding, corners, shadow, ratio)
        context.run("Adding background", false) { urls, _ in
            let image = try ImageProcessing.loadCGImage(urls[0])
            guard let output = FrameRenderer.render(image, background: background, padding: padding, corners: corners, shadow: shadow, ratio: ratio) else {
                throw ConversionError.encodingFailed("This frame would be too large. Use less padding or a closer output ratio.")
            }
            let url = OutputNaming.destination(for: urls[0], extension: "png", suffix: " background")
            try ImageConverter.write([output], properties: [nil], to: url, format: .png, options: ConversionOptions())
            return [url]
        }
    }
}

// MARK: - Crop Image

struct CropImageToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var source = ImageSource()
    @State private var selections: [URL: NormalizedRect] = [:]
    @State private var active = 0
    @State private var aspect: AspectPreset = .free
    @State private var widthText = ""
    @State private var heightText = ""

    private var url: URL { context.urls[active] }
    private var rect: Binding<NormalizedRect> {
        Binding(get: { selections[url] ?? .full }, set: { selections[url] = $0; syncFields($0) })
    }

    var body: some View {
        ToolScaffold(title: "Crop Image", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                if context.urls.count > 1 {
                    Picker("Image", selection: $active) {
                        ForEach(context.urls.indices, id: \.self) { Text(context.urls[$0].lastPathComponent).tag($0) }
                    }
                    .onChange(of: active) { _, _ in source.load(url, previewSize: 1200) }
                }
                FittedImage(image: source.preview, height: 420, dark: false, inset: 14) { size in
                    ZStack(alignment: .topLeading) {
                        CropDimming(rect: rect.wrappedValue, size: size)
                        EditableRect(rect: rect, canvas: size, aspect: aspect.ratio, sourceAspect: source.aspect)
                    }
                }
                ToolRow(title: "Aspect ratio") {
                    Picker("", selection: $aspect) { ForEach(AspectPreset.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack(spacing: 8) {
                    Text("W").foregroundStyle(.secondary)
                    TextField("", text: $widthText, onCommit: applyFields).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("H").foregroundStyle(.secondary)
                    TextField("", text: $heightText, onCommit: applyFields).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("px").foregroundStyle(.secondary)
                }
                if context.urls.count > 1 {
                    Button("Use this crop for every image") {
                        for other in context.urls { selections[other] = rect.wrappedValue }
                    }
                    .help("Use this crop, as the same share of each image, for every image")
                }
            }
        } footer: {
            ToolButton(title: "Reset") { selections[url] = .full; aspect = .free }
            Spacer()
            ToolButton(title: "Apply") { save() }
        }
        .onAppear { source.load(url, previewSize: 1200) }
        .onChange(of: source.image) { _, _ in syncFields(rect.wrappedValue) }
        .onChange(of: aspect) { _, newValue in
            selections[url] = EditableRect.centered(aspect: newValue.ratio, sourceAspect: source.aspect)
            syncFields(selections[url]!)
        }
    }

    private func syncFields(_ r: NormalizedRect) {
        let size = source.pixelSize
        widthText = "\(Int((r.width * size.width).rounded()))"
        heightText = "\(Int((r.height * size.height).rounded()))"
    }

    private func applyFields() {
        let size = source.pixelSize
        guard let w = Double(widthText), let h = Double(heightText), w >= 1, h >= 1, size.width > 0 else { return }
        var r = rect.wrappedValue
        r.width = min(1, w / size.width)
        r.height = min(1, h / size.height)
        r.x = min(r.x, 1 - r.width); r.y = min(r.y, 1 - r.height)
        selections[url] = r
    }

    private func save() {
        let selections = selections
        context.run("Cropping", false) { urls, _ in
            let url = urls[0]
            let image = try ImageProcessing.loadCGImage(url)
            guard let cropped = ImageProcessing.crop(image, to: selections[url] ?? .full) else {
                throw ConversionError.encodingFailed("Could not create the cropped image.")
            }
            return [try ImageProcessing.save(cropped, beside: url, suffix: " cropped")]
        }
    }
}

/// Darkens everything outside the crop.
struct CropDimming: View {
    let rect: NormalizedRect
    let size: CGSize
    var body: some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect.rect(in: size))
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }
}

// MARK: - Redact Photo

struct RedactPhotoToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var source = ImageSource()
    @State private var rects: [NormalizedRect] = []
    @State private var selected: UUID?
    @State private var blur = false
    @State private var color = Color.black
    @State private var draft: NormalizedRect?
    @State private var detecting = false
    @State private var message: String?

    var body: some View {
        ToolScaffold(title: "Redact Photo", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                FittedImage(image: source.preview, height: 440) { size in
                    RedactionCanvas(rects: $rects, selected: $selected, draft: $draft, size: size, blur: blur, color: color, preview: source.preview)
                }
                ToolRow(title: "Style") {
                    Picker("", selection: $blur) { Text("Solid").tag(false); Text("Blur").tag(true) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if !blur {
                    ToolRow(title: "Color") { ColorPicker("", selection: $color).labelsHidden() }
                } else {
                    Text("Blur softens details. Use Solid for sensitive information.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ToolRow(title: "Detect") {
                    HStack {
                        ToolButton(title: "Faces", isEnabled: !detecting) { detect(.faces) }
                        ToolButton(title: "Text", isEnabled: !detecting) { detect(.text) }
                    }
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("Draw a rectangle over the area to hide.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } footer: {
            ToolButton(title: "Reset", isEnabled: !rects.isEmpty) { rects.removeAll(); selected = nil }
            Spacer()
            ToolButton(title: "Save Redacted Copy", isEnabled: !rects.isEmpty) { save() }
        }
        .onAppear { source.load(context.firstURL) }
        .onDeleteCommand { if let selected { rects.removeAll { $0.id == selected }; self.selected = nil } }
        .onChange(of: color) { _, newValue in
            let c = CodableColor(newValue)
            for index in rects.indices { rects[index].color = c }
        }
    }

    private func detect(_ kind: ImageProcessing.PhotoDetection) {
        guard let image = source.image else { return }
        detecting = true
        let c = CodableColor(color)
        Task {
            let found = await Task.detached { ImageProcessing.detect(kind, in: image) }.value
            rects += found.map { var r = $0; r.color = c; return r }
            message = found.isEmpty ? "Could not detect \(kind == .faces ? "faces" : "text")." : nil
            detecting = false
        }
    }

    private func save() {
        let (rects, blur) = (rects, blur)
        context.run("Redacting photo", false) { urls, _ in
            let image = try ImageProcessing.loadCGImage(urls[0])
            guard let output = ImageProcessing.redact(image, rects: rects, blur: blur) else {
                throw ConversionError.encodingFailed("Could not prepare the redacted photo.")
            }
            return [try ImageProcessing.save(output, beside: urls[0], suffix: " redacted", keepMetadata: false)]
        }
    }
}

/// Draw new rectangles, select and edit existing ones (`RedactionCanvas`).
struct RedactionCanvas: View {
    @Binding var rects: [NormalizedRect]
    @Binding var selected: UUID?
    @Binding var draft: NormalizedRect?
    let size: CGSize
    var blur: Bool
    var color: Color
    var preview: CGImage?
    var visibleIDs: Set<UUID>? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    let a = CGPoint(x: value.startLocation.x / size.width, y: value.startLocation.y / size.height)
                    let b = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                    draft = NormalizedRect(x: max(0, min(a.x, b.x)), y: max(0, min(a.y, b.y)),
                                           width: min(1, abs(b.x - a.x)), height: min(1, abs(b.y - a.y)), color: CodableColor(color))
                }.onEnded { _ in
                    if let draft, draft.width > 0.01, draft.height > 0.01 {
                        rects.append(draft)
                        selected = draft.id
                    }
                    draft = nil
                })
                .onTapGesture { selected = nil }
            ForEach($rects) { $rect in
                if visibleIDs?.contains(rect.id) ?? true {
                    EditableRect(rect: $rect, canvas: size, fill: blur ? Color.gray.opacity(0.55) : rect.color.color,
                                 isSelected: selected == rect.id, onSelect: { selected = rect.id })
                }
            }
            if let draft {
                Rectangle().fill((blur ? Color.gray.opacity(0.5) : draft.color.color).opacity(0.8))
                    .overlay(Rectangle().stroke(Color.satsumaAccent, lineWidth: 2))
                    .frame(width: draft.width * size.width, height: draft.height * size.height)
                    .offset(x: draft.x * size.width, y: draft.y * size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

// MARK: - Create Collage

struct CollageToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = CollageSettings()
    @State private var images: [CGImage] = []
    @State private var order: [Int] = []
    @State private var preview: CGImage?
    @State private var spacingExpanded = false
    @State private var orderExpanded = false

    var body: some View {
        ToolScaffold(title: "Create Collage", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                FittedImage(image: preview, height: 300, dark: false) { _ in EmptyView() }
                ToolRow(title: "Style") {
                    Picker("", selection: $settings.style) { ForEach(CollageStyleChoice.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                }
                if settings.style == .grid {
                    ToolRow(title: "Columns") { Stepper("\(settings.columns)", value: $settings.columns, in: 1...max(1, images.count)) }
                }
                ToolRow(title: "Canvas") {
                    Picker("", selection: $settings.canvas) { ForEach(CollageCanvas.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                }
                ToolRow(title: "Width") {
                    Picker("", selection: $settings.width) { ForEach([1024, 2048, 3072, 4096], id: \.self) { Text("\($0.formatted()) px").tag($0) } }
                        .labelsHidden().fixedSize()
                }
                ToolRow(title: "Image fit") {
                    Picker("", selection: $settings.fillImages) { Text("Fill cells (crop edges)").tag(true); Text("Fit whole images").tag(false) }
                        .labelsHidden().fixedSize()
                }
                Divider()
                DisclosureGroup("Spacing & background", isExpanded: $spacingExpanded) {
                    VStack(spacing: 8) {
                        ToolSliderRow(title: "Spacing", value: $settings.spacing, range: 0...80, step: 1, format: { "\(Int($0)) px" })
                        ToolSliderRow(title: "Padding", value: $settings.padding, range: 0...160, step: 1, format: { "\(Int($0)) px" })
                        ToolSliderRow(title: "Corners", value: $settings.cornerRadius, range: 0...120, step: 1, format: { "\(Int($0)) px" })
                        ToolRow(title: "Background") {
                            Picker("", selection: $settings.background) { ForEach(CollageBackgroundChoice.allCases) { Text($0.rawValue).tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    .padding(.top, 6)
                }
                DisclosureGroup("Image order", isExpanded: $orderExpanded) {
                    VStack(spacing: 4) {
                        ForEach(Array(order.enumerated()), id: \.element) { position, index in
                            HStack {
                                Text("\(position + 1)").foregroundStyle(.secondary).frame(width: 20)
                                Text(context.urls[index].lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { move(position, -1) } label: { Image(systemName: "chevron.up") }.disabled(position == 0)
                                Button { move(position, 1) } label: { Image(systemName: "chevron.down") }.disabled(position == order.count - 1)
                            }
                            .font(.system(size: 12))
                        }
                        Button("Sort by Name") { order.sort { context.urls[$0].lastPathComponent.localizedStandardCompare(context.urls[$1].lastPathComponent) == .orderedAscending } }
                            .help("Order the files by name, as Finder lists them")
                    }
                    .padding(.top, 6)
                }
                HStack { Spacer(); ToolButton(title: "Reset Layout") { settings = CollageSettings(); order = Array(images.indices) } }
            }
        } footer: {
            Spacer()
            ToolButton(title: "Create Collage", isEnabled: !images.isEmpty) { save() }
        }
        .task {
            images = context.urls.compactMap { try? ImageProcessing.resized(ImageProcessing.loadCGImage($0), maxDimension: 900) }
            order = Array(images.indices)
            settings.columns = images.count <= 2 ? images.count : (images.count <= 4 ? 2 : 3)
            refresh()
        }
        .onChange(of: settings) { _, _ in refresh() }
        .onChange(of: order) { _, _ in refresh() }
    }

    private func move(_ position: Int, _ delta: Int) {
        let target = position + delta
        guard order.indices.contains(target) else { return }
        order.swapAt(position, target)
    }

    private func refresh() {
        var small = settings
        small.width = 800
        small.spacing = settings.spacing * 800 / Double(settings.width)
        small.padding = settings.padding * 800 / Double(settings.width)
        small.cornerRadius = settings.cornerRadius * 800 / Double(settings.width)
        preview = CollageRenderer.render(order.compactMap { images.indices.contains($0) ? images[$0] : nil }, settings: small)
    }

    private func save() {
        let (settings, order) = (settings, order)
        context.run("Creating collage", true) { urls, _ in
            let full = try order.map { try ImageProcessing.loadCGImage(urls[$0]) }
            guard let collage = CollageRenderer.render(full, settings: settings) else { throw ConversionError.encodingFailed("Could not render the collage.") }
            let output = OutputNaming.destination(for: urls[0], extension: "png", suffix: " collage")
            try ImageConverter.write([collage], properties: [nil], to: output, format: .png, options: ConversionOptions())
            return [output]
        }
    }
}
