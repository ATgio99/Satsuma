import AppKit
import Combine

/// Folders the user allowed from Welcome or Settings → Folders (`FolderAccessStore`), kept as bookmarks.
final class FolderAccessStore: ObservableObject {
    static let shared = FolderAccessStore()
    private static let key = "folderAccess.bookmarks"
    private let defaults: UserDefaults

    @Published private(set) var folders: [URL] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = (defaults.array(forKey: Self.key) as? [Data] ?? []).compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    /// True when the home folder, or a folder that contains it (e.g. /Users), is allowed.
    var homeFolderAllowed: Bool { folders.contains { Self.covers($0, FileManager.default.homeDirectoryForCurrentUser) } }

    static func covers(_ folder: URL, _ item: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = item.standardizedFileURL.resolvingSymlinksInPath().path
        return itemPath == folderPath || itemPath.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }

    /// Open panel at `directory` with the "Allow Access" prompt; returns whether a folder was added.
    @discardableResult
    func requestAccess(startingAt directory: URL? = nil, message: String? = nil) -> Bool {
        requestFolder(startingAt: directory, message: message) != nil
    }

    /// Runs the panel and returns the allowed folder, or nil when cancelled.
    func requestFolder(startingAt directory: URL? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow Access"
        panel.message = message ?? "Choose a folder where Satsuma can save conversion results."
        panel.directoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        add(url)
        return url
    }

    /// Opens the panel already inside the home folder, so "Allow Access" grants it with one click.
    /// Returns the folder the user allowed (any folder counts), or nil when cancelled.
    func requestHomeFolderAccess() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let url = requestFolder(startingAt: home, message: "Click Allow Access to let Satsuma save next to your files.") else { return nil }
        // Reading the protected folders now lets macOS ask once instead of during a conversion.
        if Self.covers(url, home) {
            for name in ["Desktop", "Documents", "Downloads"] {
                _ = try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(name).path)
            }
        }
        return url
    }

    func add(_ url: URL) {
        guard !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        folders.append(url)
        save()
    }

    func replace(_ old: URL, with new: URL) {
        guard let index = folders.firstIndex(of: old) else { return add(new) }
        folders[index] = new
        save()
    }

    func remove(_ url: URL) {
        folders.removeAll { $0 == url }
        save()
    }

    private func save() {
        defaults.set(folders.compactMap { try? $0.bookmarkData() }, forKey: Self.key)
    }
}
