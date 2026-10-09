import SwiftUI

/// Speed presets and a fine slider from 0.25× to 4×.
struct SpeedPanel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                panelHeading("Playback Speed")
                Spacer()
                Text(PlaybackSpeed.label(for: player.rate))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 6) {
                ForEach(PlaybackSpeed.presets, id: \.self) { speed in
                    Button { player.setRate(speed) } label: {
                        Text(PlaybackSpeed.label(for: speed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(player.rate == speed ? 0.3 : 0.1), in: .capsule)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlaybackSpeed.label(for: speed))
                    .accessibilityAddTraits(player.rate == speed ? .isSelected : [])
                }
            }
            HStack(spacing: 10) {
                Text("0.25×").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { PlaybackSpeed.sliderPosition(forRate: player.rate) },
                        set: { player.setRate(PlaybackSpeed.rate(forSliderPosition: $0)) }
                    ),
                    in: 0...1
                )
                .accessibilityLabel("Playback speed")
                .accessibilityValue(PlaybackSpeed.label(for: player.rate))
                Text("4×").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("[ and ] step, \\ resets").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset to 1×") { player.setRate(1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(player.rate == 1)
                    .opacity(player.rate == 1 ? 0.4 : 1)
            }
        }
        .panelGlass(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback speed")
    }
}
