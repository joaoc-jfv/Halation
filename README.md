# Halation

A free macOS video player built for HDR highlights, Spatial Audio, and a Liquid Glass interface.

Requires macOS 26 or later. See [PLAN.md](PLAN.md) for the architecture and roadmap.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Halation -destination 'platform=macOS' build
xcodebuild -scheme Halation -destination 'platform=macOS' test
```

Test media goes in the gitignored `TestMedia/` folder and is never committed.
