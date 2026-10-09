import Foundation
import Observation

struct RecentEntry: Codable, Identifiable, Equatable {
    var path: String
    var name: String
    /// App-scoped security bookmark, so the sandbox lets us reopen the file after a relaunch.
    var bookmark: Data
    var lastOpened: Date

    var id: String { path }
}

/// The Open Recent list.
@MainActor
@Observable
final class RecentFiles {
    static let limit = 20
    private static let key = "recentFiles"

    private(set) var entries: [RecentEntry] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RecentEntry].self, from: $0) } ?? []
    }

    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        // Inside the sandbox a user-chosen file can be bookmarked; anything else is reopened by path.
        let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        entries.removeAll { $0.path == path }
        entries.insert(RecentEntry(path: path, name: url.deletingPathExtension().lastPathComponent, bookmark: bookmark, lastOpened: now()), at: 0)
        entries = Array(entries.prefix(Self.limit))
        save()
    }

    /// The file behind an entry, or nil when it no longer exists. A bookmark gives sandbox access to the
    /// file; `PlayerModel` starts its own scoped access when it opens the URL.
    func resolve(_ entry: RecentEntry) -> URL? {
        if !entry.bookmark.isEmpty {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                if stale { note(url) }
                return url
            }
        }
        let url = URL(fileURLWithPath: entry.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ entry: RecentEntry) {
        entries.removeAll { $0 == entry }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}
