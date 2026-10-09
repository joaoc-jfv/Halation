import Foundation
import Testing
@testable import Halation

@Suite struct PlaybackSpeedTests {
    @Test func stepsUpTheLadder() {
        #expect(PlaybackSpeed.stepped(from: 1, up: true) == 1.25)
        #expect(PlaybackSpeed.stepped(from: 2, up: true) == 3)
        #expect(PlaybackSpeed.stepped(from: 4, up: true) == 4)
    }

    @Test func stepsDownTheLadder() {
        #expect(PlaybackSpeed.stepped(from: 1, up: false) == 0.75)
        #expect(PlaybackSpeed.stepped(from: 0.25, up: false) == 0.25)
    }

    @Test func snapsOffLadderRatesToTheNextStep() {
        #expect(PlaybackSpeed.stepped(from: 1.1, up: true) == 1.25)
        #expect(PlaybackSpeed.stepped(from: 1.1, up: false) == 1)
    }

    @Test func formatsLabels() {
        #expect(PlaybackSpeed.label(for: 1) == "1×")
        #expect(PlaybackSpeed.label(for: 1.25) == "1.25×")
        #expect(PlaybackSpeed.label(for: 0.5) == "0.5×")
    }
}

@MainActor
@Suite struct ControlsBehaviourTests {
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
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func playing(seconds: Int = 20) async throws -> (PlayerModel, URL) {
        let url = try await TestVideo.make(seconds: seconds)
        let player = PlayerModel(preferences: TestPreferences.make())
        player.autoHideDelay = .milliseconds(150)
        player.open(url)
        await wait("playback to start") { player.state == .playing }
        return (player, url)
    }

    @Test func controlsHideAfterInactivityWhilePlaying() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        #expect(player.controlsVisible)
        await wait("controls to hide") { !player.controlsVisible }
    }

    @Test func activityBringsControlsBackAndTheyHideAgain() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        await wait("controls to hide") { !player.controlsVisible }
        player.registerActivity()
        #expect(player.controlsVisible)
        await wait("controls to hide again") { !player.controlsVisible }
    }

    @Test func continuousActivityKeepsControlsUp() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        for _ in 0..<15 {
            player.registerActivity()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(player.controlsVisible)
    }

    @Test func controlsStayUpWhileThePointerIsOverThem() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        player.setPointerOverControls(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(player.controlsVisible)
        player.setPointerOverControls(false)
        await wait("controls to hide") { !player.controlsVisible }
    }

    @Test func controlsStayUpWhilePaused() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        player.pause()
        await wait("pause") { player.state == .paused }
        try await Task.sleep(for: .milliseconds(500))
        #expect(player.controlsVisible)
    }

    @Test func toastsAppearAndExpire() async {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.toastDuration = .milliseconds(80)
        player.showToast("Hello", symbol: "star")
        #expect(player.toast?.text == "Hello")
        await wait("toast to expire") { player.toast == nil }
    }

    @Test func newToastReplacesTheOldOne() async throws {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.toastDuration = .milliseconds(200)
        player.showToast("One")
        let first = player.toast?.id
        try await Task.sleep(for: .milliseconds(120))
        player.showToast("Two")
        try await Task.sleep(for: .milliseconds(120))
        #expect(player.toast?.text == "Two")
        #expect(player.toast?.id != first)
    }

    @Test func volumeShortcutsStepAndToast() {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.setVolume(0.5)
        player.adjustVolumeByShortcut(by: 0.05)
        #expect(player.volume == 0.55)
        #expect(player.toast?.text == "Volume 55%")
        player.adjustVolumeByShortcut(by: -0.2)
        #expect(player.volume == 0.35)
        player.setVolume(0.98)
        player.adjustVolumeByShortcut(by: 0.05)
        #expect(player.volume == 1)
    }

    @Test func raisingVolumeUnmutes() {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.toggleMuteByShortcut()
        #expect(player.isMuted)
        #expect(player.toast?.text == "Muted")
        player.adjustVolumeByShortcut(by: 0.05)
        #expect(!player.isMuted)
    }

    @Test func speedShortcutsUseTheLadder() {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.stepSpeedByShortcut(up: true)
        #expect(player.rate == 1.25)
        #expect(player.toast?.text == "Speed 1.25×")
        player.resetSpeedByShortcut()
        #expect(player.rate == 1)
        player.stepSpeedByShortcut(up: false)
        #expect(player.rate == 0.75)
    }

    @Test func trackCyclingExplainsWhenThereAreNoTracks() {
        let player = PlayerModel(preferences: TestPreferences.make())
        player.cycleSubtitlesByShortcut()
        #expect(player.toast?.text == "No subtitles")
        player.cycleAudioByShortcut()
        #expect(player.toast?.text == "No other audio tracks")
    }

    @Test func seekShortcutMovesThePlayheadAndToasts() async throws {
        let (player, url) = try await playing()
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        await wait("duration") { player.duration.seconds > 10 }
        player.seekByShortcut(seconds: 5)
        #expect(player.currentTime.seconds >= 5)
        #expect(player.toast?.text == "+5 s")
        player.seekByShortcut(seconds: -30)
        #expect(player.currentTime == .zero)
        #expect(player.toast?.text == "−30 s")
    }

    @Test func bufferedRangeIsReported() async throws {
        let (player, url) = try await playing(seconds: 3)
        defer { player.close(); try? FileManager.default.removeItem(at: url) }
        await wait("buffered range") { player.buffered.seconds > 0 }
    }
}
