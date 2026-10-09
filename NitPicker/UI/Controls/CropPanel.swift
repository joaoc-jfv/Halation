import SwiftUI

/// Aspect ratio override, crop presets and zoom.
struct CropPanel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    panelHeading("Aspect Ratio")
                    ForEach(VideoLayout.Aspect.allCases, id: \.self) { aspect in
                        PanelRow(title: aspect.label, isSelected: player.videoLayout.aspect == aspect) {
                            player.setAspect(aspect)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 4) {
                    panelHeading("Crop")
                    ForEach(VideoLayout.Crop.allCases, id: \.self) { crop in
                        PanelRow(title: crop.label, isSelected: player.videoLayout.crop == crop) {
                            player.setCrop(crop)
                        }
                    }
                    Text("Press C to cycle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                Picker("Zoom", selection: Binding(get: { player.videoLayout.zoom }, set: { player.setZoom($0) })) {
                    ForEach(VideoLayout.Zoom.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .accessibilityLabel("Zoom")
                Spacer()
                Button("Reset") { player.resetVideoLayout() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(player.videoLayout.isDefault)
                    .opacity(player.videoLayout.isDefault ? 0.4 : 1)
            }
        }
        .panelGlass(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Crop and aspect ratio")
    }
}
