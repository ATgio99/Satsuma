import AppKit
import SwiftUI

/// What a tool view needs from the app: its files, a way to close, and a way to run the export.
@MainActor
final class ToolContext: ObservableObject {
    let tool: FileTool
    @Published var urls: [URL]
    var close: () -> Void = {}
    /// Hands the export to the task store (progress panel), then closes the window.
    var run: (_ title: String, _ batch: Bool, _ work: @escaping ([URL], @escaping (Double) -> Void) async throws -> [URL]) -> Void = { _, _, _ in }

    init(tool: FileTool, urls: [URL]) {
        self.tool = tool
        self.urls = urls
    }

    var firstURL: URL { urls[0] }
    var fileName: String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files" }
}

/// Borderless-looking panel for tool windows (`FileToolOptionsPanel`).
final class ToolPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        minSize = NSSize(width: 340, height: 260)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Opens one window per tool invocation (`FileToolOptionsWindowController`) and keeps it alive.
@MainActor
final class ToolWindowManager {
    static let shared = ToolWindowManager()
    private var windows: [UUID: NSWindow] = [:]
    var taskStore: ConversionTaskStore?

    func open(_ tool: FileTool, urls: [URL]) {
        let id = UUID()
        let context = ToolContext(tool: tool, urls: urls)
        let size = Self.defaultSize(for: tool)
        let panel = ToolPanel(size: size)
        context.close = { [weak self, weak panel] in
            panel?.close()
            self?.windows[id] = nil
        }
        context.run = { [weak self, weak panel] title, batch, work in
            guard let self else { return }
            let urls = context.urls
            panel?.close()
            self.windows[id] = nil
            self.taskStore?.run(title: title, urls: urls, batch: batch, work: work)
        }
        let root = ToolRootView(context: context)
            .frame(minWidth: size.width - 40, minHeight: 240)
        panel.contentView = NSHostingView(rootView: root)
        panel.setContentSize(size)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windows[id] = nil }
        }
        windows[id] = panel
        // Open near the pointer, like the original's panels.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func defaultSize(for tool: FileTool) -> NSSize {
        switch tool {
        case .compress: return NSSize(width: 380, height: 375)
        case .removeMetadata: return NSSize(width: 480, height: 540)
        case .joinVideos, .mergePDF: return NSSize(width: 320, height: 300)
        case .trimAudio, .audioChannels, .redactAudio: return NSSize(width: 400, height: 400)
        case .organizePDF: return NSSize(width: 560, height: 600)
        case .editImage: return NSSize(width: 480, height: 790)
        case .annotateImage, .frameImage: return NSSize(width: 440, height: 720)
        case .redactVideo: return NSSize(width: 400, height: 900)
        case .normalizeAudio: return NSSize(width: 400, height: 610)
        default: return NSSize(width: 400, height: 680)
        }
    }
}

/// Picks the view for a tool.
struct ToolRootView: View {
    @ObservedObject var context: ToolContext

    var body: some View {
        Group {
            switch context.tool {
            case .compress: CompressToolView(context: context)
            case .removeMetadata: MetadataToolView(context: context)
            case .editImage: EditPhotoToolView(context: context)
            case .annotateImage: AnnotateToolView(context: context)
            case .frameImage: FrameImageToolView(context: context)
            case .cropImage: CropImageToolView(context: context)
            case .redactImage: RedactPhotoToolView(context: context)
            case .createCollage: CollageToolView(context: context)
            case .trimVideo: TrimVideoToolView(context: context)
            case .cropVideo: CropVideoToolView(context: context)
            case .changeVideoSpeed: VideoSpeedToolView(context: context)
            case .joinVideos: OrderedFilesToolView(context: context, kind: .videos)
            case .videoSnapshots: VideoSnapshotsToolView(context: context)
            case .splitVideo: SplitVideoToolView(context: context)
            case .redactVideo: RedactVideoToolView(context: context)
            case .normalizeAudio: NormalizeAudioToolView(context: context)
            case .audioToVideo: AudioVisualizerToolView(context: context)
            case .trimAudio: TrimAudioToolView(context: context)
            case .audioChannels: AudioChannelsToolView(context: context)
            case .redactAudio: BleepAudioToolView(context: context)
            case .mergePDF: OrderedFilesToolView(context: context, kind: .pdfs)
            case .organizePDF: OrganizePDFToolView(context: context)
            default: ToolScaffold(title: context.tool.name, onClose: context.close) { Text("No options for this tool.") } footer: { EmptyView() }
            }
        }
        .tint(.satsumaAccent)
    }
}

// MARK: - Scaffold and shared controls

/// Header with the round close button and centered title, content, divider and footer.
struct ToolScaffold<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    var scrolls = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                HStack {
                    CloseCircleButton(action: onClose)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(height: 40)
            Divider()
            Group {
                if scrolls {
                    ScrollView { content().padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    content().padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Divider()
            HStack(spacing: 10) { footer() }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .background(Color.toolBackground)
        .ignoresSafeArea()
    }
}

struct CloseCircleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

/// Grey footer / inline button like the reference ("Apply", "Reset", "Add Frame").
struct ToolButton: View {
    let title: String
    var systemImage: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .padding(.horizontal, 4)
        }
        .controlSize(.large)
        .disabled(!isEnabled)
    }
}

/// Label on the left, control on the right ("Style", "Color", "Detect").
struct ToolRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            control()
        }
        .font(.system(size: 13))
        .padding(.vertical, 2)
    }
}

/// Slider row with value and reset arrow (Edit Photo) or value only.
struct ToolSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%+.0f", $0) }
    var resetValue: Double? = nil
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: labelWidth, alignment: .leading)
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }
            .controlSize(.small)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            if let resetValue {
                Button { value = resetValue } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(value == resetValue ? 0.5 : 1)
            }
        }
        .font(.system(size: 13))
    }
}

/// Section caption in grey (`Light`, `Color`, `Detail`).
struct ToolSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

/// Dark rounded preview well used by image and video tools.
struct PreviewWell<Content: View>: View {
    var height: CGFloat = 300
    var dark = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack { content() }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dark ? Color(white: 0.1) : Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum ToolFormat {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
    }
}

extension Color {
    /// Tool panel background: #F5F5F5 in light mode, the window background in dark mode.
    static let toolBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .windowBackgroundColor : NSColor(white: 0.965, alpha: 1)
    })
}
