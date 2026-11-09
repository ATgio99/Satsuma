import AppKit
import ImageIO
import SwiftUI

// MARK: - Model

/// Whether the window edits pixel sizes or a percentage (`ImageResizeMode`).
enum ImageResizeMode: Int, CaseIterable, Identifiable {
    case pixels, scale
    var id: Int { rawValue }
    var title: String { self == .pixels ? "Pixels" : "Percentage" }
}

/// One side of the output (`ResizeDimension`).
enum ResizeDimension: Hashable {
    case width, height
}

/// Which side several images keep in common (`ImageResizePriority`).
enum ImageResizePriority: Int, CaseIterable, Identifiable {
    case width, height
    var id: Int { rawValue }
    var title: String { self == .width ? "Width" : "Height" }
}

/// A pixel goal; with none, the percentages apply (`ImageResizeTarget`).
enum ImageResizeTarget: Equatable {
    case longEdge(Double)
    case width(Double)
    case height(Double)
    case fit(Double, Double)
    case exact(Double, Double)
}

/// What gets applied to every file (`ImageResizeOptions`).
struct ImageResizeOptions: Equatable {
    var percentage = 100.0
    var heightPercentage = 100.0
    var keepsProportions = true
    var target: ImageResizeTarget?
}

struct ImagePixelSize: Equatable {
    var width: Int
    var height: Int
    var label: String { "\(width) × \(height)" }
}

/// An entry of the "Common sizes" menu (`ImageResizePreset`).
struct ImageResizePreset: Equatable {
    enum Size: Equatable {
        case longEdge(Int)
        case box(Int, Int)
    }

    let name: String
    let size: Size

    private init(_ name: String, long edge: Int) { self.name = name; size = .longEdge(edge) }
    private init(_ name: String, _ width: Int, _ height: Int) { self.name = name; size = .box(width, height) }

    var label: String {
        switch size {
        case .longEdge(let edge): return "\(edge) px long edge"
        case .box(let width, let height): return "\(width) × \(height)"
        }
    }

    static let groups: [(name: String, presets: [ImageResizePreset])] = [
        ("Web", [.init("Extra Large", long: 2560), .init("Large", long: 1920), .init("Medium", long: 1280),
                 .init("Small", long: 800), .init("Thumbnail", long: 320)]),
        ("Screens", [.init("4K UHD", 3840, 2160), .init("QHD", 2560, 1440), .init("Full HD", 1920, 1080), .init("HD", 1280, 720)]),
        ("Social", [.init("Square Post", 1080, 1080), .init("Portrait Post", 1080, 1350), .init("Story / Reel", 1080, 1920),
                    .init("Link Preview", 1200, 630), .init("Video Thumbnail", 1280, 720)]),
        ("Icons", [.init("App Icon", 1024, 1024), .init("Large Icon", 512, 512), .init("Touch Icon", 180, 180), .init("Favicon", 32, 32)]),
    ]

    static let percentages: [Double] = [10, 25, 33, 50, 75, 90]
}

// MARK: - Size computation and pixels

enum ImageResizer {
    static let maximumSide = 16_384
    static let invalidSizeMessage = "Enter a width and height of at least 1 pixel."
    static let unchangedMessage = "Change the size to resize."
    static var tooLargeMessage: String { "Keep each side at most \(maximumSide.formatted()) pixels." }
    /// The WebP format itself stops one pixel short of `maximumSide`.
    static let maximumWebPSide = 16_383

    /// Size of one image's output.
    static func outputSize(of source: CGSize, options: ImageResizeOptions) throws -> ImagePixelSize {
        let width = Double(source.width), height = Double(source.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw ConversionError.sourceCannotBeRead }
        func checked(_ values: Double...) throws {
            guard values.allSatisfy({ $0.isFinite && $0 >= 1 }) else { throw ConversionError.invalidFileToolOptions(invalidSizeMessage) }
        }
        func scaled(_ factor: Double) -> (Double, Double) { (max(1, (width * factor).rounded()), max(1, (height * factor).rounded())) }
        let output: (width: Double, height: Double)
        switch options.target {
        case .longEdge(let edge):
            try checked(edge)
            output = scaled(edge / max(width, height))
        case .width(let side):
            try checked(side)
            output = scaled(side / width)
        case .height(let side):
            try checked(side)
            output = scaled(side / height)
        case .fit(let boxWidth, let boxHeight):
            try checked(boxWidth, boxHeight)
            output = scaled(min(boxWidth / width, boxHeight / height))
        case .exact(let exactWidth, let exactHeight):
            try checked(exactWidth, exactHeight)
            output = (exactWidth.rounded(), exactHeight.rounded())
        case nil:
            let percentage = options.percentage
            let heightPercentage = options.keepsProportions ? options.percentage : options.heightPercentage
            guard percentage.isNormal, percentage > 0, heightPercentage.isNormal, heightPercentage > 0 else {
                throw ConversionError.invalidFileToolOptions(invalidSizeMessage)
            }
            output = (max(1, (width * percentage / 100).rounded()), max(1, (height * heightPercentage / 100).rounded()))
        }
        guard max(output.width, output.height) <= Double(maximumSide) else { throw ConversionError.invalidFileToolOptions(tooLargeMessage) }
        return ImagePixelSize(width: Int(output.width), height: Int(output.height))
    }

    /// Resamples with high-quality interpolation, keeping an RGB colour space and the source's depth.
    static func render(_ image: CGImage, to size: ImagePixelSize) -> CGImage? {
        guard size.width != image.width || size.height != image.height else { return image }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? sRGB
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        func canvas(_ space: CGColorSpace, _ bits: Int, order: CGBitmapInfo = []) -> CGContext? {
            CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue | order.rawValue)
        }
        // Same byte order as the decoder: the HEIC encoder misreads 16-bit samples otherwise.
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        guard let context = canvas(space, bits, order: bits == 16 ? image.bitmapInfo.intersection(.byteOrderMask) : [])
                ?? canvas(space, bits) ?? canvas(sRGB, 8) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    /// Writes `<stem> Resized.<ext>` beside the source, upright and without the source's metadata.
    static func resize(_ url: URL, options: ImageResizeOptions) async throws -> URL {
        let image: CGImage
        do { image = try ImageProcessing.loadCGImage(url) } catch { throw readFailure(url) }
        let size = try outputSize(of: CGSize(width: image.width, height: image.height), options: options)
        guard let output = render(image, to: size) else { throw ConversionError.encodingFailed("Could not create the resized image.") }
        let format = ConversionFormat.detect(url) ?? .png
        // Camera RAW and SVG have no encoder; other formats ImageIO cannot write fall back the same way, except WebP (cwebp).
        let target: ConversionFormat = [.raw, .svg].contains(format) || (format != .webp && !ImageConverter.imageIOCanWrite(format)) ? .png : format
        guard target != .webp || max(size.width, size.height) <= maximumWebPSide else {
            throw ConversionError.invalidFileToolOptions("Keep each side of a WebP image at most \(maximumWebPSide.formatted()) pixels.")
        }
        let fileExtension = target == format && !url.pathExtension.isEmpty ? url.pathExtension : target.fileExtension
        let destination = OutputNaming.destination(for: url, extension: fileExtension, suffix: " Resized")
        do {
            try await write(output, to: destination, format: target)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private static func write(_ image: CGImage, to url: URL, format: ConversionFormat) async throws {
        guard format == .webp, !ImageConverter.imageIOCanWrite(.webp) else {
            guard let type = ImageConverter.utType(for: format),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ConversionError.encodingFailed("Could not save the resized image.")
            }
            let properties: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.95]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodingFailed("Could not save the resized image.") }
            return
        }
        guard let cwebp = ToolLocator.path("cwebp") else { throw ConversionError.missingTool("cwebp") }
        let folder = try OutputNaming.temporaryDirectory(prefix: "Satsuma-img-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("frame.png")
        try await write(image, to: png, format: .png)
        do {
            try await ProcessRunner.run(cwebp, ["-quiet", "-lossless", png.path, "-o", url.path])
        } catch {
            throw ConversionError.encodingFailed("Could not save the resized image.")
        }
    }

    static func readFailure(_ url: URL) -> ConversionError {
        .encodingFailed("Could not read the image \(url.lastPathComponent)")
    }

    /// Upright pixel size and a small preview, without decoding the whole file where the header is enough.
    static func loadSource(_ url: URL, thumbnailSide: Int = 480) throws -> ImageResizeSource {
        let name = url.lastPathComponent
        if ConversionFormat.detect(url) != .raw, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSide] as CFDictionary)
            let sideways = ImageConverter.orientation(of: properties) >= 5
            return ImageResizeSource(name: name, size: CGSize(width: sideways ? height : width, height: sideways ? width : height), thumbnail: thumbnail)
        }
        do {
            let image = try ImageProcessing.loadCGImage(url)
            return ImageResizeSource(name: name, size: CGSize(width: image.width, height: image.height),
                                     thumbnail: ImageProcessing.resized(image, maxDimension: CGFloat(thumbnailSide)))
        } catch { throw readFailure(url) }
    }
}

struct ImageResizeSource {
    let name: String
    let size: CGSize
    let thumbnail: CGImage?
}

// MARK: - Editing

/// The window's state and how each control changes it (`ImageResizeEditor`).
struct ImageResizeEditor: Equatable {
    static let keepsProportionsKey = "imageResizeKeepsProportions"
    static var storedKeepsProportions: Bool { UserDefaults.standard.object(forKey: keepsProportionsKey) as? Bool ?? true }

    var sources: [CGSize] = []
    private(set) var mode: ImageResizeMode = .pixels
    private(set) var options = ImageResizeOptions()
    private(set) var priority: ImageResizePriority = .width

    init(sources: [CGSize] = [], keepsProportions: Bool = true) {
        self.sources = sources
        options.keepsProportions = keepsProportions
    }

    private var isMultiple: Bool { sources.count > 1 }

    /// Far past the size limit, so typing more digits still reads as "too large", and small enough for any integer conversion.
    private static let largestEntry = 1e9

    /// Output of the first image, which the fields describe.
    var currentSize: ImagePixelSize? { sources.first.flatMap { try? ImageResizer.outputSize(of: $0, options: options) } }

    var isAtDefaults: Bool {
        mode == .pixels && options == ImageResizeOptions()
    }

    /// Why Resize can't run yet, if there is a reason.
    var problem: String? {
        guard !sources.isEmpty else { return nil }
        do {
            let changed = try sources.map { source -> Bool in
                let output = try ImageResizer.outputSize(of: source, options: options)
                return Double(output.width) != Double(source.width) || Double(output.height) != Double(source.height)
            }
            return changed.contains(true) ? nil : ImageResizer.unchangedMessage
        } catch {
            return error.localizedDescription
        }
    }

    /// With several locked images only the matched side is typed in; the other follows each image.
    func isAutomatic(_ dimension: ResizeDimension) -> Bool {
        guard isMultiple, options.keepsProportions else { return false }
        if case .fit = options.target { return false }
        return dimension != (priority == .width ? .width : .height)
    }

    func fieldValue(_ dimension: ResizeDimension) -> Double? {
        if isMultiple, case .fit(let width, let height) = options.target { return dimension == .width ? width : height }
        return currentSize.map { Double(dimension == .width ? $0.width : $0.height) }
    }

    func fieldText(_ dimension: ResizeDimension) -> String {
        if isAutomatic(dimension) { return "Auto" }
        return fieldValue(dimension).map { String(Int($0)) } ?? ""
    }

    var usesPreset: Bool {
        switch options.target {
        case .longEdge, .fit: return true
        case .exact(let width, let height): return Self.isPresetBox(width, height)
        default: return false
        }
    }

    var matchCaption: String? {
        guard isMultiple, mode == .pixels else { return nil }
        if usesPreset { return "Each image is sized to the preset." }
        if case .exact = options.target { return nil }
        return priority == .width ? "Every image gets the same width; heights follow each image's proportions."
                                  : "Every image gets the same height; widths follow each image's proportions."
    }

    var lockCaption: String? {
        guard mode == .pixels else { return nil }
        switch options.target {
        case .fit: return "Lock on: images fit inside the size."
        case .exact: return "Lock off: images stretch to the size."
        default: return nil
        }
    }

    mutating func setMode(_ newMode: ImageResizeMode) {
        mode = newMode
        guard newMode == .scale else { return }
        options.heightPercentage = options.percentage
        options.target = nil
        clampPercentages()
    }

    mutating func setPercentage(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        options.percentage = min(value, Self.largestEntry)
        options.heightPercentage = options.percentage
        options.target = nil
        clampPercentages()
    }

    /// One image, or percentage mode: stored as a percentage. Several images in pixels mode: a shared pixel goal.
    mutating func set(_ dimension: ResizeDimension, to value: Double) {
        guard value.isFinite, value > 0, let first = sources.first else { return }
        let value = min(value, Self.largestEntry)
        if !isMultiple || mode == .scale {
            let percentage = value / Double(dimension == .width ? first.width : first.height) * 100
            if options.keepsProportions {
                options.percentage = percentage
                options.heightPercentage = percentage
            } else if dimension == .width {
                options.percentage = percentage
            } else {
                options.heightPercentage = percentage
            }
            options.target = nil
            clampPercentages()
            return
        }
        if options.keepsProportions {
            options.target = dimension == .width ? .width(value) : .height(value)
            priority = dimension == .width ? .width : .height
        } else {
            // An out-of-range goal has no computed size, but its other side must survive.
            var other = currentSize.map { Double(dimension == .width ? $0.height : $0.width) } ?? Double(dimension == .width ? first.height : first.width)
            if case .exact(let width, let height) = options.target { other = dimension == .width ? height : width }
            options.target = dimension == .width ? .exact(value, other) : .exact(other, value)
        }
        storePercentages()
    }

    mutating func apply(_ preset: ImageResizePreset) {
        switch preset.size {
        case .longEdge(let edge): options.target = .longEdge(Double(edge))
        case .box(let width, let height):
            options.target = options.keepsProportions ? .fit(Double(width), Double(height)) : .exact(Double(width), Double(height))
        }
        storePercentages()
    }

    mutating func setPriority(_ newPriority: ImageResizePriority) {
        guard newPriority != priority else { return }
        let current = currentSize
        priority = newPriority
        guard let current else { return }
        switch options.target {
        case .width where newPriority == .height: options.target = .height(Double(current.height))
        case .height where newPriority == .width: options.target = .width(Double(current.width))
        default: return
        }
        storePercentages()
    }

    mutating func toggleKeepsProportions() {
        switch options.target {
        case nil:
            options.heightPercentage = options.percentage
        case .width, .height:
            if let current = currentSize { options.target = .exact(Double(current.width), Double(current.height)) }
        case .fit(let width, let height):
            options.target = .exact(width, height)
        case .exact(let width, let height):
            options.target = Self.isPresetBox(width, height) ? .fit(width, height) : (priority == .width ? .width(width) : .height(height))
        case .longEdge:
            break
        }
        options.keepsProportions.toggle()
        clampPercentages()
    }

    mutating func reset() {
        mode = .pixels
        options = ImageResizeOptions()
    }

    private static func isPresetBox(_ width: Double, _ height: Double) -> Bool {
        ImageResizePreset.groups.contains { group in
            group.presets.contains { $0.size == .box(Int(width), Int(height)) && Double(Int(width)) == width && Double(Int(height)) == height }
        }
    }

    /// Keeps the percentages describing the first image's output, for when a pixel goal is dropped.
    private mutating func storePercentages() {
        guard let first = sources.first, let current = currentSize else { return }
        options.percentage = Double(current.width) / Double(first.width) * 100
        options.heightPercentage = Double(current.height) / Double(first.height) * 100
    }

    /// With no pixel goal, the largest image must still fit the size limit.
    private mutating func clampPercentages() {
        guard options.target == nil, !sources.isEmpty else { return }
        let limit = Double(ImageResizer.maximumSide)
        let widest = sources.map { Double($0.width) }.max()!, tallest = sources.map { Double($0.height) }.max()!
        // Percentage mode shows one number, so it scales both sides by it whatever the lock says.
        if options.keepsProportions || mode == .scale {
            options.percentage = min(options.percentage, limit / max(widest, tallest) * 100)
            options.heightPercentage = options.percentage
        } else {
            options.percentage = min(options.percentage, limit / widest * 100)
            options.heightPercentage = min(options.heightPercentage, limit / tallest * 100)
        }
    }
}

// MARK: - Window

struct ResizeImageToolView: View {
    @ObservedObject var context: ToolContext
    @State private var editor = ImageResizeEditor(keepsProportions: ImageResizeEditor.storedKeepsProportions)
    @State private var items: [ImageResizeSource] = []
    @State private var loading = true
    @State private var loadFailure: String?
    @State private var draft: String?
    @State private var percentageDraft: String?
    @State private var scrubbed: (dimension: ResizeDimension, start: Double)?
    @FocusState private var focusedDimension: ResizeDimension?
    @FocusState private var percentageFocused: Bool

    private var draftIsInvalid: Bool {
        [draft, percentageDraft].contains { text in text.map { (Double($0) ?? 0) <= 0 } ?? false }
    }

    private var message: String? { draftIsInvalid ? ImageResizer.invalidSizeMessage : editor.problem }

    var body: some View {
        ToolScaffold(title: "Resize Images", onClose: context.close) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                ToolRow(title: "Resize by") {
                    Picker("", selection: Binding(get: { editor.mode }, set: { editor.setMode($0) })) {
                        ForEach(ImageResizeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("imageResizeMode")
                }
                if editor.mode == .pixels { pixelControls } else { percentageControls }
                if let loadFailure { Text(loadFailure).font(.system(size: 12)).foregroundStyle(.red) }
                if !loading, let message {
                    Text(message).font(.system(size: 12))
                        .foregroundStyle(message == ImageResizer.unchangedMessage ? Color.secondary : Color.red)
                }
            }
        } footer: {
            ToolButton(title: "Reset", isEnabled: !editor.isAtDefaults) { reset() }
            Spacer()
            ToolButton(title: "Resize", isEnabled: !loading && !items.isEmpty && message == nil) { start() }
        }
        .task { await load() }
        .onChange(of: focusedDimension) { _, _ in draft = nil }
        .onChange(of: percentageFocused) { _, _ in percentageDraft = nil }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if loading {
            PreviewWell(height: 200, dark: false) { ProgressView() }
        } else if items.count == 1 {
            card(items[0], thumbnailHeight: 220)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(items.indices, id: \.self) { card(items[$0], thumbnailHeight: 110).frame(width: 150) }
                }
            }
        }
    }

    private func card(_ item: ImageResizeSource, thumbnailHeight: CGFloat) -> some View {
        let after = try? ImageResizer.outputSize(of: item.size, options: editor.options)
        return ResizeThumbnailCard(image: item.thumbnail, name: item.name,
                                   before: ImagePixelSize(width: Int(item.size.width), height: Int(item.size.height)),
                                   after: after, thumbnailHeight: thumbnailHeight, highlight: after == nil)
    }

    // MARK: Pixels

    private var pixelControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                dimensionField(.width, title: "Width")
                lockButton
                dimensionField(.height, title: "Height")
                Text("px").foregroundStyle(.secondary).padding(.bottom, 4)
                Spacer(minLength: 4)
                sizePresets.padding(.bottom, 3)
            }
            .font(.system(size: 13))
            if items.count > 1 {
                ToolRow(title: "Match") {
                    Picker("", selection: Binding(get: { editor.priority }, set: { editor.setPriority($0) })) {
                        ForEach(ImageResizePriority.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(!editor.options.keepsProportions || editor.usesPreset)
                    .accessibilityIdentifier("imageResizePriority")
                }
            }
            if let caption = editor.matchCaption ?? editor.lockCaption {
                Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dimensionField(_ dimension: ResizeDimension, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { scrub(dimension, $0) }.onEnded { _ in scrubbed = nil })
                .help("Drag left or right to change the \(title.lowercased()). Hold Shift for bigger steps or Option for single pixels.")
            TextField("", text: text(for: dimension))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 84)
                .focused($focusedDimension, equals: dimension)
                .disabled(editor.isAutomatic(dimension))
                .accessibilityLabel("\(title) in pixels")
        }
    }

    private func text(for dimension: ResizeDimension) -> Binding<String> {
        Binding(get: { focusedDimension == dimension ? (draft ?? editor.fieldText(dimension)) : editor.fieldText(dimension) },
                set: { typed in
                    let digits = typed.filter(\.isASCII).filter(\.isNumber)
                    draft = digits
                    if let value = Double(digits), value > 0 { editor.set(dimension, to: value) }
                })
    }

    private func scrub(_ dimension: ResizeDimension, _ drag: DragGesture.Value) {
        guard !editor.isAutomatic(dimension) else { return }
        if scrubbed?.dimension != dimension { scrubbed = (dimension, editor.fieldValue(dimension) ?? 1) }
        focusedDimension = nil
        let flags = NSEvent.modifierFlags
        let step: Double = flags.contains(.option) ? 1 : flags.contains(.shift) ? 10 : 2
        editor.set(dimension, to: max(1, ((scrubbed?.start ?? 1) + drag.translation.width * step).rounded()))
    }

    private var lockButton: some View {
        let locked = editor.options.keepsProportions
        return Button(action: toggleLock) {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .frame(width: 24, height: 24)
                .foregroundStyle(locked ? Color.satsumaAccent : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(locked ? "Proportions are kept. Click to stretch width and height separately."
                     : "Width and height stretch separately. Click to keep proportions.")
        .accessibilityLabel(locked ? "Keep proportions on" : "Keep proportions off")
        .accessibilityIdentifier("imageResizeProportions")
    }

    private var sizePresets: some View {
        Menu {
            ForEach(ImageResizePreset.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.presets, id: \.name) { preset in
                        Button("\(preset.name) · \(preset.label)") { focusedDimension = nil; editor.apply(preset) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) { Text("Common sizes"); Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Size presets")
        .accessibilityIdentifier("imageResizePresets")
    }

    // MARK: Percentage

    private var percentageControls: some View {
        HStack(spacing: 8) {
            TextField("", text: percentageText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
                .focused($percentageFocused)
                .accessibilityLabel("Resize percentage")
                .accessibilityIdentifier("imageResizePercentage")
            Text("%").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu {
                ForEach(ImageResizePreset.percentages, id: \.self) { value in
                    Button("\(Int(value))%") { percentageFocused = false; editor.setPercentage(value) }
                }
            } label: {
                HStack(spacing: 3) { Text("Common percentages"); Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Percentage presets")
            .accessibilityIdentifier("imageResizePercentagePresets")
        }
        .font(.system(size: 13))
    }

    private var percentageText: Binding<String> {
        let shown = String(format: "%lld", Int64(editor.options.percentage.rounded()))
        return Binding(get: { percentageFocused ? (percentageDraft ?? shown) : shown },
                       set: { typed in
                           let digits = typed.filter(\.isASCII).filter(\.isNumber)
                           percentageDraft = digits
                           if let value = Double(digits), value > 0 { editor.setPercentage(value) }
                       })
    }

    // MARK: Actions

    private func load() async {
        let urls = context.urls
        let results = await Task.detached { urls.map { url in Result { try ImageResizer.loadSource(url) } } }.value
        items = results.compactMap { try? $0.get() }
        for case .failure(let error) in results {
            loadFailure = error.localizedDescription
            break
        }
        editor.sources = items.map(\.size)
        loading = false
    }

    private func toggleLock() {
        focusedDimension = nil
        editor.toggleKeepsProportions()
        UserDefaults.standard.set(editor.options.keepsProportions, forKey: ImageResizeEditor.keepsProportionsKey)
    }

    private func reset() {
        focusedDimension = nil
        percentageFocused = false
        editor.reset()
        UserDefaults.standard.set(true, forKey: ImageResizeEditor.keepsProportionsKey)
    }

    private func start() {
        let options = editor.options
        context.run("Resizing images", false) { urls, _ in
            [try await ImageResizer.resize(urls[0], options: options)]
        }
    }
}

/// Thumbnail with the size before and after (`ResizeThumbnailCard`).
struct ResizeThumbnailCard: View {
    let image: CGImage?
    let name: String
    let before: ImagePixelSize
    let after: ImagePixelSize?
    let thumbnailHeight: CGFloat
    var highlight = false

    private var badge: String? {
        guard let after else { return nil }
        let scaled = after.width * after.height, original = before.width * before.height
        return scaled == original ? nil : (scaled < original ? "Downscale" : "Upscale")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PreviewWell(height: thumbnailHeight, dark: false) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(highlight ? Color.red : Color.clear, lineWidth: 2))
            Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(before.label).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Text("→ \(after?.label ?? "—")").font(.system(size: 11)).monospacedDigit()
        }
    }
}
