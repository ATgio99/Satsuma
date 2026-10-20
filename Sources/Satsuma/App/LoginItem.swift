import AppKit
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`, on by default from the first launch.
enum LoginItem {
    private static let defaultAppliedKey = "launchAtLogin.defaultApplied"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Registers the app once, the first time it runs from an app bundle. Turning it off later sticks.
    static func applyDefault(_ defaults: UserDefaults = .standard) {
        guard Bundle.main.bundleURL.pathExtension == "app", !defaults.bool(forKey: defaultAppliedKey) else { return }
        defaults.set(true, forKey: defaultAppliedKey)
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Launch at login: %@", error.localizedDescription) }
        return isEnabled
    }
}
