import SwiftUI

@main
struct HalationApp: App {
    @State private var player = PlayerModel()

    var body: some Scene {
        Window("Halation", id: "main") {
            PlayerWindowView()
                .environment(player)
                .onOpenURL { player.open($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 540)
        .commands { AppCommands(player: player) }

        Settings {
            SubtitleSettingsView()
                .environment(player)
        }
    }
}
