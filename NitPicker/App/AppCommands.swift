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
            Menu("Open Recent") {
                ForEach(player.recentFiles.entries) { entry in
                    Button(entry.name) {
                        if let url = player.recentFiles.resolve(entry) {
                            player.open(url)
                        } else {
                            player.recentFiles.remove(entry)
                        }
                    }
                }
                Divider()
                Button("Clear Menu") { player.recentFiles.clear() }
                    .disabled(player.recentFiles.entries.isEmpty)
            }
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
            Button(player.showsInfoPanel ? "Hide Info" : "Show Info") { player.toggleInfoPanel() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(!player.hasMedia)
            // Esc itself is handled by the player view (it must also leave full screen).
            Button("Close Panel") { player.dismissTopmostOverlay() }
                .disabled(player.activePanel == nil && !player.showsInfoPanel)
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
                Button("Previous Chapter") { player.chapterByShortcut(forward: false) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Next Chapter") { player.chapterByShortcut(forward: true) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Menu("Chapters") {
                    ForEach(player.chapters) { chapter in
                        Toggle("\(chapter.title)  (\(chapter.start.clockString))", isOn: Binding(
                            get: { chapter == player.currentChapter },
                            set: { _ in player.goToChapter(chapter) }
                        ))
                    }
                }
                .disabled(player.chapters.isEmpty)
                Divider()
                Button("Next Video in Folder") { player.playNextFile() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!player.hasNextFile)
                Button("Previous Video in Folder") { player.playPreviousFile() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!player.hasPreviousFile)
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

        CommandMenu("Video") {
            Group {
                Button("Next Crop Preset") { player.cycleCropByShortcut() }
                    .keyboardShortcut("c", modifiers: [])
                Menu("Crop") {
                    ForEach(VideoLayout.Crop.allCases, id: \.self) { crop in
                        Toggle(crop.label, isOn: Binding(
                            get: { player.videoLayout.crop == crop },
                            set: { _ in player.setCrop(crop) }
                        ))
                    }
                }
                Menu("Aspect Ratio") {
                    ForEach(VideoLayout.Aspect.allCases, id: \.self) { aspect in
                        Toggle(aspect.label, isOn: Binding(
                            get: { player.videoLayout.aspect == aspect },
                            set: { _ in player.setAspect(aspect) }
                        ))
                    }
                }
                Menu("Zoom") {
                    ForEach(VideoLayout.Zoom.allCases, id: \.self) { zoom in
                        Toggle(zoom.label, isOn: Binding(
                            get: { player.videoLayout.zoom == zoom },
                            set: { _ in player.setZoom(zoom) }
                        ))
                    }
                }
                Divider()
                Button(player.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture") {
                    player.togglePictureInPictureByShortcut()
                }
                .keyboardShortcut("p", modifiers: [])
                Divider()
                Toggle("Compatibility Engine", isOn: Binding(
                    get: { player.isCompatibilityEngine },
                    set: { _ in player.toggleCompatibilityEngine() }
                ))
                Divider()
                Button("Reset Video Adjustments") { player.resetVideoLayout() }
                    .disabled(player.videoLayout.isDefault)
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
                Button("Add Subtitle File…") {
                    OpenPanel.chooseSubtitleFile { player.addSubtitleFile($0) }
                }
                Divider()
                Button("Subtitle Delay −0.1 s") { player.adjustSubtitleDelayByShortcut(.milliseconds(-100)) }
                    .keyboardShortcut("z", modifiers: [])
                Button("Subtitle Delay +0.1 s") { player.adjustSubtitleDelayByShortcut(.milliseconds(100)) }
                    .keyboardShortcut("x", modifiers: [])
                Button("Reset Subtitle Delay") { player.resetSubtitleDelay() }
                    .disabled(player.subtitles.delay == .zero)
                Divider()
                Menu("Subtitle Track") {
                    Toggle("Off", isOn: Binding(
                        get: { !player.hasVisibleSubtitle },
                        set: { _ in player.selectSubtitle(nil) }
                    ))
                    ForEach(player.selectableSubtitleTracks) { track in
                        Toggle(track.displayName, isOn: Binding(
                            get: { track == player.displayedSubtitle },
                            set: { _ in player.selectSubtitle(track) }
                        ))
                    }
                    ForEach(player.subtitles.tracks) { track in
                        Toggle(track.label, isOn: Binding(
                            get: { track == player.subtitles.selected },
                            set: { _ in player.selectExternalSubtitle(track) }
                        ))
                    }
                }
            }
            .disabled(!player.hasMedia)
        }
    }
}
