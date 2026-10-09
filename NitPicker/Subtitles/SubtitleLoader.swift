import Foundation

enum SubtitleLoader {
    enum LoadError: Error, Equatable {
        case unsupportedFormat
        case noCues
    }

    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// Reads and parses a subtitle file. Runs on whatever thread calls it, so call it off the main actor.
    static func load(from url: URL) throws -> SubtitleCueList {
        let text = SubtitleDecoding.string(from: try Data(contentsOf: url))
        let cues: [SubtitleCue]
        switch url.pathExtension.lowercased() {
        case "srt": cues = SRTParser.parse(text)
        case "vtt": cues = WebVTTParser.parse(text)
        case "ass", "ssa": cues = ASSParser.parse(text)
        default: throw LoadError.unsupportedFormat
        }
        guard !cues.isEmpty else { throw LoadError.noCues }
        return SubtitleCueList(cues)
    }
}
