import Foundation

struct ResumeRecord: Codable, Equatable {
    var path: String
    var name: String
    var size: Int64
    var position: Double
    var duration: Double
    var updated: Date
}

/// Remembers where each video stopped (PLAN.md §5.7).
@MainActor
final class ResumeStore {
    /// Nothing is saved before this point, so a quick peek doesn't count as watching.
    static let minimumPosition: Double = 30
    /// Past this share of the file counts as finished.
    static let finishedFraction = 0.97
    private static let key = "resumePositions"
    private static let limit = 300

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    private var records: [ResumeRecord] {
        get {
            defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ResumeRecord].self, from: $0) } ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(Array(newValue.suffix(Self.limit))), forKey: Self.key)
        }
    }

    /// The saved position for `url`: the same path, or a moved copy with the same name and size.
    func record(for url: URL) -> ResumeRecord? {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let size = Self.size(of: url)
        let all = records
        return all.first { $0.path == path } ?? all.first { $0.name == name && size != nil && $0.size == size }
    }

    /// Records progress. Under 30 s in changes nothing (an earlier record stays, so a resume offer
    /// can still be taken); within the last 3% the record is dropped as finished.
    func update(url: URL, position: Double, duration: Double) {
        guard duration > 0, position.isFinite else { return }
        if position >= duration * Self.finishedFraction {
            remove(url)
        } else if position >= Self.minimumPosition {
            save(url: url, position: position, duration: duration)
        }
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        records = records.filter { $0.path != path }
    }

    func removeAll() {
        records = []
    }

    private func save(url: URL, position: Double, duration: Double) {
        let path = url.standardizedFileURL.path
        var all = records.filter { $0.path != path }
        all.append(ResumeRecord(
            path: path, name: url.lastPathComponent, size: Self.size(of: url) ?? 0,
            position: position, duration: duration, updated: now()
        ))
        records = all
    }

    /// Whether a saved record is worth offering: it must still be in the middle of the file.
    static func isOfferable(_ record: ResumeRecord) -> Bool {
        record.position >= minimumPosition && record.position < record.duration * finishedFraction
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
