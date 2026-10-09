import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        TabView {
            Tab("Playback", systemImage: "play.rectangle") {
                PlaybackSettingsView()
            }
            Tab("Subtitles", systemImage: "captions.bubble") {
                SubtitleSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 500)
    }
}

struct PlaybackSettingsView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Form {
            Toggle("Play the next episode automatically", isOn: Binding(
                get: { player.autoplaysNextEpisode },
                set: { player.setAutoplaysNextEpisode($0) }
            ))
            Text("When an episode ends, the next one in the same folder starts, if its file name follows on (S01E02, then S01E03). A card offers it during the last seconds, and its close button stops this for the episode.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
