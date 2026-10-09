# Halation — Project Plan

> **Halation** (n.): the soft glow that forms around bright highlights on film.
> A free macOS video player built for HDR highlights, spatial audio, and a Liquid Glass interface.

This document is the full build plan. It is written so that an engineer (or another model) can implement it phase by phase without needing the conversation that produced it. **Status:** milestones 1.1 (project skeleton), 1.2 (engine core), 1.3 (video surface and window), 1.4 (Liquid Glass controls), 1.5 (tracks), 1.6 (sidecar subtitles), 1.7 (crop, aspect, speed), 1.8 (system integration) and 1.9 (info HUD, welcome, scrub thumbnails) are done; see §7 for the order of the rest.

---

## 1. Goals and non-goals

### Goals
- **Free** native Mac video player that looks at home on macOS 26+ (Liquid Glass).
- **HDR done right**: HDR10, HLG, and Dolby Vision (profiles 5 / 8.1 / 8.4) shown with real extended brightness (EDR) on capable displays, never washed out.
- **Spatial Audio**: object-based E-AC-3 (E-AC-3 JOC) tracks rendered as spatial audio on AirPods and Mac speakers, plus spatialized multichannel/stereo when the user wants it.
- **Broad format support**: MP4/MOV first, then MKV through remuxing, then everything else through a fallback engine.
- **All the basics**: subtitles, audio track switching, audio output mode, crop/aspect, playback speed, Picture in Picture, media keys, resume, keyboard control.

### Non-goals (for now)
- Streaming services, DRM, network shares/library servers (could come much later).
- Video editing or transcoding/export.
- iOS/iPadOS/visionOS versions (keep the engine layer platform-neutral where it costs nothing, but don't design for them yet).
- Object-based decoding of TrueHD or DTS:X height channels. No free decoder exists; those play as plain multichannel.

### Terminology rule
Use **"Spatial Audio"** everywhere user-facing: UI, menus, badges, README, App Store text, marketing. Never write "Dolby Atmos" in user-facing strings, because the name needs a Dolby license. In code and comments, use the technical name `E-AC-3 JOC` (or `eac3JOC`) for the codec.

---

## 2. The key constraint (why the architecture is hybrid)

| | AVFoundation (`AVPlayer`) | libmpv / FFmpeg |
|---|---|---|
| Containers | MP4, MOV, M4V, HLS. **No MKV** | Everything |
| Video codecs | H.264, HEVC, ProRes, AV1 (hardware on M3+) | Everything |
| HDR10 / HLG | Native EDR | Good (tone-mapped/EDR, more work) |
| Dolby Vision | Real DV (5, 8.1, 8.4) | Tone-mapped only |
| Spatial Audio (E-AC-3 JOC) | **Yes**, spatialized by the system | **No**, only passthrough to a receiver |
| TrueHD / DTS | No | Decoded to multichannel PCM |
| Subtitles | Embedded text tracks only | All, including ASS styling and PGS images |

**Conclusion:** AVFoundation is the only path to real Dolby Vision and Spatial Audio on macOS, so it is the main engine. MKV files are **remuxed on the fly** (no re-encoding) into something AVPlayer can play. Anything still unsupported falls back to **libmpv**, with a visible "Compatibility mode" note.

---

## 3. Architecture

```
┌──────────────────────────── SwiftUI + Liquid Glass UI ────────────────────────────┐
│  PlayerWindow · VideoSurface · ControlBar · Track/Speed/Crop panels · InfoHUD     │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                        │ observes
                              ┌─────────▼─────────┐
                              │   PlayerModel     │  @Observable, @MainActor
                              │ (UI-facing state) │  owns the active engine
                              └─────────┬─────────┘
                                        │ PlaybackEngine protocol
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
   AVFoundationEngine          RemuxEngine (phase 2)        MPVEngine (phase 3)
   MP4/MOV/M4V/HLS             MKV → fMP4/HLS → AVPlayer    libmpv fallback
             ▲                          ▲                          ▲
             └──────────── EngineRouter (uses MediaProbe) ─────────┘

   Shared services: MediaProbe · SubtitleRenderer (SRT/VTT, later ASS) ·
   NowPlayingService · ResumeStore · RecentFiles · Preferences
```

### 3.1 `PlaybackEngine` protocol (sketch)

Every engine conforms to one protocol, so the UI never knows which engine is active.

```swift
@MainActor
protocol PlaybackEngine: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }   // state, time, tracks, errors
    var videoView: NSView { get }                    // view hosting the video layer

    func load(_ url: URL, startAt: Duration?) async throws
    func play()
    func pause()
    func seek(to: Duration, precise: Bool) async
    func step(frames: Int)                           // ±1 frame while paused

    var rate: Float { get set }                      // 0.25 ... 4.0
    var volume: Float { get set }                    // 0 ... 1
    var isMuted: Bool { get set }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }         // embedded tracks only
    var selectedAudioTrack: MediaTrack? { get }
    var selectedSubtitleTrack: MediaTrack? { get }
    func selectAudio(_ track: MediaTrack?)
    func selectSubtitle(_ track: MediaTrack?)        // nil = off

    var audioOutputMode: AudioOutputMode { get set } // .spatial, .stereo
    var capabilities: EngineCapabilities { get }     // e.g. supportsPiP, supportsDolbyVision
    func close()
}
```

Supporting types: `PlaybackState` (idle/loading/ready/playing/paused/ended/failed), `PlaybackError`, `PlaybackEvent` (state, time, duration, buffering, buffered range, media info, tracks changed), `MediaTrack` (id, kind, language, title, codec, channels, isDefault, isForced, `isSpatial`), `MediaInfo` (container, engine name, HDR format, codecs, coded `resolution`, `displaySize` with pixel aspect ratio applied, frame rate, bitrate; audio layout and chapters join it in 1.5 and 1.8), `AudioOutputMode`, `EngineCapabilities`. `HDRFormat` (.sdr/.hdr10/.hdr10Plus/.hlg/.dolbyVision(profile, compatibilityID)) lives in `PlaybackTypes.swift`, and `CropMode` with the crop panel (1.7). An engine instance serves one file; `PlayerModel` creates a new one for each open and applies its stored rate, volume, mute and output mode.

`PlayerModel` translates engine events into simple observable properties (`isPlaying`, `currentTime`, `duration`, `buffered`, `mediaInfo`, track lists, selected tracks) and holds UI-only state (controls visible, active panel, crop mode, external subtitle track).

### 3.2 Engine routing

`EngineRouter.engine(for: url)`:
1. `MediaProbe` inspects the file. For AV-native containers use `AVURLAsset` + `load(.isPlayable)`. For others, sniff the container: magic bytes, then libavformat in phase 2+.
2. If it's an AV-native container and all chosen tracks are playable → **AVFoundationEngine**.
3. If it's MKV/WebM and the video codec is H.264/HEVC/AV1 and the audio is AAC/AC-3/E-AC-3/ALAC/FLAC/Opus → **RemuxEngine**.
4. Otherwise → **MPVEngine**.
5. Until phase 3 exists, unsupported files show a clear error ("This format isn't supported yet") instead of failing silently.

---

## 4. Tech stack and project setup

- **Language/UI:** Swift 6 (strict concurrency on), SwiftUI app lifecycle, AppKit bridging where needed (`NSViewRepresentable` for the video surface, `NSWindow` tweaks).
- **Deployment target:** macOS 26.0 (Liquid Glass APIs). Dev machine runs macOS 27 / Xcode 27.
- **Bundle ID:** `com.joaocadide.halation` (adjust if needed).
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Commit `project.yml`; gitignore the generated `Halation.xcodeproj`. This keeps the project file reviewable and lets a model regenerate it without using the Xcode GUI.
- **Targets:** `Halation` (app), `HalationTests` (unit tests, Swift Testing), and later `HalationUITests` if needed.
- **Dependencies:**
  - Phase 1: none (Apple frameworks only: AVFoundation, AVKit, CoreMedia, MediaPlayer, SwiftUI, AppKit).
  - Phase 2+: FFmpeg libraries (libavformat/libavcodec/libavutil) and later libmpv + libass. Preferred source: **MPVKit** (Swift package shipping libmpv, FFmpeg, and libass as xcframeworks). Pick its **LGPL** variant unless we decide to open-source under GPL. *Verify the current package name, maintenance status, and license variants before adding it.*
- **Entitlements:** defined under `entitlements.properties` in `project.yml` (XcodeGen rewrites the `.entitlements` file from them, so editing the file by hand is lost; until 1.6 it had been regenerated empty and the app ran unsandboxed). App Sandbox; `com.apple.security.files.user-selected.read-only`; `com.apple.security.files.bookmarks.app-scope` (resume and recents across launches via security-scoped bookmarks). Hardened Runtime is enabled in build settings, but Xcode turns it off while signing ad hoc (`CODE_SIGN_IDENTITY: "-"`, used so the project builds without a team). Set a real signing identity for release builds. If phase 2 uses a localhost HTTP server, add `com.apple.security.network.server`. The plan prefers `AVAssetResourceLoader`, which avoids that.
- **Distribution (later):** Developer ID + notarization, Sparkle for updates, GitHub Releases. App Store optional; the sandbox setup above keeps that open.

### Folder layout

```
Halation/
├── PLAN.md
├── CLAUDE.md
├── README.md
├── project.yml
├── .gitignore
├── Halation/
│   ├── App/            HalationApp.swift, AppDelegate.swift, AppCommands.swift
│   ├── Engine/
│   │   ├── PlaybackEngine.swift, PlaybackTypes.swift, EngineRouter.swift
│   │   ├── AVFoundation/   AVFoundationEngine.swift, AVTrackMapping.swift, PlayerLayerView.swift, PiPController.swift
│   │   ├── Remux/          (phase 2)
│   │   └── MPV/            (phase 3)
│   ├── Media/          CodecNames.swift, ColorDescription.swift, MediaBadges.swift, InfoSections.swift, LanguageMatching.swift, MediaProbe.swift, HDRDetection.swift, AudioFormatDetection.swift
│   ├── Player/         PlayerModel.swift, PlayerModel+Shortcuts.swift, ChapterNavigation.swift, VideoLayout.swift, VideoGeometry.swift, TrackSelectionPolicy.swift, MediaTrack+Labels.swift, PlaybackSpeed.swift, Toast.swift, TimeFormatting.swift
│   ├── Subtitles/      SubtitleCue.swift, SubtitleDecoding.swift, SRTParser.swift, WebVTTParser.swift, SubtitleMarkup.swift, SubtitleLoader.swift, SidecarSubtitles.swift, SubtitleStyle.swift, SubtitleTrackStore.swift
│   ├── UI/
│   │   ├── Player/     PlayerWindowView.swift, VideoSurfaceView.swift, WindowController.swift, WindowSizing.swift, OpenPanel.swift, SubtitleOverlay.swift, SubtitleLayout.swift
│   │   ├── Settings/   SubtitleSettingsView.swift (⌘, window)
│   │   ├── Controls/   ControlBar.swift, TrackSlider.swift (scrubber and volume), ScrubPreviewView.swift, PanelRow.swift, TrackPanel.swift, CropPanel.swift, SpeedPanel.swift, TrackPanel.swift, SpeedPanel.swift, CropPanel.swift, VolumeControl.swift
│   │   ├── HUD/        InfoHUD.swift, FormatBadges.swift (the Spatial Audio tag), OSDToast.swift
│   │   └── Welcome/    WelcomeView.swift (drop zone + recents)
│   ├── Services/       NowPlayingService.swift, ResumeStore.swift, RecentFiles.swift, ThumbnailCache.swift, SleepPrevention.swift, PlayerServices.swift, Preferences.swift, FolderAccess.swift
│   └── Resources/      Assets.xcassets, Info.plist, Halation.entitlements
└── HalationTests/
```

---

## 5. Feature specs

### 5.1 HDR and Dolby Vision
- Render with `AVPlayerLayer` hosted in a layer-backed `NSView`. On Apple Silicon with an EDR-capable display, AVFoundation outputs HDR as EDR automatically. **Do not** put an `AVVideoComposition` or Core Image filter in the path for normal playback, because that can strip HDR/DV metadata and costs performance.
- Detection (`HDRDetection`): use `AVAssetTrack` media characteristics (`.containsHDRVideo`), the format description's transfer function (`kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` → HDR10, `_ITU_R_2100_HLG` → HLG), and the Dolby Vision codec types (`dvh1`/`dvhe`, or HEVC with a `dvcC`/`dvvC` extension) → DV profile.
- Implementation notes (1.3): `AVPlayerLayer` switches to EDR by itself when HDR plays, so the layer needs no `wantsExtendedDynamicRangeContent` flag. `HDRDetection` works from the track's format description. Dolby Vision profile and compatibility ID come from the `dvcC`/`dvvC` record, so 8.1 reads as profile 8, ID 1 and 8.4 as profile 8, ID 4. HDR10+ can't be told apart from HDR10 there (its metadata is in the bitstream), so `.hdr10Plus` is never produced yet.
- Implementation notes (1.9): the top-right pill is built from the resolution (by the longer side, so 3840×1600 is still 4K), the HDR badge, and "Spatial Audio" when the selected track is spatial and the output mode is Spatial. Clicking it, or `I`, expands the info panel; `Esc` closes an open bar panel first, then the info panel, then leaves full screen. The welcome screen's posters are small JPEGs in the caches folder, written when a file opens (the same frame as the Now Playing artwork). Scrub thumbnails come from nearby keyframes on a grid of about 1% of the duration, cached per file.
- Show `AVPlayer.eligibleForHDRPlayback` in the info panel so users know if their display or setup can show HDR.
- Keep `AVPlayerItem.appliesPerFrameHDRDisplayMetadata = true` (the default) for DV and HDR10+.
- Badge in the HUD: `HDR10`, `HDR10+`, `HLG`, `Dolby Vision` (see open question about DV naming), or nothing for SDR.

### 5.2 Spatial Audio
- Set `AVPlayerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel` when the output mode is **Spatial** (the default).
- **Stereo** mode sets it to `[]` (no spatialization) for people who want a plain downmix.
- Detect E-AC-3 JOC tracks: codec `ec-3`, plus the JOC flag in the `dec3` box extension. The SDK has no media characteristic for it. `AudioFormatDetection` reads `flag_ec3_extension_type_a` and a non-zero `complexity_index_type_a` after the substreams (ETSI TS 102 366 Annex F.6), from the sample description atoms and, failing that, the magic cookie. It is tested against records built from the spec but **not yet against a real JOC file**, and which of the two sources CoreMedia fills is unconfirmed. Mark those tracks `isSpatial = true` and show a **Spatial Audio** badge.
- - AVFoundation has no public link from a selection option to its audio track, so `AVTrackMapping.pair` matches them: by position when the counts and codecs agree, else by language and codec. Forced-only subtitle tracks are kept in the model (for the "Off" rule in §5.3) but hidden from the list and from `S`.
- Remembered choices (`Preferences`): last audio language, subtitle choice (unset / off / language) and output mode. They are applied when a file opens (`TrackSelectionPolicy`), and changed only by the user's own picks.
- The audio track list labels each track with its language, title, codec, and channels, plus "Spatial" where it applies (for example "English · 5.1 · Spatial").
- Head tracking is controlled by the system (Control Center), not the app. Don't build a toggle for it.

### 5.3 Subtitles
- **Embedded:** from `AVMediaSelectionGroup` for `.legible`. Selecting one uses `AVPlayerItem.select(_:in:)`. "Off" means `nil`. Respect forced subtitles: when "Off", still show forced tracks that match the audio language.
- **External (sidecar):** auto-load `movie.srt`, `movie.en.srt`, `movie.vtt`, and so on from the same folder. The sandbox needs the user to grant folder access the first time, or use "Add Subtitle File…" in the panel. Parse SRT and WebVTT into `[SubtitleCue]` and render with our own `SubtitleOverlay` (SwiftUI text above the video, synced to the current time with a binary search over cues).
- **Styling (preferences):** font size (S/M/L/XL, as a fraction of the video height), background (none / shadow / box), position offset, set in the Settings window (⌘,) with a live preview. The delay is ±0.1 s per step (`Z`/`X`, also in the Subtitles menu), applies only to sidecar tracks, and resets for each file.
- Implementation notes (1.6): files are decoded as UTF-8 (BOM-aware, UTF-16 too), falling back to Windows-1252. Inline `<i>`, `<b>`, `<u>` are kept and every other tag or ASS override is dropped. Overlapping cues all show. The overlay reads the engine's live playhead about 30 times a second (the 4 Hz `currentTime` would be visibly late), sits in the video's own rectangle rather than the window's, and lifts clear of the control bar while it shows. Sidecars load after playback starts. With no embedded subtitles and no remembered choice, the first sidecar is selected. A remembered language picks the matching sidecar, and Off keeps them listed but hidden.
- Folder access: listing the video's folder can fail in the sandbox. The panel then offers "Find Subtitles in This Folder…", which asks for the folder and remembers it with an app-scoped security bookmark (`FolderAccess`). "Add Subtitle File…" always works. **Not yet checked in a strictly enforced sandbox:** on the dev Mac, a sandboxed build could still list ~/Documents, so only the failure path (a missing folder) is tested.
- **ASS/SSA and PGS:** phase 3 via libass and libmpv.

### 5.4 Audio tracks and channels
- Audio tracks come from `AVMediaSelectionGroup` for `.audible`.
- Output mode: **Spatial** / **Stereo** (5.2).
- Volume 0–100% with a slider in the control bar, plus mute. An optional "boost" above 100% is out of scope for phase 1.
- Remember the preferred audio and subtitle language in Preferences and apply it automatically when a file opens.

### 5.5 Crop, aspect ratio, and zoom
- Implement by **sizing and positioning the `AVPlayerLayer` inside a clipping container** (`masksToBounds = true`), not with a video composition. This keeps HDR and DV intact and costs nothing.
- Modes:
  - Aspect override: Auto, 16:9, 4:3, 2.39:1, 2.00:1, 1.85:1, 1:1.
  - Crop presets: None, 2.39:1, 2.00:1, 1.85:1, 16:9, 4:3. These remove letterbox bars by scaling the layer so the chosen region fills the view.
  - Zoom: fit (default), fill, and step zoom with pan (later).
- `C` cycles through crop presets, with an on-screen toast showing the current mode.
- Implementation notes (1.7): `VideoGeometry.placement` is a pure function from container size, display size and `VideoLayout` to a clip rect and a video rect. `VideoSurfaceView` puts the player view inside a masked clip view and sets the two frames, animated unless Reduce Motion is on. An aspect override stretches the picture (`videoGravity = .resize`) before any crop is taken from it. A crop takes a centered region of the chosen ratio (wider than the picture trims top and bottom, narrower trims the sides). **Fit** shows that whole region inside the window and **Fill** covers the window with it. Subtitles are placed in the clip rect. Layout is per file and resets when another file opens. Zoom steps and pan are still to do. The display size comes from the track's format description (pixel aspect ratio and clean aperture), because `naturalSize` already has the PAR in it.
- Phase 4: automatic black-bar detection by sampling a few frames with `AVPlayerItemVideoOutput` at load time.

### 5.6 Playback speed
- Presets 0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×, and a fine slider 0.25×–4×.
- Use `AVPlayerItem.audioTimePitchAlgorithm = .timeDomain` (or `.spectral`; test both for voice quality) so pitch stays natural.
- `[` / `]` step speed down/up, `\` resets to 1×. Show a toast on change.
- Use `AVPlayer.defaultRate` (macOS 13+) so pressing play resumes at the chosen speed.
- The speed panel has the presets and a logarithmic fine slider (0.25× at the left, 1× in the middle, 4× at the right, in 0.05 steps).

### 5.7 Other basics (phase 1)
- **Open:** drag and drop onto the window or Dock icon, File ▸ Open (⌘O), Open Recent, "Open With" from Finder. Declare document types in Info.plist: `public.movie`, `public.mpeg-4`, `com.apple.quicktime-movie`, `public.avi`, plus imported UTIs for `org.matroska.mkv` and `org.webmproject.webm`.
- Implementation notes (1.8): `PlayerModel` takes a `PlayerServices` bundle (preferences, folder access, Now Playing, resume, recents, sleep) and an engine factory, so tests run it with fakes and a scripted `FakeEngine`. Resume records are keyed by path, with a fallback to the same name and size for moved files. Opening is by security-scoped bookmark in Open Recent. Now Playing publishes on state, duration, seek and rate changes only (the system extrapolates the elapsed time), and the artwork is a keyframe from about 10% in. Remote command handlers hop to the main actor. Closing the window quits the app (`AppDelegate`), and quitting saves the position. Chapter navigation: `⌥→` goes to the next chapter and `⌥←` restarts the current chapter, or goes back one when it is within 3 s of its start.
- **Resume:** save the position every ~5 s and on close, using security-scoped bookmarks. When reopening, offer "Resume from 42:10" as a glass toast with a button, auto-dismissed after ~6 s. Don't save if under 30 s in or within the last 3% of the file.
- **Picture in Picture:** `AVPictureInPictureController(playerLayer:)`. Button in the control bar.
- **Now Playing and media keys:** `MPNowPlayingInfoCenter` (title, duration, elapsed, rate, artwork from a frame) and `MPRemoteCommandCenter` (play, pause, toggle, skip ±10 s, change position).
- **Chapters:** read `AVAsset` chapter metadata groups. Show tick marks on the scrubber and a chapter list in a menu. `⌥←`/`⌥→` jump between chapters.
- **Frame stepping:** `,` and `.` while paused (`AVPlayerItem.step(byCount:)`).
- **Full screen:** native full screen (`F` or ⌃⌘F), double-click on the video toggles it.
- **Sleep:** keep the display awake while playing (`IOPMAssertion` or `ProcessInfo.beginActivity`).
- **Scrub preview thumbnails:** `AVAssetImageGenerator` with a small cache, shown above the scrubber on hover. It's fine to land this at the end of phase 1.

### 5.8 Keyboard shortcuts (default)

| Key | Action |
|---|---|
| Space | Play/Pause |
| ← / → | Seek −5 s / +5 s |
| ⇧← / ⇧→ | Seek −30 s / +30 s |
| ⌥← / ⌥→ | Previous / next chapter |
| , / . | Frame step back / forward (paused) |
| ↑ / ↓ | Volume ±5% |
| M | Mute |
| F | Full screen |
| [ / ] / \ | Speed down / up / reset |
| S | Cycle subtitles (including Off) |
| A | Cycle audio tracks |
| C | Cycle crop presets |
| Z / X | Subtitle delay −/+ 0.1 s |
| I | Toggle info panel |
| ⌘O | Open |
| Esc | Exit full screen / close panel |

Landing order: everything except the rows below shipped in 1.4. Audio and subtitle cycling (A/S) work on the engine's embedded tracks now and get their panel and preferences in 1.5. Subtitle delay (Z/X) comes with 1.6, crop (C) with 1.7, chapters (⌥←/⌥→) with 1.8, and the info panel (I) with 1.9. Esc leaving full screen is AppKit's own behavior.

All shortcuts also appear in the menu bar (Playback, Audio, Subtitles, Video menus) so they're discoverable and accessible.

---

## 6. Liquid Glass UI design

**Principle:** the video is the content and glass is the chrome. Controls float over the video and disappear when not needed.

- **Window:** `.windowStyle(.hiddenTitleBar)`, full-size content view, the video fills the window edge to edge. Traffic lights float over the video and fade with the controls. The window resizes to the video's aspect ratio when a file opens: native size, at least 640 pt wide, capped to 80% of the screen (`WindowSizing`). It is not aspect-locked afterwards. Black window background.
- **Control bar:** a floating capsule, bottom-center, inset 20 pt from the bottom, max width ~720 pt. Uses `.glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .capsule)` (the dark tint keeps white controls readable over bright video; the track panel uses a 0.4 tint) inside a `GlassEffectContainer` so panels can **morph out of the bar** (shortcuts are menu key equivalents with no modifier, so they win over a focused slider; auto-hide runs in `PlayerModel`, which restarts nothing on mouse movement and just moves a last-activity timestamp) (with `glassEffectID` and a `@Namespace`).
  - Left: play/pause, −10 s, +10 s.
  - Center: elapsed time · scrubber (buffered range, chapter ticks, hover thumbnail) · remaining time (click to toggle total).
  - Right: volume, **Audio & Subtitles** (one button, one panel with two columns like the Apple TV app), speed, crop/aspect, PiP, full screen.
- **Panels:** glass popovers that grow out of the control bar. Track rows show language, details, a checkmark, and a "Spatial" tag where it applies.
- **Info HUD (top-right glass pill):** format badges such as `4K · HDR10 · Spatial Audio`, shown with the controls. `I` expands it into a detailed panel: codecs, bitrate, frame rate, color primaries and transfer, HDR eligibility, audio layout, and the active engine (with "Compatibility mode" when it's mpv).
- **Toasts (OSD):** small glass capsules near the top-center for volume, speed, crop mode, subtitle delay, and seek amount. They fade after ~1.2 s.
- **Auto-hide:** while playing, hide the controls, traffic lights, and cursor after 2.5 s without mouse movement. Show them again on mouse move or any key. Keep them visible while paused or while a panel is open or the pointer is over the controls.
- **Empty state (WelcomeView):** a centered glass drop zone, "Drop a video to play", an Open… button, and a grid of recent files with thumbnails and progress bars below it.
- **Legibility:** put a soft black gradient behind the bottom ~120 pt **only while the controls are visible**, so glass stays readable over very bright HDR highlights. Test on bright snow/sky HDR scenes.
- **Accessibility:** respect Reduce Transparency and Reduce Motion (glass falls back automatically; also disable morph animations), VoiceOver labels on every control, full keyboard navigation, and Dynamic Type–style sizing for subtitles.

---

## 7. Phased roadmap

Each milestone ends with a working, runnable app. Commit at the end of each milestone.

### Phase 1 — Native player (AVFoundation only)

| # | Milestone | Done when |
|---|---|---|
| 1.1 | **Project skeleton**: `project.yml`, app target, test target, entitlements, Info.plist document types, `.gitignore`, README | `xcodegen && xcodebuild` builds an empty window app |
| 1.2 | **Engine core**: `PlaybackEngine`, types, `AVFoundationEngine` (load/play/pause/seek/rate/volume), `PlayerModel` | An MP4 plays with temporary basic buttons |
| 1.3 | **Video surface + window**: `VideoSurfaceView` hosting `AVPlayerLayer`, hidden title bar, aspect-fit window sizing, full screen | HDR10 and DV test files look visibly HDR on an XDR/EDR display |
| 1.4 | **Liquid Glass controls**: control bar, scrubber, auto-hide, toasts, keyboard shortcuts, menus | All controls and shortcuts from §5.8 work |
| 1.5 | **Tracks**: audio and embedded subtitle selection, Spatial/Stereo output mode, Spatial detection and badge, language preferences | Switching tracks works mid-playback; an E-AC-3 JOC file shows the badge and sounds spatial on AirPods |
| 1.6 | **Sidecar subtitles**: SRT/VTT parsers (unit tested), overlay renderer, styling, delay | An external SRT shows correctly timed and styled |
| 1.7 | **Crop/aspect/speed panels** | Every preset in §5.5 and §5.6 works and HDR stays intact while cropped |
| 1.8 | **System integration**: Now Playing, media keys, PiP, resume, recents, sleep prevention, chapters, frame step | Media keys work, resume prompt appears, PiP works |
| 1.9 | **Info HUD + welcome screen + scrub thumbnails** | Full UI from §6 is in place |
| 1.10 | **Polish pass**: accessibility, Reduce Transparency, error states, app icon | Ready for daily use with MP4/MOV |

### Phase 2 — MKV via remuxing
- Add FFmpeg libraries (via MPVKit or a dedicated FFmpeg xcframework).
- `MKVProbe`: read tracks, codecs, cues (keyframe index), chapters, and attachments with libavformat.
- `RemuxEngine`: present the MKV to AVPlayer as an HLS VOD stream with fMP4 segments, served through `AVAssetResourceLoader` with a custom URL scheme (`halation-remux://`):
  - Build the master and media playlists up front from the cues (segments of roughly 4–6 s, aligned to keyframes).
  - Generate the init segment and each media segment on demand: seek the demuxer, copy packets (no re-encode) into fragmented MP4 with the right sample entries (`hvc1` for HEVC, `dvh1` plus `dvcC`/`dvvC` for Dolby Vision, `av01`, `ec-3` with `dec3` keeping the JOC info for spatial audio).
  - Audio AVPlayer can't play in HLS (TrueHD, DTS, maybe FLAC/Opus; *verify which*) is decoded with libavcodec and re-encoded. AAC 5.1 or E-AC-3 are the candidates; pick whichever keeps the channel count and works in fMP4 HLS. If none works well, route the file to MPVEngine instead.
  - MKV text subtitles (SRT/ASS) are extracted to our own overlay. ASS shows as plain text until phase 3.
- **Fallback:** if building the playlist fails or there's no usable cue index, hand the file to MPVEngine (phase 3) or show a clear error.
- **Done when:** a typical HEVC + E-AC-3 JOC + SRT MKV plays with HDR/DV, Spatial Audio, subtitles, instant seeking, and track switching, using under ~10% CPU on Apple Silicon.

*Risk note:* this is the hardest part of the project. Prototype it as a standalone spike first: one MKV, one segment, played in AVPlayer. Confirm the approach before building it out.

### Phase 3 — mpv fallback engine
- `MPVEngine` using libmpv's render API, drawing into an EDR-enabled layer (`wantsExtendedDynamicRangeContent`). IINA's open-source code is a useful reference for the render loop, EDR, and event handling. IINA is GPLv3, so read it for ideas, don't copy code unless we go GPL.
- Map mpv properties to the protocol: `pause`, `time-pos`, `duration`, `speed`, `volume`, `aid`, `sid`, `track-list`, `video-crop`/`video-aspect-override`, `sub-delay`.
- ASS/SSA styled subtitles and PGS image subtitles through libass/mpv. Optionally reuse libass for remuxed MKVs too.
- "Compatibility mode" label in the info HUD; DV shows as "HDR (tone-mapped)".
- **Done when:** AVI/Xvid, VP9 WebM, DTS MKV, and ASS-styled anime files all play with working controls.

### Phase 4 — Nice to have
- Folder playlists and next/previous episode detection (`S01E02` patterns), with "Up next" at the end of an episode.
- Auto black-bar crop detection.
- Video adjustments (brightness, contrast, saturation) on the mpv engine only. Keep the AVFoundation path pure for HDR.
- Subtitle downloads (OpenSubtitles API). Needs an API key and consent screens.
- Screenshots (⌘⇧S) through `AVPlayerItemVideoOutput`, saved as HDR HEIC when the source is HDR.
- Sparkle updates, notarized DMG, website.

---

## 8. Testing strategy

- **Unit tests (Swift Testing):** SRT/VTT parsers (malformed input, overlapping cues, BOMs, CRLF), cue lookup at time T, `EngineRouter` decisions from mocked probe results, HDR/audio-format classification from synthetic format descriptions, crop/aspect geometry math, resume rules, time formatting.
- **Manual test matrix** (keep a `TestMedia/` folder, gitignored, with a `TestMedia/README.md` listing where each file came from):

| File | Checks |
|---|---|
| HEVC HDR10 MP4 | EDR brightness, badge, crop keeps HDR |
| HLG MOV (iPhone recording) | HLG badge, correct look |
| Dolby Vision profile 8.1 MP4 (iPhone recording) | DV badge, no green/purple tint |
| Dolby Vision profile 5 MP4 | Correct colors (P5 is easy to get wrong) |
| E-AC-3 JOC MP4 | Spatial badge, spatial on AirPods, Stereo mode works |
| AAC 5.1 MP4 | Spatialized multichannel |
| SDR H.264 with chapters and 2 audio tracks + 2 subtitle tracks | Track switching, chapters |
| Sidecar SRT/VTT (UTF-8, Latin-1, with BOM) | Encoding detection, timing |
| Phase 2: HEVC+E-AC-3 JOC MKV, HEVC DV P8 MKV, H.264+DTS MKV | Remux path and audio fallback |
| Phase 3: AVI/Xvid, VP9 WebM, ASS anime MKV, PGS subtitles | mpv path |

  Good sources: recordings from your own iPhone (HDR/HLG/DV), Apple's HLS example streams, and the Kodi sample files wiki. *Check the licenses before committing any of these. Never commit media to git.*
- **Performance:** check CPU/GPU use and energy in Activity Monitor for 4K HDR playback. The phase 1 target is close to QuickTime Player.

---

## 9. Risks and open questions

1. **MKV → HLS remuxing (phase 2)** is complex. Spike it early, and consider pulling a minimal spike forward right after milestone 1.3.
2. **E-AC-3 JOC detection API:** no media characteristic exists, so the `dec3` parser (milestone 1.5) is the approach. Confirm it against a real JOC file and see which of the sample description atom or the magic cookie CoreMedia fills.
3. **Audio fallback codec inside fMP4 HLS** for TrueHD/DTS: test which multichannel formats AVPlayer accepts.
4. **MPVKit** packaging and licensing: confirm it's maintained and that an LGPL build is available.
5. **"Dolby Vision" naming in the UI:** same trademark concern as Atmos. **Decided in 1.9: keep "Dolby Vision"**, as a descriptive name of the format (the info panel adds the profile, e.g. "Dolby Vision 8.1"). It is written once, in `HDRFormat.badge`, so switching to a neutral label such as "DV" is a one-line change. "Dolby Atmos" stays out of all user-facing text (a test checks the badges and info panel).
6. **Name check:** "Halation" may be used by other apps (for example photo filter apps). Search the App Store and trademarks before publishing anything public.
7. **License for Halation itself:** MIT (with LGPL dependencies) vs GPLv3 (would allow borrowing from IINA/mpv GPL code). **Decision needed** before phase 3.

---

## 10. Implementation notes for whoever writes the code

- Work milestone by milestone (§7) and keep the app building and runnable after each one. Commit at each milestone boundary.
- Phase 1 must not depend on any third-party code.
- Keep all AVFoundation specifics inside `Engine/AVFoundation/` and `Media/`. The UI talks only to `PlayerModel`.
- Use `@Observable` (not `ObservableObject`), `async`/`await` with AVFoundation's async `load(...)` APIs, and `@MainActor` for UI-touching types.
- When an API in this plan is marked *verify*, check the current Apple docs or headers before relying on it. If reality differs from this plan, update this file in the same commit.
- **Callbacks the system runs on its own queue** (MediaPlayer artwork and remote-command handlers, and the like) must be built in a `nonisolated` function. A closure written inside a `@MainActor` method is main-actor-isolated, and Swift 6 traps with a dispatch assertion when the system calls it from another queue. Tests that use fake services can't catch this, so check such paths by launching the real app. (`SystemNowPlaying.makeArtwork` and `.handler` follow this rule, and a test calls the artwork handler off the main thread.)
- Build and test from the command line:
  ```bash
  xcodegen generate
  xcodebuild -scheme Halation -destination 'platform=macOS' build
  xcodebuild -scheme Halation -destination 'platform=macOS' test
  ```
