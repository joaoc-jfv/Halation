import Foundation

/// Everything the player model talks to outside itself, so tests can swap in fakes.
@MainActor
struct PlayerServices {
    var preferences: Preferences
    var folderAccess: FolderAccess
    var nowPlaying: any NowPlayingPublishing
    var resume: ResumeStore
    var recents: RecentFiles
    var sleep: any SleepPrevention
    var thumbnails: ThumbnailCache

    static func live() -> PlayerServices {
        PlayerServices(
            preferences: Preferences(), folderAccess: FolderAccess(), nowPlaying: SystemNowPlaying(),
            resume: ResumeStore(), recents: RecentFiles(), sleep: SystemSleepPrevention(),
            thumbnails: ThumbnailCache()
        )
    }
}
