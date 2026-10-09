import CoreGraphics
import Foundation

enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case ended
    case failed(PlaybackError)
}

enum PlaybackError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedFormat
    case notPlayable
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This format isn't supported yet."
        case .notPlayable: "This file can't be played."
        case .loadFailed(let reason): reason
        }
    }
}

enum PlaybackEvent: Sendable {
    case stateChanged(PlaybackState)
    case timeChanged(Duration)
    case durationChanged(Duration)
    case bufferingChanged(Bool)
    case mediaInfoChanged(MediaInfo)
    /// Track lists or the selected tracks changed; re-read them from the engine.
    case tracksChanged
}

enum AudioOutputMode: Sendable, Equatable {
    /// Let the system spatialize mono, stereo and multichannel audio.
    case spatial
    /// Plain downmix, no spatialization.
    case stereo
}

struct EngineCapabilities: Sendable, Equatable {
    var supportsPictureInPicture: Bool
    var supportsDolbyVision: Bool
    var supportsSpatialAudio: Bool
}

struct MediaTrack: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case audio, subtitle }

    let id: String
    let kind: Kind
    var language: String?
    var title: String?
    var codec: String?
    var channels: Int?
    var isDefault: Bool
    var isForced: Bool
    var isSpatial: Bool
}

struct MediaInfo: Equatable, Sendable {
    var container: String
    var engineName: String
    var videoCodec: String?
    var audioCodec: String?
    var resolution: CGSize?
    var frameRate: Double?
    /// Sum of the tracks' estimated data rates, in bits per second.
    var bitrate: Double?
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
