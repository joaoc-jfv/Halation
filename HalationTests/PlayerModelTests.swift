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
        let player = PlayerModel()
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

    @Test func rateVolumeAndMuteSurviveAcrossFiles() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel()
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
        let player = PlayerModel()
        player.open(URL(fileURLWithPath: "/tmp/movie.mkv"))
        await wait("failure") { player.errorMessage != nil }
        #expect(player.errorMessage == "This format isn't supported yet.")
        #expect(player.videoView == nil)
    }

    @Test func reportsMissingFiles() async {
        let player = PlayerModel()
        player.open(URL(fileURLWithPath: "/tmp/halation-does-not-exist.mp4"))
        await wait("failure") { player.errorMessage != nil }
        #expect(player.state != .playing)
    }

    @Test func closeResetsState() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel()
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        player.close()
        #expect(player.state == .idle)
        #expect(!player.hasMedia)
        #expect(player.videoView == nil)
        #expect(player.currentTime == .zero)
    }
}
