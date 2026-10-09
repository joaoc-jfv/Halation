import Foundation
import Testing
@testable import Halation

@Suite struct MPVMappingTests {
    @Test func buildsTracksFromMPVsList() throws {
        let audio = MPVMapping.TrackFields(id: 2, type: "audio", language: "eng", title: "Commentary", codec: "dts", channels: 6, isDefault: true)
        let track = try #require(MPVMapping.mediaTrack(audio))
        #expect(track.id == "audio-2" && track.kind == .audio)
        #expect(track.language == "en" && track.title == "Commentary" && track.codec == "DTS" && track.channels == 6)
        #expect(track.isDefault && !track.isForced && !track.isSpatial)
        #expect(MPVMapping.mpvID(of: track) == 2)

        let subtitle = MPVMapping.TrackFields(id: 5, type: "sub", language: "fre", codec: "hdmv_pgs_subtitle", isForced: true)
        let sub = try #require(MPVMapping.mediaTrack(subtitle))
        #expect(sub.id == "subtitle-5" && sub.kind == .subtitle && sub.language == "fr" && sub.codec == "PGS" && sub.isForced)
        #expect(sub.channels == nil)

        #expect(MPVMapping.mediaTrack(MPVMapping.TrackFields(id: 1, type: "video")) == nil)
        #expect(MPVMapping.mediaTrack(MPVMapping.TrackFields(id: 1, type: "audio", channels: 0))?.channels == nil)
    }

    @Test func mapsColourNamesToTheOnesTheInfoPanelKnows() {
        #expect(MPVMapping.hdr(gamma: "pq") == .hdr10)
        #expect(MPVMapping.hdr(gamma: "hlg") == .hlg)
        #expect(MPVMapping.hdr(gamma: "bt.1886") == .sdr)
        #expect(MPVMapping.hdr(gamma: nil) == .sdr)
        #expect(MPVMapping.ffmpegPrimaries("bt.2020") == "bt2020")
        #expect(MPVMapping.ffmpegPrimaries("display-p3") == "smpte432")
        #expect(MPVMapping.ffmpegTransfer("pq") == "smpte2084")
        #expect(MPVMapping.ffmpegTransfer("hlg") == "arib-std-b67")
        #expect(MPVMapping.ffmpegPrimaries(nil) == nil)
        // The panel's own wording comes out of the existing mapping.
        #expect(ColorDescription.primaries(ColorDescription.coreMediaPrimaries(fromFFmpeg: MPVMapping.ffmpegPrimaries("bt.2020"))) == "BT.2020")
    }

    @Test func understandsTheBibliographicLanguageCodesMatroskaAndAVIUse() {
        for (code, alpha2) in [("fre", "fr"), ("ger", "de"), ("chi", "zh"), ("dut", "nl"), ("gre", "el"), ("eng", "en"), ("ita", "it"), ("fra", "fr")] {
            #expect(LanguageMatching.primaryLanguage(code) == alpha2, "\(code)")
        }
        #expect(LanguageMatching.matches("fre", "fr") && LanguageMatching.matches("fra", "fre"))
    }

    @Test func namesContainersShortly() {
        #expect(MPVMapping.containerName("matroska,webm") == "MKV")
        #expect(MPVMapping.containerName("avi") == "AVI")
        #expect(MPVMapping.containerName("mov,mp4,m4a,3gp,3g2,mj2") == "MOV")
        #expect(MPVMapping.containerName(nil) == "")
    }

    @Test func startsWithHDRPassthroughOnlyWhenTheDisplayCanShowIt() {
        func value(_ key: String, hdr: Bool) -> String? { MPVEngine.options(hdr: hdr, audioLanguage: nil).first { $0.0 == key }?.1 }
        #expect(value("target-colorspace-hint", hdr: true) == "yes")
        #expect(value("target-colorspace-hint", hdr: false) == "no")
        #expect(value("sub-auto", hdr: true) == "no")  // the app finds sidecar subtitles itself
        #expect(MPVEngine.options(hdr: false, audioLanguage: "fr").contains { $0.0 == "alang" && $0.1 == "fr" })
    }

    @Test func softensMPVsErrorsForTheUser() {
        #expect(MPVEngine.friendly("unrecognized file format") == "This file can't be played.")
        #expect(MPVEngine.friendly("loading failed") == "This file can't be played (loading failed).")
    }

    @Test func displaysCodecNamesForWhatLegacyFilesCarry() {
        #expect(CodecNames.displayName(forFFmpegCodec: "mpeg4") == "MPEG-4")
        #expect(CodecNames.displayName(forFFmpegCodec: "vp9") == "VP9")
        #expect(CodecNames.displayName(forFFmpegCodec: "truehd") == "TrueHD")
        #expect(CodecNames.displayName(forFFmpegCodec: "pcm_s24le") == "PCM")
        #expect(CodecNames.displayName(forFFmpegCodec: "unknowncodec") == "UNKNOWNCODEC")
    }
}

@MainActor
@Suite struct MPVPlaybackTests {
    private func player() -> PlayerModel {
        PlayerModel(services: .testing())
    }

    @Test func playsAFileTheOtherEnginesRefuseAndFindsItsWayThroughIt() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 6)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = player()
        defer { model.close() }

        model.open(file)  // Matroska, so the remuxer refuses the MPEG-4 and libmpv takes over
        await waitUntil("playback", timeout: .seconds(20)) { model.state == .playing }
        #expect(model.errorMessage == nil)
        await waitUntil("media info") { model.mediaInfo?.videoCodec != nil }
        #expect(model.mediaInfo?.engineName == "mpv (compatibility mode)")
        #expect(model.mediaInfo?.container == "MKV")
        #expect(model.mediaInfo?.videoCodec == "MPEG-4")
        #expect(model.mediaInfo?.resolution == CGSize(width: 320, height: 240))
        await waitUntil("duration") { abs(model.duration.seconds - 6) < 0.5 }
        await waitUntil("time moving", timeout: .seconds(10)) { model.currentTime.seconds > 1 }

        model.pause()
        await waitUntil("paused") { model.state == .paused }
        model.seek(to: .seconds(4), precise: true)
        await waitUntil("the seek") { abs(model.livePlaybackTime().seconds - 4) < 0.3 }
        model.play()
        await waitUntil("the end", timeout: .seconds(15)) { model.state == .ended }
        #expect(model.errorMessage == nil)
    }

    @Test func playsAnMPEGTransportStreamAVFoundationCannotOpen() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 3, container: "mpegts", fileExtension: "ts")
        defer { try? FileManager.default.removeItem(at: file) }
        let model = player()
        defer { model.close() }
        model.open(file)
        await waitUntil("playback", timeout: .seconds(12)) { model.state == .playing }
        #expect(model.state == .playing, "state \(model.state), engine \(String(describing: model.mediaInfo?.engineName)), error \(String(describing: model.errorMessage))")
        #expect(model.errorMessage == nil)
        #expect(model.mediaInfo?.engineName == "mpv (compatibility mode)")
    }

    @Test func reportsAFileLibmpvCannotOpenEither() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("halation-junk-\(UUID().uuidString).avi")
        try Data("not a video at all".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let model = player()
        defer { model.close() }
        model.open(junk)
        await waitUntil("an error", timeout: .seconds(15)) { model.errorMessage != nil }
        #expect(model.errorMessage?.hasPrefix("This file can't be played") == true)
    }
}
