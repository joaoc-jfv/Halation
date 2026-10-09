import AppKit
import AVFoundation

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

    private var url: URL?
    private var probe: MKVProbeResult?
    /// The audio tracks that can be copied, in file order, and the one playing.
    private var audioStreams: [ProbedStream] = []
    private var currentAudioID: Int?
    /// Whether each audio track carries Spatial Audio objects; the playing track's is known at once, the others' a moment later.
    private var spatialFlags: [Int: Bool] = [:]
    private var switchTask: Task<Void, Never>?
    /// Where playback was when a track switch began, kept until the switch lands (a second switch starts from the same place).
    private var switchResume: (time: Duration, wasPlaying: Bool)?

    private var subtitleStreams: [ProbedStream] = []
    private var selectedSubtitleID: Int?
    private let cues = SubtitleCueStore()
    private var backgroundTasks: [Task<Void, Never>] = []

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
            // A codec this engine can't copy or convert is libmpv's job; say nothing and let the model hand the file over.
            if (error as? RemuxSession.Failure)?.retryWithCompatibilityEngine == true { throw PlaybackError.needsCompatibilityMode }
            let failure = PlaybackError.loadFailed(error.localizedDescription)
            continuation.yield(.stateChanged(.failed(failure)))
            throw failure
        }
        guard !Task.isCancelled else {
            session.stop()
            throw CancellationError()
        }
        self.session = session
        self.url = url
        probe = session.probe
        audioStreams = session.probe.audio.filter { RemuxSupport.canPlayAudio(codec: $0.codec) }
        currentAudioID = session.audio?.id
        if let track = session.audioTrack, let id = session.audio?.id { spatialFlags[id] = track.isSpatial }
        subtitleStreams = session.probe.subtitles.filter { MKVSubtitleReader.isTextCodec($0.codec) }
        continuation.yield(.mediaInfoChanged(session.mediaInfo))
        continuation.yield(.tracksChanged)
        try await inner.load(session.playbackURL, startAt: startAt)
        startBackgroundWork(for: session, path: url.path)
    }

    /// Once playback is under way: read the text subtitles out of the file, and find which other audio tracks are Spatial.
    private func startBackgroundWork(for session: RemuxSession, path: String) {
        let streams = subtitleStreams
        if !streams.isEmpty {
            let cues = cues
            backgroundTasks.append(Task.detached(priority: .utility) { [weak self] in
                try? MKVSubtitleReader.read(path: path, streams: streams) { found in
                    cues.update(found)
                    Task { @MainActor in self?.continuation.yield(.tracksChanged) }
                }
                cues.markFinished()
                await MainActor.run { self?.continuation.yield(.tracksChanged) }
            })
        }
        for audio in audioStreams where audio.id != currentAudioID && audio.codec == "eac3" && spatialFlags[audio.id] == nil {
            let video = session.video, segments = session.segments
            backgroundTasks.append(Task { [weak self] in
                let spatial = await RemuxSession.detectSpatial(path: path, video: video, audio: audio, segments: segments)
                guard !Task.isCancelled, let self else { return }
                spatialFlags[audio.id] = spatial
                continuation.yield(.tracksChanged)
            })
        }
    }

    func close() {
        switchTask?.cancel()
        backgroundTasks.forEach { $0.cancel() }
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

    // MARK: Tracks

    var audioTracks: [MediaTrack] {
        audioStreams.map { RemuxSession.mediaTrack(for: $0, isSpatial: spatialFlags[$0.id] ?? false) }
    }

    var selectedAudioTrack: MediaTrack? {
        audioStreams.first { $0.id == currentAudioID }.map { RemuxSession.mediaTrack(for: $0, isSpatial: spatialFlags[$0.id] ?? false) }
    }

    var subtitleTracks: [MediaTrack] { subtitleStreams.map(Self.mediaTrack(for:)) }
    var selectedSubtitleTrack: MediaTrack? { subtitleStreams.first { $0.id == selectedSubtitleID }.map(Self.mediaTrack(for:)) }

    func selectSubtitle(_ track: MediaTrack?) {
        selectedSubtitleID = track.flatMap { track in subtitleStreams.first { Self.mediaTrack(for: $0).id == track.id }?.id }
        continuation.yield(.tracksChanged)
    }

    func subtitleCues(for track: MediaTrack) -> SubtitleCueList? {
        subtitleStreams.first { Self.mediaTrack(for: $0).id == track.id }.flatMap { cues.list(for: $0.id) } ?? SubtitleCueList([])
    }

    static func mediaTrack(for stream: ProbedStream) -> MediaTrack {
        MediaTrack(
            id: "subtitle-\(stream.id)", kind: .subtitle, language: stream.language.map(LanguageMatching.primaryLanguage),
            title: stream.title, codec: MKVSubtitleReader.displayName(forCodec: stream.codec), channels: nil,
            isDefault: stream.isDefault, isForced: stream.isForced, isSpatial: false
        )
    }

    /// Plays another audio track. Which audio is muxed is decided before AVPlayer starts, so this starts a new session
    /// with the track and reloads from the same place, resuming if playback was running. There is a brief gap.
    func selectAudio(_ track: MediaTrack?) {
        guard let track, let stream = audioStreams.first(where: { RemuxSession.mediaTrack(for: $0, isSpatial: false).id == track.id }),
              stream.id != currentAudioID, probe != nil
        else { return }
        let previous = currentAudioID
        if switchResume == nil { switchResume = (inner.currentTime, inner.isPlaying) }
        currentAudioID = stream.id
        continuation.yield(.tracksChanged)
        switchTask?.cancel()
        switchTask = Task { [weak self] in await self?.switchAudio(to: stream, revertingTo: previous) }
    }

    private func switchAudio(to stream: ProbedStream, revertingTo previous: Int?) async {
        guard let url, let probe, let resume = switchResume else { return }
        let fresh: RemuxSession
        do {
            fresh = try await RemuxSession.start(url: url, probe: probe, audioStreamID: stream.id, preferredAudioLanguage: nil)
        } catch {
            // Keep playing the track that was playing.
            if !(error is CancellationError) {
                currentAudioID = previous
                switchResume = nil
                continuation.yield(.tracksChanged)
            }
            return
        }
        guard !Task.isCancelled else { fresh.stop(); return }
        let old = session
        session = fresh
        continuation.yield(.mediaInfoChanged(fresh.mediaInfo))
        do {
            try await inner.load(fresh.playbackURL, startAt: resume.time)
        } catch {
            old?.stop()
            return  // superseded by another switch, or the inner engine has reported the failure
        }
        old?.stop()
        guard !Task.isCancelled else { return }
        switchResume = nil
        // A new item inherits the player's rate, so say outright which of the two it should be.
        if resume.wasPlaying { inner.play() } else { inner.pause() }
    }

    var audioOutputMode: AudioOutputMode { get { inner.audioOutputMode } set { inner.audioOutputMode = newValue } }
    var stretchesVideoToFrame: Bool { get { inner.stretchesVideoToFrame } set { inner.stretchesVideoToFrame = newValue } }
    var capabilities: EngineCapabilities { inner.capabilities }

    var isHDRPlaybackEligible: Bool { inner.isHDRPlaybackEligible }
    var isPictureInPictureAvailable: Bool { inner.isPictureInPictureAvailable }
    func togglePictureInPicture() { inner.togglePictureInPicture() }

    /// AVFoundation can't make stills from an HLS stream, so the keyframe at `time` is cut into a small MP4 of its own.
    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        guard let session, let clip = try? await session.stillClip(near: time) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("halation-still-\(UUID().uuidString).mp4")
        guard (try? clip.data.write(to: file)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        // The muxer keeps the keyframe's place in the file as an empty edit at the start, so the picture is there and not at zero.
        return try? await generator.image(at: (clip.keyframe + .milliseconds(50)).cmTime).image
    }
}
