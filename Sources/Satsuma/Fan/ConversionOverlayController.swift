import AppKit

/// Borderless panel that floats the wheel above every app (`ConversionOverlayPanel`).
final class ConversionOverlayPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel and the wheel; configured by `DragGestureMonitor` (`ConversionOverlayController`).
final class ConversionOverlayController {
    var onDrop: (([URL], ConversionFanAction) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var isDragInside = false
    var fanMode: ConversionFanMode = .conversions

    let overlayView: ConversionOverlayView
    let panel: ConversionOverlayPanel
    private var lastConfiguration: (urls: [URL], mode: ConversionFanMode)?

    init() {
        // Extra room around the wheel so the bubble's overshoot on open isn't clipped by the panel.
        let size = ceil(NativeGlassFanView.size + NativeGlassFanView.bubbleMargin * 2)
        panel = ConversionOverlayPanel(size: size)
        overlayView = ConversionOverlayView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = overlayView
        overlayView.onDragStateChanged = { [weak self] inside in self?.isDragInside = inside }
        overlayView.onDrop = { [weak self] urls, action in
            self?.dismiss()
            self?.onDrop?(urls, action)
        }
    }

    private var isClosing = false
    private var pendingOrderOut: DispatchWorkItem?

    /// False while the close animation plays, so a new drag can bring the wheel straight back.
    var isVisible: Bool { panel.isVisible && !isClosing }

    /// Work out the formats, the center label and the petals.
    func configure(urls: [URL], mode: ConversionFanMode) {
        let standardized = urls.map(\.standardizedFileURL)
        if let last = lastConfiguration, last.urls == standardized, last.mode == mode, isVisible { return }
        lastConfiguration = (standardized, mode)

        let fileManager = FileManager.default
        var formats: [ConversionFormat] = []
        var unknownCount = 0
        var folderCount = 0
        for url in standardized {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let isPackage = ConversionFormat.packageExtensions.contains(url.pathExtension.lowercased())
            if isDirectory.boolValue && !isPackage { folderCount += 1; continue }
            if let format = ConversionFormat.detect(url) { formats.append(format) } else { unknownCount += 1 }
        }

        let actions: [ConversionFanAction]
        var label: String
        if standardized.isEmpty {
            actions = []
            label = "Drop at least one item"
        } else if mode == .fileActions {
            actions = ConversionFanAction.fileActions
            label = Self.idleLabel(urls: standardized, formats: formats, folders: folderCount, unknown: unknownCount)
        } else if unknownCount > 0 || folderCount > 0 || formats.isEmpty {
            actions = []
            label = mode == .fileTools ? "No tools available" : "No installed converter for \(formats.first?.title ?? "this file")"
        } else {
            actions = ActionRegistry.actions(for: formats, mode: mode)
            label = Self.idleLabel(urls: standardized, formats: formats, folders: folderCount, unknown: unknownCount)
            if actions.isEmpty {
                if mode == .fileTools {
                    label = "No tools available"
                } else if Set(formats).count > 1 {
                    label = "No shared actions for selected files"
                } else {
                    label = "No installed converter for \(formats[0].title)"
                }
            }
        }
        overlayView.setActions(actions, sourceURLs: standardized, idleText: label, compact: false)
    }

    /// Center label rules.
    static func idleLabel(urls: [URL], formats: [ConversionFormat], folders: Int, unknown: Int) -> String {
        let count = urls.count
        if folders == count {
            return count == 1 ? "FOLDER" : "\(count) FOLDERS"
        }
        if count == 1, let format = formats.first {
            let size = (try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            let sizeText = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Size unavailable"
            return "\(format.title)\n\(sizeText)"
        }
        if folders == 0 && unknown == 0 {
            let distinct = Set(formats)
            if distinct.count == 1, let format = formats.first { return "\(count) \(format.title) FILES" }
            return "\(count) MIXED FILES"
        }
        return "\(count) ITEMS"
    }

    /// Center the wheel on the pointer, on the screen that contains it, then fade in.
    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = CGPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y - panel.frame.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        }
        // Reopened during the close animation: cancel the pending order-out.
        pendingOrderOut?.cancel()
        pendingOrderOut = nil
        isClosing = false
        panel.ignoresMouseEvents = false
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        overlayView.playIntro()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Close animation: the panel goes away once the petals have folded back.
    func dismiss() {
        isDragInside = false
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        panel.ignoresMouseEvents = true
        let duration = overlayView.playOutro()
        let work = DispatchWorkItem { [weak self] in self?.finishDismiss() }
        pendingOrderOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func finishDismiss() {
        pendingOrderOut = nil
        isClosing = false
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        overlayView.model.chosenSlot = nil
        overlayView.clearHighlight()
        lastConfiguration = nil
        onDismiss?()
    }
}
