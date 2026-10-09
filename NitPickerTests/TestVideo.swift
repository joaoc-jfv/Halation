import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Writes a tiny clip so playback tests don't need media files in the repo.
enum TestVideo {
    enum Flavor { case sdrH264, hdr10HEVC }

    /// - Parameter audioLanguages: ISO 639-2 codes (`"eng"`, `"fra"`); one silent AAC track each,
    ///   all in one alternate group so they show up as selectable audio options.
    static func make(
        seconds: Int = 2, fps: Int = 10, size: CGSize = CGSize(width: 320, height: 240),
        flavor: Flavor = .sdrH264, audioLanguages: [String] = [], pixelAspectRatio: (horizontal: Int, vertical: Int)? = nil
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if flavor == .hdr10HEVC {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ]
        }
        // A keyframe every second, so the container index has several entries to read.
        var keyframes = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        keyframes[AVVideoMaxKeyFrameIntervalKey] = fps
        settings[AVVideoCompressionPropertiesKey] = keyframes
        if let pixelAspectRatio {
            var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            compression[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: pixelAspectRatio.horizontal,
                AVVideoPixelAspectRatioVerticalSpacingKey: pixelAspectRatio.vertical,
            ]
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)

        let silence = try silentFormat()
        var audioInputs: [AVAssetWriterInput] = []
        for language in audioLanguages {
            let audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: sampleRate, AVEncoderBitRateKey: 64_000,
                ],
                sourceFormatHint: silence
            )
            audio.languageCode = language
            audio.extendedLanguageTag = language == "fra" ? "fr" : language == "eng" ? "en" : language
            writer.add(audio)
            audioInputs.append(audio)
        }
        if audioInputs.count > 1 {
            writer.add(AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: audioInputs[0]))
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Round-robin over every input that is ready, so the writer's interleaving never stalls.
        let totalFrames = seconds * fps
        var nextFrame = 0
        var nextSecond = Array(repeating: 0, count: audioInputs.count)
        var idleRounds = 0
        while nextFrame < totalFrames || nextSecond.contains(where: { $0 < seconds }) {
            var progressed = false
            if nextFrame < totalFrames, input.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), Int32((nextFrame * 8) % 256), CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(fps)))
                nextFrame += 1
                progressed = true
            }
            for (index, audio) in audioInputs.enumerated() where nextSecond[index] < seconds && audio.isReadyForMoreMediaData {
                audio.append(try silentBuffer(startFrame: Int64(nextSecond[index]) * Int64(sampleRate), format: silence))
                nextSecond[index] += 1
                if nextSecond[index] == seconds { audio.markAsFinished() }  // lets the writer release the video
                progressed = true
            }
            if progressed {
                idleRounds = 0
            } else {
                idleRounds += 1
                guard idleRounds < 1000 else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static let sampleRate = 44_100.0

    private static func silentFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { throw CocoaError(.fileWriteUnknown) }
        return format
    }

    /// One second of 16-bit mono silence.
    private static func silentBuffer(startFrame: Int64, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let frames = Int(sampleRate)
        let byteCount = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let block else { throw CocoaError(.fileWriteUnknown) }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: startFrame, timescale: Int32(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
