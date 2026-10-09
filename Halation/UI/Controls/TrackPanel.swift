import SwiftUI

/// Audio & Subtitles panel: two columns like the Apple TV app, plus the output mode.
struct TrackPanel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            audioColumn
            subtitleColumn
        }
        .padding(22)
        .frame(width: 560)
        .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio and Subtitles")
    }

    private var audioColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Audio")
            if player.audioTracks.isEmpty {
                emptyNote("No audio tracks")
            }
            ForEach(player.audioTracks) { track in
                TrackRow(track: track, isSelected: track == player.selectedAudio) {
                    player.selectAudio(track)
                }
            }
            Divider().padding(.vertical, 6)
            Picker("Audio output", selection: Binding(
                get: { player.audioOutputMode },
                set: { player.setAudioOutputMode($0) }
            )) {
                Text("Spatial Audio").tag(AudioOutputMode.spatial)
                Text("Stereo").tag(AudioOutputMode.stereo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Audio output")
            Text("Head tracking is set in Control Center.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Subtitles")
            TrackRow(title: "Off", isSelected: !player.hasVisibleSubtitle) {
                player.selectSubtitle(nil)
            }
            ForEach(player.selectableSubtitleTracks) { track in
                TrackRow(track: track, isSelected: track == player.displayedSubtitle) {
                    player.selectSubtitle(track)
                }
            }
            ForEach(player.subtitles.tracks) { track in
                TrackRow(title: track.label, detail: "Subtitle file", isSelected: track == player.subtitles.selected) {
                    player.selectExternalSubtitle(track)
                }
            }
            if player.selectableSubtitleTracks.isEmpty && player.subtitles.tracks.isEmpty {
                emptyNote("No subtitles found")
            }
            Divider().padding(.vertical, 6)
            panelButton("Add Subtitle File…", symbol: "plus") {
                OpenPanel.chooseSubtitleFile { player.addSubtitleFile($0) }
            }
            if player.subtitles.sidecarAccess == .needsFolderAccess {
                panelButton("Find Subtitles in This Folder…", symbol: "folder") {
                    player.requestSidecarFolderAccess()
                }
            }
            if player.subtitles.selected != nil {
                Text("Delay \(player.subtitles.delayLabel) · Z / X to adjust")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func panelButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.white)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}

private struct TrackRow: View {
    let title: String
    var detail: String?
    var isSpatial = false
    let isSelected: Bool
    let action: () -> Void

    init(title: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.action = action
    }

    init(track: MediaTrack, isSelected: Bool, action: @escaping () -> Void) {
        title = track.displayName
        detail = track.detail
        isSpatial = track.isSpatial
        self.isSelected = isSelected
        self.action = action
    }

    init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.white)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if isSpatial { SpatialAudioBadge() }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([title, detail, isSpatial ? "Spatial Audio" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
