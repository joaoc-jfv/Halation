import AVFoundation
import AppKit

@MainActor
final class AVFoundationEngine: PlaybackEngine {
    let events: AsyncStream<PlaybackEvent>
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    private let player = AVPlayer()
    private let surface: PlayerLayerView
    var videoView: NSView { surface }

    private var item: AVPlayerItem?
    private var asset: AVURLAsset?
    private var pip: PiPController?
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []

    private var state: PlaybackState = .idle
    private var isBuffering = false
    private var hasStartedPlaying = false
    private var didReachEnd = false
    private var loadGeneration = 0

    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []

    var stretchesVideoToFrame: Bool {
        get { surface.videoGravity == .resize }
        set { surface.videoGravity = newValue ? .resize : .resizeAspect }
    }

    var audioOutputMode: AudioOutputMode = .spatial {
        didSet { applyAudioOutputMode() }
    }

    let capabilities = EngineCapabilities(
        supportsPictureInPicture: true,
        supportsDolbyVision: true,
        supportsSpatialAudio: true
    )

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        surface = PlayerLayerView(player: player)
        installPlayerObservers()
        pip = PiPController(playerLayer: surface.avPlayerLayer) { [weak self] active in
            self?.emit(.pictureInPictureChanged(active))
        }
    }

    // MARK: Loading

    func load(_ url: URL, startAt: Duration?) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        detachItem()
        resetPlaybackFlags()
        setState(.loading)

        let asset = AVURLAsset(url: url)
        let info: MediaInfo
        let audio: AVMediaSelectionGroup?
        let subtitles: AVMediaSelectionGroup?
        let audioTracks: [MediaTrack]
        let duration: CMTime
        do {
            let (isPlayable, loadedDuration) = try await asset.load(.isPlayable, .duration)
            guard isPlayable else { throw PlaybackError.notPlayable }
            info = try await Self.makeMediaInfo(for: asset, url: url)
            audio = try await asset.loadMediaSelectionGroup(for: .audible)
            subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
            audioTracks = try await AVTrackMapping.audioTracks(in: audio, asset: asset)
            duration = loadedDuration
        } catch {
            guard generation == loadGeneration else { throw CancellationError() }
            let failure = error as? PlaybackError ?? .loadFailed(error.localizedDescription)
            setState(.failed(failure))
            throw failure
        }
        guard generation == loadGeneration else { throw CancellationError() }

        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        self.item = item
        self.asset = asset
        audioGroup = audio
        subtitleGroup = subtitles
        self.audioTracks = audioTracks
        subtitleTracks = AVTrackMapping.tracks(in: subtitles, kind: .subtitle)
        applyAudioOutputMode()
        attach(item)

        if let duration = Duration(duration) { emit(.durationChanged(duration)) }
        emit(.mediaInfoChanged(info))
        emit(.tracksChanged)
        player.replaceCurrentItem(with: item)
        refreshState()
        refreshBuffered()

        if let startAt { await seek(to: startAt, precise: true) }
    }

    func close() {
        loadGeneration += 1
        detachItem()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.removeAll()
        player.pause()
        setState(.idle)
        continuation.finish()
    }

    // MARK: Transport

    func play() {
        guard item != nil else { return }
        if didReachEnd {
            didReachEnd = false
            player.seek(to: .zero)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to time: Duration, precise: Bool) async {
        guard item != nil else { return }
        didReachEnd = false
        let tolerance: CMTime = precise ? .zero : .positiveInfinity
        _ = await player.seek(to: time.cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
        refreshState()
        if let now = Duration(player.currentTime()) { emit(.timeChanged(now)) }
    }

    func step(frames: Int) {
        item?.step(byCount: frames)
    }

    func thumbnail(at time: Duration, maxSize: CGSize) async -> CGImage? {
        guard let asset else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        // A nearby keyframe is plenty for artwork, and much faster than an exact frame.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        return try? await generator.image(at: time.cmTime).image
    }

    var isPictureInPictureAvailable: Bool { pip != nil }

    func togglePictureInPicture() {
        pip?.toggle()
    }

    var currentTime: Duration {
        Duration(player.currentTime()) ?? .zero
    }

    var rate: Float {
        get { player.defaultRate }
        set {
            player.defaultRate = newValue
            if player.rate != 0 { player.rate = newValue }
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    // MARK: Tracks

    var selectedAudioTrack: MediaTrack? { selectedTrack(in: audioGroup, from: audioTracks) }
    var selectedSubtitleTrack: MediaTrack? { selectedTrack(in: subtitleGroup, from: subtitleTracks) }

    func selectAudio(_ track: MediaTrack?) {
        select(track, in: audioGroup, from: audioTracks)
    }

    func selectSubtitle(_ track: MediaTrack?) {
        select(track, in: subtitleGroup, from: subtitleTracks)
    }

    private func selectedTrack(in group: AVMediaSelectionGroup?, from tracks: [MediaTrack]) -> MediaTrack? {
        guard let group, let item,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(of: option),
              tracks.indices.contains(index)
        else { return nil }
        return tracks[index]
    }

    private func select(_ track: MediaTrack?, in group: AVMediaSelectionGroup?, from tracks: [MediaTrack]) {
        guard let group, let item else { return }
        if let track {
            guard let index = tracks.firstIndex(of: track), group.options.indices.contains(index) else { return }
            item.select(group.options[index], in: group)
        } else {
            item.select(nil, in: group)
        }
        emit(.tracksChanged)
    }

    private func applyAudioOutputMode() {
        item?.allowedAudioSpatializationFormats = switch audioOutputMode {
        case .spatial: .monoStereoAndMultichannel
        case .stereo: []
        }
    }

    // MARK: Observation

    private func installPlayerObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                if let time = Duration(time) { self?.emit(.timeChanged(time)) }
            }
        }
        playerObservations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        })
    }

    private func attach(_ item: AVPlayerItem) {
        itemObservations.append(item.observe(\.status) { [weak self] _, _ in
            Task { @MainActor in self?.refreshState() }
        })
        itemObservations.append(item.observe(\.loadedTimeRanges) { [weak self] _, _ in
            Task { @MainActor in self?.refreshBuffered() }
        })
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didReachEnd = true
                self?.refreshState()
            }
        }
    }

    private func detachItem() {
        itemObservations.removeAll()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        item = nil
        asset = nil
        audioGroup = nil
        subtitleGroup = nil
        audioTracks = []
        subtitleTracks = []
        player.replaceCurrentItem(with: nil)
    }

    private func resetPlaybackFlags() {
        hasStartedPlaying = false
        didReachEnd = false
        isBuffering = false
    }

    // MARK: State

    private func refreshState() {
        guard let item else { return }
        let newState: PlaybackState
        var buffering = false
        switch item.status {
        case .failed:
            newState = .failed(.loadFailed(item.error?.localizedDescription ?? "Playback failed."))
        case .readyToPlay:
            if didReachEnd {
                newState = .ended
            } else {
                switch player.timeControlStatus {
                case .paused:
                    newState = hasStartedPlaying ? .paused : .ready
                case .waitingToPlayAtSpecifiedRate:
                    hasStartedPlaying = true
                    buffering = true
                    newState = .playing
                case .playing:
                    hasStartedPlaying = true
                    newState = .playing
                @unknown default:
                    newState = .paused
                }
            }
        default:
            newState = .loading
        }
        setState(newState)
        if buffering != isBuffering {
            isBuffering = buffering
            emit(.bufferingChanged(buffering))
        }
    }

    private func refreshBuffered() {
        guard let item else { return }
        let now = player.currentTime()
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        let current = ranges.first { $0.containsTime(now) } ?? ranges.last
        if let end = current.flatMap({ Duration($0.end) }) { emit(.bufferedChanged(end)) }
    }

    private func setState(_ newState: PlaybackState) {
        guard newState != state else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: PlaybackEvent) {
        continuation.yield(event)
    }

    // MARK: Media info

    private static func makeMediaInfo(for asset: AVURLAsset, url: URL) async throws -> MediaInfo {
        var info = MediaInfo(container: url.pathExtension.uppercased(), engineName: "AVFoundation")
        var bitrate = 0.0

        if let video = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, frameRate, dataRate, formats) = try await video.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
            )
            // The track's naturalSize is the *display* size (the header carries the pixel aspect ratio),
            // so the coded size comes from the format description.
            func oriented(_ size: CGSize) -> CGSize {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                return CGSize(width: abs(rect.width), height: abs(rect.height))
            }
            if let description = formats.first {
                let coded = CMVideoFormatDescriptionGetDimensions(description)
                info.resolution = oriented(CGSize(width: Int(coded.width), height: Int(coded.height)))
                info.displaySize = oriented(CMVideoFormatDescriptionGetPresentationDimensions(
                    description, usePixelAspectRatio: true, useCleanAperture: true
                ))
            } else {
                info.resolution = oriented(size)
                info.displaySize = info.resolution
            }
            info.frameRate = frameRate > 0 ? Double(frameRate) : nil
            info.videoCodec = formats.first.map { CodecNames.displayName(forFourCC: $0.mediaSubType.rawValue) }
            info.hdr = formats.first.map(HDRDetection.format(of:)) ?? .sdr
            bitrate += Double(dataRate)
        }
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let (dataRate, formats) = try await audio.load(.estimatedDataRate, .formatDescriptions)
            info.audioCodec = formats.first.map { CodecNames.displayName(forFourCC: $0.mediaSubType.rawValue) }
            bitrate += Double(dataRate)
        }
        info.bitrate = bitrate > 0 ? bitrate : nil
        info.title = try await Self.title(of: asset)
        info.chapters = try await Self.chapters(of: asset)
        return info
    }

    private static func title(of asset: AVURLAsset) async throws -> String? {
        let metadata = try await asset.load(.commonMetadata)
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
              let title = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    private static func chapters(of asset: AVURLAsset) async throws -> [Chapter] {
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        var chapters: [Chapter] = []
        for group in groups {
            guard let start = Duration(group.timeRange.start) else { continue }
            let titles = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle)
            let title = try await titles.first?.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(Chapter(id: chapters.count, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(chapters.count + 1)", start: start))
        }
        return chapters.sorted { $0.start < $1.start }.enumerated().map { Chapter(id: $0.offset, title: $0.element.title, start: $0.element.start) }
    }
}
