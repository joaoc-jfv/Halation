import Testing
import AppKit
import Foundation
@testable import NitPicker

@MainActor
final class FakeSleepPrevention: SleepPrevention {
    private(set) var isActive = false
    func setActive(_ active: Bool) { isActive = active }
}

@MainActor
extension PlayerServices {
    /// Services that touch nothing outside the test: throwaway defaults, no system Now Playing, no sleep assertion.
    static func testing(
        preferences: Preferences = TestPreferences.make(),
        nowPlaying: NullNowPlaying = NullNowPlaying(),
        sleep: FakeSleepPrevention = FakeSleepPrevention(),
        resume: ResumeStore = ResumeStore(defaults: throwawayDefaults()),
        recents: RecentFiles = RecentFiles(defaults: throwawayDefaults()),
        thumbnails: ThumbnailCache = ThumbnailCache(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-posters-\(UUID().uuidString)")
        )
    ) -> PlayerServices {
        PlayerServices(
            preferences: preferences, folderAccess: FolderAccess(defaults: throwawayDefaults()),
            nowPlaying: nowPlaying, resume: resume, recents: recents, sleep: sleep, thumbnails: thumbnails
        )
    }
}

func throwawayDefaults() -> UserDefaults {
    UserDefaults(suiteName: "nitpicker-tests-\(UUID().uuidString)")!
}

/// A scripted engine: tests push events and read back what the model asked for.
@MainActor
final class FakeEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    let videoView = NSView()
    var info = MediaInfo(container: "MP4", engineName: "Fake")
    var duration: Duration = .seconds(1000)
    var currentTime: Duration = .zero
    var isPictureInPictureAvailable = true
    var isHDRPlaybackEligible = true
    private(set) var thumbnailRequests: [Duration] = []
    private(set) var isPlaying = false
    private(set) var seeks: [Duration] = []
    private(set) var closed = false
    private(set) var pictureInPictureToggles = 0
    var thumbnailImage: CGImage?

    var rate: Float = 1
    var volume: Float = 1
    var isMuted = false
    var stretchesVideoToFrame = false
    var audioOutputMode: AudioOutputMode = .spatial
    var preferredAudioLanguage: String?
    let capabilities = EngineCapabilities(supportsPictureInPicture: true, supportsDolbyVision: false, supportsSpatialAudio: false)
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var selectedAudioTrack: MediaTrack?
    var selectedSubtitleTrack: MediaTrack?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
    }

    func emit(_ event: PlaybackEvent) { continuation.yield(event) }

    /// Moves the playhead and tells the model.
    func advance(to time: Duration) {
        currentTime = time
        emit(.timeChanged(time))
    }

    /// When set, `load` throws it (an engine that refuses the file).
    var loadError: (any Error)?
    private(set) var loadedURLs: [URL] = []

    func load(_ url: URL, startAt: Duration?) async throws {
        loadedURLs.append(url)
        if let loadError { throw loadError }
        emit(.durationChanged(duration))
        emit(.mediaInfoChanged(info))
        emit(.tracksChanged)
        emit(.stateChanged(.ready))
    }

    func play() { isPlaying = true; emit(.stateChanged(.playing)) }
    func pause() { isPlaying = false; emit(.stateChanged(.paused)) }
    func seek(to time: Duration, precise: Bool) async { seeks.append(time); advance(to: time) }
    func step(frames: Int) {}
    func selectAudio(_ track: MediaTrack?) { selectedAudioTrack = track }
    func selectSubtitle(_ track: MediaTrack?) { selectedSubtitleTrack = track }
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        thumbnailRequests.append(time)
        return thumbnailImage
    }
    func togglePictureInPicture() {
        pictureInPictureToggles += 1
        emit(.pictureInPictureChanged(pictureInPictureToggles % 2 == 1))
    }
    func close() { closed = true; continuation.finish() }
}

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
