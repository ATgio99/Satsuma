import AppKit
import QuickLookThumbnailing

/// The actions wheel (`FileClipboardController`, `FileMoveAction`, `TerminalFileAction`, `AirDropSharingController`).
@MainActor
enum FileActions {
    static func copy(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    static func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func move(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a destination folder for \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        var failures: [String] = []
        for url in urls {
            if destination.path.hasPrefix(url.path + "/") || destination == url {
                failures.append("Choose a destination outside \(url.lastPathComponent).")
                continue
            }
            let target = OutputNaming.unique(destination.appendingPathComponent(url.lastPathComponent))
            do { try FileManager.default.moveItem(at: url, to: target) } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "The move was not completed."
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    static func openTerminal(_ urls: [URL]) {
        let folders = Set(urls.map { url -> URL in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        })
        let bundleID = UserDefaults.standard.string(forKey: SettingsModel.Key.terminalApp) ?? "com.apple.Terminal"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(Array(folders), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static var sharingDelegates: [AirDropDelegate] = []

    static func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            let alert = NSAlert()
            alert.messageText = "AirDrop isn't available for these items."
            alert.runModal()
            return
        }
        let delegate = AirDropDelegate()
        delegate.onFinish = { [weak delegate] in sharingDelegates.removeAll { $0 === delegate } }
        sharingDelegates.append(delegate)
        service.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
        var onFinish: (() -> Void)?
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { onFinish?() }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { onFinish?() }
    }
}
