import AppKit
import Observation

typealias EngineFactory = @MainActor (URL) throws -> any PlaybackEngine

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
    private(set) var resumeOffer: ResumeOffer?
    private(set) var isPictureInPictureAvailable = false
    private(set) var isPictureInPictureActive = false
    private(set) var isHDRPlaybackEligible = false
    private(set) var showsInfoPanel = false
    private(set) var scrubPreview: ScrubPreview?
    /// False once the engine has answered a thumbnail request with nothing (the engine has no picture to give),
    /// so the scrub preview shows just the time instead of an empty box.
    private(set) var scrubThumbnailsAvailable = true

    var chapters: [Chapter] { mediaInfo?.chapters ?? [] }
    var currentChapter: Chapter? {
        ChapterNavigation.index(at: currentTime, in: chapters).map { chapters[$0] }
    }

    /// The file's title metadata, else its file name.
    var displayTitle: String {
        mediaInfo?.title ?? currentURL?.deletingPathExtension().lastPathComponent ?? "Halation"
    }

    var recentFiles: RecentFiles { services.recents }

    /// The HUD pill: `["4K", "HDR10", "Spatial Audio"]`.
    var formatBadges: [String] {
        mediaInfo?.formatBadges(spatialAudio: selectedAudio?.isSpatial == true && audioOutputMode == .spatial) ?? []
    }

    var infoSections: [InfoSection] {
        guard let info = mediaInfo else { return [] }
        return InfoSections.build(
            fileName: currentURL?.lastPathComponent ?? displayTitle, info: info, audio: selectedAudio,
            outputMode: audioOutputMode, isHDRPlaybackEligible: isHDRPlaybackEligible, rate: rate
        )
    }

    var isPlaying: Bool { state == .playing }
    /// Loading the file, or waiting for data while playing.
    var isBusy: Bool { state == .loading || isBuffering }
    var hasMedia: Bool { currentURL != nil }
    var errorMessage: String? {
        if case .failed(let error) = state { error.localizedDescription } else { nil }
    }

    /// Sidecar subtitle tracks, delay and style. Embedded tracks stay on the engine.
    let subtitles: SubtitleTrackStore

    @ObservationIgnored private let services: PlayerServices
    @ObservationIgnored private let engineFactory: EngineFactory
    @ObservationIgnored private var preferences: Preferences { services.preferences }
    @ObservationIgnored private var folderAccess: FolderAccess { services.folderAccess }
    @ObservationIgnored private var resumeOfferTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lastResumeSave: ContinuousClock.Instant?
    @ObservationIgnored private var scrubTask: Task<Void, Never>?
    @ObservationIgnored private var scrubThumbnails: [Int: CGImage] = [:]
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
    /// How often playback progress is saved for resuming.
    @ObservationIgnored var resumeSaveInterval: Duration = .seconds(5)
    @ObservationIgnored var resumeOfferDuration: Duration = .seconds(6)

    init(
        services: PlayerServices = .live(),
        engineFactory: @escaping EngineFactory = EngineRouter.engine(for:)
    ) {
        self.services = services
        self.engineFactory = engineFactory
        subtitles = SubtitleTrackStore(preferences: services.preferences, folderAccess: services.folderAccess)
        audioOutputMode = services.preferences.audioOutputMode
        services.nowPlaying.handlers = NowPlayingHandlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.skip(by: .seconds(seconds)) },
            seek: { [weak self] seconds in self?.seek(to: .seconds(seconds), precise: true) }
        )
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
            let engine = try engineFactory(url)
            attach(engine)
            try await engine.load(url, startAt: nil)
            try Task.checkCancellation()
            applyTrackPreferences(to: engine)
            engine.play()
            services.recents.note(url)
            offerResume(for: url)
            loadSidecarSubtitles(for: url)
            loadArtwork(from: engine)
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
        engine.preferredAudioLanguage = preferences.audioLanguage
        engine.stretchesVideoToFrame = videoLayout.aspect != .auto
        isPictureInPictureAvailable = engine.isPictureInPictureAvailable
        isHDRPlaybackEligible = engine.isHDRPlaybackEligible
        eventTask = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    private func teardown() {
        saveResumePosition()
        resumeOfferTask?.cancel()
        resumeOffer = nil
        artworkTask?.cancel()
        services.sleep.setActive(false)
        services.nowPlaying.clear()
        lastResumeSave = nil
        scrubTask?.cancel()
        scrubPreview = nil
        scrubThumbnails = [:]
        scrubThumbnailsAvailable = true
        showsInfoPanel = false
        isPictureInPictureAvailable = false
        isPictureInPictureActive = false
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
            services.sleep.setActive(newState == .playing)
            if newState == .paused || newState == .ended { saveResumePosition() }
            publishNowPlaying()
        case .timeChanged(let time):
            currentTime = time
            saveResumePositionIfDue()
        case .durationChanged(let newDuration):
            duration = newDuration
            publishNowPlaying()
        case .bufferingChanged(let buffering): isBuffering = buffering
        case .bufferedChanged(let end): buffered = end
        case .pictureInPictureChanged(let active): isPictureInPictureActive = active
        case .mediaInfoChanged(let info):
            mediaInfo = info
            publishNowPlaying()
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
        publishNowPlaying()
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

    private var shouldKeepControlsVisible: Bool {
        !isPlaying || isPointerOverControls || activePanel != nil || showsInfoPanel
    }

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

    // MARK: Resume, Now Playing and artwork

    /// Saves where playback is, so the file can offer to resume. Also called on quit.
    func saveResumePosition() {
        guard let url = currentURL, duration > .zero else { return }
        services.resume.update(url: url, position: currentTime.seconds, duration: duration.seconds)
        lastResumeSave = .now
    }

    private func saveResumePositionIfDue() {
        guard isPlaying else { return }
        if let last = lastResumeSave, ContinuousClock.now - last < resumeSaveInterval { return }
        saveResumePosition()
    }

    private func offerResume(for url: URL) {
        guard let record = services.resume.record(for: url), ResumeStore.isOfferable(record) else { return }
        resumeOffer = ResumeOffer(position: .seconds(record.position))
        resumeOfferTask?.cancel()
        resumeOfferTask = Task {
            try? await Task.sleep(for: resumeOfferDuration)
            guard !Task.isCancelled else { return }
            resumeOffer = nil
        }
    }

    func acceptResumeOffer() {
        guard let offer = resumeOffer else { return }
        dismissResumeOffer()
        seek(to: offer.position, precise: true)
    }

    func dismissResumeOffer() {
        resumeOfferTask?.cancel()
        resumeOffer = nil
    }

    private func publishNowPlaying() {
        guard hasMedia, duration > .zero else { return }
        services.nowPlaying.publish(NowPlayingInfo(
            title: displayTitle, duration: duration.seconds, elapsed: currentTime.seconds,
            rate: Double(rate), isPlaying: isPlaying
        ))
    }

    private func loadArtwork(from engine: any PlaybackEngine) {
        artworkTask?.cancel()
        artworkTask = Task {
            let time: Duration = duration > .zero ? min(duration / 10, .seconds(60)) : .seconds(5)
            let image = await engine.thumbnail(at: time, maxSize: CGSize(width: 640, height: 640))
            guard !Task.isCancelled else { return }
            services.nowPlaying.setArtwork(image)
            if let image, let url = currentURL { services.thumbnails.save(image, for: url) }
        }
    }

    // MARK: Info panel, scrub previews and recents

    func toggleInfoPanel() {
        showsInfoPanel.toggle()
        registerActivity()
    }

    /// Closes whatever Esc should close: an open panel first, then the info panel. Returns whether anything closed.
    @discardableResult
    func dismissTopmostOverlay() -> Bool {
        if activePanel != nil {
            closePanel()
            return true
        }
        if showsInfoPanel {
            showsInfoPanel = false
            registerActivity()
            return true
        }
        return false
    }

    /// Pointer over the scrubber at `fraction` of the way along (nil when it leaves).
    func updateScrubPreview(fraction: Double?) {
        scrubTask?.cancel()
        guard let fraction, duration > .zero, let engine else {
            scrubPreview = nil
            return
        }
        let clamped = min(max(fraction, 0), 1)
        let time = Duration.seconds(clamped * duration.seconds)
        // Thumbnails come from nearby keyframes, so a coarse grid loses nothing and keeps the cache small.
        let step = max(2, duration.seconds / 120)
        let bucket = Int((time.seconds / step).rounded())
        let cached = scrubThumbnails[bucket]
        scrubPreview = ScrubPreview(fraction: clamped, time: time, image: cached ?? scrubPreview?.image)
        guard cached == nil else { return }
        scrubTask = Task {
            let image = await engine.thumbnail(at: .seconds(Double(bucket) * step), maxSize: CGSize(width: 320, height: 180))
            guard !Task.isCancelled else { return }
            guard let image else {
                scrubThumbnailsAvailable = false
                scrubPreview?.image = nil
                return
            }
            if scrubThumbnails.count > 200 { scrubThumbnails = [:] }
            scrubThumbnails[bucket] = image
            scrubPreview?.image = image
        }
    }

    func recentPoster(for entry: RecentEntry) -> NSImage? {
        services.thumbnails.image(forPath: entry.path)
    }

    /// How far through the file the saved position is, 0...1, for the welcome screen's progress bars.
    func recentProgress(for entry: RecentEntry) -> Double? {
        guard let record = services.resume.record(for: URL(fileURLWithPath: entry.path)), record.duration > 0 else { return nil }
        return min(max(record.position / record.duration, 0), 1)
    }

    func removeRecent(_ entry: RecentEntry) {
        services.recents.remove(entry)
        services.thumbnails.remove(forPath: entry.path)
    }

    func openRecent(_ entry: RecentEntry) {
        if let url = services.recents.resolve(entry) {
            open(url)
        } else {
            removeRecent(entry)
        }
    }

    // MARK: Chapters and Picture in Picture

    func goToChapter(_ chapter: Chapter) {
        seek(to: chapter.start, precise: true)
    }

    func nextChapter() -> Chapter? {
        guard let chapter = ChapterNavigation.next(after: currentTime, in: chapters) else { return nil }
        goToChapter(chapter)
        return chapter
    }

    func previousChapter() -> Chapter? {
        guard let chapter = ChapterNavigation.previous(before: currentTime, in: chapters) else { return nil }
        goToChapter(chapter)
        return chapter
    }

    func togglePictureInPicture() {
        engine?.togglePictureInPicture()
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
        publishNowPlaying()
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
        guard drawsSubtitles else {
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
        let time = isPlaying ? livePlaybackTime() : currentTime
        if subtitles.selected != nil { return subtitles.activeCues(atPlaybackTime: time) }
        return engineDrawnCues?.active(at: time - subtitles.delay) ?? []
    }

    /// The cues of the selected embedded track when the engine hands them over to be drawn by the app (MKV text subtitles),
    /// else nil: AVFoundation draws its own tracks.
    private var engineDrawnCues: SubtitleCueList? {
        selectedSubtitle.flatMap { engine?.subtitleCues(for: $0) }
    }

    /// Whether the app draws a subtitle over the video, so the overlay and the delay controls apply.
    var drawsSubtitles: Bool { subtitles.selected != nil || engineDrawnCues != nil }

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

/// The thumbnail and time shown above the scrubber while the pointer is on it.
struct ScrubPreview {
    var fraction: Double
    var time: Duration
    var image: CGImage?
}

enum PlayerPanel: Equatable {
    case audioSubtitles
    case crop
    case speed
}
