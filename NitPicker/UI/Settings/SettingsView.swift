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
            Section {
                Toggle("Play the next episode automatically", isOn: Binding(
                    get: { player.autoplaysNextEpisode },
                    set: { player.setAutoplaysNextEpisode($0) }
                ))
                note("When an episode ends, the next one in the same folder starts, if its file name follows on (S01E02, then S01E03). A card offers it during the last seconds, and its close button stops this for the episode.")
            }
            Section {
                Toggle("Crop black bars when a file opens", isOn: Binding(
                    get: { player.cropsBlackBarsAutomatically },
                    set: { player.setCropsBlackBarsAutomatically($0) }
                ))
                note("Looks at ten stills from across the video and cuts off bars that are black in all of them. Video ▸ Detect Black Bars (⇧C) does the same on request.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
