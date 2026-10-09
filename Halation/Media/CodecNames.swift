import Foundation

enum CodecNames {
    /// The four characters of a `FourCharCode`, e.g. `"avc1"`.
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return "0x" + String(code, radix: 16, uppercase: true)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Short human-readable codec name, falling back to the raw four-character code.
    static func displayName(forFourCC code: UInt32) -> String {
        let cc = fourCC(code)
        return names[cc] ?? cc
    }

    /// Short name for a codec as FFmpeg and mpv spell it (`hevc`, `dts`, `subrip`); the uppercased name when unknown.
    static func displayName(forFFmpegCodec codec: String) -> String {
        if let name = ffmpegNames[codec] { return name }
        return codec.hasPrefix("pcm_") ? "PCM" : codec.uppercased()
    }

    private static let ffmpegNames: [String: String] = [
        "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg4": "MPEG-4", "msmpeg4v3": "MPEG-4",
        "mpeg2video": "MPEG-2", "mpeg1video": "MPEG-1", "vc1": "VC-1", "wmv3": "WMV", "wmv2": "WMV", "theora": "Theora", "prores": "ProRes",
        "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "alac": "ALAC", "flac": "FLAC", "dts": "DTS", "truehd": "TrueHD", "mlp": "MLP",
        "opus": "Opus", "vorbis": "Vorbis", "mp3": "MP3", "mp2": "MP2", "wmav2": "WMA", "wmapro": "WMA Pro",
        "subrip": "SRT", "srt": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "text": "Text", "mov_text": "Text",
        "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub", "dvb_subtitle": "DVB",
    ]

    private static let names: [String: String] = [
        "avc1": "H.264", "avc3": "H.264",
        "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "HEVC", "dvhe": "HEVC",
        "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4",
        "apch": "ProRes", "apcn": "ProRes", "apcs": "ProRes", "apco": "ProRes", "ap4h": "ProRes", "ap4x": "ProRes",
        "mp4a": "AAC", "aac ": "AAC", "aach": "HE-AAC", "aacp": "HE-AAC", ".mp3": "MP3", "ac-3": "AC-3", "ec-3": "E-AC-3", "alac": "ALAC", "fLaC": "FLAC", "Opus": "Opus", "lpcm": "PCM",
    ]
}
