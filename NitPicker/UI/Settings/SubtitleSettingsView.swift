import SwiftUI

/// Subtitle appearance, in the Settings window (⌘,).
struct SubtitleSettingsView: View {
    @Environment(PlayerModel.self) private var player

    private var style: Binding<SubtitleStyle> {
        Binding(get: { player.subtitles.style }, set: { player.setSubtitleStyle($0) })
    }

    var body: some View {
        Form {
            Picker("Size", selection: style.size) {
                ForEach(SubtitleStyle.Size.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Background", selection: style.background) {
                Text("None").tag(SubtitleStyle.Background.none)
                Text("Shadow").tag(SubtitleStyle.Background.shadow)
                Text("Box").tag(SubtitleStyle.Background.box)
            }
            .pickerStyle(.segmented)

            LabeledContent("Position") {
                Slider(value: style.verticalOffset, in: SubtitleStyle.offsetRange) {
                    Text("Position")
                } minimumValueLabel: {
                    Image(systemName: "arrow.down")
                } maximumValueLabel: {
                    Image(systemName: "arrow.up")
                }
                .accessibilityLabel("Subtitle position")
            }

            preview
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var preview: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.indigo, .teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing)
            SubtitleText(
                cues: [SubtitleCue(start: .zero, end: .seconds(1), text: "This is how subtitles look.\n<i>Lines can be italic too.</i>")],
                style: player.subtitles.style, videoHeight: 360, maxWidth: 400
            )
            .padding(.bottom, 360 * (0.06 + player.subtitles.style.verticalOffset))
        }
        .frame(height: 180)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
