import CoreMedia
import Foundation
import Testing
@testable import NitPicker

/// Byte-for-byte records that FFmpeg's mp4 muxer wrote when remuxing a real Dolby Vision profile 8.1 +
/// E-AC-3 JOC MKV (the phase 2 spike). Unlike the synthetic records elsewhere, these show what real files carry.
@Suite struct RealWorldVectorTests {
    private func data(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    /// `dec3` of a 5.1 E-AC-3 track with the JOC extension (16 objects), 768 kb/s.
    private let jocDec3 = "18002 00f000110".replacingOccurrences(of: " ", with: "")

    @Test func recognizesTheJOCRecordARealMuxerWrote() {
        #expect(AudioFormatDetection.isJOC(dec3: data(jocDec3)))
    }

    @Test func theSameRecordWithoutItsExtensionIsPlainEAC3() {
        #expect(!AudioFormatDetection.isJOC(dec3: data("18002 00f00".replacingOccurrences(of: " ", with: ""))))
    }

    @Test func readsTheDolbyVisionRecordARealMuxerWrote() throws {
        // `dvvC`: version 1.0, profile 8, level 6, RPU present, base layer only, compatibility ID 1 (HDR10).
        let record = data("010010351000000000000000000000000000000000000000")
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: 0x6876_6331,  // hvc1: the muxer keeps hvc1 and adds dvvC
            width: 3840, height: 1920,
            extensions: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["dvvC": record],
                kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            ] as CFDictionary,
            formatDescriptionOut: &description
        )
        #expect(status == noErr)
        let format = HDRDetection.format(of: try #require(description))
        #expect(format == .dolbyVision(profile: 8, compatibilityID: 1))
        #expect(format.detailName == "Dolby Vision 8.1")
    }
}
