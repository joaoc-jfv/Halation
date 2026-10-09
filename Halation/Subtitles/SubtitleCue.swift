import Foundation

struct SubtitleCue: Equatable, Sendable {
    var start: Duration
    var end: Duration
    /// Raw cue text, possibly with inline tags (`<i>`, `<b>`, ...). See `SubtitleMarkup`.
    var text: String
}

/// Cues sorted by start time, with a binary-search lookup for the cues showing at a given time.
struct SubtitleCueList: Sendable {
    let cues: [SubtitleCue]
    private let longestCue: Duration

    init(_ cues: [SubtitleCue]) {
        // Offsets keep equal start times in file order.
        self.cues = cues.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        longestCue = cues.map { $0.end - $0.start }.max() ?? .zero
    }

    var isEmpty: Bool { cues.isEmpty }

    /// Every cue with `start <= time < end`, in start order. Overlapping cues all show.
    func active(at time: Duration) -> [SubtitleCue] {
        // First index whose cue starts after `time`.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        // Walk back only as far as the longest cue could still be showing.
        var result: [SubtitleCue] = []
        var index = low - 1
        while index >= 0, cues[index].start + longestCue > time {
            if cues[index].end > time { result.append(cues[index]) }
            index -= 1
        }
        return result.reversed()
    }
}
