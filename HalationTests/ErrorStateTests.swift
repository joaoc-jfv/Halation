import Foundation
import Testing
@testable import Halation

private struct EngineBoom: Error, LocalizedError {
    var errorDescription: String? { "The engine could not start." }
}

@MainActor
@Suite struct ErrorStateTests {
    @Test func aCorruptFileFailsCleanly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("halation-corrupt-\(UUID().uuidString).mp4")
        try Data("this is not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }

        player.open(url)
        await waitUntil("an error") { player.errorMessage != nil }
        #expect(player.state != .playing)
        #expect(!player.isBusy)
        #expect(player.hasMedia)  // the file stays "open", so the message and Open… button show
        #expect(player.errorMessage?.isEmpty == false)
    }

    @Test func aFileThatCannotBeOpenedReportsWhy() async {
        let player = PlayerModel(services: .testing(), engineFactory: { _ in throw EngineBoom() })
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("an error") { player.errorMessage != nil }
        #expect(player.errorMessage == "The engine could not start.")
        #expect(player.videoView == nil)
    }

    @Test func aFileEveryEngineRefusesSaysSo() async {
        let first = FakeEngine(), second = FakeEngine()
        first.loadError = PlaybackError.needsCompatibilityMode
        second.loadError = PlaybackError.loadFailed("This file can't be played.")
        let player = PlayerModel(services: .testing(), engineFactory: { _ in first }, compatibilityFactory: { _ in second })
        player.open(URL(fileURLWithPath: "/Movies/film.avi"))
        await waitUntil("an error") { player.errorMessage != nil }
        #expect(player.errorMessage == "This file can't be played.")
        #expect(first.closed)  // the engine that gave up is released
    }

    @Test func aFileTheFirstEngineCannotPlayGoesToTheCompatibilityEngine() async {
        let first = FakeEngine(), second = FakeEngine()
        first.loadError = PlaybackError.needsCompatibilityMode
        second.info = MediaInfo(container: "AVI", engineName: "mpv (compatibility mode)")
        let player = PlayerModel(services: .testing(), engineFactory: { _ in first }, compatibilityFactory: { _ in second })
        let url = URL(fileURLWithPath: "/Movies/film.avi")
        player.open(url)
        await waitUntil("playback on the second engine") { player.state == .playing }
        #expect(second.loadedURLs == [url])
        #expect(player.mediaInfo?.engineName == "mpv (compatibility mode)")
        #expect(first.closed && !second.closed)
        #expect(player.errorMessage == nil)
    }

    @Test func aFileAVFoundationCannotOpenIsRetriedToo() async {
        let first = FakeEngine(), second = FakeEngine()
        first.loadError = PlaybackError.notPlayable
        let player = PlayerModel(services: .testing(), engineFactory: { _ in first }, compatibilityFactory: { _ in second })
        player.open(URL(fileURLWithPath: "/Movies/film.mov"))
        await waitUntil("playback on the second engine") { player.state == .playing }
        #expect(player.errorMessage == nil)
    }

    @Test func otherLoadFailuresAreNotRetried() async {
        let first = FakeEngine(), second = FakeEngine()
        first.loadError = PlaybackError.loadFailed("The disk went away.")
        let player = PlayerModel(services: .testing(), engineFactory: { _ in first }, compatibilityFactory: { _ in second })
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("an error") { player.errorMessage != nil }
        #expect(player.errorMessage == "The disk went away.")
        #expect(second.loadedURLs.isEmpty)
    }

    @Test func aFailureDuringPlaybackShowsTheMessageAndStopsTheSleepAssertion() async {
        let fake = FakeEngine()
        let sleep = FakeSleepPrevention()
        let player = PlayerModel(services: .testing(sleep: sleep), engineFactory: { _ in fake })
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(sleep.isActive)

        fake.emit(.stateChanged(.failed(.loadFailed("The file stopped being readable."))))
        await waitUntil("failure") { player.errorMessage != nil }
        #expect(player.errorMessage == "The file stopped being readable.")
        #expect(!sleep.isActive)
        #expect(player.controlsVisible)
    }

    @Test func openingAnotherFileAfterAFailureRecovers() async {
        let fake = FakeEngine()
        var attempts = 0
        let player = PlayerModel(services: .testing(), engineFactory: { _ in
            attempts += 1
            if attempts == 1 { throw EngineBoom() }
            return fake
        })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/bad.mp4"))
        await waitUntil("an error") { player.errorMessage != nil }
        player.open(URL(fileURLWithPath: "/Movies/good.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(player.errorMessage == nil)
        #expect(player.videoView != nil)
    }

    @Test func loadingAndBufferingCountAsBusy() async {
        let fake = FakeEngine()
        let player = PlayerModel(services: .testing(), engineFactory: { _ in fake })
        defer { player.close() }
        #expect(!player.isBusy)
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(!player.isBusy)
        fake.emit(.bufferingChanged(true))
        await waitUntil("buffering") { player.isBusy }
        fake.emit(.bufferingChanged(false))
        await waitUntil("done buffering") { !player.isBusy }
    }

    @Test func playingAFileAfterANonexistentOneDoesNotKeepTheOldError() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/definitely/not/here.mp4"))
        await waitUntil("an error") { player.errorMessage != nil }
        player.open(url)
        await waitUntil("playback") { player.state == .playing }
        #expect(player.errorMessage == nil)
    }
}
