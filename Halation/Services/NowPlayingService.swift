import AppKit
import CoreGraphics
import Foundation
import MediaPlayer

/// What the player shows in Control Center and the Now Playing menu, and which remote commands it answers.
struct NowPlayingInfo: Equatable {
    var title: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var isPlaying: Bool
}

@MainActor
protocol NowPlayingPublishing: AnyObject {
    /// Called for the system's play, pause, toggle, skip and scrub commands.
    var handlers: NowPlayingHandlers { get set }
    func publish(_ info: NowPlayingInfo)
    func setArtwork(_ image: CGImage?)
    func clear()
}

struct NowPlayingHandlers {
    var play: @MainActor () -> Void = {}
    var pause: @MainActor () -> Void = {}
    var toggle: @MainActor () -> Void = {}
    var skip: @MainActor (_ seconds: Double) -> Void = { _ in }
    var seek: @MainActor (_ seconds: Double) -> Void = { _ in }
}

@MainActor
final class SystemNowPlaying: NowPlayingPublishing {
    var handlers = NowPlayingHandlers()
    private var isRegistered = false
    private var artwork: MPMediaItemArtwork?
    private var lastInfo: NowPlayingInfo?

    static func dictionary(for info: NowPlayingInfo, artwork: MPMediaItemArtwork?) -> [String: Any] {
        var dictionary: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            // `0.0`, not `0`: in an `[String: Any]` literal a bare `0` would be an Int.
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? info.rate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { dictionary[MPMediaItemPropertyArtwork] = artwork }
        return dictionary
    }

    func publish(_ info: NowPlayingInfo) {
        registerCommandsIfNeeded()
        lastInfo = info
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = Self.dictionary(for: info, artwork: artwork)
        center.playbackState = info.isPlaying ? .playing : .paused
        setCommandsEnabled(true)
    }

    func setArtwork(_ image: CGImage?) {
        artwork = image.map { image in
            let size = CGSize(width: image.width, height: image.height)
            // The system calls this from any thread, so it only captures the (immutable) image.
            return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: image, size: size) }
        }
        if let lastInfo { publish(lastInfo) }
    }

    func clear() {
        artwork = nil
        lastInfo = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        setCommandsEnabled(false)
    }

    // MARK: Remote commands

    private func registerCommandsIfNeeded() {
        guard !isRegistered else { return }
        isRegistered = true
        let commands = MPRemoteCommandCenter.shared()
        // The system may call these off the main thread, so each hops to the main actor.
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers.toggle() }
            return .success
        }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.handlers.skip(interval) }
            return .success
        }
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.handlers.skip(-interval) }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.handlers.seek(position) }
            return .success
        }
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        let commands = MPRemoteCommandCenter.shared()
        for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand,
                        commands.skipForwardCommand, commands.skipBackwardCommand, commands.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
    }
}

/// Does nothing. For tests and previews, so they never touch the system's Now Playing state.
@MainActor
final class NullNowPlaying: NowPlayingPublishing {
    var handlers = NowPlayingHandlers()
    private(set) var published: [NowPlayingInfo] = []
    private(set) var hasArtwork = false
    private(set) var clearCount = 0

    func publish(_ info: NowPlayingInfo) { published.append(info) }
    func setArtwork(_ image: CGImage?) { hasArtwork = image != nil }
    func clear() { clearCount += 1; published = []; hasArtwork = false }
}
