import AppKit
import QuickLookThumbnailing
import Quartz
import SwiftUI

/// Float: a floating shelf of files (`FloatingFileWindowController`, `FloatingFileGroupModel`).
/// Compact it is a clipped stack of files; expanded it lists them as icons or rows. It attaches to
/// any screen edge when released near it, takes drops, and drags its files back out.
@MainActor
final class FloatShelfController: NSObject, NSWindowDelegate {
    static var shelves: [FloatShelfController] = []

    let model = FloatGroupModel()
    private let panel: FloatPanel
    private var quickLook: FloatQuickLookSource?

    static func float(_ urls: [URL]) {
        if SettingsModel.shared.floatWheelBehavior == .addToExisting, let existing = shelves.last {
            existing.model.add(urls)
            existing.panel.orderFrontRegardless()
            return
        }
        let shelf = FloatShelfController()
        shelves.append(shelf)
        shelf.model.add(urls)
        shelf.show()
    }

    override init() {
        panel = FloatPanel()
        super.init()
        panel.delegate = self
        let actions = FloatActions(
            close: { [weak self] in self?.close() },
            moveEnded: { [weak self] in self?.snapToEdge() },
            menu: { [weak self] url in self?.contextMenu(for: url) ?? NSMenu() },
            quickLook: { [weak self] in self?.showQuickLook() })
        panel.contentView = NSHostingView(rootView: FloatRootView(model: model, actions: actions))
        panel.quickLookSource = { [weak self] in self?.quickLookSource() }
        model.onLayoutChange = { [weak self] animated in self?.fit(animated: animated) }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let size = model.layout(screenHeight: screenHeight).size
        panel.setFrame(NSRect(x: mouse.x + 60, y: mouse.y - size.height / 2, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
    }

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible, panel.isKeyWindow { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        Self.shelves.removeAll { $0 === self }
    }

    /// The panel, for `--render-ui` snapshots.
    var window: NSWindow { panel }

    private var screenHeight: CGFloat { (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800 }

    /// Resizes around the attached edge, or around the top-left corner while floating.
    private func fit(animated: Bool) {
        if model.items.isEmpty { close(); return }
        let size = model.layout(screenHeight: screenHeight).size
        var frame = panel.frame
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        switch model.placement.isAttached ? model.placement.edge : nil {
        case .right?: frame.origin.x = visible.maxX - size.width
        case .bottom?: break
        case .left?: frame.origin.x = visible.minX
        default: frame.origin.y += frame.height - size.height
        }
        if model.placement.isAttached, model.placement.edge == .top { frame.origin.y = visible.maxY - size.height }
        frame.size = size
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - size.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - size.width)
        panel.setFrame(frame, display: true, animate: animated)
    }

    func windowDidMove(_ notification: Notification) {
        if NSEvent.pressedMouseButtons == 0 { snapToEdge() }
    }

    /// `FloatingTabPlacement`: attach to the nearest of the four edges within 48 pt, else detach.
    private func snapToEdge() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let distances: [(FloatGroupModel.Edge, CGFloat)] = [
            (.left, frame.minX - visible.minX), (.right, visible.maxX - frame.maxX),
            (.top, visible.maxY - frame.maxY), (.bottom, frame.minY - visible.minY),
        ]
        let nearest = distances.min { $0.1 < $1.1 }!
        let attach = nearest.1 < 48
        var placement = model.placement
        placement.isAttached = attach
        placement.edge = nearest.0
        placement.displayID = screen.displayID
        placement.position = nearest.0 == .left || nearest.0 == .right
            ? (frame.midY - visible.minY) / max(visible.height, 1)
            : (frame.midX - visible.minX) / max(visible.width, 1)
        if placement != model.placement {
            withAnimation(.easeOut(duration: 0.32)) { model.placement = placement }
        }
        var target = panel.frame
        if attach {
            switch nearest.0 {
            case .left: target.origin.x = visible.minX
            case .right: target.origin.x = visible.maxX - target.width
            case .top: target.origin.y = visible.maxY - target.height
            case .bottom: target.origin.y = visible.minY
            }
        }
        target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
        target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - target.width)
        fit(animated: false)
        if target.origin != panel.frame.origin { panel.setFrameOrigin(target.origin) }
    }

    // MARK: Context menu

    private func contextMenu(for url: URL?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let targets: [URL] = url.map { model.selectedItemIDs.contains($0) ? model.selectedURLs : [$0] } ?? model.items
        if let url {
            if !model.selectedItemIDs.contains(url) { model.selectedItemIDs = [url] }
            menu.addItem(MenuAction.item("Quick Look", symbol: "eye") { [weak self] in self?.showQuickLook() })
            menu.addItem(MenuAction.item("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting(targets) })
            menu.addItem(.separator())
            menu.addItem(openWithItem(for: targets))
            menu.addItem(MenuAction.item("Duplicate", symbol: "plus.square.on.square") { [weak self] in self?.duplicate(targets) })
            menu.addItem(MenuAction.item("Move to Trash", symbol: "trash") { [weak self] in self?.trash(targets) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("Remove from Float", symbol: "minus.circle") { [weak self] in self?.model.remove(targets) })
        }
        menu.addItem(MenuAction.item("Clear All", symbol: "xmark.circle") { [weak self] in self?.close() })
        return menu
    }

    private func openWithItem(for urls: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        let submenu = NSMenu()
        let apps = urls.first.map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Applications Available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for app in apps {
            let entry = MenuAction.item(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), symbol: nil) {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func duplicate(_ urls: [URL]) {
        var copies: [URL] = []
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var candidate = url
            var index = 1
            repeat {
                let name = index == 1 ? "\(base) copy" : "\(base) copy \(index)"
                candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
                index += 1
            } while FileManager.default.fileExists(atPath: candidate.path)
            if (try? FileManager.default.copyItem(at: url, to: candidate)) != nil { copies.append(candidate) }
        }
        model.add(copies)
    }

    private func trash(_ urls: [URL]) {
        NSWorkspace.shared.recycle(urls) { [weak self] _, _ in
            Task { @MainActor in self?.model.remove(urls) }
        }
    }

    // MARK: Quick Look

    private func quickLookSource() -> FloatQuickLookSource {
        let urls = model.selectedURLs.isEmpty ? model.items : model.selectedURLs
        let source = FloatQuickLookSource(urls: urls)
        quickLook = source
        return source
    }

    private func showQuickLook() {
        panel.makeKey()
        let preview = QLPreviewPanel.shared()!
        if preview.isVisible { preview.orderOut(nil) } else { preview.makeKeyAndOrderFront(nil) }
    }
}

/// Closures the SwiftUI side calls back into the controller with.
struct FloatActions {
    let close: () -> Void
    let moveEnded: () -> Void
    let menu: (URL?) -> NSMenu
    let quickLook: () -> Void
}

/// Target/action shim so menu items can run closures.
final class MenuAction: NSObject {
    private let handler: () -> Void
    private init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc private func run() { handler() }

    static func item(_ title: String, symbol: String?, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}

final class FloatQuickLookSource: NSObject, QLPreviewPanelDataSource {
    let urls: [URL]
    init(urls: [URL]) { self.urls = urls }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

final class FloatPanel: NSPanel {
    var quickLookSource: (() -> FloatQuickLookSource?)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 131), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookSource?()
        panel.reloadData()
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Model and layout

@MainActor
final class FloatGroupModel: ObservableObject {
    enum Edge: Equatable { case top, right, bottom, left }
    enum ViewMode { case icons, list }
    enum Presentation { case compact, expanded }

    /// `FloatingTabPlacement`.
    struct Placement: Equatable {
        var edge: Edge = .right
        var position: CGFloat = 0.5
        var displayID: CGDirectDisplayID = 0
        var isAttached = false
    }

    @Published var items: [URL] = []
    @Published var selectedItemIDs: Set<URL> = []
    @Published var selectionFocusID: URL?
    @Published var presentation: Presentation = .compact { didSet { if oldValue != presentation { onLayoutChange(true) } } }
    @Published var viewMode: ViewMode = .icons { didSet { if oldValue != viewMode { onLayoutChange(true) } } }
    @Published var dropTargetItemCount = 0 { didSet { if (oldValue == 0) != (dropTargetItemCount == 0) { onLayoutChange(true) } } }
    @Published var placement = Placement()
    @Published var isPaperClipRetractionActive = false
    var onLayoutChange: (Bool) -> Void = { _ in }

    var selectedURLs: [URL] { items.filter { selectedItemIDs.contains($0) } }

    func add(_ urls: [URL]) {
        let new = urls.filter { !items.contains($0) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        clip()
        onLayoutChange(true)
    }

    func remove(_ urls: [URL]) {
        items.removeAll { urls.contains($0) }
        selectedItemIDs.subtract(urls)
        onLayoutChange(true)
    }

    /// The clip lifts while files land, then snaps back onto the stack.
    private func clip() {
        withAnimation(.easeOut(duration: 0.14)) { isPaperClipRetractionActive = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { self?.isPaperClipRetractionActive = false }
        }
    }

    /// Title shown under the compact stack.
    var summary: String {
        if items.count == 1 { return items[0].lastPathComponent }
        let folders = items.filter { $0.hasDirectoryPath }.count
        if folders == items.count { return "\(items.count) folders" }
        return "\(items.count) items"
    }

    func layout(screenHeight: CGFloat) -> FloatTabLayout {
        FloatTabLayout(presentation: presentation, viewMode: viewMode, itemCount: items.count,
                       isAttached: placement.isAttached, dropTargetItemCount: dropTargetItemCount,
                       screenHeight: screenHeight, summaryWidth: Self.textWidth(summary))
    }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width)
    }
}

/// `FloatingTabLayout`.
struct FloatTabLayout {
    static let stackSize = CGSize(width: 77.945, height: 90.417)
    static let maxViewport: CGFloat = 472

    let size: CGSize
    let viewportHeight: CGFloat
    let cornerRadius: CGFloat
    let isAttached: Bool
    let itemRowHeight: CGFloat
    let contentTopInset: CGFloat
    let headerHeight: CGFloat

    init(presentation: FloatGroupModel.Presentation, viewMode: FloatGroupModel.ViewMode, itemCount: Int,
         isAttached: Bool, dropTargetItemCount: Int, screenHeight: CGFloat, summaryWidth: CGFloat) {
        self.isAttached = isAttached
        itemRowHeight = viewMode == .list ? 38 : 92
        contentTopInset = viewMode == .list ? 8 : 12
        if presentation == .compact {
            let width = min(max(summaryWidth + 24, 80), 116)
            var height: CGFloat = isAttached ? 115 : 131
            if dropTargetItemCount >= 1 { height = 157 }
            size = CGSize(width: max(100, width), height: height)
            viewportHeight = 0
            headerHeight = height
            cornerRadius = isAttached ? 16 : 29.667
        } else {
            let width: CGFloat = viewMode == .list ? 140 : 112
            let header: CGFloat = isAttached ? 114 : 163
            let rows = CGFloat(itemCount) * itemRowHeight + contentTopInset
            let viewport = min(max(rows, itemRowHeight), min(screenHeight - header, Self.maxViewport))
            size = CGSize(width: width, height: header + viewport)
            viewportHeight = viewport
            headerHeight = header
            cornerRadius = 29.667
        }
    }
}

// MARK: - Views

struct FloatRootView: View {
    @ObservedObject var model: FloatGroupModel
    let actions: FloatActions
    @State private var hovering = false

    var body: some View {
        let layout = model.layout(screenHeight: NSScreen.main?.visibleFrame.height ?? 800)
        let shape = FloatShape(radius: layout.cornerRadius, edge: model.placement.isAttached ? model.placement.edge : nil)
        let content = ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header(layout)
                if model.presentation == .expanded {
                    FloatFileList(model: model, layout: layout, actions: actions)
                        .frame(height: layout.viewportHeight)
                        .transition(.opacity)
                }
            }
            if model.dropTargetItemCount > 0 { dropTarget(shape) }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onDrop(of: [.fileURL], delegate: FloatDropDelegate(model: model))
        .animation(.easeOut(duration: 0.32), value: model.presentation)
        .animation(.easeOut(duration: 0.12), value: model.dropTargetItemCount)

        Group {
            if #available(macOS 26.0, *), !DebugRender.active {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(VisualEffectBackground(material: .popover).clipShape(shape))
                    .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func header(_ layout: FloatTabLayout) -> some View {
        let expanded = model.presentation == .expanded
        VStack(spacing: 0) {
            ZStack {
                WindowMoveHandle(onMoveEnded: actions.moveEnded)
                    .help("Move Float; drag near an edge to attach, or away to detach")
                    .accessibilityLabel("Move Float; drag near an edge to attach, or away to detach")
                Capsule().fill(Color.primary.opacity(0.22)).frame(width: 28, height: 4).allowsHitTesting(false)
                HStack(spacing: 0) {
                    if expanded || hovering {
                        Button(action: actions.close) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Close Float without deleting files")
                        .accessibilityLabel("Close Float without deleting files")
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    if expanded {
                        Button { model.viewMode = model.viewMode == .icons ? .list : .icons } label: {
                            Image(systemName: model.viewMode == .icons ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(model.viewMode == .icons ? "Show as List" : "Show as Icons")
                    }
                }
                .padding(.horizontal, layout.isAttached ? 8 : 14)
                .animation(.easeOut(duration: 0.14), value: hovering)
            }
            .frame(height: layout.isAttached ? 22 : 38)

            FloatStackPreview(model: model, actions: actions)
                .frame(height: FloatTabLayout.stackSize.height)

            if !layout.isAttached || model.presentation == .compact {
                Text(model.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: layout.size.width - 12)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(height: model.presentation == .expanded ? layout.headerHeight : nil)
    }

    private func dropTarget(_ shape: FloatShape) -> some View {
        let count = model.dropTargetItemCount
        return ZStack {
            shape.fill(Color.satsumaAccent.opacity(0.86))
            shape.stroke(Color.satsumaAccent, lineWidth: 2)
            Text("Drop to add\n\(count) \(count == 1 ? "item" : "items") to it")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .frame(width: 100)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Rounded panel whose screen-side corners are square while attached.
struct FloatShape: Shape {
    let radius: CGFloat
    let edge: FloatGroupModel.Edge?

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var radii = RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
        switch edge {
        case .left?: radii.topLeading = 0; radii.bottomLeading = 0
        case .right?: radii.topTrailing = 0; radii.bottomTrailing = 0
        case .top?: radii.topLeading = 0; radii.topTrailing = 0
        case .bottom?: radii.bottomLeading = 0; radii.bottomTrailing = 0
        case nil: break
        }
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

/// `FloatingTabStackPreview`: up to three fanned cards held by a paper clip; dragging it drags every file,
/// clicking it expands or collapses the Float.
struct FloatStackPreview: View {
    @ObservedObject var model: FloatGroupModel
    let actions: FloatActions

    var body: some View {
        let shown = Array(model.items.suffix(3))
        let expanded = model.presentation == .expanded
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                let depth = shown.count - 1 - index
                FloatThumbnail(url: url, side: 128)
                    .frame(width: 58, height: 66)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.92)))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .rotationEffect(.degrees(depth == 0 ? 0 : (depth == 1 ? -7 : 6)))
                    .offset(x: depth == 0 ? 0 : (depth == 1 ? -6 : 6), y: CGFloat(depth) * -2 + 6)
            }
            PaperClip()
                .frame(width: 16, height: 38)
                .rotationEffect(.degrees(-8))
                .offset(x: -18, y: model.isPaperClipRetractionActive || model.dropTargetItemCount > 0 ? -34 : -26)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                .allowsHitTesting(false)
        }
        .frame(width: FloatTabLayout.stackSize.width, height: FloatTabLayout.stackSize.height)
        .overlay(
            FileDragSource(urls: { model.items },
                           onClick: { _ in model.presentation = expanded ? .compact : .expanded },
                           onDoubleClick: { model.presentation = expanded ? .compact : .expanded },
                           menu: { actions.menu(nil) })
        )
        .accessibilityLabel(expanded ? "Collapse Float, \(model.summary)" : "Expand Float, \(model.summary)")
    }
}

/// Satsuma's own paper clip: three nested loops of bent wire with a steel gradient.
struct PaperClip: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            Path { path in
                let outer = w / 2, mid = w * 0.32, inner = w * 0.18
                path.move(to: CGPoint(x: w / 2 + inner, y: h * 0.30))
                path.addLine(to: CGPoint(x: w / 2 + inner, y: h - mid - 4))
                path.addArc(center: CGPoint(x: w / 2, y: h - mid - 4), radius: inner, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                path.addLine(to: CGPoint(x: w / 2 - inner, y: outer))
                path.addArc(center: CGPoint(x: w / 2 + inner - mid + inner, y: outer), radius: mid, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                path.addLine(to: CGPoint(x: w / 2 + mid + inner * 0.6, y: h - outer - 1))
                path.addArc(center: CGPoint(x: w / 2 - inner * 0.2, y: h - outer - 1), radius: outer - 1.2, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                path.addLine(to: CGPoint(x: 1.2 - inner * 0.2 + inner * 0.2, y: h * 0.42))
            }
            .stroke(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55), Color(white: 0.8)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// `FloatingTabFile` list: icons or rows, with click / ⌘-click / ⇧-click selection, rubber-band selection
/// in empty space, type-to-select, Space for Quick Look and Delete to remove from the Float.
struct FloatFileList: View {
    @ObservedObject var model: FloatGroupModel
    let layout: FloatTabLayout
    let actions: FloatActions
    @State private var frames: [URL: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: Set<URL> = []
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @FocusState private var focused: Bool

    var body: some View {
        let cellWidth = layout.size.width - 12
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(rubberBand)
                    .onTapGesture { model.selectedItemIDs = [] }
                    .accessibilityLabel("File selection area. Drag empty space to select multiple files.")
                VStack(spacing: 0) {
                    ForEach(model.items, id: \.self) { url in
                        FloatFileCell(url: url, mode: model.viewMode, width: cellWidth, rowHeight: layout.itemRowHeight,
                                      selected: model.selectedItemIDs.contains(url))
                            .frame(width: cellWidth, height: layout.itemRowHeight)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: FloatFrameKey.self, value: [url: proxy.frame(in: .named("floatList"))])
                            })
                            .overlay(FileDragSource(urls: { model.selectedItemIDs.contains(url) ? model.selectedURLs : [url] },
                                                    onClick: { flags in click(url, flags) },
                                                    onDoubleClick: { (model.selectedItemIDs.contains(url) ? model.selectedURLs : [url]).forEach { NSWorkspace.shared.open($0) } },
                                                    menu: { actions.menu(url) }))
                    }
                }
                .padding(.top, layout.contentTopInset)
                .frame(maxWidth: .infinity)
                if let band {
                    Rectangle().fill(Color.satsumaAccent.opacity(0.15))
                        .overlay(Rectangle().stroke(Color.satsumaAccent.opacity(0.7), lineWidth: 1))
                        .frame(width: band.width, height: band.height)
                        .offset(x: band.minX, y: band.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: layout.viewportHeight, alignment: .top)
            .coordinateSpace(name: "floatList")
            .onPreferenceChange(FloatFrameKey.self) { frames = $0 }
        }
        .scrollIndicators(.never)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("floatList"))
            .onChanged { value in
                if band == nil { bandBase = NSEvent.modifierFlags.contains(.command) ? model.selectedItemIDs : [] }
                let rect = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                band = rect
                model.selectedItemIDs = bandBase.union(frames.filter { $0.value.intersects(rect) }.map(\.key))
            }
            .onEnded { _ in band = nil; focused = true }
    }

    private func click(_ url: URL, _ flags: NSEvent.ModifierFlags) {
        focused = true
        if flags.contains(.command) {
            if model.selectedItemIDs.contains(url) { model.selectedItemIDs.remove(url) } else { model.selectedItemIDs.insert(url) }
        } else if flags.contains(.shift), let anchor = model.selectionFocusID,
                  let a = model.items.firstIndex(of: anchor), let b = model.items.firstIndex(of: url) {
            model.selectedItemIDs = Set(model.items[min(a, b)...max(a, b)])
            return
        } else {
            model.selectedItemIDs = [url]
        }
        model.selectionFocusID = url
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space: actions.quickLook(); return .handled
        case .delete, .deleteForward:
            model.remove(model.selectedURLs); return .handled
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            guard !model.items.isEmpty else { return .ignored }
            let current = model.selectionFocusID.flatMap { model.items.firstIndex(of: $0) } ?? -1
            let step = press.key == .upArrow || press.key == .leftArrow ? -1 : 1
            let next = min(max(current + step, 0), model.items.count - 1)
            model.selectedItemIDs = [model.items[next]]
            model.selectionFocusID = model.items[next]
            return .handled
        default:
            guard press.modifiers.subtracting(.shift).isEmpty, !press.characters.isEmpty,
                  press.characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) || $0 == " " })
            else { return .ignored }
            if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
            typed += press.characters.lowercased()
            typedAt = Date()
            if let match = model.items.first(where: { $0.lastPathComponent.lowercased().hasPrefix(typed) }) {
                model.selectedItemIDs = [match]
                model.selectionFocusID = match
            }
            return .handled
        }
    }
}

private struct FloatFrameKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// One file in the expanded Float (`FloatingTabFile`): icon cells are `width × (row − 4)` with a
/// title 88 wide that fades in after a short delay; rows show a small icon and the name.
struct FloatFileCell: View {
    let url: URL
    let mode: FloatGroupModel.ViewMode
    let width: CGFloat
    let rowHeight: CGFloat
    let selected: Bool
    @State private var revealsTitle = false

    var body: some View {
        Group {
            if mode == .icons {
                VStack(spacing: 4) {
                    FloatThumbnail(url: url, side: 128).frame(width: 56, height: 56)
                    Text(url.lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .frame(width: 88)
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.satsumaAccent : .clear))
                        .foregroundStyle(selected ? .white : .primary)
                        .opacity(revealsTitle ? 1 : 0)
                }
                .padding(.vertical, 4)
                .frame(width: width, height: rowHeight - 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.primary.opacity(0.10) : .clear))
            } else {
                HStack(spacing: 6) {
                    FloatThumbnail(url: url, side: 64).frame(width: 24, height: 24)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: width - 24 - 14, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .frame(width: width, height: rowHeight - 4, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.satsumaAccent : .clear))
                .foregroundStyle(selected ? .white : .primary)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.32).delay(0.12)) { revealsTitle = true }
        }
    }
}

/// Quick Look thumbnail with the Finder icon as placeholder.
struct FloatThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                           representationTypes: .thumbnail)
                thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}

/// Counts incoming files for "Drop to add N items to it" and adds them on drop.
struct FloatDropDelegate: DropDelegate {
    let model: FloatGroupModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        let count = info.itemProviders(for: [.fileURL]).count
        Task { @MainActor in model.dropTargetItemCount = max(count, 1) }
    }

    func dropExited(info: DropInfo) {
        Task { @MainActor in model.dropTargetItemCount = 0 }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in model.dropTargetItemCount = 0 }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.add([url]) } }
            }
        }
        return true
    }
}

// MARK: - AppKit bridges

/// Transparent view that turns a click into `onClick`, a drag into a file drag of `urls()`, and a
/// right click into `menu()`.
struct FileDragSource: NSViewRepresentable {
    let urls: () -> [URL]
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuProvider = menu
    }
}

final class FileDragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuProvider: () -> NSMenu = { NSMenu() }
    private var downEvent: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        if event.clickCount == 2 { onDoubleClick(); downEvent = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        dragging = true
        let files = urls()
        guard !files.isEmpty else { return }
        let items: [NSDraggingItem] = files.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let origin = convert(down.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: origin.x - 24 + CGFloat(index) * 4, y: origin.y - 24 - CGFloat(index) * 4, width: 48, height: 48), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, !dragging { onClick(event.modifierFlags) }
        downEvent = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy]
    }
}

/// Drag handle that moves the window, then lets the controller snap it to an edge.
struct WindowMoveHandle: NSViewRepresentable {
    let onMoveEnded: () -> Void
    func makeNSView(context: Context) -> WindowMoveHandleView { WindowMoveHandleView() }
    func updateNSView(_ view: WindowMoveHandleView, context: Context) { view.onMoveEnded = onMoveEnded }
}

final class WindowMoveHandleView: NSView {
    var onMoveEnded: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        onMoveEnded()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
