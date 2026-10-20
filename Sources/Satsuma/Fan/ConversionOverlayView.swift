import AppKit
import SwiftUI

/// Plays the highlight tick and haptic (`FanHighlightSoundPlayer`: a small pool of sounds, round-robin).
final class FanHighlightSoundPlayer {
    static let shared = FanHighlightSoundPlayer()
    private var sounds: [NSSound] = []
    private var nextSoundIndex = 0

    func play() {
        guard SettingsModel.shared.soundsAndHapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if sounds.isEmpty {
            let click = HighlightClick.wavData()
            sounds = (0..<6).compactMap { _ in NSSound(data: click) }
            sounds.forEach { $0.volume = 0.45 }
        }
        guard !sounds.isEmpty else { return }
        let sound = sounds[nextSoundIndex % sounds.count]
        nextSoundIndex += 1
        sound.stop()
        sound.play()
    }
}

/// The wheel host (`ConversionOverlayView`): receives the file drag, hit-tests petals geometrically
/// and renders the SwiftUI `NativeGlassFanView`.
final class ConversionOverlayView: NSView {
    var onDrop: (([URL], ConversionFanAction) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    let model = NativeGlassFanModel()
    private let hostingView: NSHostingView<NativeGlassFanView>
    private(set) var sourceURLs: [URL] = []
    var idleCenterLabelText = ""
    private var idleCompact = false
    private var themeObserver: NSObjectProtocol?

    var actions: [ConversionFanAction] { model.actions }

    override init(frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: NativeGlassFanView(model: model))
        super.init(frame: frameRect)
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        registerForDraggedTypes([.fileURL])
        themeObserver = NotificationCenter.default.addObserver(forName: SettingsModel.themeDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.model.visualTheme = SettingsModel.shared.conversionFanTheme
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }

    func setActions(_ actions: [ConversionFanAction], sourceURLs: [URL], idleText: String, compact: Bool = false) {
        self.sourceURLs = sourceURLs
        idleCenterLabelText = idleText
        idleCompact = compact
        if model.actions != actions {
            model.actions = actions
            model.highlightedSlot = nil
        }
        if model.highlightedSlot == nil {
            model.centerLabelText = idleText
            model.centerLabelUsesCompactStyle = compact
        }
    }

    func playIntro() {
        model.visualTheme = SettingsModel.shared.conversionFanTheme
        model.chosenSlot = nil
        model.introRequest += 1
    }

    /// Starts the close animation; returns how long it lasts.
    func playOutro() -> TimeInterval {
        model.closeRequest += 1
        return NativeGlassFanView.outroDuration(count: model.actions.count)
    }

    // MARK: Hit testing

    private func slot(at point: NSPoint) -> Int? {
        PetalGeometry.slot(atOffset: point.x - bounds.midX, -(point.y - bounds.midY), count: model.actions.count)
    }

    private func updateHighlight(at point: NSPoint) {
        let hit = slot(at: point)
        guard hit != model.highlightedSlot else { return }
        model.highlightedSlot = hit
        if let hit {
            let action = model.actions[hit]
            model.centerLabelText = action.centerTitle
            model.centerLabelUsesCompactStyle = action.symbolName != nil
            FanHighlightSoundPlayer.shared.play()
        } else {
            // Between petals or in the hub: back to the idle label.
            model.centerLabelText = idleCenterLabelText
            model.centerLabelUsesCompactStyle = idleCompact
        }
    }

    func clearHighlight() {
        model.highlightedSlot = nil
        model.centerLabelText = idleCenterLabelText
        model.centerLabelUsesCompactStyle = idleCompact
    }

    var highlightedAction: ConversionFanAction? {
        model.highlightedSlot.flatMap { $0 < model.actions.count ? model.actions[$0] : nil }
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragStateChanged?(true)
        updateHighlight(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(at: convert(sender.draggingLocation, from: nil))
        return model.highlightedSlot == nil ? .generic : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearHighlight()
        onDragStateChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { model.highlightedSlot != nil }

    /// Only proceeds with source URLs and a highlighted petal.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DragGestureMonitor.fileURLs(in: sender.draggingPasteboard)
        guard let action = highlightedAction, !urls.isEmpty else { return false }
        // The chosen petal keeps its highlight for the close animation; the controller clears it afterwards.
        model.chosenSlot = model.highlightedSlot
        onDragStateChanged?(false)
        onDrop?(urls, action)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if model.chosenSlot == nil { clearHighlight() }
    }

    /// A drop refused over the wheel (center, ring, no petal) ends here, not in `draggingExited`.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        if model.chosenSlot == nil { clearHighlight() }
        onDragStateChanged?(false)
    }

    // Clicking a petal also works (preview behaviour).
    override func mouseMoved(with event: NSEvent) { updateHighlight(at: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = slot(at: point), !sourceURLs.isEmpty {
            model.highlightedSlot = index
            model.chosenSlot = index
            onDrop?(sourceURLs, model.actions[index])
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let the host view (not SwiftUI) receive drags and clicks.
        frame.contains(point) ? self : nil
    }
}
