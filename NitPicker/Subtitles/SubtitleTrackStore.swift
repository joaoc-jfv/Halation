import Foundation
import Observation

/// Sidecar (external) subtitle tracks for the open file: discovery, loading, selection, delay and style.
/// The PlayerModel decides how a pick here interacts with embedded tracks.
@MainActor
@Observable
final class SubtitleTrackStore {
    struct Track: Identifiable, Equatable {
        let id: String
        var label: String
        var language: String?
        /// Where the cues came from (nil for none).
        var source: URL?
        let cues: SubtitleCueList

        static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
    }

    enum SidecarAccess: Equatable {
        /// Not looked yet.
        case unknown
        case available
        /// The sandbox won't let us list the video's folder; the user can grant access.
        case needsFolderAccess
    }

    private(set) var tracks: [Track] = []
    private(set) var selectedID: String?
    private(set) var delay: Duration = .zero
    private(set) var sidecarAccess: SidecarAccess = .unknown
    /// Sidecar files only an engine that draws subtitles itself can show (found by `discover(for:enginePaintsSubtitles:)`).
    private(set) var nativeCandidates: [SidecarSubtitles.Candidate] = []
    private(set) var style: SubtitleStyle

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let folderAccess: FolderAccess
    @ObservationIgnored private var generation = 0

    static let delayStep: Duration = .milliseconds(100)

    init(preferences: Preferences, folderAccess: FolderAccess) {
        self.preferences = preferences
        self.folderAccess = folderAccess
        style = preferences.subtitleStyle
    }

    var selected: Track? { tracks.first { $0.id == selectedID } }

    /// Forgets everything about the previous file. The delay resets per file; the style does not.
    func reset() {
        generation += 1
        tracks = []
        nativeCandidates = []
        selectedID = nil
        delay = .zero
        sidecarAccess = .unknown
    }

    // MARK: Discovery and loading

    /// Looks for subtitle files next to `media` and loads them. With `enginePaintsSubtitles`, ASS/SSA files and the image formats are
    /// left for the engine (`nativeCandidates`) so they keep their styling; otherwise ASS/SSA is read as plain text.
    func discover(for media: URL, enginePaintsSubtitles: Bool = false) async {
        let current = generation
        let scopedFolder = folderAccess.beginAccess(toFolderContaining: media)
        defer { scopedFolder?.stopAccessingSecurityScopedResource() }

        let folder = media.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            if current == generation { sidecarAccess = .needsFolderAccess }
            return
        }
        guard current == generation else { return }
        sidecarAccess = .available

        if enginePaintsSubtitles { nativeCandidates = SidecarSubtitles.nativeCandidates(forMedia: media, in: contents) }
        for candidate in SidecarSubtitles.candidates(forMedia: media, in: contents) {
            if enginePaintsSubtitles, SidecarSubtitles.nativeExtensions.contains(candidate.url.pathExtension.lowercased()) { continue }
            guard let cues = try? await Self.loadCues(from: candidate.url), current == generation else { continue }
            append(Track(id: candidate.url.path, label: candidate.label, language: candidate.language, source: candidate.url, cues: cues))
        }
    }

    /// Adds a file the user picked. Throws if it can't be read or has no cues.
    @discardableResult
    func add(fileAt url: URL) async throws -> Track {
        if let existing = tracks.first(where: { $0.id == url.path }) { return existing }
        let current = generation
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cues = try await Self.loadCues(from: url)
        guard current == generation else { throw CancellationError() }
        let candidate = SidecarSubtitles.candidates(forMedia: url.deletingPathExtension(), in: [url]).first
        let track = Track(
            id: url.path,
            label: candidate.map(\.label).flatMap { $0 == "Subtitles" ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent,
            language: candidate?.language,
            source: url,
            cues: cues
        )
        append(track)
        return track
    }

    private func append(_ track: Track) {
        guard !tracks.contains(track) else { return }
        tracks.append(track)
    }

    private nonisolated static func loadCues(from url: URL) async throws -> SubtitleCueList {
        try await Task.detached { try SubtitleLoader.load(from: url) }.value
    }

    // MARK: Selection, delay, style

    func select(_ id: String?) {
        selectedID = id.flatMap { id in tracks.contains { $0.id == id } ? id : nil }
    }

    func adjustDelay(by offset: Duration) {
        delay = (delay + offset).rounded(toStepOf: Self.delayStep)
    }

    func resetDelay() {
        delay = .zero
    }

    /// `+0.3 s`, `−1.2 s`, `0.0 s`
    var delayLabel: String {
        let tenths = Int((delay.seconds * 10).rounded())
        let magnitude = String(format: "%d.%d s", abs(tenths) / 10, abs(tenths) % 10)
        return tenths > 0 ? "+" + magnitude : tenths < 0 ? "−" + magnitude : magnitude
    }

    func setStyle(_ newStyle: SubtitleStyle) {
        style = newStyle
        preferences.subtitleStyle = newStyle
    }

    /// Cues showing at `playbackTime`, after the delay. A positive delay shows subtitles later.
    func activeCues(atPlaybackTime playbackTime: Duration) -> [SubtitleCue] {
        selected?.cues.active(at: playbackTime - delay) ?? []
    }
}

extension Duration {
    /// Rounds to the nearest multiple of `step`, so repeated nudges never drift.
    func rounded(toStepOf step: Duration) -> Duration {
        let steps = (seconds / step.seconds).rounded()
        return .seconds(steps * step.seconds)
    }
}
