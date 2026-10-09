import FFmpegKit
import Foundation

/// Decodes an audio track AVPlayer can't play (DTS, TrueHD, Opus, MP3, Vorbis, PCM...) and re-encodes it as AAC, so the
/// remuxer can still hand it to AVPlayer (PLAN.md, milestone 2.4).
///
/// The encoder keeps its state from one segment to the next, so playing straight on is seamless; it is rebuilt only when
/// playback jumps (a seek), which can cost a click at that one boundary. The FFmpeg build here has no AC-3/E-AC-3 encoder,
/// so AAC it is: up to 5.1 channels, anything wider is mixed down to 5.1.
///
/// Not thread-safe: the segment muxer's serial queue is the only caller.
final class AudioTranscoder {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// What the output will be, from the source stream alone.
    struct Format: Equatable {
        var channels: Int
        var sampleRate: Int
        var bitRate: Int
        /// The CODECS entry for the HLS master playlist.
        static let codecString = "mp4a.40.2"
    }

    static func outputFormat(for stream: ProbedStream) -> Format {
        let channels = min(max(stream.channels, 1), 6)
        let rate = stream.sampleRate > 0 ? min(stream.sampleRate, 48000) : 48000
        return Format(channels: channels, sampleRate: rate, bitRate: channels == 1 ? 96_000 : channels == 2 ? 192_000 : 64_000 * channels)
    }

    let format: Format
    /// Describes the encoded stream for the muxer (AAC, with its AudioSpecificConfig).
    let outputParameters: UnsafeMutablePointer<AVCodecParameters>
    /// Where the last segment stopped. The next one continues the stream only if it starts here.
    var resumeTime: Duration?

    private let sourceParameters: UnsafeMutablePointer<AVCodecParameters>
    private let sourceTimeBase: AVRational
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var encoder: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var fifo: OpaquePointer?
    /// Presentation time of the next sample to hand to the encoder, in 1/sampleRate.
    private var nextPTS: Int64?

    init(stream: ProbedStream, from context: UnsafeMutablePointer<AVFormatContext>) throws {
        guard let source = context.pointee.streams[stream.id] else { throw Failure(message: "The audio track is missing.") }
        format = Self.outputFormat(for: stream)
        sourceTimeBase = source.pointee.time_base
        guard let copy = avcodec_parameters_alloc(), let output = avcodec_parameters_alloc() else { throw Failure(message: "Out of memory.") }
        sourceParameters = copy
        outputParameters = output
        guard avcodec_parameters_copy(copy, source.pointee.codecpar) >= 0 else { throw Failure(message: "Out of memory.") }
        do {
            try openDecoder()
            try openEncoder()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
        var source: UnsafeMutablePointer<AVCodecParameters>? = sourceParameters
        var output: UnsafeMutablePointer<AVCodecParameters>? = outputParameters
        avcodec_parameters_free(&source)
        avcodec_parameters_free(&output)
    }

    func close() {
        avcodec_free_context(&decoder)
        avcodec_free_context(&encoder)
        swr_free(&resampler)
        if fifo != nil { av_audio_fifo_free(fifo); fifo = nil }
    }

    // MARK: Setup

    private func openDecoder() throws {
        guard let codec = avcodec_find_decoder(sourceParameters.pointee.codec_id), let context = avcodec_alloc_context3(codec) else {
            throw Failure(message: "This file's audio can't be decoded.")
        }
        decoder = context
        guard avcodec_parameters_to_context(context, sourceParameters) >= 0 else { throw Failure(message: "This file's audio can't be decoded.") }
        context.pointee.pkt_timebase = sourceTimeBase
        guard avcodec_open2(context, codec, nil) >= 0 else { throw Failure(message: "This file's audio can't be decoded.") }
    }

    private func openEncoder() throws {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_AAC), let context = avcodec_alloc_context3(codec) else {
            throw Failure(message: "This build can't encode AAC.")
        }
        encoder = context
        context.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        context.pointee.sample_rate = Int32(format.sampleRate)
        context.pointee.bit_rate = Int64(format.bitRate)
        context.pointee.time_base = AVRational(num: 1, den: Int32(format.sampleRate))
        context.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
        av_channel_layout_default(&context.pointee.ch_layout, Int32(format.channels))
        guard avcodec_open2(context, codec, nil) >= 0 else { throw Failure(message: "This build can't encode AAC.") }
        guard avcodec_parameters_from_context(outputParameters, context) >= 0 else { throw Failure(message: "Out of memory.") }
        guard let queue = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, Int32(format.channels), 1) else { throw Failure(message: "Out of memory.") }
        fifo = queue
    }

    /// Starts over with cold decoder and encoder, for a jump in the timeline.
    func reset() {
        avcodec_free_context(&decoder)
        avcodec_free_context(&encoder)
        swr_free(&resampler)
        if fifo != nil { av_audio_fifo_free(fifo); fifo = nil }
        nextPTS = nil
        resumeTime = nil
        try? openDecoder()
        try? openEncoder()
    }

    // MARK: Transcoding

    /// Decodes `packet` (nil flushes everything still inside) and passes each AAC packet it completes to `emit`. Timestamps are
    /// in 1/sampleRate.
    func process(_ packet: UnsafeMutablePointer<AVPacket>?, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        guard let decoder, let encoder else { throw Failure(message: "The audio converter isn't ready.") }
        var code = avcodec_send_packet(decoder, packet)
        if code < 0, code != Self.avErrorEOF {
            // A damaged packet shouldn't end playback; skip it.
            if packet != nil { return }
            throw Failure(message: "The audio can't be decoded.")
        }
        var framePointer: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&framePointer) }
        guard let frame = framePointer else { throw Failure(message: "Out of memory.") }
        while true {
            code = avcodec_receive_frame(decoder, frame)
            if code < 0 { break }
            defer { av_frame_unref(frame) }
            try convertAndQueue(frame, encoder: encoder)
            try encodeQueued(encoder: encoder, flushing: false, emit: emit)
        }
        if packet == nil {
            try convertAndQueue(nil, encoder: encoder)
            try encodeQueued(encoder: encoder, flushing: true, emit: emit)
        }
    }

    private func convertAndQueue(_ input: UnsafeMutablePointer<AVFrame>?, encoder: UnsafeMutablePointer<AVCodecContext>) throws {
        if let input, input.pointee.ch_layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&input.pointee.ch_layout, input.pointee.ch_layout.nb_channels)
        }
        var convertedPointer: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&convertedPointer) }
        guard let converted = convertedPointer else { throw Failure(message: "Out of memory.") }
        converted.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        converted.pointee.sample_rate = Int32(format.sampleRate)
        av_channel_layout_copy(&converted.pointee.ch_layout, &encoder.pointee.ch_layout)

        if resampler == nil {
            guard let input else { return }  // nothing was ever decoded
            guard let context = swr_alloc() else { throw Failure(message: "Out of memory.") }
            resampler = context
            let configCode = swr_config_frame(context, converted, input)
            guard configCode >= 0 else { throw Failure(message: "The audio can't be converted (resampler setup \(configCode)).") }
            let initCode = swr_init(context)
            guard initCode >= 0 else { throw Failure(message: "The audio can't be converted (resampler init \(initCode)).") }
        }
        if nextPTS == nil, let input {
            let timestamp = input.pointee.best_effort_timestamp
            let base = timestamp == Int64.min ? 0 : av_rescale_q(timestamp, sourceTimeBase, encoder.pointee.time_base)
            // The encoder reports its first packet one `initial_padding` early; start it late by that much so packets begin on time.
            nextPTS = base + Int64(encoder.pointee.initial_padding)
        }
        let convertCode = swr_convert_frame(resampler, converted, input)
        guard convertCode >= 0 else { throw Failure(message: "The audio can't be converted (resampling \(convertCode)).") }
        guard converted.pointee.nb_samples > 0, let fifo else { return }
        let data = UnsafeMutableRawPointer(converted.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard av_audio_fifo_write(fifo, data, converted.pointee.nb_samples) >= 0 else { throw Failure(message: "Out of memory.") }
    }

    private func encodeQueued(
        encoder: UnsafeMutablePointer<AVCodecContext>, flushing: Bool, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        guard let fifo else { return }
        let frameSize = Int(encoder.pointee.frame_size)
        while av_audio_fifo_size(fifo) >= frameSize || (flushing && av_audio_fifo_size(fifo) > 0) {
            let count = Int32(min(Int(av_audio_fifo_size(fifo)), frameSize))
            var framePointer: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&framePointer) }
            guard let frame = framePointer else { throw Failure(message: "Out of memory.") }
            frame.pointee.nb_samples = count
            frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            frame.pointee.sample_rate = Int32(format.sampleRate)
            av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
            guard av_frame_get_buffer(frame, 0) >= 0 else { throw Failure(message: "Out of memory.") }
            let data = UnsafeMutableRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            guard av_audio_fifo_read(fifo, data, count) >= 0 else { throw Failure(message: "The audio can't be converted.") }
            frame.pointee.pts = nextPTS ?? 0
            nextPTS = (nextPTS ?? 0) + Int64(count)
            guard avcodec_send_frame(encoder, frame) >= 0 else { throw Failure(message: "The audio can't be encoded.") }
            try drainPackets(encoder: encoder, emit: emit)
        }
        if flushing {
            _ = avcodec_send_frame(encoder, nil)
            try drainPackets(encoder: encoder, emit: emit)
        }
    }

    private func drainPackets(encoder: UnsafeMutablePointer<AVCodecContext>, emit: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        var packetPointer: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&packetPointer) }
        guard let packet = packetPointer else { throw Failure(message: "Out of memory.") }
        while avcodec_receive_packet(encoder, packet) >= 0 {
            defer { av_packet_unref(packet) }
            try emit(packet)
        }
    }

    private static let avErrorEOF: Int32 = -541478725
}
