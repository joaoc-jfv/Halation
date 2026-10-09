# Halation

Free macOS video player (SwiftUI + Liquid Glass, macOS 26+) with HDR/Dolby Vision and Spatial Audio.

**Read `PLAN.md` first.** It holds the architecture, feature specs, and the milestone order. Build milestone by milestone and keep the app runnable after each one.

## Rules
- User-facing text says **"Spatial Audio"**, never "Dolby Atmos". In code, call the codec `E-AC-3 JOC`.
- Phase 1 uses Apple frameworks only, with no third-party dependencies.
- No `AVVideoComposition` or Core Image in the normal playback path, because it breaks HDR/DV. Crop by sizing the `AVPlayerLayer` inside a clipping container.
- Swift 6 strict concurrency, `@Observable`, `@MainActor` for UI types, async AVFoundation `load(...)` APIs.
- The UI talks only to `PlayerModel`. Engine details stay in `Engine/`.
- Never commit media files. Test media lives in the gitignored `TestMedia/`.
- If reality differs from `PLAN.md`, update the plan in the same commit.

## Commands
```bash
xcodegen generate
xcodebuild -scheme Halation -destination 'platform=macOS' build
xcodebuild -scheme Halation -destination 'platform=macOS' test
```
