import SwiftUI

/// Floating Liquid Glass control bar (PLAN.md §6). Crop and PiP buttons arrive with milestones 1.7 and 1.8.
struct ControlBar: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage("timeLabelShowsTotal") private var showsTotal = false
    @State private var scrubFraction: Double?
    @State private var volumeDrag: Double?
    let namespace: Namespace.ID
    var onToggleFullScreen: () -> Void

    private var durationSeconds: Double { player.duration.seconds }
    private var elapsed: Duration {
        scrubFraction.map { .seconds($0 * durationSeconds) } ?? player.currentTime
    }

    var body: some View {
        HStack(spacing: 10) {
            transportButtons
            timeLabel(elapsed.clockString)
            scrubber
            Button { showsTotal.toggle() } label: {
                timeLabel(showsTotal ? player.duration.clockString : "−" + (player.duration - elapsed).clockString)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsTotal ? "Total time" : "Time remaining")
            .accessibilityValue(showsTotal ? player.duration.clockString : (player.duration - elapsed).clockString)
            .accessibilityHint("Switches between total and remaining time")
            volume
            ControlButton(
                symbol: "captions.bubble",
                label: "Audio and Subtitles",
                isActive: player.activePanel == .audioSubtitles
            ) { player.togglePanel(.audioSubtitles) }
            speedMenu
            ControlButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen", action: onToggleFullScreen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .capsule)
        .glassEffectID("bar", in: namespace)
    }

    private var transportButtons: some View {
        HStack(spacing: 2) {
            ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", label: player.isPlaying ? "Pause" : "Play") {
                player.togglePlayPause()
            }
            ControlButton(symbol: "gobackward.10", label: "Skip Back 10 Seconds") { player.skip(by: .seconds(-10)) }
            ControlButton(symbol: "goforward.10", label: "Skip Forward 10 Seconds") { player.skip(by: .seconds(10)) }
        }
    }

    private var scrubber: some View {
        TrackSlider(
            value: durationSeconds > 0 ? player.currentTime.seconds / durationSeconds : 0,
            buffered: durationSeconds > 0 ? player.buffered.seconds / durationSeconds : nil,
            dragValue: $scrubFraction,
            label: "Playback position",
            valueDescription: "\(player.currentTime.clockString) of \(player.duration.clockString)",
            onCommit: { player.seek(to: .seconds($0 * durationSeconds), precise: true) },
            onAdjust: { player.skip(by: .seconds(Double($0) * 5)) }
        )
        .frame(minWidth: 120)
    }

    private var volume: some View {
        HStack(spacing: 2) {
            ControlButton(
                symbol: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: player.isMuted ? "Unmute" : "Mute"
            ) { player.toggleMute() }
            TrackSlider(
                value: player.isMuted ? 0 : Double(player.volume),
                dragValue: $volumeDrag,
                label: "Volume",
                valueDescription: "\(Int((player.volume * 100).rounded())) percent",
                onChange: { player.setVolume(Float($0)) },
                onAdjust: { player.setVolume(player.volume + Float($0) * 0.05) }
            )
            .frame(width: 64)
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PlaybackSpeed.presets, id: \.self) { speed in
                Toggle(PlaybackSpeed.label(for: speed), isOn: Binding(
                    get: { player.rate == speed },
                    set: { _ in player.setRate(speed) }
                ))
            }
        } label: {
            Text(PlaybackSpeed.label(for: player.rate)).monospacedDigit()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(PlaybackSpeed.label(for: player.rate))
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 44)
    }
}

struct ControlButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(isActive ? 0.25 : 0), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
