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
    private(set) var videoLayout = VideoLayout()

    private(set) var rate: Float = 1
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var audioOutputMode: AudioOutputMode

    // UI-only state
    private(set) var activePanel: PlayerPanel?
    private(set) var controlsVisible = true
    private(set) var isPointerOverControls = false
    private(set) var toast: Toast?

    var isPlaying: Bool { state == .playing }
    var hasMedia: Bool { currentURL != nil }
    var errorMessage: String? {
        if case .failed(let error) = state { error.localizedDescription } else { nil }
    }

    /// Sidecar subtitle tracks, delay and style. Embedded tracks stay on the engine.
    let subtitles: SubtitleTrackStore

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let folderAccess: FolderAccess
    @ObservationIgnored private var sidecarTask: Task<Void, Never>?
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

    init(preferences: Preferences = Preferences(), folderAccess: FolderAccess = FolderAccess()) {
        self.preferences = preferences
        self.folderAccess = folderAccess
        subtitles = SubtitleTrackStore(preferences: preferences, folderAccess: folderAccess)
        audioOutputMode = preferences.audioOutputMode
    }

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
            applyTrackPreferences(to: engine)
            engine.play()
            loadSidecarSubtitles(for: url)
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
        engine.stretchesVideoToFrame = videoLayout.aspect != .auto
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    private func teardown() {
        sidecarTask?.cancel()
        sidecarTask = nil
        subtitles.reset()
        eventTask?.cancel()
        eventTask = nil
        engine?.close()
        engine = nil
        videoView = nil
        videoLayout = VideoLayout()
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
        case .tracksChanged: refreshTracks()
        }
    }

    private func refreshTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        selectedAudio = engine.selectedAudioTrack
        selectedSubtitle = engine.selectedSubtitleTrack
    }

    /// Applies the remembered audio and subtitle languages to a freshly loaded file.
    private func applyTrackPreferences(to engine: any PlaybackEngine) {
        if let audio = TrackSelectionPolicy.audio(from: engine.audioTracks, preferredLanguage: preferences.audioLanguage),
           audio != engine.selectedAudioTrack {
            engine.selectAudio(audio)
        }
        let decision = TrackSelectionPolicy.subtitle(
            from: engine.subtitleTracks,
            choice: preferences.subtitleChoice,
            audioLanguage: engine.selectedAudioTrack?.language
        )
        if case .select(let track) = decision, track != engine.selectedSubtitleTrack {
            engine.selectSubtitle(track)
        }
        refreshTracks()
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

    private var shouldKeepControlsVisible: Bool { !isPlaying || isPointerOverControls || activePanel != nil }

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

    // MARK: Crop, aspect and zoom

    func setAspect(_ aspect: VideoLayout.Aspect) { updateLayout { $0.aspect = aspect } }
    func setCrop(_ crop: VideoLayout.Crop) { updateLayout { $0.crop = crop } }
    func setZoom(_ zoom: VideoLayout.Zoom) { updateLayout { $0.zoom = zoom } }
    func resetVideoLayout() { updateLayout { $0 = VideoLayout() } }

    private func updateLayout(_ change: (inout VideoLayout) -> Void) {
        var layout = videoLayout
        change(&layout)
        guard layout != videoLayout else { return }
        videoLayout = layout
        engine?.stretchesVideoToFrame = layout.aspect != .auto
    }

    // MARK: Panels

    func togglePanel(_ panel: PlayerPanel) {
        activePanel = activePanel == panel ? nil : panel
        registerActivity()
    }

    func closePanel() {
        guard activePanel != nil else { return }
        activePanel = nil
        registerActivity()
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
        preferences.audioOutputMode = mode
        engine?.audioOutputMode = mode
    }

    /// Subtitle tracks the user can pick. Forced-only tracks are chosen automatically, not listed.
    var selectableSubtitleTracks: [MediaTrack] { subtitleTracks.filter { !$0.isForced } }

    /// The selected subtitle track as the user sees it: a forced-only track counts as Off.
    var displayedSubtitle: MediaTrack? { selectedSubtitle.flatMap { $0.isForced ? nil : $0 } }

    // MARK: Sidecar subtitles

    /// Whether an embedded or sidecar subtitle is showing.
    var hasVisibleSubtitle: Bool { displayedSubtitle != nil || subtitles.selected != nil }

    /// Selects a sidecar track and turns embedded subtitles off (a forced one in the audio language still shows).
    func selectExternalSubtitle(_ track: SubtitleTrackStore.Track, remember: Bool = true) {
        subtitles.select(track.id)
        if case .select(let forced) = TrackSelectionPolicy.subtitle(
            from: subtitleTracks, choice: .off, audioLanguage: selectedAudio?.language
        ) {
            engine?.selectSubtitle(forced)
        }
        refreshTracks()
        if remember, let language = track.language { preferences.subtitleChoice = .language(language) }
    }

    /// Reads a subtitle file the user picked and shows it.
    func addSubtitleFile(_ url: URL) {
        Task {
            do {
                let track = try await subtitles.add(fileAt: url)
                selectExternalSubtitle(track)
                showToast("Subtitles: \(track.label)", symbol: "captions.bubble")
            } catch is CancellationError {
            } catch {
                showToast("Couldn't read that subtitle file", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Asks for access to the video's folder, so sidecar files next to it can load, and remembers the choice.
    func requestSidecarFolderAccess() {
        guard let url = currentURL else { return }
        OpenPanel.chooseFolder(startingAt: url.deletingLastPathComponent()) { [weak self] folder in
            guard let self else { return }
            try? folderAccess.remember(folder)
            loadSidecarSubtitles(for: url)
        }
    }

    private func loadSidecarSubtitles(for url: URL) {
        sidecarTask?.cancel()
        sidecarTask = Task {
            await subtitles.discover(for: url)
            guard !Task.isCancelled, currentURL == url else { return }
            applySidecarPreference()
        }
    }

    /// With no embedded subtitle showing, picks a sidecar track to match the remembered choice.
    private func applySidecarPreference() {
        guard subtitles.selected == nil, displayedSubtitle == nil, !subtitles.tracks.isEmpty else { return }
        let track: SubtitleTrackStore.Track?
        switch preferences.subtitleChoice {
        case .off: track = nil
        case .language(let language): track = subtitles.tracks.first { LanguageMatching.matches($0.language, language) }
        case .unset: track = selectableSubtitleTracks.isEmpty ? subtitles.tracks.first : nil
        }
        if let track { selectExternalSubtitle(track, remember: false) }
    }

    func adjustSubtitleDelayByShortcut(_ offset: Duration) {
        registerActivity()
        guard subtitles.selected != nil else {
            showToast("Delay needs a subtitle file", symbol: "captions.bubble")
            return
        }
        subtitles.adjustDelay(by: offset)
        showToast("Subtitle delay \(subtitles.delayLabel)", symbol: "captions.bubble")
    }

    func resetSubtitleDelay() {
        subtitles.resetDelay()
        showToast("Subtitle delay \(subtitles.delayLabel)", symbol: "captions.bubble")
    }

    /// The playhead for subtitle timing. Reads the engine directly because `currentTime` only updates 4 times a second.
    func livePlaybackTime() -> Duration {
        engine?.currentTime ?? currentTime
    }

    func activeSubtitleCues() -> [SubtitleCue] {
        subtitles.activeCues(atPlaybackTime: isPlaying ? livePlaybackTime() : currentTime)
    }

    /// Switches audio track mid-playback and remembers its language for the next file.
    func selectAudio(_ track: MediaTrack?) {
        engine?.selectAudio(track)
        refreshTracks()
        if let language = track?.language { preferences.audioLanguage = language }
    }

    /// `nil` turns subtitles off (a forced track in the audio language still shows). The choice is remembered.
    func selectSubtitle(_ track: MediaTrack?) {
        subtitles.select(nil)
        if let track {
            engine?.selectSubtitle(track)
            if let language = track.language { preferences.subtitleChoice = .language(language) }
        } else {
            let forced = TrackSelectionPolicy.subtitle(
                from: subtitleTracks, choice: .off, audioLanguage: selectedAudio?.language
            )
            if case .select(let forcedTrack) = forced { engine?.selectSubtitle(forcedTrack) }
            preferences.subtitleChoice = .off
        }
        refreshTracks()
    }
}

enum PlayerPanel: Equatable {
    case audioSubtitles
    case crop
    case speed
}
