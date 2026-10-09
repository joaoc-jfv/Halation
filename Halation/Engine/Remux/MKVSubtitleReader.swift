import FFmpegKit
import Foundation

/// Reads the text subtitle tracks out of a Matroska file (PLAN.md, milestone 2.3).
///
/// Matroska interleaves subtitles through the whole file, so reading them means one pass over it. The pass reads every
/// text track at once, so choosing a different language later costs nothing, and it reports what it has found as it goes.
enum MKVSubtitleReader {
    /// Codecs whose packets are plain or ASS-style text. Bitmap tracks (PGS, VobSub) are phase 3.
    static func isTextCodec(_ codec: String) -> Bool {
        ["subrip", "ass", "ssa", "webvtt", "text"].contains(codec)
    }

    /// Short name for the track list: `SRT`, `ASS`.
    static func displayName(forCodec codec: String) -> String {
        ["subrip": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "text": "Text"][codec] ?? codec.uppercased()
    }

    /// The text of one packet, ready for `SubtitleMarkup`. SubRip and WebVTT packets are the text itself; ASS packets are
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`, so the text is everything after the eighth comma.
    /// Nil for a packet with no text, or one that draws vector shapes (`{\p1}`).
    static func text(fromPacket bytes: [UInt8], codec: String) -> String? {
        var text = String(decoding: bytes, as: UTF8.self)
        if codec == "ass" || codec == "ssa" {
            var commas = 0
            guard let split = text.firstIndex(where: { character in
                if character == "," { commas += 1 }
                return commas == 8
            }) else { return nil }
            text = String(text[text.index(after: split)...])
            if text.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { return nil }
            text = text
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// How long a cue shows when the file doesn't say.
    static let defaultCueDuration: Duration = .seconds(3)

    /// Reads `streams` (the text tracks) from the file in one pass. `progress` gets the cue lists that changed, at most about
    /// once a second and once more at the end. Blocks until the pass is done or the calling task is cancelled, so run it detached.
    static func read(
        path: String, streams: [ProbedStream], progress: @Sendable ([Int: SubtitleCueList]) -> Void
    ) throws {
        guard !streams.isEmpty else { return }
        var opened: UnsafeMutablePointer<AVFormatContext>?
        let code = avformat_open_input(&opened, path, nil, nil)
        guard code >= 0, let context = opened else { throw MKVProbe.Failure.cannotOpen(message(for: code)) }
        defer { avformat_close_input(&opened) }

        let codecs = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0.codec) })
        for index in 0..<Int(context.pointee.nb_streams) where codecs[index] == nil {
            context.pointee.streams[index]?.pointee.discard = AVDISCARD_ALL
        }
        guard let packet = av_packet_alloc() else { return }
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }

        var cues: [Int: [SubtitleCue]] = [:]
        var changed = Set<Int>()
        var lastReport = ContinuousClock.now
        func report() {
            guard !changed.isEmpty else { return }
            progress(Dictionary(uniqueKeysWithValues: changed.map { ($0, SubtitleCueList(cues[$0] ?? [])) }))
            changed = []
            lastReport = .now
        }

        let noPTS = Int64.min
        while av_read_frame(context, packet) >= 0 {
            defer { av_packet_unref(packet) }
            if Task.isCancelled { return }
            let index = Int(packet.pointee.stream_index)
            guard let codec = codecs[index], let stream = context.pointee.streams[index], packet.pointee.size > 0,
                  let data = packet.pointee.data
            else { continue }
            let pts = packet.pointee.pts != noPTS ? packet.pointee.pts : packet.pointee.dts
            guard pts != noPTS else { continue }
            let timeBase = av_q2d(stream.pointee.time_base)
            let start = Duration.seconds(max(0, Double(pts) * timeBase))
            let length = packet.pointee.duration > 0 ? Duration.seconds(Double(packet.pointee.duration) * timeBase) : defaultCueDuration
            guard let text = text(fromPacket: Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))), codec: codec) else { continue }
            cues[index, default: []].append(SubtitleCue(start: start, end: start + length, text: text))
            changed.insert(index)
            if ContinuousClock.now - lastReport >= .seconds(1) { report() }
        }
        report()
    }

    private static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// Cue lists the scan has found so far, safe to read from the main actor while the scan writes from its own thread.
final class SubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [Int: SubtitleCueList] = [:]
    private var finished = false

    func update(_ new: [Int: SubtitleCueList]) {
        lock.withLock { lists.merge(new) { _, new in new } }
    }

    func markFinished() { lock.withLock { finished = true } }

    func list(for streamID: Int) -> SubtitleCueList? { lock.withLock { lists[streamID] } }

    /// Whether the pass over the file has ended (a track with no list then really has no cues).
    var isFinished: Bool { lock.withLock { finished } }
}
