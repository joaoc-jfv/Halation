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

    /// The cues of a text subtitle track the engine reads itself and the app draws over the video (MKV subtitles), found so far.
    /// Nil for a track the engine renders natively.
    func subtitleCues(for track: MediaTrack) -> SubtitleCueList?

    /// Whether the engine draws the selected subtitle track itself (mpv does, including styled ASS and image formats), so the
    /// app's own overlay has nothing to show for it but the delay, style and position still apply to the engine.
    var drawsSubtitlesNatively: Bool { get }
    /// Positive shows subtitles later. Only for engines that draw them.
    func setSubtitleDelay(_ delay: Duration)
    /// The user's subtitle size, background and position, for engines that draw plain-text subtitles themselves.
    func setSubtitleStyle(_ style: SubtitleStyle)
    /// How far above the bottom of the video the subtitles should sit, as a fraction of its height, so they clear the controls.
    func setSubtitleLift(_ fraction: Double)
    /// Loads a subtitle file the engine draws itself (ASS, SSA, SUP, VobSub) so it joins `subtitleTracks`. Returns the new track, or
    /// nil if the engine can't. The caller selects it.
    func addExternalSubtitle(_ url: URL, title: String?, language: String?) -> MediaTrack?

    /// A still from around `time`, no larger than `maxSize`, for artwork and scrub previews. Nil if none could be made.
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage?

    /// Whether this Mac's display and setup can currently show HDR (it can change when displays do).
    var isHDRPlaybackEligible: Bool { get }

    /// Whether the system can show this engine's video in a floating Picture in Picture window.
    var isPictureInPictureAvailable: Bool { get }
    func togglePictureInPicture()

    /// `true` stretches the picture to fill the video view's frame (an aspect-ratio override);
    /// `false` keeps its own aspect ratio inside the frame.
    var stretchesVideoToFrame: Bool { get set }

    /// Which audio track to start with, for engines that must pick one before playback starts (the remux engine).
    var preferredAudioLanguage: String? { get set }

    var audioOutputMode: AudioOutputMode { get set }
    var capabilities: EngineCapabilities { get }
    /// Whether this is the libmpv engine, which plays what the others can't and has no Dolby Vision or system Spatial Audio.
    var isCompatibilityEngine: Bool { get }
    func close()
}

extension PlaybackEngine {
    func subtitleCues(for track: MediaTrack) -> SubtitleCueList? { nil }
    var drawsSubtitlesNatively: Bool { false }
    var isCompatibilityEngine: Bool { false }
    func setSubtitleDelay(_ delay: Duration) {}
    func setSubtitleStyle(_ style: SubtitleStyle) {}
    func setSubtitleLift(_ fraction: Double) {}
    func addExternalSubtitle(_ url: URL, title: String?, language: String?) -> MediaTrack? { nil }
}
