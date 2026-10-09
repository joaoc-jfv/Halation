import Foundation

enum ChapterNavigation {
    /// How far into a chapter "previous" still means "back to its start".
    static let restartThreshold: Duration = .seconds(3)

    /// The chapter showing at `time`: the last one that has started.
    static func index(at time: Duration, in chapters: [Chapter]) -> Int? {
        chapters.lastIndex { $0.start <= time }
    }

    static func next(after time: Duration, in chapters: [Chapter]) -> Chapter? {
        chapters.first { $0.start > time }
    }

    /// Past the first few seconds of a chapter, its own start; otherwise the chapter before it.
    static func previous(before time: Duration, in chapters: [Chapter]) -> Chapter? {
        guard let current = index(at: time, in: chapters) else { return chapters.first }
        if time - chapters[current].start > restartThreshold || current == 0 { return chapters[current] }
        return chapters[current - 1]
    }

    /// Chapter starts as fractions of the duration, for the scrubber's tick marks.
    static func marks(for chapters: [Chapter], duration: Duration) -> [Double] {
        guard duration > .zero else { return [] }
        return chapters.dropFirst().map { $0.start.seconds / duration.seconds }.filter { $0 > 0 && $0 < 1 }
    }
}

struct ResumeOffer: Equatable {
    var position: Duration
    var label: String { "Resume from \(position.clockString)" }
}
