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
    /// This engine can't play the file, but the compatibility engine (libmpv) may; not shown to the user unless that fails too.
    case needsCompatibilityMode
    case loadFailed(String)

    /// Whether `PlayerModel` should retry the file with the compatibility engine.
    var wantsCompatibilityEngine: Bool { self == .needsCompatibilityMode || self == .notPlayable }

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "This format isn't supported yet."
        case .notPlayable: "This file can't be played."
        case .needsCompatibilityMode: "This format isn't supported yet."
        case .loadFailed(let reason): reason
        }
    }
}

enum PlaybackEvent: Sendable {
    case stateChanged(PlaybackState)
    case timeChanged(Duration)
    case durationChanged(Duration)
    case bufferingChanged(Bool)
    /// End of the loaded range around the playhead.
    case bufferedChanged(Duration)
    case pictureInPictureChanged(Bool)
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

enum HDRFormat: Equatable, Sendable {
    case sdr
    case hdr10
    /// Not detected yet: HDR10+ is signalled in the bitstream, not the format description.
    case hdr10Plus
    case hlg
    /// `nil` when the configuration record is missing or unreadable.
    case dolbyVision(profile: Int?, compatibilityID: Int?)

    var isHDR: Bool { self != .sdr }
}

struct Chapter: Identifiable, Equatable, Sendable {
    /// Position in the chapter list.
    let id: Int
    var title: String
    var start: Duration
}

struct MediaInfo: Equatable, Sendable {
    var container: String
    var engineName: String
    var hdr: HDRFormat = .sdr
    var videoCodec: String?
    var audioCodec: String?
    /// Coded size with the rotation applied, e.g. 3840×2160.
    var resolution: CGSize?
    /// Size the picture is meant to be shown at: `resolution` with pixel aspect ratio and clean aperture applied.
    var displaySize: CGSize?
    var frameRate: Double?
    /// Raw CoreMedia names, shown through `ColorDescription`.
    var colorPrimaries: String?
    var transferFunction: String?
    /// Sum of the tracks' estimated data rates, in bits per second.
    var bitrate: Double?
    /// The file's own title metadata, if it has any.
    var title: String?
    var chapters: [Chapter] = []

    /// What layout code should use: the display size, or the coded size when that is unknown.
    var presentationSize: CGSize? { displaySize ?? resolution }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
