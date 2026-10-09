import AppKit

/// Plays MKV (and other containers AVPlayer can't open) by copying their packets into fragmented MP4 on the fly and
/// handing AVPlayer an HLS stream from a loopback server. Playback itself is the existing `AVFoundationEngine`, so HDR,
/// Dolby Vision, Spatial Audio, tracks, Picture in Picture and the rest work exactly as they do for MP4.
@MainActor
final class RemuxEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation
    private let inner = AVFoundationEngine()
    private var session: RemuxSession?
    private var forwarding: Task<Void, Never>?
    private var currentAudioTrack: MediaTrack?

    var preferredAudioLanguage: String?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        let inner = inner
        forwarding = Task { [weak self] in
            for await event in inner.events { self?.forward(event) }
        }
    }

    /// The inner engine's media info and tracks come from an HLS asset, which AVFoundation can't describe the way it does a
    /// file (no codec, size or HDR details, and a made-up audio track), so they are dropped. The file's own come from the session.
    private func forward(_ event: PlaybackEvent) {
        switch event {
        case .mediaInfoChanged, .tracksChanged: break
        default: continuation.yield(event)
        }
    }

    // MARK: Loading

    func load(_ url: URL, startAt: Duration?) async throws {
        continuation.yield(.stateChanged(.loading))
        let session: RemuxSession
        do {
            session = try await RemuxSession.start(url: url, preferredAudioLanguage: preferredAudioLanguage)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = PlaybackError.loadFailed(error.localizedDescription)
            continuation.yield(.stateChanged(.failed(failure)))
            throw failure
        }
        guard !Task.isCancelled else {
            session.stop()
            throw CancellationError()
        }
        self.session = session
        currentAudioTrack = session.audioTrack
        continuation.yield(.mediaInfoChanged(session.mediaInfo))
        continuation.yield(.tracksChanged)
        try await inner.load(session.playbackURL, startAt: startAt)
    }

    func close() {
        inner.close()
        session?.stop()
        session = nil
        forwarding?.cancel()
        continuation.finish()
    }

    // MARK: Everything else is the inner engine's

    var videoView: NSView { inner.videoView }
    func play() { inner.play() }
    func pause() { inner.pause() }
    func seek(to time: Duration, precise: Bool) async { await inner.seek(to: time, precise: precise) }
    func step(frames: Int) { inner.step(frames: frames) }
    var currentTime: Duration { inner.currentTime }

    var rate: Float { get { inner.rate } set { inner.rate = newValue } }
    var volume: Float { get { inner.volume } set { inner.volume = newValue } }
    var isMuted: Bool { get { inner.isMuted } set { inner.isMuted = newValue } }

    // One audio track is remuxed, chosen before playback starts. Switching tracks and subtitles come with milestone 2.3.
    var audioTracks: [MediaTrack] { currentAudioTrack.map { [$0] } ?? [] }
    var subtitleTracks: [MediaTrack] { [] }
    var selectedAudioTrack: MediaTrack? { currentAudioTrack }
    var selectedSubtitleTrack: MediaTrack? { nil }
    func selectAudio(_ track: MediaTrack?) {}
    func selectSubtitle(_ track: MediaTrack?) {}

    var audioOutputMode: AudioOutputMode { get { inner.audioOutputMode } set { inner.audioOutputMode = newValue } }
    var stretchesVideoToFrame: Bool { get { inner.stretchesVideoToFrame } set { inner.stretchesVideoToFrame = newValue } }
    var capabilities: EngineCapabilities { inner.capabilities }

    var isHDRPlaybackEligible: Bool { inner.isHDRPlaybackEligible }
    var isPictureInPictureAvailable: Bool { inner.isPictureInPictureAvailable }
    func togglePictureInPicture() { inner.togglePictureInPicture() }

    /// AVFoundation can't make stills from an HLS stream; MKV thumbnails come later.
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? { nil }
}
