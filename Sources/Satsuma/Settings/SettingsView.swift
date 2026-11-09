import ServiceManagement
import SwiftUI

/// Settings (`ColumnSettingsWindow`): a 456×560 single-column window with toolbar tabs
/// General, Formats, Compression, Compatibility, Folders and About.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", formats = "Formats", compression = "Compression", compatibility = "Compatibility", folders = "Folders", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .formats: return "slider.horizontal.3"
        case .compression: return "arrow.down.right.and.arrow.up.left"
        case .compatibility: return "tablecells"
        case .folders: return "folder"
        case .about: return "info.circle"
        }
    }
}

enum SettingsWindowFactory {
    static let size = NSSize(width: 456, height: 560)

    static func makeWindow(model: SettingsModel) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: SettingsTabView(tab: tab, model: model))
            controller.preferredContentSize = NSSize(width: size.width, height: size.height - 52)
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.rawValue
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.rawValue)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.title = "Satsuma Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: size.width, height: size.height - 52))
        return window
    }
}

struct SettingsTabView: View {
    let tab: SettingsTab
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(model: model)
            case .formats: FormatSettings(model: model)
            case .compression: CompressionSettings(model: model)
            case .compatibility: FormatCompatibilityView()
            case .folders: FolderSettings()
            case .about: AboutSettings()
            }
        }
        .frame(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height - 52)
        .tint(.satsumaAccent)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @AppStorage(SettingsModel.Key.terminalApp) private var terminalApp = "com.apple.Terminal"

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at login")
                    Text("Satsuma starts with your Mac, ready in the menu bar.")
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    launchAtLogin = LoginItem.set(enabled) || (enabled && LoginItem.needsApproval)
                    loginStatus = SMAppService.mainApp.status
                }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("One more step: allow Satsuma in macOS Login Items.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: {
                Text("Startup")
            }
            Section("Appearance") {
                Picker("Wheel style", selection: $model.conversionFanTheme) {
                    Text("Glass").tag(ConversionFanTheme.glass)
                    Text("Metallic").tag(ConversionFanTheme.metallic)
                }
                Toggle("Sound and haptic feedback", isOn: $model.soundsAndHapticsEnabled)
                Toggle(isOn: $model.showMenuBarIcon) {
                    Text("Show icon in menu bar")
                    Text("When hidden, Satsuma keeps running: open it again from Applications or Spotlight to get back to Settings.")
                }
            }
            Section {
                ModifierPicker(title: "Conversion wheel", mask: $model.conversionMask)
                ModifierPicker(title: "Tools wheel", mask: $model.toolsMask)
                ModifierPicker(title: "Actions wheel", mask: $model.actionsMask)
            } header: {
                Text("Drag Modifiers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tap the chosen modifier combination while dragging files.")
                    if let conflict = modifierConflict {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Float") {
                Picker("Float from the actions wheel", selection: $model.floatWheelBehavior) {
                    Text("Create a New Float").tag(FloatWheelBehavior.createNew)
                    Text("Add Files to an Existing Float").tag(FloatWheelBehavior.addToExisting)
                }
            }
            Section("Terminal") {
                Picker("Terminal app", selection: $terminalApp) {
                    ForEach(TerminalChoice.installed, id: \.id) { Text($0.title).tag($0.id) }
                    if TerminalChoice.installed.isEmpty { Text("No Applications Available").tag(terminalApp) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modifierConflict: String? {
        let masks = [model.conversionMask, model.toolsMask, model.actionsMask]
        if masks.contains(0) { return "A wheel without modifiers can't be opened." }
        return Set(masks).count < masks.count ? "Two wheels share the same modifiers." : nil
    }
}

/// `TerminalApplication`: Terminal or iTerm2, whichever are installed.
enum TerminalChoice {
    static let known: [(id: String, title: String)] = [("com.apple.Terminal", "Terminal"), ("com.googlecode.iterm2", "iTerm2"),
                                                        ("dev.warp.Warp-Stable", "Warp"), ("com.mitchellh.ghostty", "Ghostty")]
    static var installed: [(id: String, title: String)] { known.filter { ToolLocator.appInstalled(bundleID: $0.id) } }
}

struct ModifierPicker: View {
    let title: String
    @Binding var mask: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach([(DragModifierCombination.control, "⌃"), (DragModifierCombination.option, "⌥"),
                         (DragModifierCombination.shift, "⇧"), (DragModifierCombination.command, "⌘")], id: \.0) { bit, symbol in
                    let on = mask & bit != 0
                    Button { mask = on ? mask & ~bit : mask | bit } label: {
                        Text(symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 22)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? Color.satsumaAccent : Color.primary.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

extension ConversionFormat.Group {
    static let settingsOrder: [ConversionFormat.Group] = [.images, .documents, .spreadsheets, .audio, .video, .archives, .subtitles]
    var title: String {
        switch self {
        case .images: return "Images"
        case .documents: return "Documents"
        case .spreadsheets: return "Spreadsheets"
        case .audio: return "Audio"
        case .video: return "Video"
        case .archives: return "Archives"
        case .subtitles: return "Subtitles"
        }
    }
    var formats: [ConversionFormat] { ConversionFormat.allCases.filter { $0.group == self } }
}

// MARK: Formats

/// Search, group chips, output formats, then "<FMT> Settings" (`ConversionOptionsFields`).
private struct FormatSettings: View {
    @ObservedObject var model: SettingsModel
    @State private var search = ""
    @State private var group: ConversionFormat.Group = .images
    @State private var selected: ConversionFormat = .jpg

    private var outputs: [ConversionFormat] {
        let all = ConversionFormat.allCases.filter { !$0.isInputOnly }
        if search.isEmpty { return all.filter { $0.group == group } }
        return all.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.group.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search formats", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ConversionFormat.Group.settingsOrder, id: \.self) { item in
                            Chip(title: item.title, selected: search.isEmpty && item == group) {
                                search = ""
                                group = item
                                if let first = item.formats.first(where: { !$0.isInputOnly }) { selected = first }
                            }
                        }
                    }
                }
                if outputs.isEmpty {
                    Text("No results").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 30)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(outputs, id: \.self) { format in
                            Button { selected = format } label: {
                                Text(format.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .frame(maxWidth: .infinity).frame(height: 26)
                                    .foregroundStyle(format == selected ? Color.white : Color.primary)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(format == selected ? Color.satsumaAccent : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)

            Form {
                Section {
                    FormatOptionFields(format: selected, model: model)
                } header: {
                    Text("\(selected.title) Settings")
                } footer: {
                    Text("Conversion defaults are configured on the output format you choose.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { model.defaultOptions = ConversionOptions() }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).frame(height: 24)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.satsumaAccent : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private struct FormatOptionFields: View {
    let format: ConversionFormat
    @ObservedObject var model: SettingsModel

    var body: some View {
        switch format.group {
        case .images where format != .pdf:
            qualityPicker
            Toggle("Preserve metadata", isOn: $model.defaultOptions.preserveMetadata)
        case .video where format == .gif:
            Stepper("Frame rate: \(model.defaultOptions.gifFrameRate) fps", value: $model.defaultOptions.gifFrameRate, in: 5...30)
            Stepper("Maximum width: \(model.defaultOptions.gifMaxWidth) px", value: $model.defaultOptions.gifMaxWidth, in: 160...1920, step: 80)
        case .video:
            qualityPicker
            Picker("Maximum video height", selection: $model.defaultOptions.videoMaxHeight) {
                Text("Original").tag(0)
                ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
            }
            Toggle("Preserve metadata", isOn: $model.defaultOptions.preserveMetadata)
        case .audio where [.wav, .aiff].contains(format):
            Picker("Bit depth", selection: $model.defaultOptions.audioSampleDepth) {
                Text("Match source").tag(AudioSampleDepth.matchSource)
                Text("16-bit").tag(AudioSampleDepth.bit16)
                Text("24-bit").tag(AudioSampleDepth.bit24)
                Text("32-bit").tag(AudioSampleDepth.bit32)
                Text("32-bit float").tag(AudioSampleDepth.float32)
            }
        case .audio where format != .flac:
            Picker("Audio bitrate", selection: $model.defaultOptions.audioBitrate) {
                ForEach([96, 128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
        case .documents where [.docx, .pages, .pptx].contains(format), .spreadsheets where format == .xlsx:
            Picker("From PDF", selection: $model.defaultOptions.pdfOfficeLayout) {
                Text("Editable paragraphs").tag(PDFOfficeLayout.editable)
                Text("Preserve original pages").tag(PDFOfficeLayout.preservePages)
            }
            note(model.defaultOptions.pdfOfficeLayout == .editable
                 ? "Create normal paragraphs, headings, and tables that reflow when edited. Recognize scanned text with OCR. Keep illustrations as inline images."
                 : "Keep every page as a sharp image, including tables, equations, and scanned content. Text cannot be edited.")
        case .documents where format == .epub:
            Picker("From PDF", selection: $model.defaultOptions.epubLayout) {
                Text("Adjustable text").tag(EPUBLayout.adjustableText)
                Text("Preserve pages").tag(EPUBLayout.preservePages)
            }
            note(model.defaultOptions.epubLayout == .adjustableText
                 ? "Create adjustable, selectable text with parsed headings and tables. Keep illustrations and complex equations as separate artwork."
                 : "Create a fixed layout book of page images. Text resizing, selection, and search are unavailable.")
        case .archives where format != .tar:
            Picker("Compression", selection: $model.defaultOptions.compression) {
                Text("Faster").tag(CompressionLevel.fast)
                Text("Balanced").tag(CompressionLevel.balanced)
                Text("Smallest File").tag(CompressionLevel.maximum)
            }
        default:
            Text("This output format has no adjustable conversion defaults.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: $model.defaultOptions.quality) {
            Text("Smaller File").tag(ConversionQuality.compact)
            Text("Balanced").tag(ConversionQuality.balanced)
            Text("Higher Quality").tag(ConversionQuality.high)
        }
    }
}

// MARK: Compression

private struct CompressionSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Compression strength", selection: $model.imageCompressionStrength) {
                    Text("Balanced").tag(CompressionStrength.balanced)
                    Text("Strong").tag(CompressionStrength.strong)
                }
                .pickerStyle(.segmented)
                Picker("Image size", selection: $model.imageCompressionSize) {
                    ForEach(ImageCompressionSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Image Compression")
            } footer: {
                caption(model.imageCompressionStrength)
            }
            Section {
                Picker("Compression strength", selection: $model.videoCompressionStrength) {
                    Text("Balanced").tag(CompressionStrength.balanced)
                    Text("Strong").tag(CompressionStrength.strong)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Video Compression")
            } footer: {
                caption(model.videoCompressionStrength)
            }
            Section {
                HStack {
                    Text("The Compress tool starts from these presets.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Compression Defaults") { model.restoreCompressionDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func caption(_ strength: CompressionStrength) -> some View {
        Text(strength == .strong ? "Much smaller files with more visible quality loss." : "Better visual quality with moderate file-size savings.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

// MARK: Compatibility

/// `FormatCompatibilityMatrix`: inputs of one group (rows) against every output (columns) on this Mac.
struct FormatCompatibilityView: View {
    @State private var group: ConversionFormat.Group = .images
    private let cell: CGFloat = 18
    private let rowLabel: CGFloat = 64

    private var inputs: [ConversionFormat] { group.formats }
    private var outputs: [ConversionFormat] {
        let reachable = Set(inputs.flatMap { ActionRegistry.conversionOutputs(for: [$0]) })
        return ConversionFormat.allCases.filter { reachable.contains($0) || ($0.group == group && !$0.isInputOnly) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ConversionFormat.Group.settingsOrder, id: \.self) { item in
                        Chip(title: item.title, selected: item == group) { group = item }
                    }
                }
            }
            Text("Input to output").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .bottom, spacing: 2) {
                        Color.clear.frame(width: rowLabel, height: 1)
                        ForEach(outputs, id: \.self) { output in
                            Text(output.title)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(ActionRegistry.conversionOutputs(for: [output]).isEmpty ? Color.satsumaAccent : Color.primary)
                                .fixedSize()
                                .rotationEffect(.degrees(-90))
                                .frame(width: cell, height: 52, alignment: .bottom)
                        }
                    }
                    ForEach(inputs, id: \.self) { input in
                        let supported = Set(ActionRegistry.conversionOutputs(for: [input]))
                        HStack(spacing: 2) {
                            Text(input.title)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(supported.isEmpty ? .tertiary : .primary)
                                .italic(input.isInputOnly)
                                .frame(width: rowLabel, alignment: .leading)
                            ForEach(outputs, id: \.self) { output in
                                matrixCell(input: input, output: output, on: supported.contains(output))
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            legend
        }
        .padding(20)
    }

    private func matrixCell(input: ConversionFormat, output: ConversionFormat, on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(input == output ? Color.primary.opacity(0.02) : on ? Color.satsumaAccent.opacity(0.16) : Color.primary.opacity(0.05))
            .overlay {
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.satsumaAccent) }
            }
            .frame(width: cell, height: cell)
            .accessibilityLabel(input.title + (on ? " converts to " + output.title : " to " + output.title + " unavailable"))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(Text("EXT").font(.system(size: 9, weight: .semibold, design: .rounded)), "Input and output format.")
            legendRow(Text("EXT").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(Color.satsumaAccent), "Output-only format.")
            legendRow(Text("EXT").font(.system(size: 9, weight: .semibold, design: .rounded)).italic(), "Input-only format.")
            legendRow(Text("EXT").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary), "Unavailable for conversion.")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func legendRow(_ sample: some View, _ text: String) -> some View {
        HStack(spacing: 8) { sample.frame(width: 30, alignment: .leading); Text(text) }
    }
}

// MARK: Folders

private struct FolderSettings: View {
    @ObservedObject private var store = FolderAccessStore.shared

    var body: some View {
        Form {
            Section {
                if store.folders.isEmpty {
                    Text("No folders allowed yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(store.folders, id: \.self) { folder in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.lastPathComponent).font(.system(size: 13))
                                Text((folder.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Menu {
                                Button("Choose Again") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.prompt = "Allow Access"
                                    panel.directoryURL = folder
                                    if panel.runModal() == .OK, let url = panel.url { store.replace(folder, with: url) }
                                }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                                Divider()
                                Button("Remove access", role: .destructive) { store.remove(folder) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
            } header: {
                Text("Folder Access")
            } footer: {
                Text("Satsuma saves results beside the original files. Allow the folders you convert in most so macOS doesn't ask each time.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Allow Access…") { store.requestAccess() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: About

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            SatsumaMark().frame(width: 96, height: 96)
            Text("Satsuma").font(.system(size: 24, weight: .bold))
            Text(version).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Drag a file, tap a key, drop on a petal.\nEverything happens locally on your Mac.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
            Spacer()
            VStack(spacing: 4) {
                Text("A study rebuild of a drag-and-drop converter, written from scratch.")
                Text("Uses ffmpeg, cwebp and exiftool when they are installed.")
            }
            .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }
}
