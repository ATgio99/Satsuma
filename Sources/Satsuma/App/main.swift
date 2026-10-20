import AppKit
import SwiftUI

let arguments = CommandLine.arguments
let app = NSApplication.shared

/// Offscreen snapshots can't draw Liquid Glass; views check this to fall back to plain materials.
enum DebugRender {
    static var active = false

    /// Draws `view` on a flat backdrop (padding 24) and writes a PNG.
    @MainActor static func snapshot(_ view: NSView, to url: URL, dark: Bool, wait: TimeInterval = 1.2) {
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: view.frame.width + 48, height: view.frame.height + 48))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
                                                : NSColor(srgbRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)).cgColor
        backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame.origin = CGPoint(x: 24, y: 24)
        backdrop.addSubview(view)
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = backdrop
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        backdrop.layoutSubtreeIfNeeded()
        let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

if arguments.count >= 5, arguments[1] == "--render-wheel" {
    // Debug: Satsuma --render-wheel <out.png> <conversions|fileTools|fileActions> <file>... [--highlight N] [--metallic]
    MainActor.assumeIsolated {
        SettingsModel.shared.conversionFanTheme = arguments.contains("--metallic") ? .metallic : .glass
        let mode: ConversionFanMode = ["fileTools": .fileTools, "fileActions": .fileActions][arguments[3]] ?? .conversions
        let files = arguments[4...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        let controller = ConversionOverlayController()
        controller.configure(urls: files, mode: mode)
        let view = controller.overlayView
        view.model.allowsLiquidGlass = false
        view.model.visualTheme = SettingsModel.shared.conversionFanTheme
        view.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        if let index = arguments.firstIndex(of: "--highlight"), let slot = Int(arguments[index + 1]), slot < view.actions.count {
            view.model.highlightedSlot = slot
            view.model.centerLabelText = view.actions[slot].centerTitle
            view.model.centerLabelUsesCompactStyle = view.actions[slot].symbolName != nil
        }
        view.model.introRequest += 1
        // `--at T` snapshots the open animation T seconds in; `--closing T` the close animation.
        func seconds(after flag: String) -> TimeInterval? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? TimeInterval(arguments[$0 + 1]) : nil }
        }
        if let closing = seconds(after: "--closing") {
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            view.model.chosenSlot = view.model.highlightedSlot
            _ = view.playOutro()
            RunLoop.main.run(until: Date().addingTimeInterval(closing))
        } else {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds(after: "--at") ?? 1.2))
        }
        view.layoutSubtreeIfNeeded()
        let backdrop = NSView(frame: view.bounds.insetBy(dx: -20, dy: -20))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = (arguments.contains("--dark") ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1)).cgColor
        view.frame.origin = CGPoint(x: 20, y: 20)
        backdrop.addSubview(view)
        let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[2]))
        print(view.actions.map(\.title).joined(separator: " "))
        exit(0)
    }
} else if arguments.count >= 5, arguments[1] == "--render-tool" {
    // Debug: Satsuma --render-tool <tool> <out.png> <file>...
    MainActor.assumeIsolated {
        guard let tool = FileTool.allCases.first(where: { "\($0)" == arguments[2] }) else { exit(2) }
        let context = ToolContext(tool: tool, urls: arguments[4...].map { URL(fileURLWithPath: $0) })
        let size = ToolWindowManager.defaultSize(for: tool)
        let host = NSHostingView(rootView: ToolRootView(context: context).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arguments[3]))
        exit(0)
    }
} else if arguments.count >= 4, arguments[1] == "--render-ui" {
    // Debug: Satsuma --render-ui <welcome N|settings Tab|float [--expanded] [--list] file…|progress [done|errors]> <out.png> [--dark]
    DebugRender.active = true
    MainActor.assumeIsolated {
        let kind = arguments[2], out = URL(fileURLWithPath: arguments[3])
        let extra = Array(arguments.dropFirst(4)), dark = extra.contains("--dark")
        let files = extra.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        switch kind {
        case "welcome":
            let page = OnboardingView.Page(rawValue: Int(extra.first ?? "") ?? 0) ?? .welcome
            let host = NSHostingView(rootView: OnboardingView(settings: .shared, page: page, onDismiss: {}))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 452)
            DebugRender.snapshot(host, to: out, dark: dark, wait: 2.5)
        case "settings":
            let tab = SettingsTab.allCases.first { $0.rawValue.lowercased() == extra.first?.lowercased() } ?? .general
            let host = NSHostingView(rootView: SettingsTabView(tab: tab, model: .shared).background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height - 52)
            DebugRender.snapshot(host, to: out, dark: dark)
        case "float":
            let shelf = FloatShelfController()
            shelf.model.add(files)
            if extra.contains("--list") { shelf.model.viewMode = .list }
            if extra.contains("--expanded") { shelf.model.presentation = .expanded }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let content = shelf.window.contentView else { exit(2) }
            content.removeFromSuperview()
            content.frame = NSRect(origin: .zero, size: shelf.window.frame.size)
            DebugRender.snapshot(content, to: out, dark: dark, wait: 2)
        default:
            let controller = OperationProgressWindowController(title: "Converting to MP3", itemCount: extra.contains("errors") ? 3 : 1)
            controller.model.begin(index: 0, name: "Interview.wav")
            controller.model.update(0.42)
            if extra.contains("done") { controller.finish(outputs: [URL(fileURLWithPath: "/tmp/Interview.mp3")], failures: []) }
            if extra.contains("errors") {
                controller.model.succeeded()
                controller.model.failed("b.wav failed: The file couldn’t be read.")
                controller.model.failed("c.wav failed: Unsupported codec.")
                controller.finish(outputs: [URL(fileURLWithPath: "/tmp/a.mp3")],
                                  failures: ["b.wav failed: The file couldn’t be read.", "c.wav failed: Unsupported codec."])
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let window = controller.window, let content = window.contentView else { exit(2) }
            content.removeFromSuperview()
            content.frame = NSRect(origin: .zero, size: window.frame.size)
            DebugRender.snapshot(content, to: out, dark: dark)
        }
        exit(0)
    }
} else if arguments.count >= 2, arguments[1] == "--test-welcome" {
    // Debug: clicks Continue, Back and the close control of a real Welcome window with synthetic events.
    MainActor.assumeIsolated {
        app.setActivationPolicy(.accessory)
        var log: [String] = []
        var view = OnboardingView(settings: .shared, onMinimize: { log.append("minimize") }, onDismiss: { log.append("dismiss") })
        view.onPageChange = { log.append("page \($0.rawValue)") }
        let window = WelcomeWindow(rootView: view)
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        func click(_ name: String, _ x: CGFloat, _ yFromTop: CGFloat) {
            let point = NSPoint(x: x, y: window.frame.height - yFromTop)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            print(name, "→", log.isEmpty ? "nothing" : log.joined(separator: ", "))
            log.removeAll()
        }
        let s = OnboardingView.scale, r = OnboardingView.canvas.height / 2
        click("Continue (welcome)", 437.5 * s, 408 * s)
        click("Continue (converter)", (525 + 84.5) * s, 393 * s)
        click("Back (tools)", (525 + 20) * s, 145 * s)
        let angle = -120.0 * .pi / 180
        click("Close", (r + (r - 40) * cos(angle)) * s, (r + (r - 40) * sin(angle)) * s)
        exit(0)
    }
} else if arguments.count >= 2, arguments[1] == "--test-progress" {
    // Debug: clicks ✕ on a finished-with-errors progress panel with synthetic events.
    MainActor.assumeIsolated {
        app.setActivationPolicy(.accessory)
        let panel = OperationProgressWindowController(title: "Converting to Pages", itemCount: 1)
        panel.showWindow(nil)
        panel.finish(outputs: [], failures: ["test.pdf failed: synthetic error"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let window = panel.window else { exit(2) }
        let point = NSPoint(x: 16 + 12, y: window.frame.height - 14 - 12)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("Close (errors) →", window.isVisible ? "still open" : "closed")
        exit(window.isVisible ? 1 : 0)
    }
} else if arguments.count >= 4, arguments[1] == "--convert" || arguments[1] == "--tool" {
    // Headless mode for scripted checks: Satsuma --convert <file> <format> | --tool <tool> <file>...
    Task { @MainActor in
        do {
            if arguments[1] == "--convert" {
                guard let format = ConversionFormat(rawValue: arguments[3]) else { throw ConversionError.unsupportedSource }
                let output = try await ConversionEngine.convert(URL(fileURLWithPath: arguments[2]), to: format,
                                                                options: SettingsModel.shared.defaultOptions) { _ in }
                print(output.path)
            } else {
                guard let tool = FileTool.allCases.first(where: { "\($0)" == arguments[2] }) else { throw ConversionError.unsupportedSource }
                let urls = arguments[3...].map { URL(fileURLWithPath: $0) }
                let outputs = try await FileToolRunner.run(tool, urls: urls, options: SettingsModel.shared.defaultOptions) { _ in }
                outputs.forEach { print($0.path) }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
