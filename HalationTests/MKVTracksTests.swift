import Foundation
import Testing
@testable import Halation

@Suite struct MKVSubtitleTextTests {
    private func text(_ packet: String, _ codec: String) -> String? {
        MKVSubtitleReader.text(fromPacket: Array(packet.utf8), codec: codec)
    }

    @Test func subRipPacketsAreTheTextItself() {
        #expect(text("Hello\r\nthere\r\n", "subrip") == "Hello\nthere")
        #expect(text("<i>Hello</i>", "subrip") == "<i>Hello</i>")
        #expect(text("  \n", "subrip") == nil)
    }

    @Test func assPacketsKeepEverythingAfterTheEighthComma() {
        #expect(text("0,0,Default,,0,0,0,,Hello, world", "ass") == "Hello, world")
        #expect(text(#"12,1,Sign,Bob,0,0,10,,{\an8}Top\NBottom\hline"#, "ass") == #"{\an8}Top"# + "\nBottom line")
        #expect(text("0,0,Default,,0,0,0,,", "ass") == nil)
        #expect(text("not an ass event", "ass") == nil)
    }

    @Test func assVectorDrawingsAreSkipped() {
        #expect(text(#"1,0,Default,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}"#, "ass") == nil)
        #expect(text(#"1,0,Default,,0,0,0,,{\pos(10,10)}Not a drawing"#, "ass") == #"{\pos(10,10)}Not a drawing"#)
    }

    @Test func assOverridesAreStrippedByTheOverlay() throws {
        let raw = try #require(text(#"0,0,Default,,0,0,0,,{\i1}Styled{\i0}\Nsecond line"#, "ass"))
        #expect(SubtitleMarkup.plainText(from: raw) == "Styled\nsecond line")
    }

    @Test func onlyTextCodecsAreRead() {
        for codec in ["subrip", "ass", "ssa", "webvtt", "text"] { #expect(MKVSubtitleReader.isTextCodec(codec)) }
        for codec in ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"] { #expect(!MKVSubtitleReader.isTextCodec(codec)) }
    }
}

@Suite struct RemuxAudioPlanTests {
    private func probe() -> MKVProbeResult {
        MKVProbeResult(
            formatName: "matroska,webm", title: nil, duration: .seconds(60),
            streams: [
                ProbedStream(id: 0, kind: .video, codec: "hevc", width: 1920, height: 1080),
                ProbedStream(id: 1, kind: .audio, codec: "eac3", language: "ita", isDefault: true, channels: 6),
                ProbedStream(id: 2, kind: .audio, codec: "eac3", language: "eng", channels: 6),
                ProbedStream(id: 3, kind: .audio, codec: "dts", language: "fra", channels: 6),
            ],
            chapters: [], keyframes: [.zero, .seconds(6), .seconds(12), .seconds(18), .seconds(24), .seconds(30)]
        )
    }

    @Test func playsTheRequestedTrack() throws {
        let plan = try RemuxSession.plan(for: probe(), preferredAudioLanguage: nil, audioStreamID: 2)
        #expect(plan.audio?.id == 2)
    }

    @Test func ignoresARequestForATrackItCannotCopy() throws {
        let plan = try RemuxSession.plan(for: probe(), preferredAudioLanguage: nil, audioStreamID: 3)
        #expect(plan.audio?.id == 1)  // back to the file's default
    }
}

@MainActor
@Suite struct MKVTrackPlaybackTests {
    private struct Clip {
        let mkv: URL
        private let source: URL

        init(seconds: Int = 14, audio: [String] = ["eng", "fra"], options: MKVFixture.Options = .init()) async throws {
            source = try await TestVideo.make(seconds: seconds, fps: 10, flavor: .sdrH264, audioLanguages: audio)
            mkv = try MKVFixture.make(from: source, options: options)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: mkv)
        }
    }

    private func player(preferences: Preferences = TestPreferences.make()) -> PlayerModel {
        PlayerModel(services: .testing(preferences: preferences))
    }

    // MARK: Audio

    @Test func listsEveryAudioTrackAndSwitchesBetweenThem() async throws {
        let clip = try await Clip(seconds: 20)
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.audioTracks.count == 2)
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "en"))

        model.seek(to: .seconds(8), precise: true)
        // The model shows the target at once; wait for the player itself to get there.
        await waitUntil("seek to 8 s") { model.livePlaybackTime().seconds >= 8 }
        model.selectAudio(model.audioTracks[1])
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "fr"))  // at once, before the reload lands

        await waitUntil("playing again after the switch", timeout: .seconds(15)) { model.state == .playing && model.currentTime.seconds > 8.3 }
        #expect(model.currentTime.seconds < 11)  // resumed where it was (8 s), not from the start
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "fr"))
        #expect(model.errorMessage == nil)

        // And back, repeatedly.
        model.selectAudio(model.audioTracks[0])
        model.selectAudio(model.audioTracks[1])
        model.selectAudio(model.audioTracks[0])
        await waitUntil("settled on the last pick", timeout: .seconds(15)) { model.state == .playing && LanguageMatching.matches(model.selectedAudio?.language, "en") }
        #expect(model.errorMessage == nil)
    }

    @Test func switchingWhilePausedStaysPaused() async throws {
        let clip = try await Clip(seconds: 12)
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        model.seek(to: .seconds(4), precise: true)
        await waitUntil("seek to 4 s") { model.livePlaybackTime().seconds >= 4 }
        model.pause()
        await waitUntil("paused") { model.state == .paused }

        model.selectAudio(model.audioTracks[1])
        // The reload takes a fraction of a second; afterwards the player may report ready or paused, but never playing.
        try await Task.sleep(for: .seconds(2.5))
        #expect(model.state == .ready || model.state == .paused, "state \(model.state)")
        #expect(abs(model.currentTime.seconds - 4) < 0.5, "time after switch: \(model.currentTime.seconds)")
        #expect(model.errorMessage == nil)
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "fr"))
    }

    // MARK: Subtitles

    @Test func readsTextSubtitlesAndDrawsThemInStepWithThePlayhead() async throws {
        let clip = try await Clip(seconds: 10, audio: ["eng"], options: .init(subtitle: (language: "ita", forced: false), assSubtitle: "eng"))
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.subtitleTracks.map(\.codec) == ["SRT", "ASS"])
        #expect(model.subtitleTracks.map(\.language) == ["it", "en"])
        #expect(model.activeSubtitleCues().isEmpty)  // nothing is selected yet
        model.pause()

        let srt = model.subtitleTracks[0], ass = model.subtitleTracks[1]
        model.selectSubtitle(srt)
        #expect(model.drawsSubtitles)
        model.seek(to: .seconds(1), precise: true)
        await waitUntil("the SRT cue") { model.activeSubtitleCues().map(\.text) == ["Hello from the fixture"] }
        model.seek(to: .seconds(2.5), precise: true)
        await waitUntil("the cue to end") { model.currentTime.seconds >= 2.5 && model.activeSubtitleCues().isEmpty }

        model.selectSubtitle(ass)
        model.seek(to: .seconds(3.5), precise: true)
        await waitUntil("the ASS cue") { !model.activeSubtitleCues().isEmpty }
        #expect(SubtitleMarkup.plainText(from: model.activeSubtitleCues()[0].text) == "Styled\nsecond line")
        model.seek(to: .seconds(5.2), precise: true)  // the vector drawing is dropped
        await waitUntil("past the drawing") { model.currentTime.seconds >= 5.2 }
        #expect(model.activeSubtitleCues().isEmpty)
        model.seek(to: .seconds(6.5), precise: true)
        await waitUntil("the comma cue") { model.activeSubtitleCues().map(\.text) == ["Comma, inside"] }

        model.selectSubtitle(nil)
        #expect(!model.drawsSubtitles)
        #expect(model.activeSubtitleCues().isEmpty)
    }

    @Test func subtitleDelayAppliesToFileSubtitles() async throws {
        let clip = try await Clip(seconds: 8, audio: ["eng"], options: .init(subtitle: (language: "eng", forced: false)))
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        model.pause()
        model.selectSubtitle(model.subtitleTracks[0])
        model.seek(to: .seconds(1), precise: true)
        await waitUntil("the cue") { model.activeSubtitleCues().count == 1 }

        for _ in 0..<12 { model.adjustSubtitleDelayByShortcut(SubtitleTrackStore.delayStep) }  // +1.2 s: the cue (0.5–2.0 s) now shows 1.7–3.2 s
        #expect(model.activeSubtitleCues().isEmpty)
        model.seek(to: .seconds(2.5), precise: true)
        await waitUntil("the delayed cue") { model.currentTime.seconds >= 2.5 && model.activeSubtitleCues().count == 1 }
    }

    @Test func appliesTheRememberedSubtitleLanguageWhenTheFileOpens() async throws {
        let clip = try await Clip(seconds: 6, audio: ["eng"], options: .init(subtitle: (language: "ita", forced: false), assSubtitle: "eng"))
        defer { clip.cleanUp() }
        let preferences = TestPreferences.make()
        preferences.subtitleChoice = .language("en")
        let model = player(preferences: preferences)
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.displayedSubtitle?.codec == "ASS")
        #expect(model.drawsSubtitles)
    }

    @Test func aForcedTrackIsKeptOutOfTheListButStillShowsWhenSubtitlesAreOff() async throws {
        let clip = try await Clip(seconds: 6, audio: ["eng"], options: .init(subtitle: (language: "eng", forced: true)))
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.selectableSubtitleTracks.isEmpty)
        model.selectSubtitle(nil)
        #expect(model.selectedSubtitle?.isForced == true)
        #expect(model.drawsSubtitles)
        #expect(model.displayedSubtitle == nil)  // counts as Off in the panel
    }

    // MARK: Thumbnails

    @Test func makesStillsFromTheRemuxedStream() async throws {
        let clip = try await Clip(seconds: 12, audio: ["eng"])
        defer { clip.cleanUp() }
        let engine = RemuxEngine()
        defer { engine.close() }
        try await engine.load(clip.mkv, startAt: nil)

        for seconds in [0.0, 5.0, 11.5] {
            let image = await engine.thumbnail(at: .seconds(seconds), maxSize: CGSize(width: 160, height: 160))
            let still = try #require(image, "no still at \(seconds) s")
            #expect(still.width <= 160 && still.width > 0)
            #expect(still.height > 0)
        }
    }

    @Test func scrubPreviewsWorkForMKV() async throws {
        let clip = try await Clip(seconds: 12, audio: ["eng"])
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        model.updateScrubPreview(fraction: 0.5)
        await waitUntil("a thumbnail", timeout: .seconds(10)) { model.scrubPreview?.image != nil }
        #expect(model.scrubThumbnailsAvailable)
    }
}
