# Halation

Free macOS video player (SwiftUI + Liquid Glass, macOS 26+) with HDR/Dolby Vision and Spatial Audio.

**Read `PLAN.md` first, starting with §0 "Where things stand".** It holds the current state, what to do next, the architecture, feature specs, and the milestone order. Build milestone by milestone, keep the app runnable after each one, and commit once per milestone.

## Rules
- User-facing text says **"Spatial Audio"**, never "Dolby Atmos". In code, call the codec `E-AC-3 JOC`.
- Dependencies: Apple frameworks, plus FFmpeg (LGPL, static) through the local package `Packages/FFmpegKit` for MKV remuxing. Anything else needs a reason recorded in `PLAN.md`.
- No `AVVideoComposition` or Core Image in the normal playback path, because it breaks HDR/DV. Crop by sizing the `AVPlayerLayer` inside a clipping container.
- Swift 6 strict concurrency, `@Observable`, `@MainActor` for UI types, async AVFoundation `load(...)` APIs. Closures that the system calls on its own queue (MediaPlayer, etc.) must be created in `nonisolated` functions.
- The UI talks only to `PlayerModel`. Engine details stay in `Engine/`.
- `project.yml` is the source of truth for the Xcode project, Info.plist and **entitlements** (XcodeGen rewrites the `.entitlements` file). Run `xcodegen generate` after adding or removing files.
- Never commit media files. Test media lives in the gitignored `TestMedia/`; tests generate their own clips (`TestVideo`, `MKVFixture`).
- Every milestone ships with tests, and real-app checks where the behavior can't be unit-tested. Say plainly what was and wasn't verified.
- If reality differs from `PLAN.md`, update the plan in the same commit.

## Commands
```bash
xcodegen generate
xcodebuild -scheme Halation -destination 'platform=macOS' build
xcodebuild -scheme Halation -destination 'platform=macOS' test
```
The MKV spike is a separate package: `cd Spikes/MKVRemux && swift build` (see its README).
