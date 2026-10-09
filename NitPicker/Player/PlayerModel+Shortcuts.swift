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

    /// Cycles Off → embedded tracks → sidecar tracks → Off.
    func cycleSubtitlesByShortcut() {
        registerActivity()
        let embedded = selectableSubtitleTracks
        let external = subtitles.tracks
        guard !embedded.isEmpty || !external.isEmpty else {
            showToast("No subtitles", symbol: "captions.bubble")
            return
        }
        // Options in order, with the one showing now (nil = Off).
        let count = embedded.count + external.count
        let current: Int? = subtitles.selected.flatMap { selected in external.firstIndex(of: selected).map { embedded.count + $0 } }
            ?? displayedSubtitle.flatMap { embedded.firstIndex(of: $0) }
        let next = current.map { $0 + 1 } ?? 0

        if next >= count {
            selectSubtitle(nil)
            showToast("Subtitles Off", symbol: "captions.bubble")
        } else if next < embedded.count {
            selectSubtitle(embedded[next])
            showToast("Subtitles: \(embedded[next].displayName)", symbol: "captions.bubble")
        } else {
            let track = external[next - embedded.count]
            selectExternalSubtitle(track)
            showToast("Subtitles: \(track.label)", symbol: "captions.bubble")
        }
    }

    func chapterByShortcut(forward: Bool) {
        registerActivity()
        guard !chapters.isEmpty else {
            showToast("No chapters", symbol: "list.bullet")
            return
        }
        guard let chapter = forward ? nextChapter() : previousChapter() else { return }
        showToast("\(chapter.title)", symbol: "list.bullet")
    }

    func togglePictureInPictureByShortcut() {
        registerActivity()
        guard isPictureInPictureAvailable else {
            showToast("Picture in Picture isn't available", symbol: "pip")
            return
        }
        togglePictureInPicture()
    }

    /// `C`: None → 2.39:1 → 2.00:1 → 1.85:1 → 16:9 → 4:3 → None.
    func cycleCropByShortcut() {
        setCrop(videoLayout.crop.next)
        showToast("Crop: \(videoLayout.crop.label)", symbol: "crop")
        registerActivity()
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
