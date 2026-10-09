import SwiftUI

/// Small "Spatial Audio" tag used in the track list and the top-right badge.
struct SpatialAudioBadge: View {
    var body: some View {
        Label("Spatial Audio", systemImage: "airpods.gen3")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.2), in: .capsule)
    }
}

/// Top-right badges shown with the controls. The full info HUD arrives in milestone 1.9.
struct FormatBadges: View {
    @Environment(PlayerModel.self) private var player

    private var showsSpatialAudio: Bool {
        player.selectedAudio?.isSpatial == true && player.audioOutputMode == .spatial
    }

    var body: some View {
        if showsSpatialAudio {
            SpatialAudioBadge()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
