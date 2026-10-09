import AppKit
import Observation

/// UI-facing playback state. The UI talks only to this type; engines stay behind it.
@MainActor
@Observable
final class PlayerModel {
    private(set) var state: PlaybackState = .idle
    private(set) var currentURL: URL?
    private(set) var currentTime: Duration = .zero
    private(set) var duration: Duration = .zero
    private(set) var buffered: Duration = .zero
    private(set) var isBuffering = false
    private(set) var mediaInfo: MediaInfo?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudio: MediaTrack?
    private(set) var selectedSubtitle: MediaTrack?
    private(set) var videoView: NSView?

    private(set) var rate: Float = 1
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var audioOutputMode: AudioOutputMode = .spatial

    // UI-only state
    private(set) var controlsVisible = true
    private(set) var isPointerOverControls = false
    private(set) var toast: Toast?

    var isPlaying: Bool { state == .playing }
    var hasMedia: Bool { currentURL != nil }
    var errorMessage: String? {
        if case .failed(let error) = state { error.localizedDescription } else { nil }
    }

    @ObservationIgnored private var engine: (any PlaybackEngine)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastActivity = ContinuousClock.now

    /// How long the controls stay up without mouse or keyboard activity while playing.
    @ObservationIgnored var autoHideDelay: Duration = .seconds(2.5)
    @ObservationIgnored var toastDuration: Duration = .seconds(1.2)

    // MARK: Opening

    func open(_ url: URL) {
        openTask?.cancel()
        openTask = Task { await performOpen(url) }
    }

    func close() {
        openTask?.cancel()
        teardown()
        currentURL = nil
    }

    private func performOpen(_ url: URL) async {
        teardown()
        currentURL = url
        state = .loading
        if url.startAccessingSecurityScopedResource() { scopedURL = url }

        do {
            let engine = try EngineRouter.engine(for: url)
            attach(engine)
            try await engine.load(url, startAt: nil)
            try Task.checkCancellation()
            engine.play()
        } catch is CancellationError {
            // Superseded by another open().
        } catch {
            // The engine reports its own failures through events; this covers the router.
            if !Task.isCancelled, case .loading = state {
                state = .failed(error as? PlaybackError ?? .loadFailed(error.localizedDescription))
            }
        }
    }

    private func attach(_ engine: any PlaybackEngine) {
        self.engine = engine
        videoView = engine.videoView
        engine.rate = rate
        engine.volume = volume
        engine.isMuted = isMuted
        engine.audioOutputMode = audioOutputMode
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    private func teardown() {
        eventTask?.cancel()
        eventTask = nil
        engine?.close()
        engine = nil
        videoView = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        state = .idle
        cancelHideTimer()
        controlsVisible = true
        currentTime = .zero
        duration = .zero
        buffered = .zero
        isBuffering = false
        mediaInfo = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudio = nil
        selectedSubtitle = nil
    }

    private func handle(_ event: PlaybackEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            // A new state counts as activity: paused shows the controls, playing starts the countdown.
            registerActivity()
        case .timeChanged(let time): currentTime = time
        case .durationChanged(let newDuration): duration = newDuration
        case .bufferingChanged(let buffering): isBuffering = buffering
        case .bufferedChanged(let end): buffered = end
        case .mediaInfoChanged(let info): mediaInfo = info
        case .tracksChanged:
            guard let engine else { return }
            audioTracks = engine.audioTracks
            subtitleTracks = engine.subtitleTracks
            selectedAudio = engine.selectedAudioTrack
            selectedSubtitle = engine.selectedSubtitleTrack
        }
    }

    // MARK: Transport

    func play() { engine?.play() }
    func pause() { engine?.pause() }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to time: Duration, precise: Bool = false) {
        let clamped = min(max(time, .zero), duration)
        currentTime = clamped
        guard let engine else { return }
        Task { await engine.seek(to: clamped, precise: precise) }
    }

    func skip(by offset: Duration) {
        seek(to: currentTime + offset)
    }

    func stepFrame(forward: Bool) {
        engine?.step(frames: forward ? 1 : -1)
    }

    // MARK: Controls visibility

    private var shouldKeepControlsVisible: Bool { !isPlaying || isPointerOverControls }

    /// Call on mouse movement or any key. Shows the controls and restarts the auto-hide countdown.
    func registerActivity() {
        lastActivity = .now
        controlsVisible = true
        startHideTimerIfNeeded()
    }

    func setPointerOverControls(_ isOver: Bool) {
        guard isOver != isPointerOverControls else { return }
        isPointerOverControls = isOver
        if isOver { cancelHideTimer() }
        registerActivity()
    }

    private func startHideTimerIfNeeded() {
        guard hideTask == nil, !shouldKeepControlsVisible else { return }
        hideTask = Task {
            // Mouse movement only moves `lastActivity`, so this loop re-sleeps instead of restarting.
            while !Task.isCancelled {
                let deadline = lastActivity + autoHideDelay
                guard ContinuousClock.now < deadline else { break }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            hideTask = nil
            if !shouldKeepControlsVisible { controlsVisible = false }
        }
    }

    private func cancelHideTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: Toasts

    func showToast(_ text: String, symbol: String? = nil) {
        toast = Toast(text: text, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: toastDuration)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: Audio and rate

    func setRate(_ newRate: Float) {
        rate = min(max(newRate, 0.25), 4)
        engine?.rate = rate
    }

    func setVolume(_ newVolume: Float) {
        volume = min(max(newVolume, 0), 1)
        engine?.volume = volume
    }

    func toggleMute() {
        isMuted.toggle()
        engine?.isMuted = isMuted
    }

    func setAudioOutputMode(_ mode: AudioOutputMode) {
        audioOutputMode = mode
        engine?.audioOutputMode = mode
    }

    func selectAudio(_ track: MediaTrack?) {
        engine?.selectAudio(track)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        engine?.selectSubtitle(track)
    }
}
