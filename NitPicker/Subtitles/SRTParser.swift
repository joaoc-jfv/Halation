import Foundation

enum SRTParser {
    /// Parses SubRip text. Malformed blocks are skipped, and a missing blank line between cues is tolerated.
    static func parse(_ text: String) -> [SubtitleCue] {
        let lines = SubtitleDecoding.normalizedLines(text)
        var cues: [SubtitleCue] = []
        var index = 0
        while index < lines.count {
            guard lines[index].contains("-->"), let range = SubtitleTimestamp.parseRange(lines[index]) else {
                index += 1
                continue
            }
            var body: [String] = []
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                // The next cue's index line, when the blank separator is missing.
                if Int(line.trimmingCharacters(in: .whitespaces)) != nil,
                   index + 1 < lines.count, lines[index + 1].contains("-->") { break }
                body.append(line)
                index += 1
            }
            let cueText = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty {
                cues.append(SubtitleCue(start: range.start, end: range.end, text: cueText))
            }
        }
        return cues
    }
}
