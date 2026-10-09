import Foundation

/// Remembers folders the user has allowed the sandboxed app to read, so sidecar subtitles next to
/// a video can load without asking again (PLAN.md §5.3). Uses app-scoped security bookmarks.
@MainActor
final class FolderAccess {
    private static let key = "folderBookmarks"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var bookmarks: [String: Data] {
        get { defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    func remember(_ folder: URL) throws {
        let data = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        bookmarks[folder.standardizedFileURL.path] = data
    }

    /// Starts access to the closest remembered folder that contains `file`. The caller must call
    /// `stopAccessingSecurityScopedResource()` on the result when done. Nil when no folder covers it.
    func beginAccess(toFolderContaining file: URL) -> URL? {
        let filePath = file.standardizedFileURL.path
        let covering = bookmarks
            .filter { filePath.hasPrefix($0.key.hasSuffix("/") ? $0.key : $0.key + "/") }
            .max { $0.key.count < $1.key.count }
        guard let (path, data) = covering.map({ ($0.key, $0.value) }) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else {
            bookmarks[path] = nil
            return nil
        }
        if isStale { try? remember(url) }
        return url
    }
}
