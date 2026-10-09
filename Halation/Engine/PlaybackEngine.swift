import AppKit

/// Every engine conforms to this, so the UI never knows which engine is active.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Finishes when the engine is closed.
    var events: AsyncStream<PlaybackEvent> { get }
    /// View hosting the video layer.
    var videoView: NSView { get }

    /// Returns once the media is loaded and an item is attached. Playback
    /// failures after that point arrive as `.stateChanged(.failed)` events.
    func load(_ url: URL, startAt: Duration?) async throws
    func play()
    func pause()
    func seek(to time: Duration, precise: Bool) async
    /// ±1 frame while paused.
    func step(frames: Int)
    /// The playhead right now, unlike the throttled `.timeChanged` events. For subtitle timing.
    var currentTime: Duration { get }

    /// 0.25 ... 4.0
    var rate: Float { get set }
    /// 0 ... 1
    var volume: Float { get set }
    var isMuted: Bool { get set }

    var audioTracks: [MediaTrack] { get }
    /// Embedded tracks only.
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioTrack: MediaTrack? { get }
    var selectedSubtitleTrack: MediaTrack? { get }
    func selectAudio(_ track: MediaTrack?)
    /// `nil` turns subtitles off.
    func selectSubtitle(_ track: MediaTrack?)

    var audioOutputMode: AudioOutputMode { get set }
    var capabilities: EngineCapabilities { get }
    func close()
}
