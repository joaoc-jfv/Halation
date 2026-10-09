import SwiftUI

@main
struct HalationApp: App {
    var body: some Scene {
        Window("Halation", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 540)
    }
}

private struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black
            Text("Drop a video to play")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .glassEffect(.regular, in: .capsule)
        }
        .ignoresSafeArea()
    }
}
