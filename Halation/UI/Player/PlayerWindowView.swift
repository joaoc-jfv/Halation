import SwiftUI

struct PlayerWindowView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowController = WindowController()
    @FocusState private var isFocused: Bool

    private var showsControls: Bool { player.hasMedia && player.errorMessage == nil }

    var body: some View {
        ZStack {
            Color.black
            if let videoView = player.videoView {
                VideoSurfaceView(videoView: videoView) { windowController.toggleFullScreen() }
            }
            if !showsControls {
                EmptyStateView()
            }
            if showsControls {
                if player.activePanel != nil {
                    // Click anywhere outside the panel to dismiss it.
                    Color.clear.contentShape(Rectangle()).onTapGesture { player.closePanel() }
                }
                controls
            }
            toast
        }
        .ignoresSafeArea()
        .background(WindowAccessor { windowController.configure($0) })
        .onChange(of: player.mediaInfo?.resolution) { _, size in
            if let size { windowController.fit(toVideoSize: size) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        // Esc closes an open panel first, and otherwise leaves full screen as usual.
        .onExitCommand {
            if player.activePanel != nil {
                player.closePanel()
            } else {
                windowController.exitFullScreen()
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { player.registerActivity() }
        }
        .onChange(of: player.controlsVisible) { _, visible in
            windowController.setChromeVisible(visible)
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            player.open(url)
            return true
        }
    }

    /// The bottom gradient keeps the glass readable over bright HDR highlights. It only exists
    /// while the controls are showing.
    private var controls: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            ControlsOverlay { windowController.toggleFullScreen() }
                .frame(maxHeight: .infinity, alignment: .bottom)
            FormatBadges()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 24)
                .padding(.trailing, 20)
        }
        .opacity(player.controlsVisible ? 1 : 0)
        .allowsHitTesting(player.controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: player.controlsVisible)
    }

    private var toast: some View {
        VStack {
            if let toast = player.toast {
                OSDToastView(toast: toast)
                    .id(toast.id)
                    .transition(.opacity)
            }
            Spacer()
        }
        .padding(.top, 28)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: player.toast)
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

/// The control bar and the panel that grows out of it, in one glass container so they morph.
private struct ControlsOverlay: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace
    var onToggleFullScreen: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(spacing: 12) {
                if player.activePanel == .audioSubtitles {
                    TrackPanel()
                        .glassEffectID("panel", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                }
                ControlBar(namespace: glassNamespace, onToggleFullScreen: onToggleFullScreen)
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .onHover { player.setPointerOverControls($0) }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: player.activePanel)
    }
}
