import AppKit
import SwiftUI

/// Menus carry every shortcut so they are discoverable and accessible (PLAN.md §5.8).
/// Shortcuts for features that land later (chapters, crop, subtitle delay, info panel)
/// are added with those features.
struct AppCommands: Commands {
    let player: PlayerModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { OpenPanel.chooseVideo { player.open($0) } }
                .keyboardShortcut("o")
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
            // Esc itself is handled by the player view (it must also leave full screen).
            Button("Close Panel") { player.closePanel() }
                .disabled(player.activePanel == nil)
        }

        CommandMenu("Playback") {
            Group {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPauseByShortcut() }
                    .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button("Skip Back 5 Seconds") { player.seekByShortcut(seconds: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Skip Forward 5 Seconds") { player.seekByShortcut(seconds: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Skip Back 30 Seconds") { player.seekByShortcut(seconds: -30) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Skip Forward 30 Seconds") { player.seekByShortcut(seconds: 30) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                Divider()
                Button("Previous Frame") { player.stepFrameByShortcut(forward: false) }
                    .keyboardShortcut(",", modifiers: [])
                Button("Next Frame") { player.stepFrameByShortcut(forward: true) }
                    .keyboardShortcut(".", modifiers: [])
                Divider()
                Button("Slower") { player.stepSpeedByShortcut(up: false) }
                    .keyboardShortcut("[", modifiers: [])
                Button("Faster") { player.stepSpeedByShortcut(up: true) }
                    .keyboardShortcut("]", modifiers: [])
                Button("Normal Speed") { player.resetSpeedByShortcut() }
                    .keyboardShortcut("\\", modifiers: [])
            }
            .disabled(!player.hasMedia)
        }

        CommandMenu("Audio") {
            Group {
                Button("Volume Up") { player.adjustVolumeByShortcut(by: 0.05) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("Volume Down") { player.adjustVolumeByShortcut(by: -0.05) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMuteByShortcut() }
                    .keyboardShortcut("m", modifiers: [])
                Divider()
                Button("Next Audio Track") { player.cycleAudioByShortcut() }
                    .keyboardShortcut("a", modifiers: [])
                Menu("Audio Track") {
                    ForEach(player.audioTracks) { track in
                        Toggle(track.summary, isOn: Binding(
                            get: { track == player.selectedAudio },
                            set: { _ in player.selectAudio(track) }
                        ))
                    }
                }
                .disabled(player.audioTracks.isEmpty)
                Picker("Output", selection: Binding(
                    get: { player.audioOutputMode },
                    set: { player.setAudioOutputMode($0) }
                )) {
                    Text("Spatial Audio").tag(AudioOutputMode.spatial)
                    Text("Stereo").tag(AudioOutputMode.stereo)
                }
                .pickerStyle(.inline)
            }
            .disabled(!player.hasMedia)
        }

        CommandMenu("Subtitles") {
            Group {
                Button("Next Subtitle Track") { player.cycleSubtitlesByShortcut() }
                    .keyboardShortcut("s", modifiers: [])
                Menu("Subtitle Track") {
                    Toggle("Off", isOn: Binding(
                        get: { player.displayedSubtitle == nil },
                        set: { _ in player.selectSubtitle(nil) }
                    ))
                    ForEach(player.selectableSubtitleTracks) { track in
                        Toggle(track.displayName, isOn: Binding(
                            get: { track == player.displayedSubtitle },
                            set: { _ in player.selectSubtitle(track) }
                        ))
                    }
                }
            }
            .disabled(!player.hasMedia)
        }
    }
}
