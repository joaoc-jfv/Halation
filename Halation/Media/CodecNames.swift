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

    private static let names: [String: String] = [
        "avc1": "H.264", "avc3": "H.264",
        "hvc1": "HEVC", "hev1": "HEVC", "dvh1": "HEVC", "dvhe": "HEVC",
        "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4",
        "apch": "ProRes", "apcn": "ProRes", "apcs": "ProRes", "apco": "ProRes", "ap4h": "ProRes", "ap4x": "ProRes",
        "mp4a": "AAC", "ac-3": "AC-3", "ec-3": "E-AC-3", "alac": "ALAC", "fLaC": "FLAC", "Opus": "Opus", "lpcm": "PCM",
    ]
}
