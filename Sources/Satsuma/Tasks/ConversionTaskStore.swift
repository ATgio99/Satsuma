import AppKit
import SwiftUI

/// Tracks running jobs (`ConversionTaskStore`) and drives the progress panels.
@MainActor
final class ConversionTaskStore {
    struct Record {
        let id: UUID
        let sourceName: String
        let targetTitle: String
        /// What the menu shows after the arrow: the output format or the tool.
        var targetName: String { targetTitle.hasPrefix("Converting to ") ? String(targetTitle.dropFirst(14)) : targetTitle }
    }

    var onChange: (() -> Void)?
    private(set) var activeTasks: [Record] = []
    /// Keeps each progress panel alive until it closes, so its buttons keep working.
    private var openPanels: [UUID: OperationProgressWindowController] = [:]

    /// Runs `work` for each URL (or once for the whole batch), showing one progress panel.
    func run(title: String, urls: [URL], batch: Bool = false,
             work: @escaping (_ urls: [URL], _ progress: @escaping (Double) -> Void) async throws -> [URL]) {
        let source = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let record = Record(id: UUID(), sourceName: source, targetTitle: title)
        activeTasks.append(record)
        onChange?()
        let groups: [[URL]] = batch ? [urls] : urls.map { [$0] }
        let panel = OperationProgressWindowController(title: title, itemCount: groups.count)
        openPanels[record.id] = panel
        panel.onClose = { [weak self] in self?.openPanels[record.id] = nil }
        panel.showWindow(nil)

        Task { @MainActor in
            var outputs: [URL] = []
            var failures: [String] = []
            for (index, group) in groups.enumerated() {
                let name = group.count == 1 ? group[0].lastPathComponent : "\(group.count) items"
                panel.model.begin(index: index, name: name)
                do {
                    let result = try await work(group) { fraction in
                        Task { @MainActor in panel.model.update(fraction) }
                    }
                    outputs += result
                    panel.model.succeeded()
                } catch {
                    failures.append("\(name) failed: \(error.localizedDescription)")
                    panel.model.failed(failures.last!)
                }
            }
            panel.finish(outputs: outputs, failures: failures)
            activeTasks.removeAll { $0.id == record.id }
            onChange?()
        }
    }
}

/// State of one progress panel (`OperationProgressWindowController`).
@MainActor
final class OperationProgressModel {
    var title: String { didSet { onChange?() } }
    var status = "" { didSet { onChange?() } }
    var fraction: Double? { didSet { onChange?() } }
    var failures: [String] = [] { didSet { onChange?() } }
    var savedOutputs: [URL] = []
    var finished = false { didSet { onChange?() } }
    var onChange: (() -> Void)?
    let itemCount: Int
    private var completed = 0
    private var saved = 0

    init(title: String, itemCount: Int) {
        self.title = title
        self.itemCount = itemCount
        status = itemCount == 1 ? "Preparing…" : "Preparing \(itemCount) files…"
    }

    func begin(index: Int, name: String) {
        status = itemCount > 1 ? "\(saved) of \(itemCount) saved" : name
        fraction = completed == 0 && itemCount == 1 ? nil : Double(completed) / Double(max(itemCount, 1))
    }

    func update(_ itemFraction: Double) {
        fraction = (Double(completed) + max(0, min(1, itemFraction))) / Double(max(itemCount, 1))
    }

    func succeeded() {
        completed += 1
        saved += 1
        fraction = Double(completed) / Double(max(itemCount, 1))
        status = "\(saved) of \(itemCount) saved"
    }

    func failed(_ message: String) {
        completed += 1
        failures.append(message)
        fraction = Double(completed) / Double(max(itemCount, 1))
    }
}

/// Orange 5 pt bar on a faint track (`OrangeIndeterminateProgressView`): determinate width is
/// `fraction × width`; indeterminate is a `max(0.28 × width, 48)` segment sweeping in 1.15 s.
final class OrangeProgressBarView: NSView {
    private let barLayer = CALayer()
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    var fractionCompleted: Double? { didSet { updateFill(animated: true) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        barLayer.masksToBounds = true
        barLayer.cornerRadius = 2.5
        fillLayer.cornerRadius = 2.5
        barLayer.addSublayer(trackLayer)
        barLayer.addSublayer(fillLayer)
        layer?.addSublayer(barLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            fillLayer.backgroundColor = SatsumaColor.accent.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = CGRect(x: 0, y: (bounds.height - 5) / 2, width: bounds.width, height: 5)
        trackLayer.frame = barLayer.bounds
        applyColors()
        CATransaction.commit()
        updateFill(animated: false)
    }

    private func updateFill(animated: Bool) {
        let width = barLayer.bounds.width
        guard width > 0 else { return }
        if let fraction = fractionCompleted {
            fillLayer.removeAnimation(forKey: "sweep")
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(0.2)
            fillLayer.frame = CGRect(x: 0, y: 0, width: width * max(0, min(1, fraction)), height: 5)
            CATransaction.commit()
        } else {
            let fillWidth = max(width * 0.28, 48)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.frame = CGRect(x: -fillWidth, y: 0, width: fillWidth, height: 5)
            CATransaction.commit()
            guard fillLayer.animation(forKey: "sweep") == nil else { return }
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -fillWidth / 2
            sweep.toValue = width + fillWidth / 2
            sweep.duration = 1.15
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sweep.repeatCount = .infinity
            fillLayer.add(sweep, forKey: "sweep")
        }
    }
}

/// Floating progress panel: 360×108 non-activating panel on glass with radius 24,
/// header [close, title, spacer] and body [status, bar, errors].
@MainActor
final class OperationProgressWindowController: NSWindowController {
    let model: OperationProgressModel
    var onClose: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let bar = OrangeProgressBarView()
    private let errorScroll = NSScrollView()
    private let errorText = NSTextView()
    private var errorHeight: NSLayoutConstraint!
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let headerSpacer = NSView()
    private static let width: CGFloat = 360

    init(title: String, itemCount: Int) {
        model = OperationProgressModel(title: title, itemCount: itemCount)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 108),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.contentView = buildContent()
        model.onChange = { [weak self] in self?.render() }
        render()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose?() }
        }
        // Near the pointer, where the wheel was.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - Self.width / 2, y: mouse.y + 40)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - 120)
        }
        panel.setFrameOrigin(origin)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildContent() -> NSView {
        let root: NSView
        if #available(macOS 26.0, *), !DebugRender.active {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 24
            let container = NSView()
            glass.contentView = container
            root = glass
            return populate(container, root: root)
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 24
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return populate(effect, root: effect)
    }

    private func populate(_ container: NSView, root: NSView) -> NSView {
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close window")!,
                             target: self, action: #selector(closeAction))
        close.bezelStyle = .circular
        close.controlSize = .small
        close.contentTintColor = .labelColor
        close.toolTip = "Close window"
        close.setAccessibilityLabel("Close window")
        NSLayoutConstraint.activate([close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24)])

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.widthAnchor.constraint(equalToConstant: 24).isActive = true
        revealButton.target = self
        revealButton.action = #selector(revealAction)
        revealButton.bezelStyle = .push
        revealButton.controlSize = .small
        revealButton.isHidden = true

        let header = NSStackView(views: [close, titleLabel, headerSpacer, revealButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        errorText.isEditable = false
        errorText.drawsBackground = false
        errorText.font = .systemFont(ofSize: 11)
        errorText.textColor = .systemRed
        errorText.textContainerInset = .zero
        errorText.textContainer?.lineFragmentPadding = 0
        errorText.isVerticallyResizable = true
        errorText.autoresizingMask = [.width]
        errorScroll.documentView = errorText
        errorScroll.drawsBackground = false
        errorScroll.hasVerticalScroller = true
        errorScroll.autohidesScrollers = true
        errorScroll.isHidden = true
        errorHeight = errorScroll.heightAnchor.constraint(equalToConstant: 24)
        errorHeight.isActive = true

        let body = NSStackView(views: [statusLabel, bar, errorScroll])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        for view in [header, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        for view in [statusLabel, bar, errorScroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            header.heightAnchor.constraint(equalToConstant: 24),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            body.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(backgroundClick))
        click.delegate = self
        container.addGestureRecognizer(click)
        return root
    }

    private func render() {
        let failed = !model.failures.isEmpty
        titleLabel.stringValue = model.finished && failed ? (model.savedOutputs.isEmpty ? "Couldn’t finish" : "Finished with errors") : model.title
        statusLabel.stringValue = model.status
        bar.fractionCompleted = model.fraction
        let canReveal = model.finished && !model.savedOutputs.isEmpty
        revealButton.isHidden = !canReveal
        headerSpacer.isHidden = canReveal
        guard failed, let window else { return }
        errorText.string = model.failures.joined(separator: "\n")
        errorScroll.isHidden = false
        errorText.frame.size.width = Self.width - 40
        errorText.layoutManager?.ensureLayout(for: errorText.textContainer!)
        let textHeight = ceil(errorText.layoutManager?.usedRect(for: errorText.textContainer!).height ?? 24)
        errorHeight.constant = min(max(textHeight, 24), 150)
        let height = 119 + errorHeight.constant
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: false)
    }

    override func showWindow(_ sender: Any?) { window?.orderFrontRegardless() }

    func finish(outputs: [URL], failures: [String]) {
        model.savedOutputs = outputs
        model.finished = true
        model.fraction = 1
        if failures.isEmpty {
            model.status = model.itemCount > 1 ? "\(model.itemCount) of \(model.itemCount) saved"
                : (outputs.count == 1 ? outputs[0].lastPathComponent : (outputs.isEmpty ? "Done" : "\(outputs.count) files saved"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.close() }
        } else {
            model.status = outputs.isEmpty ? "No output was saved." : "\(outputs.count) of \(model.itemCount) saved"
        }
    }

    @objc private func closeAction() { close() }
    @objc private func revealAction() { reveal() }
    @objc private func backgroundClick() { if model.finished && !model.savedOutputs.isEmpty { reveal() } }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(model.savedOutputs)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
        close()
    }

    override func close() {
        window?.orderOut(nil)
        super.close()
    }
}

extension OperationProgressWindowController: NSGestureRecognizerDelegate {
    /// The background click must not swallow clicks meant for ✕ or Show in Finder.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let content = window?.contentView, let frameView = content.superview else { return true }
        var view = frameView.hitTest(event.locationInWindow)
        while let current = view {
            if current is NSControl { return false }
            view = current.superview
        }
        return true
    }
}
