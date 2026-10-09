import Foundation

/// The playlists AVPlayer is given for a remuxed file: one master with the codecs and the HDR signalling, and one
/// VOD media playlist listing the fMP4 segments.
enum HLSPlaylists {
    static func segmentName(_ index: Int) -> String { String(format: "seg_%05d.m4s", index) }

    static func media(segments: [SegmentSpec]) -> String {
        let longest = segments.map { $0.duration.seconds }.max() ?? 6
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        for segment in segments {
            text += String(format: "#EXTINF:%.3f,\n%@\n", segment.duration.seconds, segmentName(segment.index))
        }
        return text + "#EXT-X-ENDLIST\n"
    }

    struct Variant: Equatable {
        var codecs: String
        /// Dolby Vision's own codec string, for players that can use it (`dvh1.08.06/db1p`).
        var supplementalCodecs: String?
        /// `PQ`, `HLG` or `SDR`.
        var videoRange: String
        var bandwidth: Int
        var averageBandwidth: Int
        var width: Int
        var height: Int
        var frameRate: Double?
    }

    static func master(_ variant: Variant, mediaPlaylist: String = "video.m3u8") -> String {
        var attributes = "BANDWIDTH=\(variant.bandwidth),AVERAGE-BANDWIDTH=\(variant.averageBandwidth),CODECS=\"\(variant.codecs)\""
        if let supplemental = variant.supplementalCodecs { attributes += ",SUPPLEMENTAL-CODECS=\"\(supplemental)\"" }
        attributes += ",VIDEO-RANGE=\(variant.videoRange),RESOLUTION=\(variant.width)x\(variant.height)"
        if let rate = variant.frameRate { attributes += String(format: ",FRAME-RATE=%.3f", rate) }
        return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:\(attributes)\n\(mediaPlaylist)\n"
    }

    /// Builds the variant from what the file says and what the muxer actually wrote into the init segment.
    /// Nil if the codec can't be described (the caller then fails with a clear message).
    static func variant(video: ProbedStream, audio: ProbedStream?, initSegment: [UInt8], fileBytes: Int64, duration: Duration) -> Variant? {
        var audioCodec: String?
        if let audio {
            audioCodec = audioCodecString(audio.codec)
            guard audioCodec != nil else { return nil }
        }
        var videoCodec: String?
        var supplemental: String?
        var range = "SDR"

        switch video.codec {
        case "hevc": videoCodec = MP4Boxes.hevcCodecString(initSegment)
        case "h264": videoCodec = MP4Boxes.avcCodecString(initSegment)
        default: return nil
        }
        switch video.hdr {
        case .hdr10, .hdr10Plus: range = "PQ"
        case .hlg: range = "HLG"
        case .dolbyVision:
            range = "PQ"
            if let dolby = MP4Boxes.dolbyVision(initSegment) {
                let name = String(format: "dvh1.%02d.%02d", dolby.profile, dolby.level)
                // Profiles 8.x have an HDR base layer, so they are signalled on top of it; others stand alone.
                if let suffix = ["1": "db1p", "2": "db2g", "4": "db4h"]["\(dolby.compatibilityID)"], dolby.profile == 8 {
                    supplemental = "\(name)/\(suffix)"
                } else {
                    videoCodec = name
                    if dolby.profile == 5 { range = "PQ" }
                }
            }
        case .sdr: break
        }
        guard let videoCodec else { return nil }

        let seconds = max(duration.seconds, 1)
        let average = Int(Double(fileBytes) * 8 / seconds)
        return Variant(
            codecs: [videoCodec, audioCodec].compactMap { $0 }.joined(separator: ","), supplementalCodecs: supplemental, videoRange: range,
            bandwidth: max(average * 3 / 2, average + 1_000_000), averageBandwidth: average,
            width: video.width, height: video.height, frameRate: video.frameRate
        )
    }

    static func audioCodecString(_ codec: String) -> String? {
        switch codec {
        case "eac3": "ec-3"
        case "ac3": "ac-3"
        case "aac": "mp4a.40.2"
        case "alac": "alac"
        case "flac": "fLaC"
        default: nil
        }
    }
}
