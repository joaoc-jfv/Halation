import Foundation

enum WebVTTParser {
    /// Parses WebVTT text. NOTE, STYLE and REGION blocks and cue settings are ignored; cue identifiers are optional.
    static func parse(_ text: String) -> [SubtitleCue] {
        let lines = SubtitleDecoding.normalizedLines(text)
        var cues: [SubtitleCue] = []
        var block: [String] = []

        func flush() {
            defer { block.removeAll() }
            guard let first = block.first else { return }
            if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                return
            }
            // The timing line is the first line, or the second when the first is a cue identifier.
            guard let timingIndex = block.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let range = SubtitleTimestamp.parseRange(block[timingIndex])
            else { return }
            let cueText = block[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty {
                cues.append(SubtitleCue(start: range.start, end: range.end, text: cueText))
            }
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        return cues
    }
}
