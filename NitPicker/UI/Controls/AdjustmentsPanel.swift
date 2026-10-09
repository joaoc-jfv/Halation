import SwiftUI

/// Brightness, contrast and saturation (compatibility engine only).
struct AdjustmentsPanel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeading("Picture")
            slider("Brightness", \.brightness)
            slider("Contrast", \.contrast)
            slider("Saturation", \.saturation)
            HStack {
                Text("Compatibility Engine only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { player.resetVideoAdjustments() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(player.videoAdjustments.isDefault)
                    .opacity(player.videoAdjustments.isDefault ? 0.4 : 1)
            }
        }
        .panelGlass(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture adjustments")
    }

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<VideoAdjustments, Int>) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(.white).frame(width: 84, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(player.videoAdjustments[keyPath: keyPath]) },
                    set: {
                        var adjustments = player.videoAdjustments
                        adjustments[keyPath: keyPath] = Int($0.rounded())
                        player.setVideoAdjustments(adjustments)
                    }
                ),
                in: Double(VideoAdjustments.range.lowerBound)...Double(VideoAdjustments.range.upperBound)
            )
            .accessibilityLabel(title)
            .accessibilityValue("\(player.videoAdjustments[keyPath: keyPath])")
            Text("\(player.videoAdjustments[keyPath: keyPath])")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, alignment: .trailing)
        }
    }
}
