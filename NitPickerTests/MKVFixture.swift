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
        /// Adds an ASS track (language) with three events: styled text over two lines, a vector drawing, and text with a comma.
        var assSubtitle: String?
        /// Adds an uncompressed PCM audio track (a sine wave, 48 kHz) that AVPlayer can't take as it is, so the remuxer has to convert it.
        var pcmAudio: (language: String, channels: Int)?
        /// Live mode writes no Cues, like a file recorded without an index.
        var withoutCues = false
    }

    enum Failure: Error { case ffmpeg(String, Int32) }

    private static func check(_ code: Int32, _ what: String) throws {
        if code < 0 { throw Failure.ffmpeg(what, code) }
    }

    static func make(from source: URL, options: Options = Options()) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-\(UUID().uuidString).mkv")

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

        var pcmStream: UnsafeMutablePointer<AVStream>?
        if let pcm = options.pcmAudio {
            let stream = avformat_new_stream(output, nil)!
            let parameters = stream.pointee.codecpar!
            parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            parameters.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
            parameters.pointee.format = AV_SAMPLE_FMT_S16.rawValue
            parameters.pointee.sample_rate = 48000
            parameters.pointee.bits_per_coded_sample = 16
            parameters.pointee.block_align = Int32(2 * pcm.channels)
            parameters.pointee.bit_rate = Int64(48000 * 16 * pcm.channels)
            av_channel_layout_default(&parameters.pointee.ch_layout, Int32(pcm.channels))
            stream.pointee.time_base = AVRational(num: 1, den: 48000)
            av_dict_set(&stream.pointee.metadata, "language", pcm.language, 0)
            pcmStream = stream
        }

        var assStream: UnsafeMutablePointer<AVStream>?
        if let language = options.assSubtitle {
            let stream = avformat_new_stream(output, nil)!
            stream.pointee.codecpar.pointee.codec_type = AVMEDIA_TYPE_SUBTITLE
            stream.pointee.codecpar.pointee.codec_id = AV_CODEC_ID_ASS
            stream.pointee.time_base = AVRational(num: 1, den: 1000)
            let header = Array("[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n".utf8)
            stream.pointee.codecpar.pointee.extradata = av_mallocz(header.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!.bindMemory(to: UInt8.self, capacity: header.count)
            stream.pointee.codecpar.pointee.extradata.update(from: header, count: header.count)
            stream.pointee.codecpar.pointee.extradata_size = Int32(header.count)
            av_dict_set(&stream.pointee.metadata, "language", language, 0)
            assStream = stream
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

        // PCM goes in step with the video, as in a real file, so a cut can find audio next to the keyframe it seeks to.
        var pcmChunk = 0
        func writePCM(upTo seconds: Double) throws {
            guard let pcmStream, let pcm = options.pcmAudio else { return }
            let packet = av_packet_alloc()!
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            let total = Double(input.pointee.duration) / Double(AV_TIME_BASE)
            let chunk = 1024
            let timeBase = pcmStream.pointee.time_base
            while Double(pcmChunk * chunk) / 48000 <= min(seconds, total), pcmChunk < Int(total * 48000) / chunk {
                var samples = [Int16]()
                samples.reserveCapacity(chunk * pcm.channels)
                for frame in 0..<chunk {
                    let t = Double(pcmChunk * chunk + frame) / 48000
                    for channel in 0..<pcm.channels { samples.append(Int16(8000 * sin(2 * .pi * (220 + 110 * Double(channel)) * t))) }
                }
                try check(av_new_packet(packet, Int32(samples.count * 2)), "packet")
                samples.withUnsafeBytes { packet.pointee.data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: $0.count) }
                packet.pointee.stream_index = pcmStream.pointee.index
                let pts = av_rescale_q(Int64(pcmChunk * chunk), AVRational(num: 1, den: 48000), timeBase)
                packet.pointee.pts = pts
                packet.pointee.dts = pts
                packet.pointee.duration = av_rescale_q(Int64(chunk), AVRational(num: 1, den: 48000), timeBase)
                try check(av_interleaved_write_frame(output, packet), "write pcm")
                pcmChunk += 1
            }
        }

        if let assStream {
            let packet = av_packet_alloc()!
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            let events: [(Int64, Int64, String)] = [
                (3000, 1000, "0,0,Default,,0,0,0,,{\\i1}Styled{\\i0}\\Nsecond line"),
                (5000, 500, "1,0,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}"),
                (6000, 1000, "2,0,Default,,0,0,0,,Comma, inside"),
            ]
            for (start, length, line) in events {
                let text = Array(line.utf8)
                try check(av_new_packet(packet, Int32(text.count)), "packet")
                text.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: text.count) }
                packet.pointee.stream_index = assStream.pointee.index
                packet.pointee.pts = start
                packet.pointee.dts = start
                packet.pointee.duration = length
                try check(av_interleaved_write_frame(output, packet), "write ass")
            }
        }

        let packet = av_packet_alloc()!
        defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
        while av_read_frame(input, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let inputStream = input.pointee.streams[Int(packet.pointee.stream_index)]!
            guard let mapped = outputIndex[packet.pointee.stream_index] else { continue }
            try writePCM(upTo: Double(packet.pointee.pts) * av_q2d(inputStream.pointee.time_base))
            packet.pointee.stream_index = mapped
            av_packet_rescale_ts(packet, inputStream.pointee.time_base, output.pointee.streams[Int(mapped)]!.pointee.time_base)
            try check(av_interleaved_write_frame(output, packet), "write")
        }
        try writePCM(upTo: .infinity)
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
