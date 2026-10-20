import AppKit
import Combine

enum ConversionFanTheme: String, CaseIterable, Codable { case glass, metallic }
enum FloatWheelBehavior: String, CaseIterable, Codable { case createNew, addToExisting }
enum ConversionQuality: String, CaseIterable, Codable { case compact, balanced, high }
enum AudioSampleDepth: String, CaseIterable, Codable { case matchSource, bit16, bit24, bit32, float32 }
enum CompressionLevel: String, CaseIterable, Codable { case fast, balanced, maximum }
enum EPUBLayout: String, CaseIterable, Codable { case adjustableText, preservePages }
enum PDFOfficeLayout: String, CaseIterable, Codable { case editable, preservePages }
/// Compress presets remembered as defaults (`imageCompression.defaultStrength`, `videoCompression.defaultStrength`).
enum CompressionStrength: String, CaseIterable, Codable { case balanced, strong }
/// `imageCompression.defaultSize`: longest side after compression.
enum ImageCompressionSize: String, CaseIterable, Codable {
    case original, large, medium, small
    var title: String {
        switch self {
        case .original: return "Keep original dimensions"
        case .large: return "Large · 2048 px"
        case .medium: return "Medium · 1280 px"
        case .small: return "Small · 800 px"
        }
    }
    var maxDimension: CGFloat? { switch self { case .original: return nil; case .large: return 2048; case .medium: return 1280; case .small: return 800 } }
}

/// `ConversionOptions` with the same fields as the original struct.
struct ConversionOptions: Codable, Equatable {
    var quality: ConversionQuality = .balanced
    var preserveMetadata = true
    var videoMaxHeight = 0          // 0 = keep source size
    var audioBitrate = 192
    var audioSampleDepth: AudioSampleDepth = .matchSource
    var gifFrameRate = 15
    var gifMaxWidth = 640
    var compression: CompressionLevel = .balanced
    var epubLayout: EPUBLayout = .adjustableText
    var epubReflowVersion = 1
    var pdfOfficeLayout: PDFOfficeLayout = .editable
}

/// Modifier mask bits used by the wheel shortcuts.
struct DragModifierCombination: Equatable {
    var mask: Int

    static let command = 1, option = 2, control = 4, shift = 8

    var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & Self.command != 0 { flags.insert(.command) }
        if mask & Self.option != 0 { flags.insert(.option) }
        if mask & Self.control != 0 { flags.insert(.control) }
        if mask & Self.shift != 0 { flags.insert(.shift) }
        return flags
    }

    var symbols: String {
        var text = ""
        if mask & Self.control != 0 { text += "⌃" }
        if mask & Self.option != 0 { text += "⌥" }
        if mask & Self.shift != 0 { text += "⇧" }
        if mask & Self.command != 0 { text += "⌘" }
        return text.isEmpty ? "None" : text
    }
}

/// Shared settings, persisted under the original app's UserDefaults keys.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    static let themeDidChange = Notification.Name("satsuma.conversionFanThemeDidChange")

    enum Key {
        static let conversionMask = "conversionWheelDragModifierMask"
        static let toolsMask = "toolsWheelDragModifierMask"
        static let actionsMask = "actionsWheelDragModifierMask"
        static let didMigrateTools = "didMigrateToolsWheelToCommand"
        static let theme = "conversionFanTheme"
        static let sounds = "soundsAndHapticsEnabled"
        static let floatBehavior = "floatWheelBehavior"
        static let defaultOptions = "defaultConversionOptions"
        static let terminalApp = "terminalApplicationID"
        static let didFinishWelcome = "didFinishWelcome"
        static let imageStrength = "imageCompression.defaultStrength"
        static let imageSize = "imageCompression.defaultSize"
        static let videoStrength = "videoCompression.defaultStrength"
    }

    private let defaults: UserDefaults

    @Published var conversionFanTheme: ConversionFanTheme {
        didSet {
            defaults.set(conversionFanTheme.rawValue, forKey: Key.theme)
            NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
        }
    }
    @Published var soundsAndHapticsEnabled: Bool { didSet { defaults.set(soundsAndHapticsEnabled, forKey: Key.sounds) } }
    @Published var floatWheelBehavior: FloatWheelBehavior { didSet { defaults.set(floatWheelBehavior.rawValue, forKey: Key.floatBehavior) } }
    @Published var defaultOptions: ConversionOptions {
        didSet { defaults.set(try? JSONEncoder().encode(defaultOptions), forKey: Key.defaultOptions) }
    }
    @Published var conversionMask: Int { didSet { defaults.set(conversionMask, forKey: Key.conversionMask) } }
    @Published var toolsMask: Int { didSet { defaults.set(toolsMask, forKey: Key.toolsMask) } }
    @Published var actionsMask: Int { didSet { defaults.set(actionsMask, forKey: Key.actionsMask) } }
    @Published var imageCompressionStrength: CompressionStrength { didSet { defaults.set(imageCompressionStrength.rawValue, forKey: Key.imageStrength) } }
    @Published var imageCompressionSize: ImageCompressionSize { didSet { defaults.set(imageCompressionSize.rawValue, forKey: Key.imageSize) } }
    @Published var videoCompressionStrength: CompressionStrength { didSet { defaults.set(videoCompressionStrength.rawValue, forKey: Key.videoStrength) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateModifierMasks(defaults)
        conversionFanTheme = ConversionFanTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .glass
        soundsAndHapticsEnabled = defaults.object(forKey: Key.sounds) as? Bool ?? true
        floatWheelBehavior = FloatWheelBehavior(rawValue: defaults.string(forKey: Key.floatBehavior) ?? "") ?? .createNew
        defaultOptions = (defaults.data(forKey: Key.defaultOptions)).flatMap { try? JSONDecoder().decode(ConversionOptions.self, from: $0) } ?? ConversionOptions()
        conversionMask = defaults.integer(forKey: Key.conversionMask)
        toolsMask = defaults.integer(forKey: Key.toolsMask)
        actionsMask = defaults.integer(forKey: Key.actionsMask)
        imageCompressionStrength = CompressionStrength(rawValue: defaults.string(forKey: Key.imageStrength) ?? "") ?? .balanced
        imageCompressionSize = ImageCompressionSize(rawValue: defaults.string(forKey: Key.imageSize) ?? "") ?? .original
        videoCompressionStrength = CompressionStrength(rawValue: defaults.string(forKey: Key.videoStrength) ?? "") ?? .balanced
    }

    func restoreCompressionDefaults() {
        imageCompressionStrength = .balanced
        imageCompressionSize = .original
        videoCompressionStrength = .balanced
    }

    /// Defaults: tools 10 (⇧⌥) migrates to 1 (⌘); conversions 8 (⇧); actions 4 (⌃).
    static func migrateModifierMasks(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.didMigrateTools) else { return }
        if defaults.object(forKey: Key.conversionMask) == nil { defaults.set(DragModifierCombination.shift, forKey: Key.conversionMask) }
        if defaults.object(forKey: Key.actionsMask) == nil { defaults.set(DragModifierCombination.control, forKey: Key.actionsMask) }
        defaults.set(DragModifierCombination.command, forKey: Key.toolsMask)
        defaults.set(true, forKey: Key.didMigrateTools)
    }

    /// Exact-match lookup in this order: tools, conversions, actions.
    func mode(for flags: NSEvent.ModifierFlags) -> ConversionFanMode? {
        let pressed = flags.intersection([.command, .option, .control, .shift])
        guard !pressed.isEmpty else { return nil }
        if DragModifierCombination(mask: toolsMask).flags == pressed { return .fileTools }
        if DragModifierCombination(mask: conversionMask).flags == pressed { return .conversions }
        if DragModifierCombination(mask: actionsMask).flags == pressed { return .fileActions }
        return nil
    }

    var didFinishWelcome: Bool {
        get { defaults.bool(forKey: Key.didFinishWelcome) }
        set { defaults.set(newValue, forKey: Key.didFinishWelcome) }
    }
}
