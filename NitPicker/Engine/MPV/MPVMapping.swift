import Foundation

/// Turns what mpv reports into the app's own types. Pure, so it is tested without a player.
enum MPVMapping {
    /// One entry of mpv's `track-list`, as the strings mpv gives.
    struct TrackFields: Equatable {
        var id: Int
        /// `video`, `audio` or `sub`.
        var type: String
        var language: String?
        var title: String?
        var codec: String?
        var codecProfile: String?
        var channels: Int?
        var isDefault = false
        var isForced = false
        var isSelected = false
        var isExternal = false
    }

    static func mediaTrack(_ fields: TrackFields) -> MediaTrack? {
        let kind: MediaTrack.Kind
        switch fields.type {
        case "audio": kind = .audio
        case "sub": kind = .subtitle
        default: return nil
        }
        return MediaTrack(
            id: "\(kind.rawValue)-\(fields.id)", kind: kind,
            language: fields.language.map(LanguageMatching.primaryLanguage),
            title: fields.title, codec: fields.codec.map(CodecNames.displayName(forFFmpegCodec:)),
            channels: fields.channels.flatMap { $0 > 0 ? $0 : nil },
            isDefault: fields.isDefault, isForced: fields.isForced, isSpatial: false
        )
    }

    /// mpv's id for one of our track ids (`audio-3` is mpv's audio track 3).
    static func mpvID(of track: MediaTrack) -> Int? {
        track.id.split(separator: "-").last.flatMap { Int($0) }
    }

    /// HDR10 and HLG from the transfer function mpv reports. Dolby Vision's profile isn't visible through mpv's properties.
    static func hdr(gamma: String?) -> HDRFormat {
        switch gamma {
        case "pq": .hdr10
        case "hlg": .hlg
        default: .sdr
        }
    }

    /// FFmpeg's name for a colour primaries mpv spells its own way, so `ColorDescription` can show it.
    static func ffmpegPrimaries(_ mpvName: String?) -> String? {
        guard let mpvName else { return nil }
        return [
            "bt.709": "bt709", "bt.2020": "bt2020", "display-p3": "smpte432", "dci-p3": "smpte431",
            "bt.601-525": "smpte170m", "bt.601-625": "bt470bg",
        ][mpvName] ?? mpvName
    }

    static func ffmpegTransfer(_ mpvName: String?) -> String? {
        guard let mpvName else { return nil }
        return ["bt.1886": "bt709", "pq": "smpte2084", "hlg": "arib-std-b67", "srgb": "iec61966-2-1", "linear": "linear"][mpvName] ?? mpvName
    }

    /// `matroska,webm` -> `MKV`, `avi` -> `AVI`: the first format name, in the short form the info panel uses.
    static func containerName(_ formatName: String?) -> String {
        let first = formatName?.split(separator: ",").first.map(String.init) ?? ""
        return ["matroska": "MKV", "mov": "MOV", "mpegts": "MPEG-TS", "mpeg": "MPEG-PS", "asf": "ASF", "ogg": "Ogg", "flv": "FLV"][first] ?? first.uppercased()
    }
}
