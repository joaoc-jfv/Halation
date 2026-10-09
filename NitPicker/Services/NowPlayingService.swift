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
        artwork = image.map(Self.makeArtwork)
        if let lastInfo { publish(lastInfo) }
    }

    /// Built in a nonisolated function on purpose: MediaPlayer calls the request handler on its own queue,
    /// and a closure written inside this main-actor class would be main-actor-isolated, which traps there.
    nonisolated static func makeArtwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in NSImage(cgImage: image, size: size) }
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
        commands.playCommand.addTarget(handler: Self.handler { [weak self] _ in self?.handlers.play() })
        commands.pauseCommand.addTarget(handler: Self.handler { [weak self] _ in self?.handlers.pause() })
        commands.togglePlayPauseCommand.addTarget(handler: Self.handler { [weak self] _ in self?.handlers.toggle() })
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipForwardCommand.addTarget(handler: Self.handler { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.handlers.skip(interval)
        })
        commands.skipBackwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.addTarget(handler: Self.handler { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.handlers.skip(-interval)
        })
        commands.changePlaybackPositionCommand.addTarget(handler: Self.handler { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return }
            self?.handlers.seek(position)
        })
    }

    /// Wraps `action` for the system, which calls remote command handlers on an arbitrary queue.
    /// The closure is created in a nonisolated function so it carries no actor isolation; `action`
    /// runs on the main actor.
    nonisolated static func handler(
        _ action: @escaping @MainActor @Sendable (MPRemoteCommandEvent) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            nonisolated(unsafe) let event = event
            Task { @MainActor in action(event) }
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
