import Foundation
import Testing
@testable import NitPicker

/// An engine that draws subtitles itself (mpv) gets the delay, the style, the lift above the controls and the sidecar files
/// it can draw; the model never shows an overlay of its own for them.
@MainActor
@Suite struct NativeSubtitleTests {
    private func folder(with files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files { try "[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,Hi".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return folder
    }

    private func native(_ fake: FakeEngine, preferences: Preferences = TestPreferences.make()) -> PlayerModel {
        fake.drawsSubtitlesNatively = true
        return PlayerModel(services: .testing(preferences: preferences), engineFactory: { _ in fake })
    }

    @Test func handsOverTheStyleAndDelayAndKeepsTheOverlayOut() async throws {
        let fake = FakeEngine()
        let player = native(fake)
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/film.mkv"))
        await waitUntil("playback") { player.state == .playing }
        #expect(player.enginePaintsSubtitles)
        #expect(fake.subtitleStyles.last == SubtitleStyle())
        #expect(fake.subtitleDelays.last == .zero)

        // No subtitle showing: the delay has nothing to move.
        #expect(!player.canDelaySubtitles)
        player.adjustSubtitleDelayByShortcut(.milliseconds(100))
        #expect(player.subtitles.delay == .zero)

        let track = MediaTrack(id: "subtitle-1", kind: .subtitle, language: "en", title: nil, codec: "ASS", channels: nil, isDefault: false, isForced: false, isSpatial: false)
        fake.subtitleTracks = [track]
        fake.emit(.tracksChanged)
        await waitUntil("the track") { !player.subtitleTracks.isEmpty }
        player.selectSubtitle(track)
        #expect(player.canDelaySubtitles)
        #expect(!player.drawsSubtitles, "mpv's own rendering needs no overlay")

        player.adjustSubtitleDelayByShortcut(.milliseconds(300))
        #expect(abs((fake.subtitleDelays.last ?? .zero).seconds - 0.3) < 0.001)
        player.resetSubtitleDelay()
        #expect(fake.subtitleDelays.last == .zero)

        var style = SubtitleStyle()
        style.size = .large
        player.setSubtitleStyle(style)
        #expect(fake.subtitleStyles.last == style)
        #expect(player.subtitles.style == style)

        player.setSubtitleLift(0.2)
        #expect(fake.subtitleLifts.last == 0.2)
    }

    @Test func otherEnginesKeepTheAppsOverlayAndDelay() async {
        let fake = FakeEngine()
        let player = PlayerModel(services: .testing(), engineFactory: { _ in fake })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(!player.enginePaintsSubtitles)
        #expect(!player.canDelaySubtitles)
    }

    @Test func addsAssAndImageSidecarsToTheEnginesTracksAndLeavesSrtToTheApp() async throws {
        let directory = try folder(with: ["film.en.ass", "film.fr.sup", "film.de.srt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        // SRT is plain text: the app's own overlay shows it.
        try "1\n00:00:01,000 --> 00:00:02,000\nHallo\n".write(to: directory.appendingPathComponent("film.de.srt"), atomically: true, encoding: .utf8)
        let fake = FakeEngine()
        let player = native(fake)
        defer { player.close() }
        player.open(directory.appendingPathComponent("film.mkv"))
        await waitUntil("sidecars") { fake.addedSubtitleFiles.count == 2 && player.subtitles.tracks.count == 1 }
        #expect(Set(fake.addedSubtitleFiles.map(\.lastPathComponent)) == ["film.en.ass", "film.fr.sup"])
        #expect(player.subtitles.tracks.map(\.language) == ["de"])
        #expect(player.subtitleTracks.count == 2)
    }

    @Test func aRememberedLanguageSelectsTheMatchingNativeSidecar() async throws {
        let directory = try folder(with: ["film.en.ass", "film.fr.ass"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = TestPreferences.make()
        preferences.subtitleChoice = .language("fr")
        let fake = FakeEngine()
        let player = native(fake, preferences: preferences)
        defer { player.close() }
        player.open(directory.appendingPathComponent("film.mkv"))
        await waitUntil("the French track") { player.selectedSubtitle?.language == "fr" }
        #expect(fake.selectedSubtitleTrack?.language == "fr")
    }

    @Test func aPickedAssFileIsAddedToTheEngineAndSelected() async throws {
        let directory = try folder(with: ["other.ass"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeEngine()
        let player = native(fake)
        defer { player.close() }
        player.open(directory.appendingPathComponent("film.mkv"))
        await waitUntil("playback") { player.state == .playing }
        player.addSubtitleFile(directory.appendingPathComponent("other.ass"))
        #expect(fake.addedSubtitleFiles.map(\.lastPathComponent) == ["other.ass"])
        #expect(player.selectedSubtitle?.title == "other")
    }

    @Test func withoutANativeEngineAnAssFileIsReadAsText() async throws {
        let directory = try folder(with: ["film.ass"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeEngine()
        let player = PlayerModel(services: .testing(), engineFactory: { _ in fake })
        defer { player.close() }
        player.open(directory.appendingPathComponent("film.mp4"))
        await waitUntil("the sidecar") { player.subtitles.tracks.count == 1 }
        #expect(fake.addedSubtitleFiles.isEmpty)
    }
}

@MainActor
@Suite struct CompatibilityEngineSwitchTests {
    @Test func theMenuSwitchReopensTheFileOnTheOtherEngineAtTheSamePlace() async {
        let main = FakeEngine(), compatibility = FakeEngine()
        compatibility.isCompatibilityEngine = true
        let player = PlayerModel(services: .testing(), engineFactory: { _ in main }, compatibilityFactory: { _ in compatibility })
        defer { player.close() }
        let url = URL(fileURLWithPath: "/Movies/film.mp4")
        player.open(url)
        await waitUntil("playback") { player.state == .playing }
        #expect(!player.isCompatibilityEngine)
        main.advance(to: .seconds(42))
        await waitUntil("time") { player.currentTime == .seconds(42) }

        player.toggleCompatibilityEngine()
        await waitUntil("the other engine") { compatibility.loadedURLs == [url] }
        #expect(compatibility.loadedStarts == [.seconds(42)])
        await waitUntil("playback again") { player.state == .playing && player.isCompatibilityEngine }
        #expect(main.closed)
        #expect(player.resumeOffer == nil, "it picks up where it was, so there is nothing to offer")

        compatibility.advance(to: .seconds(50))
        await waitUntil("time") { player.currentTime == .seconds(50) }
        let another = FakeEngine()
        let back = PlayerModel(services: .testing(), engineFactory: { _ in another }, compatibilityFactory: { _ in compatibility })
        defer { back.close() }
        back.open(url, compatibility: true)
        await waitUntil("compat first") { back.isCompatibilityEngine }
    }

    @Test func theHiddenPreferenceSendsEveryFileToTheCompatibilityEngine() async {
        let preferences = TestPreferences.make()
        preferences.forcesCompatibilityEngine = true
        let main = FakeEngine(), compatibility = FakeEngine()
        let player = PlayerModel(services: .testing(preferences: preferences), engineFactory: { _ in main }, compatibilityFactory: { _ in compatibility })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(main.loadedURLs.isEmpty && compatibility.loadedURLs.count == 1)
    }
}
