import Foundation

/// Actions behind the keyboard shortcuts and menu items (PLAN.md §5.8). They do what the
/// control bar does, and also show a toast and wake the controls.
extension PlayerModel {
    func seekByShortcut(seconds: Double) {
        skip(by: .seconds(seconds))
        let amount = Int(abs(seconds).rounded())
        showToast(seconds < 0 ? "−\(amount) s" : "+\(amount) s", symbol: seconds < 0 ? "gobackward" : "goforward")
        registerActivity()
    }

    func togglePlayPauseByShortcut() {
        togglePlayPause()
        registerActivity()
    }

    func stepFrameByShortcut(forward: Bool) {
        pause()
        stepFrame(forward: forward)
        registerActivity()
    }

    func adjustVolumeByShortcut(by delta: Float) {
        if isMuted, delta > 0 { toggleMute() }
        setVolume(Float(((volume + delta) * 100).rounded()) / 100)
        showVolumeToast()
        registerActivity()
    }

    func toggleMuteByShortcut() {
        toggleMute()
        showVolumeToast()
        registerActivity()
    }

    func stepSpeedByShortcut(up: Bool) {
        setRate(PlaybackSpeed.stepped(from: rate, up: up))
        showSpeedToast()
        registerActivity()
    }

    func resetSpeedByShortcut() {
        setRate(1)
        showSpeedToast()
        registerActivity()
    }

    func cycleAudioByShortcut() {
        registerActivity()
        guard audioTracks.count > 1 else {
            showToast("No other audio tracks", symbol: "speaker.wave.2")
            return
        }
        let index = selectedAudio.flatMap { audioTracks.firstIndex(of: $0) } ?? -1
        let next = audioTracks[(index + 1) % audioTracks.count]
        selectAudio(next)
        showToast("Audio: \(next.summary)", symbol: "speaker.wave.2")
    }

    /// Cycles Off → first track → … → last track → Off.
    func cycleSubtitlesByShortcut() {
        registerActivity()
        let tracks = selectableSubtitleTracks
        guard !tracks.isEmpty else {
            showToast("No subtitles", symbol: "captions.bubble")
            return
        }
        let next: MediaTrack? = switch displayedSubtitle.flatMap({ tracks.firstIndex(of: $0) }) {
        case nil: tracks[0]
        case let index? where index + 1 < tracks.count: tracks[index + 1]
        default: nil
        }
        selectSubtitle(next)
        showToast(next.map { "Subtitles: \($0.displayName)" } ?? "Subtitles Off", symbol: "captions.bubble")
    }

    private func showVolumeToast() {
        if isMuted {
            showToast("Muted", symbol: "speaker.slash.fill")
        } else {
            let symbol = volume == 0 ? "speaker.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
            showToast("Volume \(Int((volume * 100).rounded()))%", symbol: symbol)
        }
    }

    private func showSpeedToast() {
        showToast("Speed \(PlaybackSpeed.label(for: rate))", symbol: "speedometer")
    }
}
