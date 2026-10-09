import Foundation
import Testing
@testable import NitPicker

@Suite struct EpisodeNumberTests {
    private func parse(_ name: String) -> EpisodeNumber? { EpisodeNumber.parse(fileName: name) }

    @Test func readsTheCommonSeasonAndEpisodeMarkers() {
        #expect(parse("Dark.Matter.2024.S02E05.Amare.ed.essere.amato.ITA.ENG.2160p.mkv") == EpisodeNumber(series: "dark matter 2024", season: 2, episode: 5))
        #expect(parse("show name s1e2.mp4")?.season == 1 && parse("show name s1e2.mp4")?.episode == 2)
        #expect(parse("Show Name 3x07 Title.avi") == EpisodeNumber(series: "show name", season: 3, episode: 7))
        #expect(parse("Show S01E02E03.mkv")?.episode == 2)
        #expect(parse("The Show - S10 E12.mkv")?.episode == 12)
    }

    @Test func readsAnimeStyleNumbers() {
        #expect(parse("[Group] Some Anime - 05 [1080p].mkv") == EpisodeNumber(series: "some anime", season: nil, episode: 5))
        #expect(parse("Some Anime - 12v2.mkv")?.episode == 12)
        #expect(parse("Some Anime EP07.mkv") == EpisodeNumber(series: "some anime", season: nil, episode: 7))
        #expect(parse("Some Anime Episode 08.mkv")?.episode == 8)
    }

    @Test func ignoresNamesThatAreNotEpisodes() {
        #expect(parse("Movie.2019.1920x1080.mkv") == nil)
        #expect(parse("Holiday 2023.mp4") == nil)
        #expect(parse("IMG_0042.MOV") == nil)
        #expect(parse("Blade Runner 2049 - 4K.mkv") == nil)
        #expect(parse("Seven Samurai.mkv") == nil)
    }

    @Test func ordersAndLabelsEpisodes() {
        let a = EpisodeNumber(series: "x", season: 1, episode: 10), b = EpisodeNumber(series: "x", season: 2, episode: 1)
        #expect(a < b)
        #expect(a.label == "S01E10" && EpisodeNumber(series: "x", season: nil, episode: 5).label == "E05")
    }
}

@Suite struct FolderPlaylistTests {
    private func urls(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/Shows/\($0)") } }

    @Test func walksTheVideosInNaturalNameOrder() throws {
        let files = urls(["Show.S01E10.mkv", "Show.S01E02.mkv", "Show.S01E01.mkv", "notes.txt", "Show.S01E01.en.srt", ".hidden.mkv", "poster.jpg"])
        let playlist = try #require(FolderPlaylist(current: files[1], siblings: files))
        #expect(playlist.entries.map(\.lastPathComponent) == ["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E10.mkv"])
        #expect(playlist.current.lastPathComponent == "Show.S01E02.mkv")
        #expect(playlist.previous?.lastPathComponent == "Show.S01E01.mkv" && playlist.next?.lastPathComponent == "Show.S01E10.mkv")
        #expect(playlist.position == "2 of 3")
    }

    @Test func endsAtTheFirstAndLastFile() throws {
        let files = urls(["a.mp4", "b.mp4"])
        let first = try #require(FolderPlaylist(current: files[0], siblings: files))
        #expect(first.previous == nil && first.next?.lastPathComponent == "b.mp4")
        let last = try #require(FolderPlaylist(current: files[1], siblings: files))
        #expect(last.next == nil && last.previous?.lastPathComponent == "a.mp4")
    }

    @Test func aFileAloneInItsFolderHasNoPlaylist() {
        let files = urls(["only.mp4", "only.srt"])
        #expect(FolderPlaylist(current: files[0], siblings: files) == nil)
        #expect(FolderPlaylist(current: URL(fileURLWithPath: "/Shows/readme.txt"), siblings: files) == nil)
    }

    @Test func nextEpisodeNeedsTheSameSeriesAndALaterNumber() throws {
        let series = urls(["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S02E01.mkv", "Other.Show.S01E01.mkv", "Movie.mkv"])
        func nextEpisode(of name: String) throws -> String? {
            let url = URL(fileURLWithPath: "/Shows/\(name)")
            return try #require(FolderPlaylist(current: url, siblings: series)).nextEpisode?.lastPathComponent
        }
        #expect(try nextEpisode(of: "Show.S01E01.mkv") == "Show.S01E02.mkv")
        #expect(try nextEpisode(of: "Show.S01E02.mkv") == "Show.S02E01.mkv", "the next season's first episode follows")
        #expect(try nextEpisode(of: "Show.S02E01.mkv") == nil, "a different show comes next")
        #expect(try nextEpisode(of: "Other.Show.S01E01.mkv") == nil, "a movie comes next")
        #expect(try nextEpisode(of: "Movie.mkv") == nil)
    }

    @Test func aFileTheListingMissedStillJoinsItsPlace() throws {
        let listed = urls(["Show.S01E01.mkv", "Show.S01E03.mkv"])
        let current = URL(fileURLWithPath: "/Shows/Show.S01E02.mkv")
        let playlist = try #require(FolderPlaylist(current: current, siblings: listed))
        #expect(playlist.entries.map(\.lastPathComponent) == ["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv"] && playlist.index == 1)
    }
}

@MainActor
@Suite struct PlaylistPlaybackTests {
    @MainActor private final class Engines {
        var made: [FakeEngine] = []
        func make() -> FakeEngine {
            let engine = FakeEngine()
            made.append(engine)
            return engine
        }
    }

    private func folder(_ names: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-shows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func model(_ engines: Engines, preferences: Preferences = TestPreferences.make()) -> PlayerModel {
        let player = PlayerModel(services: .testing(preferences: preferences), engineFactory: { _ in engines.make() })
        player.upNextLeadTime = .seconds(15)
        return player
    }

    @Test func listsTheFolderAndWalksIt() async throws {
        let directory = try folder(["Show.S01E01.mkv", "Show.S01E02.mkv", "Show.S01E03.mkv", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = Engines()
        let player = model(engines)
        defer { player.close() }
        player.open(directory.appendingPathComponent("Show.S01E02.mkv"))
        await waitUntil("the playlist") { player.playlist != nil }
        #expect(player.hasNextFile && player.hasPreviousFile)

        player.playNextFile()
        await waitUntil("the next file") { player.currentURL?.lastPathComponent == "Show.S01E03.mkv" && player.state == .playing }
        await waitUntil("its playlist") { player.playlist?.current.lastPathComponent == "Show.S01E03.mkv" }
        #expect(!player.hasNextFile && player.hasPreviousFile)
        player.playNextFile()
        #expect(player.toast?.text == "This is the last video in the folder")
        player.playPreviousFile()
        await waitUntil("back") { player.currentURL?.lastPathComponent == "Show.S01E02.mkv" }
    }

    @Test func offersTheNextEpisodeInTheLastSecondsAndPlaysItAtTheEnd() async throws {
        let directory = try folder(["Show.S01E01.mkv", "Show.S01E02.mkv"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = Engines()
        let player = model(engines)
        defer { player.close() }
        player.open(directory.appendingPathComponent("Show.S01E01.mkv"))
        await waitUntil("playback and playlist") { player.state == .playing && player.playlist != nil }
        let first = try #require(engines.made.first)

        first.advance(to: .seconds(500))
        await waitUntil("time") { player.currentTime == .seconds(500) }
        #expect(player.upNext == nil, "not yet")
        first.advance(to: .seconds(990))
        await waitUntil("the card") { player.upNext != nil }
        #expect(player.upNext?.label == "S01E02" && player.upNext?.startsAutomatically == true)

        first.emit(.stateChanged(.ended))
        await waitUntil("the next episode") { player.currentURL?.lastPathComponent == "Show.S01E02.mkv" && player.state == .playing }
        #expect(engines.made.count == 2)
        #expect(player.upNext == nil)
    }

    @Test func closingTheCardKeepsThisEpisodeFromHandingOver() async throws {
        let directory = try folder(["Show.S01E01.mkv", "Show.S01E02.mkv"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = Engines()
        let player = model(engines)
        defer { player.close() }
        player.open(directory.appendingPathComponent("Show.S01E01.mkv"))
        await waitUntil("playback and playlist") { player.state == .playing && player.playlist != nil }
        let first = try #require(engines.made.first)
        first.advance(to: .seconds(995))
        await waitUntil("the card") { player.upNext != nil }
        player.dismissUpNext()
        #expect(player.upNext == nil)
        first.advance(to: .seconds(998))
        await waitUntil("time") { player.currentTime == .seconds(998) }
        #expect(player.upNext == nil, "it doesn't come back")
        first.emit(.stateChanged(.ended))
        try await Task.sleep(for: .milliseconds(200))
        #expect(engines.made.count == 1 && player.currentURL?.lastPathComponent == "Show.S01E01.mkv")
    }

    @Test func theSettingTurnsAutoplayOffAndTheCardJustOffersIt() async throws {
        let directory = try folder(["Show.S01E01.mkv", "Show.S01E02.mkv"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = TestPreferences.make()
        let engines = Engines()
        let player = model(engines, preferences: preferences)
        defer { player.close() }
        player.setAutoplaysNextEpisode(false)
        #expect(preferences.autoplaysNextEpisode == false)
        player.open(directory.appendingPathComponent("Show.S01E01.mkv"))
        await waitUntil("playback and playlist") { player.state == .playing && player.playlist != nil }
        let first = try #require(engines.made.first)
        first.advance(to: .seconds(992))
        await waitUntil("the card") { player.upNext != nil }
        #expect(player.upNext?.startsAutomatically == false)
        first.emit(.stateChanged(.ended))
        try await Task.sleep(for: .milliseconds(200))
        #expect(engines.made.count == 1)
        player.playUpNext()
        await waitUntil("Play Now") { player.currentURL?.lastPathComponent == "Show.S01E02.mkv" }
    }

    @Test func unrelatedFilesAreNeverPlayedAutomatically() async throws {
        let directory = try folder(["Holiday.mp4", "Wedding.mp4"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let engines = Engines()
        let player = model(engines)
        defer { player.close() }
        player.open(directory.appendingPathComponent("Holiday.mp4"))
        await waitUntil("the playlist") { player.playlist != nil }
        #expect(player.hasNextFile, "the menu can still go on")
        let first = try #require(engines.made.first)
        first.advance(to: .seconds(995))
        await waitUntil("time") { player.currentTime == .seconds(995) }
        #expect(player.upNext == nil)
        first.emit(.stateChanged(.ended))
        try await Task.sleep(for: .milliseconds(200))
        #expect(engines.made.count == 1)
    }
}
