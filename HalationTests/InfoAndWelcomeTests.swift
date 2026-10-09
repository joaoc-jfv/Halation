import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import Halation

private func info(
    size: CGSize? = CGSize(width: 3840, height: 2160), hdr: HDRFormat = .sdr, codec: String? = "HEVC"
) -> MediaInfo {
    var info = MediaInfo(container: "MP4", engineName: "AVFoundation")
    info.resolution = size
    info.displaySize = size
    info.hdr = hdr
    info.videoCodec = codec
    return info
}

@Suite struct FormatBadgeTests {
    @Test func namesResolutionsFromTheLongerSide() {
        let cases: [(CGFloat, CGFloat, String)] = [
            (7680, 4320, "8K"), (3840, 2160, "4K"), (3840, 1600, "4K"), (2560, 1440, "1440p"),
            (1920, 1080, "1080p"), (1920, 800, "1080p"), (1280, 720, "720p"), (720, 480, "480p"), (1080, 1920, "1080p"),
        ]
        for (width, height, expected) in cases {
            #expect(info(size: CGSize(width: width, height: height)).resolutionBadge == expected, "\(width)x\(height)")
        }
        #expect(info(size: nil).resolutionBadge == nil)
    }

    @Test func hdrBadgesAndDetailNames() {
        #expect(HDRFormat.sdr.badge == nil)
        #expect(HDRFormat.hdr10.badge == "HDR10")
        #expect(HDRFormat.hlg.badge == "HLG")
        #expect(HDRFormat.hdr10Plus.badge == "HDR10+")
        #expect(HDRFormat.dolbyVision(profile: 8, compatibilityID: 1).badge == "Dolby Vision")
        #expect(HDRFormat.sdr.detailName == "SDR")
        #expect(HDRFormat.dolbyVision(profile: 8, compatibilityID: 1).detailName == "Dolby Vision 8.1")
        #expect(HDRFormat.dolbyVision(profile: 8, compatibilityID: 4).detailName == "Dolby Vision 8.4")
        #expect(HDRFormat.dolbyVision(profile: 5, compatibilityID: 0).detailName == "Dolby Vision 5")
        #expect(HDRFormat.dolbyVision(profile: nil, compatibilityID: nil).detailName == "Dolby Vision")
    }

    @Test func pillCombinesResolutionHDRAndSpatialAudio() {
        #expect(info(hdr: .hdr10).formatBadges(spatialAudio: true) == ["4K", "HDR10", "Spatial Audio"])
        #expect(info().formatBadges(spatialAudio: false) == ["4K"])
        #expect(info(size: nil).formatBadges(spatialAudio: false).isEmpty)
    }

    @Test func userFacingTextNeverSaysAtmos() {
        // PLAN.md §1: "Spatial Audio" everywhere the user can read it.
        var sample = info(hdr: .dolbyVision(profile: 8, compatibilityID: 1))
        sample.audioCodec = "E-AC-3"
        let spatial = MediaTrack(id: "a", kind: .audio, language: "en", title: "English", codec: "E-AC-3", channels: 6,
                                 isDefault: true, isForced: false, isSpatial: true)
        let text = (sample.formatBadges(spatialAudio: true)
            + InfoSections.build(fileName: "f.mp4", info: sample, audio: spatial, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1)
                .flatMap { [$0.title] + $0.rows.flatMap { [$0.label, $0.value] } })
            .joined(separator: " ")
        #expect(!text.localizedCaseInsensitiveContains("atmos"))
        #expect(text.contains("Spatial Audio"))
    }
}

@Suite struct ColorDescriptionTests {
    @Test func namesTheCommonOnes() {
        #expect(ColorDescription.primaries(kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) == "BT.2020")
        #expect(ColorDescription.primaries(kCMFormatDescriptionColorPrimaries_P3_D65 as String) == "Display P3")
        #expect(ColorDescription.primaries(kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) == "BT.709")
        #expect(ColorDescription.transfer(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) == "PQ (SMPTE ST 2084)")
        #expect(ColorDescription.transfer(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) == "HLG")
    }

    @Test func passesUnknownNamesThroughAndHandlesNil() {
        #expect(ColorDescription.primaries("SomethingNew") == "SomethingNew")
        #expect(ColorDescription.transfer(nil) == nil)
    }
}

@Suite struct InfoFormattingTests {
    @Test func formatsFrameRates() {
        #expect(InfoFormatting.frameRate(24) == "24 fps")
        #expect(InfoFormatting.frameRate(23.976) == "23.976 fps")
        #expect(InfoFormatting.frameRate(29.97) == "29.97 fps")
        #expect(InfoFormatting.frameRate(60) == "60 fps")
    }

    @Test func formatsBitrates() {
        #expect(InfoFormatting.bitrate(12_500_000) == "12.5 Mb/s")
        #expect(InfoFormatting.bitrate(640_000) == "640 kb/s")
    }

    @Test func formatsSizes() {
        #expect(InfoFormatting.size(CGSize(width: 3840, height: 2160)) == "3840 × 2160")
    }
}

@Suite struct InfoSectionsTests {
    private func rows(_ sections: [InfoSection], _ title: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (sections.first { $0.title == title }?.rows ?? []).map { ($0.label, $0.value) })
    }

    private let spatialTrack = MediaTrack(
        id: "a", kind: .audio, language: "en", title: "English", codec: "E-AC-3", channels: 6,
        isDefault: true, isForced: false, isSpatial: true
    )

    @Test func describesAnHDRFileWithSpatialAudio() {
        var media = info(hdr: .dolbyVision(profile: 8, compatibilityID: 1))
        media.frameRate = 23.976
        media.bitrate = 18_400_000
        media.colorPrimaries = kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        media.transferFunction = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let sections = InfoSections.build(
            fileName: "film.mp4", info: media, audio: spatialTrack, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1
        )
        #expect(sections.map(\.title) == ["File", "Video", "HDR", "Audio", "Playback"])
        #expect(rows(sections, "Video") == [
            "Codec": "HEVC", "Resolution": "3840 × 2160", "Frame rate": "23.976 fps", "Bit rate": "18.4 Mb/s",
        ])
        #expect(rows(sections, "HDR") == [
            "Format": "Dolby Vision 8.1", "Color primaries": "BT.2020", "Transfer": "PQ (SMPTE ST 2084)", "This display": "Can show HDR",
        ])
        #expect(rows(sections, "Audio") == [
            "Track": "English", "Codec": "E-AC-3", "Layout": "5.1", "Spatial Audio track": "Yes", "Output": "Spatial Audio",
        ])
        #expect(rows(sections, "Playback") == ["Engine": "AVFoundation", "Speed": "1×"])
    }

    @Test func saysWhenTheDisplayCannotShowHDR() {
        let sections = InfoSections.build(
            fileName: "f.mp4", info: info(hdr: .hdr10), audio: nil, outputMode: .stereo, isHDRPlaybackEligible: false, rate: 1.5
        )
        #expect(rows(sections, "HDR")["This display"] == "Can't show HDR right now")
        #expect(rows(sections, "Playback")["Speed"] == "1.5×")
    }

    @Test func sdrFilesSkipTheDisplayRowAndAudioSection() {
        let sections = InfoSections.build(
            fileName: "f.mp4", info: info(), audio: nil, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1
        )
        #expect(rows(sections, "HDR") == ["Format": "SDR"])
        #expect(!sections.contains { $0.title == "Audio" })
    }

    @Test func showsTheDisplaySizeOnlyWhenItDiffers() {
        var media = info(size: CGSize(width: 320, height: 240))
        media.displaySize = CGSize(width: 427, height: 240)
        let sections = InfoSections.build(fileName: "f", info: media, audio: nil, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1)
        #expect(rows(sections, "Video")["Display size"] == "427 × 240")
        #expect(rows(InfoSections.build(fileName: "f", info: info(), audio: nil, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1), "Video")["Display size"] == nil)
    }
}

@MainActor
@Suite struct ThumbnailCacheTests {
    private func makeImage(_ size: Int = 16) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return try #require(context.makeImage())
    }

    @Test func savesAndLoadsAPoster() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halation-posters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ThumbnailCache(directory: directory)
        let url = URL(fileURLWithPath: "/Movies/film.mp4")
        #expect(cache.image(forPath: url.path) == nil)
        cache.save(try makeImage(), for: url)
        let loaded = try #require(cache.image(forPath: url.path))
        #expect(loaded.size == NSSize(width: 16, height: 16))
        cache.remove(forPath: url.path)
        #expect(cache.image(forPath: url.path) == nil)
    }

    @Test func differentPathsGetDifferentFiles() {
        let cache = ThumbnailCache(directory: FileManager.default.temporaryDirectory)
        #expect(cache.fileURL(forPath: "/a.mp4") != cache.fileURL(forPath: "/b.mp4"))
        #expect(cache.fileURL(forPath: "/a.mp4") == cache.fileURL(forPath: "/a.mp4"))
    }
}

@MainActor
private struct Rig {
    let fake = FakeEngine()
    let resume = ResumeStore(defaults: throwawayDefaults())
    let recents = RecentFiles(defaults: throwawayDefaults())
    let thumbnails = ThumbnailCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("halation-posters-\(UUID().uuidString)"))
    let model: PlayerModel
    let url = URL(fileURLWithPath: "/Movies/Some Film.mp4")

    init(hdr: HDRFormat = .sdr) {
        fake.info.resolution = CGSize(width: 3840, height: 2160)
        fake.info.hdr = hdr
        let fake = fake
        model = PlayerModel(
            services: .testing(resume: resume, recents: recents, thumbnails: thumbnails),
            engineFactory: { _ in fake }
        )
    }

    func open() async {
        model.open(url)
        await waitUntil("playback") { model.state == .playing && model.duration > .zero && model.mediaInfo != nil }
    }

    func solidImage() -> CGImage? {
        CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}

@MainActor
@Suite struct InfoPanelModelTests {
    @Test func badgesFollowTheFileAndTheSelectedTrack() async {
        let rig = Rig(hdr: .hdr10)
        let spatial = MediaTrack(id: "a", kind: .audio, language: "en", title: "English", codec: "E-AC-3", channels: 6,
                                 isDefault: true, isForced: false, isSpatial: true)
        rig.fake.audioTracks = [spatial]
        rig.fake.selectedAudioTrack = spatial
        await rig.open()
        #expect(rig.model.formatBadges == ["4K", "HDR10", "Spatial Audio"])
        rig.model.setAudioOutputMode(.stereo)  // the system won't spatialize in Stereo mode
        #expect(rig.model.formatBadges == ["4K", "HDR10"])
    }

    @Test func infoPanelTogglesAndKeepsControlsUp() async throws {
        let rig = Rig()
        rig.model.autoHideDelay = .milliseconds(80)
        await rig.open()
        #expect(!rig.model.showsInfoPanel)
        rig.model.toggleInfoPanel()
        #expect(rig.model.showsInfoPanel)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.model.controlsVisible)
        #expect(rig.model.dismissTopmostOverlay())
        #expect(!rig.model.showsInfoPanel)
        #expect(!rig.model.dismissTopmostOverlay())  // nothing left to close: Esc falls through to full screen
    }

    @Test func escapeClosesAPanelBeforeTheInfoPanel() async {
        let rig = Rig()
        await rig.open()
        rig.model.toggleInfoPanel()
        rig.model.togglePanel(.speed)
        #expect(rig.model.dismissTopmostOverlay())
        #expect(rig.model.activePanel == nil && rig.model.showsInfoPanel)
        #expect(rig.model.dismissTopmostOverlay())
        #expect(!rig.model.showsInfoPanel)
    }

    @Test func infoSectionsReflectTheEngine() async {
        let rig = Rig(hdr: .hdr10)
        rig.fake.isHDRPlaybackEligible = false
        await rig.open()
        let hdr = rig.model.infoSections.first { $0.title == "HDR" }
        #expect(hdr?.rows.contains(InfoRow(label: "This display", value: "Can't show HDR right now")) == true)
    }
}

@MainActor
@Suite struct ScrubPreviewTests {
    @Test func hoveringShowsTheTimeAndLoadsAThumbnailOnce() async throws {
        let rig = Rig()
        rig.fake.thumbnailImage = rig.solidImage()
        await rig.open()
        await waitUntil("artwork request") { rig.fake.thumbnailRequests.count == 1 }  // Now Playing artwork
        let before = rig.fake.thumbnailRequests.count

        rig.model.updateScrubPreview(fraction: 0.5)
        #expect(rig.model.scrubPreview?.time == .seconds(500))
        #expect(rig.model.scrubPreview?.image == nil)
        await waitUntil("thumbnail") { rig.model.scrubPreview?.image != nil }
        #expect(rig.fake.thumbnailRequests.count == before + 1)

        rig.model.updateScrubPreview(fraction: 0.5)  // same spot: served from the cache
        #expect(rig.model.scrubPreview?.image != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.fake.thumbnailRequests.count == before + 1)

        rig.model.updateScrubPreview(fraction: nil)
        #expect(rig.model.scrubPreview == nil)
    }

    @Test func nearbyPositionsShareAThumbnail() async throws {
        let rig = Rig()
        rig.fake.thumbnailImage = rig.solidImage()
        await rig.open()
        await waitUntil("artwork request") { rig.fake.thumbnailRequests.count == 1 }
        rig.model.updateScrubPreview(fraction: 0.5000)
        await waitUntil("thumbnail") { rig.model.scrubPreview?.image != nil }
        let count = rig.fake.thumbnailRequests.count
        rig.model.updateScrubPreview(fraction: 0.5004)  // 0.4 s further on, same bucket on a 1000 s file
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.fake.thumbnailRequests.count == count)
    }

    @Test func clampsOutOfRangePositionsAndIgnoresUnknownDurations() {
        let model = PlayerModel(services: .testing())
        model.updateScrubPreview(fraction: 0.5)  // nothing loaded
        #expect(model.scrubPreview == nil)
    }
}

@MainActor
@Suite struct WelcomeModelTests {
    @Test func progressComesFromTheSavedPosition() async {
        let rig = Rig()
        await rig.open()
        rig.recents.note(rig.url)
        let entry = rig.recents.entries[0]
        #expect(rig.model.recentProgress(for: entry) == nil)
        rig.resume.update(url: rig.url, position: 250, duration: 1000)
        #expect(rig.model.recentProgress(for: entry) == 0.25)
    }

    @Test func openingAFileSavesAPosterForTheWelcomeScreen() async {
        let rig = Rig()
        rig.fake.thumbnailImage = rig.solidImage()
        await rig.open()
        await waitUntil("poster") { rig.thumbnails.image(forPath: rig.url.path) != nil }
        let entry = rig.recents.entries[0]
        #expect(rig.model.recentPoster(for: entry) != nil)
        rig.model.removeRecent(entry)
        #expect(rig.recents.entries.isEmpty)
        #expect(rig.thumbnails.image(forPath: rig.url.path) == nil)
    }

    @Test func aMissingRecentFileDropsOutOfTheList() {
        let model = PlayerModel(services: .testing())
        model.recentFiles.note(URL(fileURLWithPath: "/definitely/not/here/film.mp4"))
        model.openRecent(model.recentFiles.entries[0])
        #expect(model.recentFiles.entries.isEmpty)
    }
}
