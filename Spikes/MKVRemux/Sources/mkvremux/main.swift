import Foundation
import Libavcodec
import Libavformat
import Libavutil

// mkvremux <input.mkv> <output dir> [--start SECONDS] [--duration SECONDS] [--audio LANG]
//
// Copies the video track and one audio track of an MKV into fragmented MP4 (no re-encode), and writes
//   combined.mp4          init + all fragments, playable as a single file
//   init.mp4              ftyp + moov
//   seg_000.m4s, ...      one moof+mdat per video GOP
//   segments.txt          start and duration of every segment, from the packet timestamps
// so the pieces can be served to AVPlayer as HLS.

func message(_ code: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    av_strerror(code, &buffer, buffer.count)
    return String(cString: buffer)
}

func check(_ code: Int32, _ what: String) {
    if code < 0 {
        FileHandle.standardError.write(Data("error: \(what): \(message(code))\n".utf8))
        exit(1)
    }
}

func fourCC(_ text: String) -> UInt32 {
    text.utf8.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
}

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
let startSeconds = option("--start").flatMap(Double.init) ?? 0
let durationSeconds = option("--duration").flatMap(Double.init) ?? 12
let audioLanguage = option("--audio") ?? "eng"
let keepTimestamps = args.firstIndex(of: "--keep-timestamps").map { args.remove(at: $0) } != nil
guard args.count == 2 else {
    print("usage: mkvremux <input.mkv> <output dir> [--start S] [--duration S] [--audio LANG]")
    exit(2)
}
let inputPath = args[0]
let outputDirectory = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: Input

var input: UnsafeMutablePointer<AVFormatContext>?
check(avformat_open_input(&input, inputPath, nil, nil), "open input")
check(avformat_find_stream_info(input, nil), "find stream info")
let inputContext = input!

struct Mapping { var inputIndex: Int; var outputIndex: Int32; var isVideo: Bool }
var mappings: [Mapping] = []
var output: UnsafeMutablePointer<AVFormatContext>?
check(avformat_alloc_output_context2(&output, nil, "mp4", nil), "alloc output")
let outputContext = output!

func language(of stream: UnsafeMutablePointer<AVStream>) -> String? {
    av_dict_get(stream.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
}

var haveVideo = false, haveAudio = false
print("input: \(inputPath.split(separator: "/").last ?? "") — \(inputContext.pointee.nb_streams) streams")
for index in 0..<Int(inputContext.pointee.nb_streams) {
    let stream = inputContext.pointee.streams[index]!
    let parameters = stream.pointee.codecpar!
    let type = parameters.pointee.codec_type
    let name = String(cString: avcodec_get_name(parameters.pointee.codec_id))
    if type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO {
        print("  #\(index) \(type == AVMEDIA_TYPE_VIDEO ? "video" : "audio") \(name) lang=\(language(of: stream) ?? "-")"
              + (type == AVMEDIA_TYPE_VIDEO ? " \(parameters.pointee.width)x\(parameters.pointee.height)" : " ch=\(parameters.pointee.ch_layout.nb_channels)"))
    }
    let wanted: Bool
    if type == AVMEDIA_TYPE_VIDEO, !haveVideo { wanted = true; haveVideo = true }
    else if type == AVMEDIA_TYPE_AUDIO, !haveAudio, language(of: stream) == audioLanguage { wanted = true; haveAudio = true }
    else { wanted = false }
    stream.pointee.discard = wanted ? AVDISCARD_DEFAULT : AVDISCARD_ALL
    guard wanted else { continue }

    let out = avformat_new_stream(outputContext, nil)!
    check(avcodec_parameters_copy(out.pointee.codecpar, parameters), "copy parameters")
    out.pointee.codecpar.pointee.codec_tag = 0
    // HEVC in MP4 for AVFoundation is `hvc1`; the muxer turns that into `dvh1` when Dolby Vision config is present.
    if parameters.pointee.codec_id == AV_CODEC_ID_HEVC { out.pointee.codecpar.pointee.codec_tag = fourCC("hvc1") }
    // Matroska doesn't carry the E-AC-3 frame size (6 blocks of 256 samples); the muxer wants it.
    if parameters.pointee.codec_id == AV_CODEC_ID_EAC3, out.pointee.codecpar.pointee.frame_size == 0 {
        out.pointee.codecpar.pointee.frame_size = 1536
    }
    av_dict_copy(&out.pointee.metadata, stream.pointee.metadata, 0)
    out.pointee.time_base = stream.pointee.time_base
    mappings.append(Mapping(inputIndex: index, outputIndex: out.pointee.index, isVideo: type == AVMEDIA_TYPE_VIDEO))
}
guard haveVideo, haveAudio else {
    print("error: need a video track and an audio track with language \(audioLanguage)")
    exit(1)
}

// MARK: Output to memory

final class Sink {
    var data = Data()
}
let sink = Sink()
let bufferSize = 1 << 16
let ioBuffer = av_malloc(bufferSize)!.assumingMemoryBound(to: UInt8.self)
let ioContext = avio_alloc_context(ioBuffer, Int32(bufferSize), 1, Unmanaged.passUnretained(sink).toOpaque(), nil, { opaque, buffer, size in
    guard let opaque, let buffer else { return -1 }
    Unmanaged<Sink>.fromOpaque(opaque).takeUnretainedValue().data.append(buffer, count: Int(size))
    return size
}, nil)!
outputContext.pointee.pb = ioContext
outputContext.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

// The mp4 muxer only writes the Dolby Vision configuration box (dvcC/dvvC) when strictness is "unofficial".
outputContext.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

// delay_moov: the E-AC-3 `dec3` box is derived from the first packets, so the moov follows the first fragment.
var muxerOptions: OpaquePointer?
av_dict_set(&muxerOptions, "movflags", "frag_keyframe+delay_moov+default_base_moof", 0)
check(avformat_write_header(outputContext, &muxerOptions), "write header")
avio_flush(ioContext)

// MARK: Copy packets

if startSeconds > 0 {
    check(av_seek_frame(inputContext, -1, Int64(startSeconds * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD), "seek")
}
let noPTS = Int64.min
let packet = av_packet_alloc()!
var firstVideoPTS: Double?
var keyframeTimes: [Double] = []
var lastVideoPTS = 0.0
var packetCount = 0, bytes = 0
let started = Date()

reading: while av_read_frame(inputContext, packet) >= 0 {
    defer { av_packet_unref(packet) }
    guard let mapping = mappings.first(where: { $0.inputIndex == Int(packet.pointee.stream_index) }) else { continue }
    let inputStream = inputContext.pointee.streams[mapping.inputIndex]!
    let outputStream = outputContext.pointee.streams[Int(mapping.outputIndex)]!
    let seconds = packet.pointee.pts == noPTS ? nil : Double(packet.pointee.pts) * av_q2d(inputStream.pointee.time_base)

    if mapping.isVideo, let seconds {
        let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        if firstVideoPTS == nil {
            // Wait for the first keyframe, so the segment starts clean.
            guard isKey else { continue }
            firstVideoPTS = seconds
        }
        if isKey {
            if seconds - firstVideoPTS! >= durationSeconds { break reading }
            keyframeTimes.append(seconds)
        }
        lastVideoPTS = seconds
    } else if firstVideoPTS == nil || (seconds ?? 0) < firstVideoPTS! - 0.001 {
        continue  // audio before the first video keyframe
    }

    packetCount += 1
    bytes += Int(packet.pointee.size)
    packet.pointee.stream_index = mapping.outputIndex
    av_packet_rescale_ts(packet, inputStream.pointee.time_base, outputStream.pointee.time_base)
    // Shift to start at zero, so the segment sits at the start of the timeline.
    let shift = keepTimestamps ? 0 : Int64((firstVideoPTS ?? 0) / av_q2d(outputStream.pointee.time_base))
    if packet.pointee.pts != noPTS { packet.pointee.pts -= shift }
    if packet.pointee.dts != noPTS { packet.pointee.dts -= shift }
    check(av_interleaved_write_frame(outputContext, packet), "write packet")
}
check(av_write_trailer(outputContext), "write trailer")
avio_flush(ioContext)
print(String(format: "copied %d packets, %.1f MB of payload in %.0f ms (%.1f s of video)", packetCount, Double(bytes) / 1e6,
             Date().timeIntervalSince(started) * 1000, lastVideoPTS - (firstVideoPTS ?? 0)))

// MARK: Split into init + fragments

struct Box { var type: String; var range: Range<Int> }
func boxes(in data: Data) -> [Box] {
    var result: [Box] = []
    var offset = 0
    while offset + 8 <= data.count {
        var size = Int(data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) })
        let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
        if size == 1, offset + 16 <= data.count { size = Int(data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) }) }
        if size == 0 { size = data.count - offset }
        guard size >= 8, offset + size <= data.count else { break }
        result.append(Box(type: type, range: offset..<offset + size))
        offset += size
    }
    return result
}

let all = sink.data
let topLevel = boxes(in: all)
print("top-level boxes: " + topLevel.prefix(6).map(\.type).joined(separator: " ") + (topLevel.count > 6 ? " … (\(topLevel.count) total)" : ""))
try all.write(to: outputDirectory.appendingPathComponent("combined.mp4"))
let moovEnd = topLevel.first { $0.type == "moov" }!.range.upperBound
try all[0..<moovEnd].write(to: outputDirectory.appendingPathComponent("init.mp4"))

// One segment per moof+mdat pair run (the muxer cuts at each video keyframe).
var segmentRanges: [Range<Int>] = []
var currentStart: Int?
for box in topLevel where box.range.lowerBound >= moovEnd {
    if box.type == "moof" { if let s = currentStart { segmentRanges.append(s..<box.range.lowerBound) }; currentStart = box.range.lowerBound }
    if box.type == "mfra" || box.type == "sidx" { continue }
}
if let s = currentStart {
    let end = topLevel.last { $0.type == "mdat" }?.range.upperBound ?? all.count
    segmentRanges.append(s..<end)
}
var listing = ""
for (index, range) in segmentRanges.enumerated() {
    let name = String(format: "seg_%03d.m4s", index)
    try all[range].write(to: outputDirectory.appendingPathComponent(name))
    let start = index < keyframeTimes.count ? keyframeTimes[index] - (firstVideoPTS ?? 0) : 0
    let end = index + 1 < keyframeTimes.count ? keyframeTimes[index + 1] - (firstVideoPTS ?? 0) : lastVideoPTS - (firstVideoPTS ?? 0)
    listing += String(format: "%@ start=%.3f duration=%.3f bytes=%d\n", name, start, end - start, range.count)
}
try listing.write(to: outputDirectory.appendingPathComponent("segments.txt"), atomically: true, encoding: .utf8)
print("wrote init.mp4, \(segmentRanges.count) segments and combined.mp4 to \(outputDirectory.path)")
print(listing, terminator: "")
