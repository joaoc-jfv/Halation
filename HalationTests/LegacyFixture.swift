import FFmpegKit
import Foundation

/// Files only the compatibility engine can play, generated with FFmpeg's own MPEG-4 encoder (this build has no AVI muxer, so
/// Matroska or MPEG-TS carry it): MPEG-4 Part 2 video, which neither AVFoundation nor the remuxer takes.
enum LegacyFixture {
    enum Failure: Error { case ffmpeg(String, Int32) }

    private static func check(_ code: Int32, _ what: String) throws {
        if code < 0 { throw Failure.ffmpeg(what, code) }
    }

    /// `container` is an FFmpeg muxer name: `matroska` or `mpegts`. A moving gradient, 320x240, `fps` frames a second.
    static func makeMPEG4(seconds: Int, fps: Int = 10, container: String = "matroska", fileExtension: String = "mkv") throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("halation-legacy-\(UUID().uuidString).\(fileExtension)")
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_MPEG4), let encoderRef = Optional(avcodec_alloc_context3(codec)), let encoder = encoderRef else {
            throw Failure.ffmpeg("encoder", -1)
        }
        var freeable: UnsafeMutablePointer<AVCodecContext>? = encoder
        defer { avcodec_free_context(&freeable) }
        encoder.pointee.width = 320
        encoder.pointee.height = 240
        encoder.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        encoder.pointee.time_base = AVRational(num: 1, den: Int32(fps))
        encoder.pointee.framerate = AVRational(num: Int32(fps), den: 1)
        encoder.pointee.gop_size = Int32(fps)
        encoder.pointee.max_b_frames = 0
        encoder.pointee.bit_rate = 400_000
        // Matroska keeps the codec's headers out of band; MPEG-TS needs them in the stream.
        if container == "matroska" { encoder.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER }

        var outputRef: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outputRef, nil, container, target.path), "output")
        let output = outputRef!
        defer { avformat_free_context(output) }
        let stream = avformat_new_stream(output, nil)!
        try check(avcodec_open2(encoder, codec, nil), "open encoder")
        try check(avcodec_parameters_from_context(stream.pointee.codecpar, encoder), "parameters")
        stream.pointee.time_base = encoder.pointee.time_base
        try check(avio_open(&output.pointee.pb, target.path, AVIO_FLAG_WRITE), "open file")
        try check(avformat_write_header(output, nil), "header")

        var frameRef = av_frame_alloc()
        defer { av_frame_free(&frameRef) }
        let frame = frameRef!
        frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        frame.pointee.width = 320
        frame.pointee.height = 240
        var packetRef = av_packet_alloc()
        defer { av_packet_free(&packetRef) }
        let packet = packetRef!

        func drain() throws {
            while avcodec_receive_packet(encoder, packet) >= 0 {
                defer { av_packet_unref(packet) }
                packet.pointee.stream_index = stream.pointee.index
                av_packet_rescale_ts(packet, encoder.pointee.time_base, stream.pointee.time_base)
                try check(av_interleaved_write_frame(output, packet), "write")
            }
        }

        for index in 0..<seconds * fps {
            try check(av_frame_make_writable(frame) < 0 ? av_frame_get_buffer(frame, 0) : 0, "buffer")
            for row in 0..<240 {
                let line = frame.pointee.data.0! + row * Int(frame.pointee.linesize.0)
                for column in 0..<320 { line[column] = UInt8((column + row + index * 8) & 255) }
            }
            for row in 0..<120 {
                let u = frame.pointee.data.1! + row * Int(frame.pointee.linesize.1)
                let v = frame.pointee.data.2! + row * Int(frame.pointee.linesize.2)
                for column in 0..<160 { u[column] = UInt8((column + index * 4) & 255); v[column] = UInt8((row + index * 4) & 255) }
            }
            frame.pointee.pts = Int64(index)
            try check(avcodec_send_frame(encoder, frame), "send frame")
            try drain()
        }
        try check(avcodec_send_frame(encoder, nil), "flush")
        try drain()
        try check(av_write_trailer(output), "trailer")
        avio_closep(&output.pointee.pb)
        return target
    }
}
