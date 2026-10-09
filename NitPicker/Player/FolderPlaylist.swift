import Foundation

/// What a file name says about where it sits in a series: `Show.Name.S02E05.1080p.mkv`, `Show 2x05`, `Show - EP05`, `[Group] Show - 05 [720p]`.
struct EpisodeNumber: Equatable, Comparable, Sendable {
    /// The part of the name before the episode marker, lowercased, with punctuation squeezed out, so two files of one show match.
    var series: String
    var season: Int?
    var episode: Int

    static func < (lhs: EpisodeNumber, rhs: EpisodeNumber) -> Bool {
        (lhs.season ?? 0, lhs.episode) < (rhs.season ?? 0, rhs.episode)
    }

    /// `S02E05`, or `E05` when there is no season.
    var label: String {
        let number = String(format: "E%02d", episode)
        return season.map { String(format: "S%02d", $0) + number } ?? number
    }

    private static let patterns: [(regex: String, hasSeason: Bool)] = [
        (#"(?<![A-Za-z0-9])[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})(?![0-9])"#, true),
        (#"(?<![A-Za-z0-9])(\d{1,2})x(\d{2,3})(?![0-9A-Za-z])"#, true),
        (#"(?<![A-Za-z0-9])(?:[Ee][Pp]?|Episode[ ._-]?)(\d{1,3})(?![0-9A-Za-z])"#, false),
        // Fansub style: `Show - 05 [1080p]`, `Show - 05v2.mkv`.
        (#"\s-\s(\d{1,3})(?:v\d)?(?=\s*(?:[\[(.]|$))"#, false),
    ]

    /// Nil when the name carries no episode marker.
    static func parse(fileName: String) -> EpisodeNumber? {
        let name = (fileName as NSString).deletingPathExtension
        for (pattern, hasSeason) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let wholeRange = Range(match.range, in: name)
            else { continue }
            func number(_ group: Int) -> Int? { Range(match.range(at: group), in: name).flatMap { Int(name[$0]) } }
            let season = hasSeason ? number(1) : nil
            guard let episode = hasSeason ? number(2) : number(1) else { continue }
            let series = squeeze(String(name[..<wholeRange.lowerBound]))
            return EpisodeNumber(series: series, season: season, episode: episode)
        }
        return nil
    }

    private static func squeeze(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The videos in the open file's folder, in name order, so Next and Previous can walk them (PLAN.md phase 4).
struct FolderPlaylist: Equatable, Sendable {
    private(set) var entries: [URL]
    private(set) var index: Int

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "asf", "flv", "ogv", "ogm", "mpg", "mpeg", "ts", "m2ts", "mts",
        "3gp", "divx", "xvid", "rm", "rmvb", "vob",
    ]

    /// Nil when `current` isn't among the folder's videos or is alone in it.
    init?(current: URL, siblings: [URL]) {
        let videos = siblings.filter {
            Self.videoExtensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".")
        }
        var sorted = Set(videos.map { $0.standardizedFileURL.path }).sorted { lhs, rhs in
            (lhs as NSString).lastPathComponent.localizedStandardCompare((rhs as NSString).lastPathComponent) == .orderedAscending
        }.map { URL(fileURLWithPath: $0) }
        let currentPath = current.standardizedFileURL.path
        if !sorted.contains(where: { $0.path == currentPath }) {
            // The file the user opened may have been renamed or hidden by the listing; it still belongs at its place.
            guard Self.videoExtensions.contains(current.pathExtension.lowercased()) else { return nil }
            sorted.append(URL(fileURLWithPath: currentPath))
            sorted.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        guard sorted.count > 1, let position = sorted.firstIndex(where: { $0.path == currentPath }) else { return nil }
        entries = sorted
        index = position
    }

    var current: URL { entries[index] }
    var next: URL? { entries.indices.contains(index + 1) ? entries[index + 1] : nil }
    var previous: URL? { index > 0 ? entries[index - 1] : nil }

    /// The next file when it is a later episode of the same series as the current one, which is what "Up next" plays by itself.
    var nextEpisode: URL? {
        guard let next, let now = EpisodeNumber.parse(fileName: current.lastPathComponent),
              let following = EpisodeNumber.parse(fileName: next.lastPathComponent),
              now.series == following.series, now < following
        else { return nil }
        return next
    }

    var position: String { "\(index + 1) of \(entries.count)" }
}
