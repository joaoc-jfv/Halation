import Foundation
import Libavcodec
import Libavformat
import Libavutil

// mkvsegments <input.mkv> <output dir> [--audio LANG] [--seg-target SECONDS] [--limit SECONDS]
//
// Writes init.mp4 plus one seg_NNN.m4s per video GOP group, each cut independently (seek, fresh muxer, copy),
// with tfdt rewritten to the segment's true position. segments.txt lists start and duration, for hlsprobe.

func check(_ code: Int32, _ what: String) {
    if code < 0 {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        FileHandle.standardError.write(Data("error: \(what): \(String(cString: buffer))\n".utf8))
        exit(1)
    }
}
func fourCC(_ text: String) -> UInt32 { text.utf8.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
let audioLanguage = option("--audio") ?? "eng"
let segmentTarget = option("--seg-target").flatMap(Double.init) ?? 6
let scanLimit = option("--limit").flatMap(Double.init) ?? 30
setvbuf(stdout, nil, _IOLBF, 0)
args.removeAll { $0 == "--index-only" }
guard args.count == 2 else { print("usage: mkvsegments <input.mkv> <output dir> [--audio LANG] [--seg-target S] [--limit S]"); exit(2) }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var inputRef: UnsafeMutablePointer<AVFormatContext>?
check(avformat_open_input(&inputRef, args[0], nil, nil), "open")
check(avformat_find_stream_info(inputRef, nil), "stream info")
let input = inputRef!
let noPTS = Int64.min

func language(of stream: UnsafeMutablePointer<AVStream>) -> String? {
    av_dict_get(stream.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
}
var videoIndex = -1, audioIndex = -1
for i in 0..<Int(input.pointee.nb_streams) {
    let stream = input.pointee.streams[i]!
    let type = stream.pointee.codecpar.pointee.codec_type
    if type == AVMEDIA_TYPE_VIDEO, videoIndex < 0 { videoIndex = i }
    else if type == AVMEDIA_TYPE_AUDIO, audioIndex < 0, language(of: stream) == audioLanguage { audioIndex = i }
    else { stream.pointee.discard = AVDISCARD_ALL }
}
guard videoIndex >= 0, audioIndex >= 0 else { print("need video and \(audioLanguage) audio"); exit(1) }
let selected = [videoIndex, audioIndex]
func seconds(_ ts: Int64, _ index: Int) -> Double { Double(ts) * av_q2d(input.pointee.streams[index]!.pointee.time_base) }

// MARK: What the Matroska Cues give us without reading the file

do {
    let stream = input.pointee.streams[videoIndex]!
    // libavformat parses the Cues lazily, on the first seek.
    let before = Int(avformat_index_get_entries_count(stream))
    let seekStart = Date()
    _ = av_seek_frame(input, -1, Int64(Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD)
    print(String(format: "first seek took %.0f ms; index entries before/after: %d / %d", Date().timeIntervalSince(seekStart) * 1000, before, Int(avformat_index_get_entries_count(stream))))
    let count = Int(avformat_index_get_entries_count(stream))
    var keyEntries: [Double] = []
    var positions: [Int64] = []
    for i in 0..<count {
        guard let entry = avformat_index_get_entry(stream, Int32(i)) else { continue }
        if entry.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 { keyEntries.append(Double(entry.pointee.timestamp) * av_q2d(stream.pointee.time_base)); positions.append(entry.pointee.pos) }
    }
    let spacing = zip(keyEntries, keyEntries.dropFirst()).map { $1 - $0 }.sorted()
    let duration = Double(input.pointee.duration) / Double(AV_TIME_BASE)
    print(String(format: "cue index: %d entries, %d keyframes; first %.3f s, last %.3f s of a %.1f s file; spacing min/median/max %.2f/%.2f/%.2f s",
                 count, keyEntries.count, keyEntries.first ?? 0, keyEntries.last ?? 0, duration,
                 spacing.first ?? 0, spacing.isEmpty ? 0 : spacing[spacing.count / 2], spacing.last ?? 0))
    if CommandLine.arguments.contains("--index-only") { exit(0) }
}

// MARK: Keyframe index (a scan here; production would read the Matroska Cues)

let packet = av_packet_alloc()!
var keyframes: [Double] = []
while av_read_frame(input, packet) >= 0 {
    defer { av_packet_unref(packet) }
    guard Int(packet.pointee.stream_index) == videoIndex, packet.pointee.flags & AV_PKT_FLAG_KEY != 0, packet.pointee.pts != noPTS else { continue }
    let t = seconds(packet.pointee.pts, videoIndex)
    if t > scanLimit { break }
    keyframes.append(t)
}
// Boundaries: keyframes at least `segmentTarget` apart.
var boundaries: [Double] = [keyframes[0]]
for t in keyframes where t - boundaries.last! >= segmentTarget { boundaries.append(t) }
print("keyframes in first \(Int(scanLimit)) s: \(keyframes.count); \(boundaries.count) boundaries: " + boundaries.map { String(format: "%.3f", $0) }.joined(separator: " "))
let origin = boundaries[0]

// MARK: One segment

struct Segment { var data: Data; var firstVideoPTS: Double; var firstAudioPTS: Double? }

/// Seeks to `start`, copies video and audio until `end` (nil = to the end of the scan) with a fresh muxer, and returns moof+mdat
/// (plus moov first when `includeInit`).
func muxSegment(start: Double, end: Double?) -> Segment {
    check(av_seek_frame(input, Int32(videoIndex), Int64(start / av_q2d(input.pointee.streams[videoIndex]!.pointee.time_base)), AVSEEK_FLAG_BACKWARD), "seek")

    var outRef: UnsafeMutablePointer<AVFormatContext>?
    check(avformat_alloc_output_context2(&outRef, nil, "mp4", nil), "output")
    let out = outRef!
    var outputIndex: [Int: Int32] = [:]
    for index in selected {
        let stream = input.pointee.streams[index]!
        let st = avformat_new_stream(out, nil)!
        check(avcodec_parameters_copy(st.pointee.codecpar, stream.pointee.codecpar), "copy params")
        st.pointee.codecpar.pointee.codec_tag = stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC ? fourCC("hvc1") : 0
        if stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3 { st.pointee.codecpar.pointee.frame_size = 1536 }
        av_dict_copy(&st.pointee.metadata, stream.pointee.metadata, 0)
        st.pointee.time_base = stream.pointee.time_base
        outputIndex[index] = st.pointee.index
    }
    out.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL
    final class Sink { var data = Data() }
    let sink = Sink()
    let buffer = av_malloc(1 << 16)!.assumingMemoryBound(to: UInt8.self)
    let io = avio_alloc_context(buffer, 1 << 16, 1, Unmanaged.passUnretained(sink).toOpaque(), nil, { opaque, buf, size in
        Unmanaged<Sink>.fromOpaque(opaque!).takeUnretainedValue().data.append(buf!, count: Int(size)); return size
    }, nil)!
    out.pointee.pb = io
    out.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
    var options: OpaquePointer?
    av_dict_set(&options, "movflags", "frag_keyframe+delay_moov+default_base_moof", 0)
    check(avformat_write_header(out, &options), "header")

    let pkt = av_packet_alloc()!
    var firstVideo: Double?, firstAudio: Double?
    var videoDone = false, audioDone = false
    while !(videoDone && audioDone), av_read_frame(input, pkt) >= 0 {
        defer { av_packet_unref(pkt) }
        let index = Int(pkt.pointee.stream_index)
        guard let mapped = outputIndex[index], pkt.pointee.pts != noPTS else { continue }
        let t = seconds(pkt.pointee.pts, index)
        if index == videoIndex {
            if firstVideo == nil {
                guard pkt.pointee.flags & AV_PKT_FLAG_KEY != 0, t >= start - 0.001 else { continue }  // start on the boundary keyframe
                firstVideo = t
            }
            if let end, t >= end - 0.001 { videoDone = true; continue }
        } else {
            if t < start - 0.001 { continue }
            if let end, t >= end - 0.001 { audioDone = true; continue }
            if firstAudio == nil { firstAudio = t }
        }
        if firstVideo == nil { continue }  // audio before the first video keyframe
        pkt.pointee.stream_index = mapped
        av_packet_rescale_ts(pkt, input.pointee.streams[index]!.pointee.time_base, out.pointee.streams[Int(mapped)]!.pointee.time_base)
        check(av_interleaved_write_frame(out, pkt), "write")
    }
    check(av_write_trailer(out), "trailer")
    avio_flush(io)
    return Segment(data: sink.data, firstVideoPTS: firstVideo ?? start, firstAudioPTS: firstAudio)
}

// MARK: ISO-BMFF helpers

func u32(_ d: Data, _ i: Int) -> Int { d[i..<i + 4].reduce(0) { $0 << 8 | Int($1) } }
func put(_ d: inout Data, _ i: Int, _ value: UInt64, bytes: Int) { for k in 0..<bytes { d[i + k] = UInt8((value >> UInt64(8 * (bytes - 1 - k))) & 0xFF) } }
func children(_ d: Data, _ start: Int, _ end: Int) -> [(type: String, offset: Int, size: Int)] {
    var result: [(String, Int, Int)] = []
    var i = start
    while i + 8 <= end {
        let size = u32(d, i)
        guard size >= 8, i + size <= end else { break }
        result.append((String(decoding: d[i + 4..<i + 8], as: UTF8.self), i, size))
        i += size
    }
    return result
}
/// Track timescales in `moov` order (mdhd).
func timescales(_ moov: Data) -> [Int] {
    var result: [Int] = []
    for trak in children(moov, 8, moov.count) where trak.type == "trak" {
        for mdia in children(moov, trak.offset + 8, trak.offset + trak.size) where mdia.type == "mdia" {
            for mdhd in children(moov, mdia.offset + 8, mdia.offset + mdia.size) where mdhd.type == "mdhd" {
                let version = Int(moov[mdhd.offset + 8])
                result.append(u32(moov, mdhd.offset + 8 + (version == 1 ? 20 : 12)))
            }
        }
    }
    return result
}
/// Edit-list media_time per track (0 when absent), from the first `elst` entry.
func mediaTimes(_ moov: Data) -> [Int] {
    var result: [Int] = []
    for trak in children(moov, 8, moov.count) where trak.type == "trak" {
        var time = 0
        for edts in children(moov, trak.offset + 8, trak.offset + trak.size) where edts.type == "edts" {
            for elst in children(moov, edts.offset + 8, edts.offset + edts.size) where elst.type == "elst" {
                let version = Int(moov[elst.offset + 8])
                let entries = u32(moov, elst.offset + 12)
                if entries > 0 {
                    time = version == 1 ? Int(Int64(bitPattern: UInt64(moov[elst.offset + 24..<elst.offset + 32].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })))
                                       : Int(Int32(bitPattern: UInt32(u32(moov, elst.offset + 20))))
                }
            }
        }
        result.append(time)
    }
    return result
}
/// First-sample composition offset of a traf's trun (0 if none).
func firstCompositionOffset(_ d: Data, trun: (offset: Int, size: Int)) -> Int {
    let flags = u32(d, trun.offset + 8) & 0xFFFFFF
    var p = trun.offset + 16
    if flags & 1 != 0 { p += 4 }
    if flags & 4 != 0 { p += 4 }
    if flags & 0x100 != 0 { p += 4 }
    if flags & 0x200 != 0 { p += 4 }
    if flags & 0x400 != 0 { p += 4 }
    return flags & 0x800 != 0 ? Int(Int32(bitPattern: UInt32(u32(d, p)))) : 0
}

// MARK: Build

var listing = ""
var initData = Data()
var moovInfo: (scales: [Int], mediaTimes: [Int]) = ([], [])
// The last boundary only closes the final segment, so every segment has an end.
for (index, start) in boundaries.dropLast().enumerated() {
    let end: Double? = boundaries[index + 1]
    var segment = muxSegment(start: start, end: end)
    let top = children(segment.data, 0, segment.data.count)
    let moov = top.first { $0.type == "moov" }!
    if index == 0 {
        initData = segment.data[0..<moov.offset + moov.size]
        let moovBox = Data(segment.data[moov.offset..<moov.offset + moov.size])  // re-indexed from 0, as the helpers expect
        moovInfo = (timescales(moovBox), mediaTimes(moovBox))
        try initData.write(to: outDir.appendingPathComponent("init.mp4"))
        print("init: track timescales \(moovInfo.scales), edit-list media times \(moovInfo.mediaTimes)")
    }
    // Rewrite tfdt so presentation time = pts - origin, where presentation = tfdt + cts - media_time.
    // A segment can hold several fragments (one per keyframe): fix the first, then shift the rest by the same per-track delta.
    var data = segment.data
    var delta: [Int: Int] = [:]  // track index → amount added to every tfdt in this segment
    for moof in children(data, 0, data.count) where moof.type == "moof" {
        for traf in children(data, moof.offset + 8, moof.offset + moof.size) where traf.type == "traf" {
            let parts = children(data, traf.offset + 8, traf.offset + traf.size)
            guard let tfhd = parts.first(where: { $0.type == "tfhd" }), let tfdt = parts.first(where: { $0.type == "tfdt" }),
                  let trun = parts.first(where: { $0.type == "trun" }) else { continue }
            let track = u32(data, tfhd.offset + 12) - 1
            let version = Int(data[tfdt.offset + 8])
            let width = version == 1 ? 8 : 4
            let current = data[tfdt.offset + 12..<tfdt.offset + 12 + width].reduce(0) { $0 << 8 | Int($1) }
            if delta[track] == nil {
                let scale = Double(moovInfo.scales[track])
                let firstPTS = track == 0 ? segment.firstVideoPTS : (segment.firstAudioPTS ?? segment.firstVideoPTS)
                let cts = track == 0 ? firstCompositionOffset(data, trun: (trun.offset, trun.size)) : 0
                let wanted = Int((firstPTS - origin) * scale) + moovInfo.mediaTimes[track] - cts
                delta[track] = max(wanted, 0) - current
            }
            put(&data, tfdt.offset + 12, UInt64(max(current + delta[track]!, 0)), bytes: width)
        }
    }
    segment.data = data
    let name = String(format: "seg_%03d.m4s", index)
    let moofStart = children(data, 0, data.count).first { $0.type == "moof" }!.offset
    try data[moofStart...].write(to: outDir.appendingPathComponent(name))
    let duration = end! - start
    listing += String(format: "%@ start=%.3f duration=%.3f bytes=%d\n", name, start - origin, duration, data.count - moofStart)
    print(String(format: "  %@: video from %.3f s, audio from %.3f s, %.1f MB", name, segment.firstVideoPTS - origin, (segment.firstAudioPTS ?? 0) - origin, Double(data.count - moofStart) / 1e6))
}
try listing.write(to: outDir.appendingPathComponent("segments.txt"), atomically: true, encoding: .utf8)
