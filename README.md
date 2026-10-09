# Nit Picker

A free macOS video player for people who care about every nit: HDR highlights, Spatial Audio, and a Liquid Glass interface.

Requires macOS 26 or later. [PLAN.md](PLAN.md) holds the architecture, the feature specs and the roadmap.

## Download

**[⬇ Download Nit Picker for Mac (NitPicker.dmg)](https://github.com/joaoc-jfv/NitPicker/releases/latest/download/NitPicker.dmg)** · [all releases](https://github.com/joaoc-jfv/NitPicker/releases)

1. Open `NitPicker.dmg` and drag **Nit Picker** onto **Applications**.
2. The first time, macOS will say it can't check the app for malware, because these early builds are not yet notarized by Apple. To open it anyway: try to open Nit Picker once, then go to **System Settings ▸ Privacy & Security**, scroll to the message about "Nit Picker" and click **Open Anyway**. You only need to do this once per download.
3. Double-click a video, or drop one on the window. MP4, MOV, M4V, MKV and WebM open directly; everything else plays in compatibility mode.

Works on Apple silicon and Intel Macs running macOS 26 or later. Prefer to build it yourself? See [Build](#build).

## What it does today

- **Plays MP4, MOV and M4V** through AVFoundation, so HDR10, HLG and Dolby Vision reach the display as real EDR brightness, with no video composition or Core Image in the way.
- **Spatial Audio**: object-based E-AC-3 tracks are detected and tagged, and the system spatializes multichannel and stereo audio too. A Stereo mode gives a plain downmix.
- **Tracks and subtitles**: pick audio and embedded subtitle tracks, load `movie.srt` / `movie.en.vtt` files next to the video (or add one), and tune their size, background, position and delay.
- **Picture controls**: crop presets that remove letterbox bars, aspect-ratio overrides, fit/fill zoom, and speed from 0.25× to 4×.
- **Episodes**: Next / Previous Video in the folder (⌘] and ⌘[), and an "Up next" card in the last seconds of an episode (`S01E02`-style names) that starts the next one when this ends.
- **Black bars**: Video ▸ Detect Black Bars (⇧C) crops baked-in letterbox or pillarbox bars, found from ten stills; it can run when a file opens (Settings ▸ Playback).
- **Screenshots**: ⌘⇧S saves the frame to Pictures ▸ Nit Picker, as 10-bit HDR HEIC for HDR videos and PNG otherwise.
- **The rest**: chapters, Picture in Picture, resume where you stopped, Open Recent, Now Playing and media keys, scrub thumbnails, an info panel (`I`), and a floating Liquid Glass control bar that fades out while you watch.

MKV and WebM play by remuxing on the fly (HEVC or H.264 video; AAC, AC-3, E-AC-3, ALAC and FLAC audio is copied as it is, and DTS, TrueHD, Opus, MP3 and the like are converted to AAC), with audio switching, text subtitles and scrub previews. Everything else (AVI, WMV, FLV, VP9, MPEG-4, ...) plays in compatibility mode through libmpv, which also draws styled ASS subtitles and adds picture adjustments (brightness, contrast, saturation). Video ▸ Compatibility Engine plays any file that way.

## Keyboard

| Key | Action |
|---|---|
| Space | Play / pause |
| ← / → | Back / forward 5 s (⇧ for 30 s) |
| ⌥← / ⌥→ | Previous / next chapter |
| , / . | Previous / next frame |
| ↑ / ↓ | Volume up / down |
| M | Mute |
| F | Full screen (double-click the video too) |
| [ / ] / \ | Slower / faster / normal speed |
| A / S | Next audio track / next subtitle track (Off included) |
| Z / X | Subtitle delay −0.1 s / +0.1 s |
| C / ⇧C | Next crop preset / detect black bars |
| P | Picture in Picture |
| I | Show / hide the info panel |
| ⌘O | Open |
| ⌘] / ⌘[ | Next / previous video in the folder |
| ⌘⇧S | Save a screenshot |
| Esc | Close a panel, then leave full screen |

Everything above is also in the menu bar. Subtitle appearance, automatic next episode and automatic black-bar cropping are in Settings (⌘,).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme NitPicker -destination 'platform=macOS' build
xcodebuild -scheme NitPicker -destination 'platform=macOS' test
```

To make a disk image (`build/NitPicker-<version>.dmg`), including signing and notarizing with a Developer ID, see the header of [scripts/make-dmg.sh](scripts/make-dmg.sh).

`project.yml` is the source of truth for the project, the Info.plist and the sandbox entitlements; the Xcode project is generated and not committed.

Test media goes in the gitignored `TestMedia/` folder and is never committed.

## License

MIT, see [LICENSE](LICENSE). The app links FFmpeg and libmpv (LGPL) through MPVKit; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
