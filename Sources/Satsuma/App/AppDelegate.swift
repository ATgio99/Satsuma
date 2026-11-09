import AppKit
import SwiftUI
import ServiceManagement
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsModel.shared
    private var overlayController: ConversionOverlayController?
    private var dragGestureMonitor: DragGestureMonitor?
    private let taskStore = ConversionTaskStore()
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    /// Launch: menu bar, drag monitor and, on first run, the Welcome window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Monitoring drag-to-convert gestures")
        LoginItem.applyDefault()
        menuBarController = MenuBarController(taskStore: taskStore,
                                              openSettings: { [weak self] in self?.showSettings() },
                                              openWelcome: { [weak self] in self?.showWelcome() })
        let monitor = DragGestureMonitor(settings: settings) { [unowned self] in self.overlay() }
        monitor.start()
        dragGestureMonitor = monitor
        if !settings.didFinishWelcome { showWelcome() }
        // Debug: open windows straight away (`--show-welcome`, `--show-settings [tab]`).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--show-settings") {
            showSettings()
            let name = arguments.indices.contains(index + 1) ? arguments[index + 1].lowercased() : ""
            if let tab = SettingsTab.allCases.firstIndex(where: { $0.rawValue.lowercased() == name }),
               let tabs = settingsWindow?.contentViewController as? NSTabViewController {
                tabs.selectedTabViewItemIndex = tab
            }
        }
        if arguments.contains("--show-welcome") { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) { dragGestureMonitor?.stop() }

    /// Opening Satsuma while it runs (Finder, Spotlight, Dock) shows Settings, the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    private func overlay() -> ConversionOverlayController {
        if let overlayController { return overlayController }
        let controller = ConversionOverlayController()
        controller.onDrop = { [weak self] urls, action in self?.perform(action, on: urls) }
        overlayController = controller
        return controller
    }

    // MARK: Actions

    func perform(_ action: ConversionFanAction, on urls: [URL]) {
        switch action {
        case .convert(let format):
            let options = settings.defaultOptions
            taskStore.run(title: "Converting to \(format.title)", urls: urls) { group, progress in
                [try await ConversionEngine.convert(group[0], to: format, options: options, progress: progress)]
            }
        case .fileTool(let tool):
            if tool.opensOptionsWindow {
                ToolWindowManager.shared.taskStore = taskStore
                ToolWindowManager.shared.open(tool, urls: urls)
                return
            }
            let batchTools: Set<FileTool> = [.createPDF, .mergePDF, .joinVideos, .createCollage, .readQRCode]
            let options = settings.defaultOptions
            let progressTitle = tool == .convertPDFA ? "Converting to PDF/A-2b" : tool.title.capitalized
            taskStore.run(title: progressTitle, urls: urls, batch: batchTools.contains(tool)) { group, progress in
                try await FileToolRunner.run(tool, urls: group, options: options, progress: progress)
            }
        case .airDrop: FileActions.airDrop(urls)
        case .float: FloatShelfController.float(urls)
        case .copy: FileActions.copy(urls)
        case .move: FileActions.move(urls)
        case .copyPath: FileActions.copyPaths(urls)
        case .openTerminal: FileActions.openTerminal(urls)
        }
    }

    private func showNotice(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowFactory.makeWindow(model: settings)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = OnboardingView(settings: settings, onMinimize: { [weak self] in
                self?.welcomeWindow?.miniaturize(nil)
            }, onDismiss: { [weak self] in
                self?.settings.didFinishWelcome = true
                self?.welcomeWindow?.close()
            })
            welcomeWindow = WelcomeWindow(rootView: view)
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.center()
        welcomeWindow?.makeKeyAndOrderFront(nil)
        welcomeWindow?.invalidateShadow()
    }
}

/// Status item and menu (`MenuBarController`, rebuilt on every open):
/// status line, shortcut summary, active tasks, Settings / Getting Started / About, Quit.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let taskStore: ConversionTaskStore
    private let openSettings: () -> Void
    private let openWelcome: () -> Void
    private var visibility: AnyCancellable?

    init(taskStore: ConversionTaskStore, openSettings: @escaping () -> Void, openWelcome: @escaping () -> Void) {
        self.taskStore = taskStore
        self.openSettings = openSettings
        self.openWelcome = openWelcome
        super.init()
        if let button = statusItem.button {
            button.image = MenuBarIcon.image()
            button.setAccessibilityLabel("Satsuma")
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        visibility = SettingsModel.shared.$showMenuBarIcon.sink { [weak self] in self?.statusItem.isVisible = $0 }
        taskStore.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()
        let working = !taskStore.activeTasks.isEmpty
        menu.addItem(disabled(working ? "Satsuma is working" : "Satsuma is ready",
                              symbol: working ? "arrow.triangle.2.circlepath" : "checkmark.circle"))
        let settings = SettingsModel.shared
        let summary = [(settings.conversionMask, "Convert"), (settings.toolsMask, "Tools"), (settings.actionsMask, "Actions")]
            .map { "\(DragModifierCombination(mask: $0.0).symbols): \($0.1)" }
            .joined(separator: " · ")
        let shortcuts = disabled(summary, symbol: nil)
        shortcuts.indentationLevel = 1
        menu.addItem(shortcuts)

        if working {
            menu.addItem(.separator())
            menu.addItem(disabled("Active Tasks", symbol: nil))
            for task in taskStore.activeTasks {
                let row = disabled("\(task.sourceName)  →  \(task.targetName)", symbol: "arrow.right")
                row.indentationLevel = 1
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        let login = item(LoginItem.needsApproval ? "Launch at Login (needs approval…)" : "Launch at Login",
                         #selector(loginAction), "", symbol: nil)
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Settings…", #selector(settingsAction), ",", symbol: "gearshape"))
        menu.addItem(item("Getting Started…", #selector(welcomeAction), "", symbol: "sparkles"))
        menu.addItem(item("About Satsuma…", #selector(aboutAction), "", symbol: nil))
        menu.addItem(.separator())
        menu.addItem(item("Quit Satsuma", #selector(quitAction), "q", symbol: nil))
    }

    private func disabled(_ title: String, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func settingsAction() { openSettings() }
    @objc private func welcomeAction() { openWelcome() }
    @objc private func loginAction() {
        if LoginItem.needsApproval { return SMAppService.openSystemSettingsLoginItems() }
        LoginItem.set(!LoginItem.isEnabled)
        if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }
    @objc private func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

/// Template menu bar icon: a small segmented wheel (Satsuma's own mark).
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 14, height: 14)  // status item image size in the binary
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.2)
            context.strokeEllipse(in: rect.insetBy(dx: 0.8, dy: 0.8))
            context.setFillColor(NSColor.black.cgColor)
            let scale = 5.4 / PetalGeometry.outerRadius
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: scale, y: scale)
            for slot in 0..<7 {
                context.addPath(PetalGeometry.petalPath(center: .zero, slot: slot, count: 7))
            }
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
