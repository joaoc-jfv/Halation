import FFmpegKit
import Foundation

struct SegmentSpec: Equatable, Sendable {
    var index: Int
    /// First video keyframe of the segment, on the file's own timeline.
    var start: Duration
    /// Start of the next segment; nil for the last one, which runs to the end of the file.
    var end: Duration?
    /// What the playlist says (the last segment's is `fileDuration - start`).
    var duration: Duration
}

/// Groups the file's video keyframes into HLS segments. Every segment starts on a keyframe, so it can be cut and
/// decoded without anything before it.
enum SegmentPlanner {
    static let targetDuration: Duration = .seconds(6)

    /// Segments of at least `target` (a GOP can't be split, so they run to the next keyframe past it). A short tail is
    /// folded into the segment before it.
    static func plan(keyframes: [Duration], duration: Duration, target: Duration = targetDuration) -> [SegmentSpec] {
        guard let first = keyframes.first else { return [] }
        var boundaries = [first]
        for keyframe in keyframes.dropFirst() where keyframe - boundaries[boundaries.count - 1] >= target {
            boundaries.append(keyframe)
        }
        let fileEnd = max(duration, boundaries[boundaries.count - 1] + .milliseconds(100))
        if boundaries.count > 1, fileEnd - boundaries[boundaries.count - 1] < target / 2 {
            boundaries.removeLast()
        }
        return boundaries.enumerated().map { index, start in
            let end: Duration? = index + 1 < boundaries.count ? boundaries[index + 1] : nil
            return SegmentSpec(index: index, start: start, end: end, duration: (end ?? fileEnd) - start)
        }
    }

    /// The segment showing at `time`.
    static func index(at time: Duration, in segments: [SegmentSpec]) -> Int {
        guard let last = segments.lastIndex(where: { $0.start <= time }) else { return 0 }
        return last
    }
}

/// What can be copied into fragmented MP4 for AVPlayer without re-encoding (PLAN.md §3.2).
enum RemuxSupport {
    static func canCopyVideo(codec: String) -> Bool {
        ["hevc", "h264"].contains(codec)
    }

    static func canCopyAudio(codec: String) -> Bool {
        ["aac", "ac3", "eac3", "alac", "flac"].contains(codec)
    }

    /// Audio AVPlayer can't play but FFmpeg can decode (DTS, TrueHD, Opus, MP3, Vorbis, PCM, ...): it is converted to AAC.
    static func canTranscodeAudio(codec: String) -> Bool {
        guard !canCopyAudio(codec: codec), let descriptor = avcodec_descriptor_get_by_name(codec) else { return false }
        return avcodec_find_decoder(descriptor.pointee.id) != nil
    }

    static func canPlayAudio(codec: String) -> Bool { canCopyAudio(codec: codec) || canTranscodeAudio(codec: codec) }

    /// The audio track to play: the preferred language, else the file's default, else the first. Tracks that play as they are
    /// win over tracks that need converting (an AC-3 core beats a TrueHD track in the same language).
    static func chooseAudio(from streams: [ProbedStream], preferredLanguage: String?) -> ProbedStream? {
        let usable = streams.filter { $0.kind == .audio && canPlayAudio(codec: $0.codec) }
        let ranked = usable.filter { canCopyAudio(codec: $0.codec) } + usable.filter { !canCopyAudio(codec: $0.codec) }
        if let preferredLanguage, let match = ranked.first(where: { LanguageMatching.matches($0.language, preferredLanguage) }) {
            return match
        }
        return usable.first(where: \.isDefault) ?? usable.first
    }
}
