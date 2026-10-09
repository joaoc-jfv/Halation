import AppKit
import SwiftUI

@main
struct HalationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = PlayerModel()

    var body: some Scene {
        Window("Halation", id: "main") {
            PlayerWindowView()
                .environment(player)
                .onOpenURL { player.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.saveResumePosition()
                }
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
