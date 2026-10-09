# Halation

A free macOS video player built for HDR highlights, Spatial Audio, and a Liquid Glass interface.

Requires macOS 26 or later. [PLAN.md](PLAN.md) holds the architecture, the feature specs and the roadmap.

## What it does today

- **Plays MP4, MOV and M4V** through AVFoundation, so HDR10, HLG and Dolby Vision reach the display as real EDR brightness, with no video composition or Core Image in the way.
- **Spatial Audio**: object-based E-AC-3 tracks are detected and tagged, and the system spatializes multichannel and stereo audio too. A Stereo mode gives a plain downmix.
- **Tracks and subtitles**: pick audio and embedded subtitle tracks, load `movie.srt` / `movie.en.vtt` files next to the video (or add one), and tune their size, background, position and delay.
- **Picture controls**: crop presets that remove letterbox bars, aspect-ratio overrides, fit/fill zoom, and speed from 0.25× to 4×.
- **The rest**: chapters, Picture in Picture, resume where you stopped, Open Recent, Now Playing and media keys, scrub thumbnails, an info panel (`I`), and a floating Liquid Glass control bar that fades out while you watch.

MKV and WebM play by remuxing on the fly (HEVC or H.264 video; AAC, AC-3, E-AC-3, ALAC and FLAC audio is copied as it is, and DTS, TrueHD, Opus, MP3 and the like are converted to AAC), with audio switching, text subtitles and scrub previews. Everything else (AVI, WMV, FLV, VP9, MPEG-4, ...) plays in compatibility mode through libmpv.

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
| C | Next crop preset |
| P | Picture in Picture |
| I | Show / hide the info panel |
| ⌘O | Open |
| Esc | Close a panel, then leave full screen |

Everything above is also in the menu bar. Subtitle appearance is in Settings (⌘,).

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Halation -destination 'platform=macOS' build
xcodebuild -scheme Halation -destination 'platform=macOS' test
```

`project.yml` is the source of truth for the project, the Info.plist and the sandbox entitlements; the Xcode project is generated and not committed.

Test media goes in the gitignored `TestMedia/` folder and is never committed.
