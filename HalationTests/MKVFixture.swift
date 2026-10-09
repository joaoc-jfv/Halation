import FFmpegKit
import Foundation

/// Builds Matroska files for tests by remuxing a generated MP4 with FFmpeg itself, so no media is committed.
enum MKVFixture {
    struct Options {
        /// Chapter titles and start times in seconds.
        var chapters: [(title: String, start: Double)] = []
        /// Writes a Dolby Vision configuration record on the video stream.
        var dolbyVision: (profile: UInt8, compatibilityID: UInt8)?
        /// Adds a text subtitle track with one cue.
        var subtitle: (language: String, forced: Bool)?
        /// Live mode writes no Cues, like a file recorded without an index.
        var withoutCues = false
    }

    enum Failure: Error { case ffmpeg(String, Int32) }

    private static func check(_ code: Int32, _ what: String) throws {
        if code < 0 { throw Failure.ffmpeg(what, code) }
    }

    static func make(from source: URL, options: Options = Options()) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("halation-\(UUID().uuidString).mkv")

        var inputRef: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&inputRef, source.path, nil, nil), "open")
        defer { avformat_close_input(&inputRef) }
        let input = inputRef!
        try check(avformat_find_stream_info(input, nil), "stream info")

        var outputRef: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputRef, nil, "matroska", target.path), "output")
        let output = outputRef!
        defer { avformat_free_context(output) }

        var outputIndex: [Int32: Int32] = [:]
        for index in 0..<Int(input.pointee.nb_streams) {
            let stream = input.pointee.streams[index]!
            guard let out = avformat_new_stream(output, nil) else { throw Failure.ffmpeg("new stream", -1) }
            try check(avcodec_parameters_copy(out.pointee.codecpar, stream.pointee.codecpar), "copy parameters")
            out.pointee.codecpar.pointee.codec_tag = 0
            av_dict_copy(&out.pointee.metadata, stream.pointee.metadata, 0)
            out.pointee.time_base = stream.pointee.time_base
            outputIndex[Int32(index)] = out.pointee.index
            if let dolby = options.dolbyVision, stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                try addDolbyVision(dolby, to: out.pointee.codecpar)
            }
        }

        var subtitleStream: UnsafeMutablePointer<AVStream>?
        if let subtitle = options.subtitle {
            let stream = avformat_new_stream(output, nil)!
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_SUBRIP
            stream.pointee.time_base = AVRational(num: 1, den: 1000)
            av_dict_set(&stream.pointee.metadata, "language", subtitle.language, 0)
            if subtitle.forced { stream.pointee.disposition |= AV_DISPOSITION_FORCED }
            subtitleStream = stream
        }

        try addChapters(options.chapters, to: output)

        var muxerOptions: OpaquePointer?
        if options.withoutCues { av_dict_set(&muxerOptions, "live", "1", 0) }
        try check(avio_open(&output.pointee.pb, target.path, AVIO_FLAG_WRITE), "open file")
        try check(avformat_write_header(output, &muxerOptions), "header")

        if let subtitleStream {
            let packet = av_packet_alloc()!
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            let text = Array("Hello from the fixture".utf8)
            try check(av_new_packet(packet, Int32(text.count)), "packet")
            text.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: text.count) }
            packet.pointee.stream_index = subtitleStream.pointee.index
            packet.pointee.pts = 500
            packet.pointee.dts = 500
            packet.pointee.duration = 1500
            try check(av_interleaved_write_frame(output, packet), "write subtitle")
        }

        let packet = av_packet_alloc()!
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let inputStream = input.pointee.streams[Int(packet.pointee.stream_index)]!
            guard let mapped = outputIndex[packet.pointee.stream_index] else { continue }
            packet.pointee.stream_index = mapped
            av_packet_rescale_ts(packet, inputStream.pointee.time_base, output.pointee.streams[Int(mapped)]!.pointee.time_base)
            try check(av_interleaved_write_frame(output, packet), "write")
        }
        try check(av_write_trailer(output), "trailer")
        avio_closep(&output.pointee.pb)
        return target
    }

    private static func addDolbyVision(_ config: (profile: UInt8, compatibilityID: UInt8), to parameters: UnsafeMutablePointer<AVCodecParameters>) throws {
        guard let side = av_packet_side_data_new(
            &parameters.pointee.coded_side_data, &parameters.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
            MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, 0
        ) else { throw Failure.ffmpeg("side data", -1) }
        var record = AVDOVIDecoderConfigurationRecord(
            dv_version_major: 1, dv_version_minor: 0, dv_profile: config.profile, dv_level: 6,
            rpu_present_flag: 1, el_present_flag: 0, bl_present_flag: 1,
            dv_bl_signal_compatibility_id: config.compatibilityID, dv_md_compression: 0
        )
        withUnsafeBytes(of: &record) { side.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
    }

    private static func addChapters(_ chapters: [(title: String, start: Double)], to context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard !chapters.isEmpty else { return }
        let array = av_malloc_array(chapters.count, MemoryLayout<UnsafeMutablePointer<AVChapter>?>.stride)!
            .bindMemory(to: UnsafeMutablePointer<AVChapter>?.self, capacity: chapters.count)
        for (index, chapter) in chapters.enumerated() {
            let pointer = av_mallocz(MemoryLayout<AVChapter>.size)!.bindMemory(to: AVChapter.self, capacity: 1)
            pointer.pointee.id = Int64(index + 1)
            pointer.pointee.time_base = AVRational(num: 1, den: 1000)
            pointer.pointee.start = Int64(chapter.start * 1000)
            pointer.pointee.end = index + 1 < chapters.count ? Int64(chapters[index + 1].start * 1000) : Int64(chapter.start * 1000) + 1000
            av_dict_set(&pointer.pointee.metadata, "title", chapter.title, 0)
            array[index] = pointer
        }
        context.pointee.chapters = array
        context.pointee.nb_chapters = UInt32(chapters.count)
    }
}
