import AppKit
import CoreGraphics

/// Watches system-wide file drags by polling the drag pasteboard, like the original app's
/// `DragGestureMonitor`. Tapping a configured modifier combination
/// while dragging files opens the matching wheel under the pointer.
final class DragGestureMonitor {
    private let overlayProvider: () -> ConversionOverlayController
    private let settings: SettingsModel
    private let dragPasteboard = NSPasteboard(name: .drag)

    // Timing values of the original app.
    private let triggerGraceInterval: TimeInterval = 0.35
    private let idlePollingInterval: TimeInterval = 0.1
    private let activePollingInterval: TimeInterval = 1.0 / 60.0

    private var timer: DispatchSourceTimer?
    private var isPollingActively = false
    private var wasEscapeDown = false
    private var previousModifiers: NSEvent.ModifierFlags = []
    private var wasPrimaryButtonDown = false
    private var lastObservedPasteboardChangeCount: Int
    private var pasteboardChangeCountBeforeMouseDown: Int?
    private var activeDragPasteboardChangeCount: Int?
    private var lastValidTriggerUptime: TimeInterval?
    private var shortcutState = WheelShortcutState()

    /// `WheelShortcutState`.
    struct WheelShortcutState {
        var mode: ConversionFanMode?
        var previousModifiers: NSEvent.ModifierFlags = []
        var wasDragging = false

        mutating func update(modifiers: NSEvent.ModifierFlags, primaryDown: Bool, escapeDown: Bool, settings: SettingsModel) {
            guard primaryDown, !escapeDown else {
                mode = nil
                previousModifiers = modifiers
                wasDragging = primaryDown
                return
            }
            let newlyPressed = !modifiers.subtracting(previousModifiers).isEmpty
            if !wasDragging || newlyPressed, let match = settings.mode(for: modifiers) {
                mode = match
            }
            previousModifiers = modifiers
            wasDragging = true
        }
    }

    init(settings: SettingsModel, overlayProvider: @escaping () -> ConversionOverlayController) {
        self.settings = settings
        self.overlayProvider = overlayProvider
        lastObservedPasteboardChangeCount = dragPasteboard.changeCount
    }

    func start() { schedule(interval: idlePollingInterval) }

    func stop() {
        timer?.cancel()
        timer = nil
        shortcutState = WheelShortcutState()
    }

    private func schedule(interval: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        let systemFlags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        let modifiers = NSEvent.modifierFlags.union(systemFlags).intersection([.shift, .control, .option, .command])
        let primaryDown = CGEventSource.buttonState(.combinedSessionState, button: .left) || (NSEvent.pressedMouseButtons & 1) != 0
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 0x35)

        shortcutState.update(modifiers: modifiers, primaryDown: primaryDown, escapeDown: escapeDown, settings: settings)
        let mode = shortcutState.mode
        let changeCount = dragPasteboard.changeCount

        if primaryDown {
            if !wasPrimaryButtonDown {
                pasteboardChangeCountBeforeMouseDown = lastObservedPasteboardChangeCount
                activeDragPasteboardChangeCount = nil
            }
            if let before = pasteboardChangeCountBeforeMouseDown, changeCount != before {
                activeDragPasteboardChangeCount = changeCount
            }
        }

        var draggedURLs: [URL]?
        if let active = activeDragPasteboardChangeCount, active == changeCount,
           dragPasteboard.availableType(from: [.fileURL]) != nil {
            draggedURLs = Self.fileURLs(in: dragPasteboard)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let newEscape = escapeDown && !wasEscapeDown
        let overlay = overlayProvider()

        if !newEscape, let mode, primaryDown, let urls = draggedURLs, !urls.isEmpty {
            lastValidTriggerUptime = now
            overlay.fanMode = mode
            overlay.configure(urls: urls, mode: mode)
            if !overlay.isVisible { overlay.show() }
        } else if overlay.isVisible {
            let graceElapsed = lastValidTriggerUptime.map { now - $0 >= triggerGraceInterval } ?? true
            // Once the button is up the drag is over, wherever it ended.
            let dragHeldOverWheel = overlay.isDragInside && primaryDown
            if newEscape || (!dragHeldOverWheel && graceElapsed && (mode == nil || !primaryDown || draggedURLs == nil)) {
                lastValidTriggerUptime = nil
                overlay.dismiss()
            }
        }

        if !primaryDown {
            pasteboardChangeCountBeforeMouseDown = nil
            activeDragPasteboardChangeCount = nil
        }
        wasEscapeDown = escapeDown
        previousModifiers = modifiers
        wasPrimaryButtonDown = primaryDown
        lastObservedPasteboardChangeCount = changeCount

        // Poll fast only while a drag may be in progress.
        let shouldPollActively = primaryDown || overlay.isVisible
        if shouldPollActively != isPollingActively {
            isPollingActively = shouldPollActively
            schedule(interval: shouldPollActively ? activePollingInterval : idlePollingInterval)
        }
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }
}
