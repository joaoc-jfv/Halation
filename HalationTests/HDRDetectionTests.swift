import CoreMedia
import Foundation
import Testing
@testable import Halation

@Suite struct HDRDetectionTests {
    private func description(
        codec: UInt32 = 0x6876_6331,  // hvc1
        transfer: CFString? = nil,
        atoms: [String: Data]? = nil
    ) throws -> CMFormatDescription {
        var extensions: [CFString: Any] = [:]
        if let transfer { extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer }
        if let atoms { extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms }
        var result: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codec, width: 3840, height: 2160,
            extensions: extensions as CFDictionary, formatDescriptionOut: &result
        )
        #expect(status == noErr)
        return try #require(result)
    }

    /// A `dvcC`/`dvvC` configuration record with the given profile and compatibility ID.
    private func dolbyVisionRecord(profile: UInt8, compatibilityID: UInt8) -> Data {
        Data([1, 0, profile << 1, 0x05, compatibilityID << 4, 0, 0, 0])
    }

    @Test func plainVideoIsSDR() throws {
        #expect(HDRDetection.format(of: try description()) == .sdr)
        #expect(HDRDetection.format(of: try description(transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2)) == .sdr)
    }

    @Test func detectsHDR10() throws {
        let format = HDRDetection.format(of: try description(transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ))
        #expect(format == .hdr10)
    }

    @Test func detectsHLG() throws {
        let format = HDRDetection.format(of: try description(transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG))
        #expect(format == .hlg)
    }

    @Test(arguments: [(5, 0), (8, 1), (8, 4)])
    func detectsDolbyVisionProfiles(profile: Int, compatibilityID: Int) throws {
        let record = dolbyVisionRecord(profile: UInt8(profile), compatibilityID: UInt8(compatibilityID))
        let desc = try description(codec: 0x6476_6831, atoms: ["dvcC": record])  // dvh1
        #expect(HDRDetection.format(of: desc) == .dolbyVision(profile: profile, compatibilityID: compatibilityID))
    }

    @Test func dolbyVisionWinsOverTheBaseLayerTransfer() throws {
        let record = dolbyVisionRecord(profile: 8, compatibilityID: 1)
        let desc = try description(transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, atoms: ["dvcC": record])
        #expect(HDRDetection.format(of: desc) == .dolbyVision(profile: 8, compatibilityID: 1))
    }

    @Test func readsDolbyVisionRecordsThatKeepTheirBoxHeader() throws {
        var boxed = Data([0, 0, 0, 16]) + Data("dvvC".utf8)
        boxed += dolbyVisionRecord(profile: 8, compatibilityID: 4)
        let desc = try description(codec: 0x6476_6865, atoms: ["dvvC": boxed])  // dvhe
        #expect(HDRDetection.format(of: desc) == .dolbyVision(profile: 8, compatibilityID: 4))
    }

    @Test func dolbyVisionSubtypeWithoutRecordHasUnknownProfile() throws {
        let desc = try description(codec: 0x6476_6831)
        #expect(HDRDetection.format(of: desc) == .dolbyVision(profile: nil, compatibilityID: nil))
    }
}

@Suite struct WindowSizingTests {
    private let screen = CGSize(width: 1500, height: 900)  // 80%: 1200 x 720

    @Test func scalesBigVideosDownToEightyPercentOfTheScreen() {
        #expect(WindowSizing.contentSize(forVideo: CGSize(width: 3840, height: 2160), in: screen) == CGSize(width: 1200, height: 675))
    }

    @Test func limitsByHeightForTallVideos() {
        #expect(WindowSizing.contentSize(forVideo: CGSize(width: 1080, height: 1920), in: screen) == CGSize(width: 405, height: 720))
    }

    @Test func keepsNativeSizeWhenItFits() {
        #expect(WindowSizing.contentSize(forVideo: CGSize(width: 800, height: 450), in: screen) == CGSize(width: 800, height: 450))
    }

    @Test func enlargesSmallVideosToTheMinimumWidth() {
        #expect(WindowSizing.contentSize(forVideo: CGSize(width: 320, height: 240), in: screen) == CGSize(width: 640, height: 480))
    }

    @Test func fallsBackForInvalidInput() {
        #expect(WindowSizing.contentSize(forVideo: .zero, in: screen) == WindowSizing.fallbackSize)
        #expect(WindowSizing.contentSize(forVideo: CGSize(width: 100, height: 100), in: .zero) == WindowSizing.fallbackSize)
    }
}
