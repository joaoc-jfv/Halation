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
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    OpenPanel.chooseVideo { player.open($0) }
                }
                .keyboardShortcut("o")
            }
        }
    }
}
