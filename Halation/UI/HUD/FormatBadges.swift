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
