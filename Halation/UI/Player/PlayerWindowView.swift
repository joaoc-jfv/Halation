import SwiftUI

struct PlayerWindowView: View {
    @Environment(PlayerModel.self) private var player
    @State private var windowController = WindowController()
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black
            if let videoView = player.videoView {
                VideoSurfaceView(videoView: videoView) { windowController.toggleFullScreen() }
            }
            if !player.hasMedia || player.errorMessage != nil {
                EmptyStateView()
            }
            if player.hasMedia {
                VStack {
                    Spacer()
                    TemporaryControls()
                }
            }
        }
        .ignoresSafeArea()
        .background(WindowAccessor { windowController.configure($0) })
        .onChange(of: player.mediaInfo?.resolution) { _, size in
            if let size { windowController.fit(toVideoSize: size) }
        }
        // TEMPORARY: milestone 1.4 moves all shortcuts into the menus.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress("f") {
            windowController.toggleFullScreen()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            player.open(url)
            return true
        }
    }
}

private struct EmptyStateView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(spacing: 12) {
            Text(player.errorMessage ?? "Drop a video to play")
                .font(.title3)
            Button("Open…") {
                OpenPanel.chooseVideo { player.open($0) }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// TEMPORARY: plain buttons so milestone 1.2 is playable. Replaced by the Liquid Glass
/// control bar in milestone 1.4.
private struct TemporaryControls: View {
    @Environment(PlayerModel.self) private var player
    @State private var scrubSeconds: Double?

    private static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        HStack(spacing: 12) {
            Button { player.skip(by: .seconds(-10)) } label: { Image(systemName: "gobackward.10") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            Button { player.skip(by: .seconds(10)) } label: { Image(systemName: "goforward.10") }

            Text(player.currentTime.clockString).monospacedDigit()
            Slider(
                value: Binding(
                    get: { scrubSeconds ?? player.currentTime.seconds },
                    set: { scrubSeconds = $0 }
                ),
                in: 0...max(player.duration.seconds, 1)
            ) { editing in
                if !editing, let target = scrubSeconds {
                    player.seek(to: .seconds(target), precise: true)
                    scrubSeconds = nil
                }
            }
            Text(player.duration.clockString).monospacedDigit()

            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            Slider(
                value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }),
                in: 0...1
            )
            .frame(width: 80)

            Picker("Speed", selection: Binding(get: { player.rate }, set: { player.setRate($0) })) {
                ForEach(Self.speeds, id: \.self) { Text("\($0, format: .number)×").tag($0) }
            }
            .labelsHidden()
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: .capsule)
        .frame(maxWidth: 720)
        .padding(.bottom, 20)
    }
}
