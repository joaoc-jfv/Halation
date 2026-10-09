import CoreGraphics
import Foundation
import MediaPlayer
import Testing
@testable import Halation

private let movie = URL(fileURLWithPath: "/Movies/Some Film (2024).mp4")

@MainActor
private struct Harness {
    let fake = FakeEngine()
    let nowPlaying = NullNowPlaying()
    let sleep = FakeSleepPrevention()
    let resume = ResumeStore(defaults: throwawayDefaults())
    let recents = RecentFiles(defaults: throwawayDefaults())
    let model: PlayerModel

    init(chapters: [Chapter] = [], title: String? = nil) {
        fake.info.chapters = chapters
        fake.info.title = title
        let fake = fake
        model = PlayerModel(
            services: .testing(nowPlaying: nowPlaying, sleep: sleep, resume: resume, recents: recents),
            engineFactory: { _ in fake }
        )
        model.resumeSaveInterval = .zero
    }

    func open() async {
        model.open(movie)
        await waitUntil("playback") { model.state == .playing && model.duration > .zero && model.mediaInfo != nil }
    }
}

@Suite struct ChapterNavigationTests {
    private let chapters = [
        Chapter(id: 0, title: "Intro", start: .zero),
        Chapter(id: 1, title: "Part 1", start: .seconds(60)),
        Chapter(id: 2, title: "Part 2", start: .seconds(180)),
    ]

    @Test func findsTheChapterAtATime() {
        #expect(ChapterNavigation.index(at: .zero, in: chapters) == 0)
        #expect(ChapterNavigation.index(at: .seconds(59.9), in: chapters) == 0)
        #expect(ChapterNavigation.index(at: .seconds(60), in: chapters) == 1)
        #expect(ChapterNavigation.index(at: .seconds(9999), in: chapters) == 2)
        #expect(ChapterNavigation.index(at: .seconds(5), in: []) == nil)
    }

    @Test func nextSkipsToTheFollowingChapter() {
        #expect(ChapterNavigation.next(after: .seconds(10), in: chapters)?.title == "Part 1")
        #expect(ChapterNavigation.next(after: .seconds(60), in: chapters)?.title == "Part 2")
        #expect(ChapterNavigation.next(after: .seconds(180), in: chapters) == nil)
    }

    @Test func previousRestartsTheChapterBeforeGoingBack() {
        #expect(ChapterNavigation.previous(before: .seconds(100), in: chapters)?.title == "Part 1")   // 40 s in: restart it
        #expect(ChapterNavigation.previous(before: .seconds(61), in: chapters)?.title == "Intro")     // 1 s in: go back
        #expect(ChapterNavigation.previous(before: .seconds(1), in: chapters)?.title == "Intro")      // first chapter
    }

    @Test func marksSkipTheFirstChapterAndStayInsideTheBar() {
        let marks = ChapterNavigation.marks(for: chapters, duration: .seconds(600))
        #expect(marks == [0.1, 0.3])
        #expect(ChapterNavigation.marks(for: chapters, duration: .zero).isEmpty)
        #expect(ChapterNavigation.marks(for: chapters, duration: .seconds(100)) == [0.6])  // the last start is past the end
    }
}

@MainActor
@Suite struct ResumeStoreTests {
    private func store() -> ResumeStore { ResumeStore(defaults: throwawayDefaults()) }

    @Test func savesOnlyMeaningfulProgress() {
        let store = store()
        store.update(url: movie, position: 10, duration: 1000)
        #expect(store.record(for: movie) == nil)  // under 30 s
        store.update(url: movie, position: 30, duration: 1000)
        #expect(store.record(for: movie)?.position == 30)
        store.update(url: movie, position: 500, duration: 1000)
        #expect(store.record(for: movie)?.position == 500)
    }

    @Test func finishingTheFileForgetsIt() {
        let store = store()
        store.update(url: movie, position: 500, duration: 1000)
        store.update(url: movie, position: 970, duration: 1000)  // exactly the last 3%
        #expect(store.record(for: movie) == nil)
    }

    @Test func aQuickPeekDoesNotEraseAnEarlierRecord() {
        let store = store()
        store.update(url: movie, position: 500, duration: 1000)
        store.update(url: movie, position: 4, duration: 1000)  // reopened and still at the start
        #expect(store.record(for: movie)?.position == 500)
    }

    @Test func ignoresUnknownDurations() {
        let store = store()
        store.update(url: movie, position: 100, duration: 0)
        store.update(url: movie, position: .nan, duration: 1000)
        #expect(store.record(for: movie) == nil)
    }

    @Test func offersOnlyRecordsInTheMiddleOfAFile() {
        func record(_ position: Double) -> ResumeRecord {
            ResumeRecord(path: "/a", name: "a", size: 1, position: position, duration: 1000, updated: .now)
        }
        #expect(ResumeStore.isOfferable(record(600)))
        #expect(!ResumeStore.isOfferable(record(29)))
        #expect(!ResumeStore.isOfferable(record(975)))
    }

    @Test func findsAMovedFileByNameAndSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("halation-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("film.mp4")
        let moved = folder.appendingPathComponent("b/film.mp4")
        try Data(repeating: 1, count: 2048).write(to: original)
        try Data(repeating: 2, count: 2048).write(to: moved)
        let different = folder.appendingPathComponent("b/other.mp4")
        try Data(repeating: 2, count: 2048).write(to: different)

        let store = store()
        store.update(url: original, position: 400, duration: 1000)
        #expect(store.record(for: moved)?.position == 400)
        #expect(store.record(for: different) == nil)
    }

    @Test func keepsTheNewestRecordsOnly() {
        let store = store()
        for index in 0..<320 {
            store.update(url: URL(fileURLWithPath: "/Movies/film-\(index).mp4"), position: 100, duration: 1000)
        }
        #expect(store.record(for: URL(fileURLWithPath: "/Movies/film-0.mp4")) == nil)
        #expect(store.record(for: URL(fileURLWithPath: "/Movies/film-319.mp4")) != nil)
    }
}

@MainActor
@Suite struct RecentFilesTests {
    private func makeFile(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data([1]).write(to: url)
        return url
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("halation-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func listsNewestFirstWithoutDuplicates() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recents = RecentFiles(defaults: throwawayDefaults())
        let a = try makeFile("a.mp4", in: folder), b = try makeFile("b.mkv", in: folder)
        recents.note(a); recents.note(b); recents.note(a)
        #expect(recents.entries.map(\.name) == ["a", "b"])
    }

    @Test func isLimitedAndPersistent() {
        let defaults = throwawayDefaults()
        let recents = RecentFiles(defaults: defaults)
        for index in 0..<30 { recents.note(URL(fileURLWithPath: "/Movies/film-\(index).mp4")) }
        #expect(recents.entries.count == RecentFiles.limit)
        #expect(recents.entries.first?.name == "film-29")
        #expect(RecentFiles(defaults: defaults).entries.count == RecentFiles.limit)
        recents.clear()
        #expect(RecentFiles(defaults: defaults).entries.isEmpty)
    }

    @Test func resolvesExistingFilesAndDropsMissingOnes() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recents = RecentFiles(defaults: throwawayDefaults())
        let file = try makeFile("film.mp4", in: folder)
        recents.note(file)
        let entry = try #require(recents.entries.first)
        #expect(recents.resolve(entry)?.standardizedFileURL.path == file.standardizedFileURL.path)
        try FileManager.default.removeItem(at: file)
        #expect(recents.resolve(entry) == nil)
    }
}

@MainActor
@Suite struct NowPlayingTests {
    @Test func dictionaryCarriesTitleDurationElapsedAndRate() {
        let info = NowPlayingInfo(title: "Film", duration: 600, elapsed: 42, rate: 1.5, isPlaying: true)
        let dictionary = SystemNowPlaying.dictionary(for: info, artwork: nil)
        #expect(dictionary[MPMediaItemPropertyTitle] as? String == "Film")
        #expect(dictionary[MPMediaItemPropertyPlaybackDuration] as? Double == 600)
        #expect(dictionary[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42)
        #expect(dictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.5)
        #expect(dictionary[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
    }

    @Test func pausedMeansZeroRateButKeepsTheDefault() {
        let info = NowPlayingInfo(title: "Film", duration: 600, elapsed: 42, rate: 2, isPlaying: false)
        let dictionary = SystemNowPlaying.dictionary(for: info, artwork: nil)
        #expect(dictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(dictionary[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 2)
    }

    @Test func modelPublishesAsPlaybackChanges() async {
        let harness = Harness(title: "A Better Title")
        await harness.open()
        let published = harness.nowPlaying.published.last
        #expect(published?.title == "A Better Title")
        #expect(published?.duration == 1000)
        #expect(published?.isPlaying == true)

        harness.model.pause()
        await waitUntil("paused info") { harness.nowPlaying.published.last?.isPlaying == false }

        harness.model.seek(to: .seconds(250), precise: true)
        #expect(harness.nowPlaying.published.last?.elapsed == 250)

        harness.model.setRate(1.5)
        #expect(harness.nowPlaying.published.last?.rate == 1.5)
    }

    /// MediaPlayer asks for the artwork on its own queue. A handler that was main-actor-isolated trapped there
    /// and crashed the app on launch (a fake publisher in the other tests can't catch that).
    @Test func artworkHandlerRunsOffTheMainThread() async throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let artwork = SystemNowPlaying.makeArtwork(image)
        let size = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: artwork.image(at: CGSize(width: 8, height: 8))?.size)
            }
        }
        #expect(size == CGSize(width: 8, height: 8))
    }

    @Test func fallsBackToTheFileNameForTheTitle() async {
        let harness = Harness()
        await harness.open()
        #expect(harness.model.displayTitle == "Some Film (2024)")
        #expect(harness.nowPlaying.published.last?.title == "Some Film (2024)")
    }

    @Test func remoteCommandsDriveThePlayer() async {
        let harness = Harness()
        await harness.open()
        let handlers = harness.nowPlaying.handlers
        handlers.pause()
        await waitUntil("pause") { harness.model.state == .paused }
        handlers.toggle()
        await waitUntil("play") { harness.model.state == .playing }
        handlers.seek(120)
        await waitUntil("seek") { harness.fake.seeks.last == .seconds(120) }
        handlers.skip(10)
        await waitUntil("skip") { harness.fake.seeks.last == .seconds(130) }
        handlers.skip(-10)
        await waitUntil("skip back") { harness.fake.seeks.last == .seconds(120) }
    }

    @Test func artworkComesFromAThumbnailAndClearsOnClose() async throws {
        let harness = Harness()
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        harness.fake.thumbnailImage = context.makeImage()
        await harness.open()
        await waitUntil("artwork") { harness.nowPlaying.hasArtwork }
        harness.model.close()
        #expect(harness.nowPlaying.clearCount > 0)
        #expect(harness.nowPlaying.published.isEmpty)
    }
}

@MainActor
@Suite struct PlaybackIntegrationTests {
    @Test func sleepIsPreventedOnlyWhilePlaying() async {
        let harness = Harness()
        #expect(!harness.sleep.isActive)
        await harness.open()
        #expect(harness.sleep.isActive)
        harness.model.pause()
        await waitUntil("pause") { !harness.sleep.isActive }
        harness.model.play()
        await waitUntil("play") { harness.sleep.isActive }
        harness.model.close()
        #expect(!harness.sleep.isActive)
    }

    @Test func openingAFileAddsItToTheRecents() async {
        let harness = Harness()
        await harness.open()
        #expect(harness.recents.entries.first?.name == "Some Film (2024)")
    }

    @Test func chaptersFollowThePlayheadAndNavigate() async {
        let chapters = [
            Chapter(id: 0, title: "Intro", start: .zero),
            Chapter(id: 1, title: "Part 1", start: .seconds(100)),
            Chapter(id: 2, title: "Part 2", start: .seconds(500)),
        ]
        let harness = Harness(chapters: chapters)
        await harness.open()
        #expect(harness.model.chapters == chapters)
        #expect(harness.model.currentChapter?.title == "Intro")

        harness.model.chapterByShortcut(forward: true)
        #expect(harness.model.toast?.text == "Part 1")
        await waitUntil("seek to chapter") { harness.model.currentChapter?.title == "Part 1" }
        harness.model.chapterByShortcut(forward: true)
        await waitUntil("seek to chapter 2") { harness.model.currentChapter?.title == "Part 2" }
        harness.model.chapterByShortcut(forward: true)  // already in the last chapter
        await waitUntil("both seeks") { harness.fake.seeks.count == 2 }
        #expect(harness.fake.seeks == [.seconds(100), .seconds(500)])

        harness.fake.advance(to: .seconds(503))
        await waitUntil("time") { harness.model.currentTime == .seconds(503) }
        harness.model.chapterByShortcut(forward: false)  // 3 s in is not past the threshold: previous chapter
        await waitUntil("previous chapter") { harness.model.currentChapter?.title == "Part 1" }
    }

    @Test func filesWithoutChaptersSayNoChapters() async {
        let harness = Harness()
        await harness.open()
        harness.model.chapterByShortcut(forward: true)
        #expect(harness.model.toast?.text == "No chapters")
    }

    @Test func pictureInPictureFollowsTheEngine() async {
        let harness = Harness()
        await harness.open()
        #expect(harness.model.isPictureInPictureAvailable)
        harness.model.togglePictureInPictureByShortcut()
        await waitUntil("PiP on") { harness.model.isPictureInPictureActive }
        harness.model.togglePictureInPicture()
        await waitUntil("PiP off") { !harness.model.isPictureInPictureActive }
    }

    @Test func pictureInPictureExplainsWhenUnavailable() async {
        let harness = Harness()
        harness.fake.isPictureInPictureAvailable = false
        await harness.open()
        harness.model.togglePictureInPictureByShortcut()
        #expect(harness.model.toast?.text == "Picture in Picture isn't available")
        #expect(harness.fake.pictureInPictureToggles == 0)
    }
}

@MainActor
@Suite struct ResumePlaybackTests {
    @Test func offersToResumeASavedPosition() async {
        let harness = Harness()
        harness.resume.update(url: movie, position: 600, duration: 1000)
        await harness.open()
        #expect(harness.model.resumeOffer?.label == "Resume from 10:00")
        harness.model.acceptResumeOffer()
        #expect(harness.model.resumeOffer == nil)
        await waitUntil("seek") { harness.fake.seeks == [.seconds(600)] }
    }

    @Test func theOfferGoesAwayByItself() async {
        let harness = Harness()
        harness.model.resumeOfferDuration = .milliseconds(80)
        harness.resume.update(url: movie, position: 600, duration: 1000)
        await harness.open()
        #expect(harness.model.resumeOffer != nil)
        await waitUntil("offer to expire") { harness.model.resumeOffer == nil }
        #expect(harness.fake.seeks.isEmpty)
    }

    @Test func noOfferWithoutARecordOrForFinishedOnes() async {
        let harness = Harness()
        await harness.open()
        #expect(harness.model.resumeOffer == nil)
    }

    @Test func dismissingTheOfferKeepsPlaying() async {
        let harness = Harness()
        harness.resume.update(url: movie, position: 600, duration: 1000)
        await harness.open()
        harness.model.dismissResumeOffer()
        #expect(harness.model.resumeOffer == nil)
        #expect(harness.model.state == .playing)
    }

    @Test func savesProgressWhilePlayingAndOnPause() async {
        let harness = Harness()
        await harness.open()
        harness.fake.advance(to: .seconds(100))
        await waitUntil("saved position") { harness.resume.record(for: movie)?.position == 100 }
        harness.fake.advance(to: .seconds(200))
        harness.model.pause()
        await waitUntil("saved on pause") { harness.resume.record(for: movie)?.position == 200 }
    }

    @Test func forgetsAFileThatPlayedToTheEnd() async {
        let harness = Harness()
        harness.resume.update(url: movie, position: 600, duration: 1000)
        await harness.open()
        harness.fake.advance(to: .seconds(999))
        harness.fake.emit(.stateChanged(.ended))
        await waitUntil("record removed") { harness.resume.record(for: movie) == nil }
    }

    @Test func savesWhenTheFileIsClosed() async {
        let harness = Harness()
        harness.model.resumeSaveInterval = .seconds(3600)  // too long for the periodic save to fire
        await harness.open()
        harness.fake.advance(to: .seconds(321))
        await waitUntil("time") { harness.model.currentTime == .seconds(321) }
        harness.model.close()
        #expect(harness.resume.record(for: movie)?.position == 321)
    }
}

@MainActor
@Suite struct FrameStepTests {
    @Test func stepsOneFrameAtATimeWhilePaused() async throws {
        let url = try await TestVideo.make(seconds: 3, fps: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(url)
        await waitUntil("playback") { player.state == .playing }
        player.pause()
        await waitUntil("pause") { player.state == .paused }
        player.seek(to: .seconds(1), precise: true)
        await waitUntil("seek") { abs(player.livePlaybackTime().seconds - 1) < 0.05 }

        player.stepFrameByShortcut(forward: true)
        await waitUntil("one frame on") { abs(player.livePlaybackTime().seconds - 1.1) < 0.02 }
        player.stepFrameByShortcut(forward: true)
        await waitUntil("two frames on") { abs(player.livePlaybackTime().seconds - 1.2) < 0.02 }
        player.stepFrameByShortcut(forward: false)
        await waitUntil("one frame back") { abs(player.livePlaybackTime().seconds - 1.1) < 0.02 }
        #expect(player.state == .paused)
    }

    @Test func steppingWhilePlayingPausesFirst() async throws {
        let url = try await TestVideo.make(seconds: 3, fps: 10)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(url)
        await waitUntil("playback") { player.state == .playing }
        player.stepFrameByShortcut(forward: true)
        await waitUntil("paused by the step") { player.state == .paused }
    }
}
