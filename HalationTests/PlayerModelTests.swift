import Foundation
import Testing
@testable import Halation

@MainActor
@Suite struct PlayerModelTests {
    /// Polls until `condition` holds, failing the test after `timeout`.
    private func wait(
        _ what: String, timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func playsPausesSeeksAndEnds() async throws {
        let url = try await TestVideo.make(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        defer { player.close() }

        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.videoView != nil)
        await wait("duration") { player.duration.seconds > 1 }
        #expect(abs(player.duration.seconds - 2) < 0.2)

        let info = try #require(player.mediaInfo)
        #expect(info.container == "MP4")
        #expect(info.videoCodec == "H.264")
        #expect(info.resolution == CGSize(width: 320, height: 240))
        #expect(info.engineName == "AVFoundation")

        await wait("time to advance") { player.currentTime.seconds > 0.2 }

        player.pause()
        await wait("pause") { player.state == .paused }

        player.seek(to: .seconds(1), precise: true)
        await wait("seek") { abs(player.currentTime.seconds - 1) < 0.15 }

        player.play()
        await wait("end of file") { player.state == .ended }

        // Playing again after the end restarts from the beginning.
        player.play()
        await wait("restart") { player.state == .playing }
    }

    @Test func reportsSDRForAnSDRFile() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        defer { player.close() }
        player.open(url)
        await wait("media info") { player.mediaInfo != nil }
        #expect(player.mediaInfo?.hdr == .sdr)
    }

    @Test func detectsAndPlaysHDR10() async throws {
        let url = try await TestVideo.make(seconds: 1, flavor: .hdr10HEVC)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        defer { player.close() }
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.mediaInfo?.hdr == .hdr10)
        #expect(player.mediaInfo?.videoCodec == "HEVC")
    }

    @Test func rateVolumeAndMuteSurviveAcrossFiles() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        defer { player.close() }

        player.setRate(1.5)
        player.setVolume(0.4)
        player.toggleMute()
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.rate == 1.5)
        #expect(player.volume == 0.4)
        #expect(player.isMuted)
    }

    @Test func rejectsUnsupportedContainers() async {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.open(URL(fileURLWithPath: "/tmp/movie.mkv"))
        await wait("failure") { player.errorMessage != nil }
        #expect(player.errorMessage == "This format isn't supported yet.")
        #expect(player.videoView == nil)
    }

    @Test func reportsMissingFiles() async {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.open(URL(fileURLWithPath: "/tmp/halation-does-not-exist.mp4"))
        await wait("failure") { player.errorMessage != nil }
        #expect(player.state != .playing)
    }

    @Test func closeResetsState() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        player.close()
        #expect(player.state == .idle)
        #expect(!player.hasMedia)
        #expect(player.videoView == nil)
        #expect(player.currentTime == .zero)
    }
}

@MainActor
@Suite struct TrackPlaybackTests {
    private func wait(
        _ what: String, timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func listsAudioTracksWithDetailsAndSwitchesMidPlayback() async throws {
        let url = try await TestVideo.make(seconds: 3, audioLanguages: ["eng", "fra"])
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = TestPreferences.make()
        let player = PlayerModel(preferences: preferences)
        defer { player.close() }

        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.audioTracks.count == 2)
        #expect(player.audioTracks.map(\.codec) == ["AAC", "AAC"])
        #expect(player.audioTracks.map(\.channels) == [1, 1])
        #expect(player.audioTracks.allSatisfy { !$0.isSpatial })
        #expect(player.audioTracks.map { LanguageMatching.primaryLanguage($0.language ?? "") } == ["en", "fr"])
        #expect(player.selectedAudio == player.audioTracks[0])
        #expect(player.mediaInfo?.audioCodec == "AAC")

        player.selectAudio(player.audioTracks[1])
        #expect(player.selectedAudio == player.audioTracks[1])
        #expect(player.state == .playing)
        #expect(preferences.audioLanguage == player.audioTracks[1].language)

        player.cycleAudioByShortcut()
        #expect(player.selectedAudio == player.audioTracks[0])
        #expect(player.toast?.text.hasPrefix("Audio: ") == true)
    }

    @Test func appliesTheRememberedAudioLanguageOnOpen() async throws {
        let url = try await TestVideo.make(seconds: 2, audioLanguages: ["eng", "fra"])
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = TestPreferences.make()
        preferences.audioLanguage = "fr"
        let player = PlayerModel(preferences: preferences)
        defer { player.close() }

        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.selectedAudio == player.audioTracks[1])
    }

    @Test func outputModeIsRememberedAndAppliedToTheEngine() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let preferences = TestPreferences.make()
        let player = PlayerModel(preferences: preferences)
        defer { player.close() }
        player.setAudioOutputMode(.stereo)
        #expect(preferences.audioOutputMode == .stereo)
        #expect(PlayerModel(preferences: preferences).audioOutputMode == .stereo)
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        #expect(player.audioOutputMode == .stereo)
    }

    @Test func panelStateKeepsControlsUp() async throws {
        let url = try await TestVideo.make(seconds: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(preferences: TestPreferences.make())
        defer { player.close() }
        player.autoHideDelay = .milliseconds(100)
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        player.togglePanel(.audioSubtitles)
        try await Task.sleep(for: .milliseconds(400))
        #expect(player.controlsVisible)
        player.closePanel()
        await wait("controls to hide") { !player.controlsVisible }
    }
}

@Suite struct TrackPairingTests {
    typealias Option = AVTrackMapping.OptionKey
    typealias Candidate = AVTrackMapping.TrackCandidate
    private let aac: UInt32 = 0x6D70_3461  // mp4a
    private let eac3: UInt32 = 0x6563_2D33  // ec-3

    @Test func pairsByPositionWhenCountsAndCodecsAgree() {
        let result = AVTrackMapping.pair(
            options: [Option(language: "en", subtypes: [aac]), Option(language: "fr", subtypes: [eac3])],
            tracks: [Candidate(language: "en", subtype: aac), Candidate(language: "fr", subtype: eac3)]
        )
        #expect(result == [0, 1])
    }

    @Test func fallsBackToLanguageAndCodecWhenCountsDiffer() {
        let result = AVTrackMapping.pair(
            options: [Option(language: "fr", subtypes: [eac3]), Option(language: "en", subtypes: [aac])],
            tracks: [
                Candidate(language: "en", subtype: aac),
                Candidate(language: "de", subtype: aac),
                Candidate(language: "fr", subtype: eac3),
            ]
        )
        #expect(result == [2, 0])
    }

    @Test func neverReusesATrackAndReportsMissingOnes() {
        let result = AVTrackMapping.pair(
            options: [Option(language: "en", subtypes: []), Option(language: "en", subtypes: []), Option(language: "ja", subtypes: [])],
            tracks: [Candidate(language: "en", subtype: aac)]
        )
        #expect(result == [0, nil, nil])
    }
}
