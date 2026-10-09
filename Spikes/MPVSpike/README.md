# libmpv spike (phase 3)

Throwaway experiment that answers: *can libmpv (MPVKit's LGPL build) play into an AppKit window on macOS 26, with
hardware decoding and HDR, and is it light enough to be Halation's fallback engine?* Not part of the app target and not
built by `xcodegen`. First `swift build` downloads about 1.9 GB of MPVKit binaries (every platform slice; the app only
links the macOS one).

```bash
cd Spikes/MPVSpike && swift build
.build/debug/mpvspike <file> [--hdr] [--seconds N] [--vo gpu-next|gpu] [--sid N] [--aid N]
```

It opens a window with a `CAMetalLayer`, hands the layer to mpv as `wid`, plays the file and prints what mpv reports
every 2 s (hardware decoder, codec, fps, dropped frames, colour parameters, the display's EDR headroom).

## What it found (MPVKit 1.1.0-n9.0.2, mpv 0.41, FFmpeg n9, on an Apple M4 / macOS 26)

Test file: the 3840×1920 HEVC Dolby Vision 8.1 + E-AC-3 JOC MKV with 46 subtitle tracks.

**Works**
- `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk` (Vulkan on Metal), `hwdec=videotoolbox`: plays the file, hardware
  decoded, 23.976 fps, 0–2 dropped frames in 12–22 s. mpv reports the 6-channel E-AC-3 audio and all 48 tracks.
- **HDR passthrough**: with `target-colorspace-hint=yes` the display goes into HDR mode (EDR headroom 1.2 → ~15), BT.2020/PQ,
  0 dropped frames. Without it mpv tone-maps to SDR (headroom stays 1.2). The option has to be set before `mpv_initialize`.
- CPU about 10–13% of one core in the *debug* spike build while playing 4K Dolby Vision (the AVFoundation path measured 15–20%
  for the same file in a Release app, so the two are comparable).
- Size: the *release* spike executable is 36 MB (31 MB stripped) with FFmpeg, mpv, libass, libplacebo and MoltenVK's
  Vulkan layer all in it. Linking FFmpeg only once, the app should stay well under 100 MB.

**Gotchas**
- The `CAMetalLayer` needs the two workarounds from MPVKit's demo (`MetalLayer`): ignore a `drawableSize` of 1×1 (MoltenVK sets it
  to complete a presentation, which flickers) and set `wantsExtendedDynamicRangeContent` from the main thread. MPVKit's demo also
  warns that Metal API validation must be off when playing HDR under Xcode (MoltenVK issue 2226).
- `screenshot-to-file` fails: MPVKit's LGPL FFmpeg has no PNG/JPEG encoder. `screenshot-raw` (a raw frame in memory) is the way.
- MPVKit's README says it is lightly maintained and Metal support is an unofficial patch; expect rough edges.
- MPVKit ships its own FFmpeg (the same n9.0.2 LGPL binaries `Packages/FFmpegKit` uses, plus avfilter, swscale and more), so the
  app must link only one set.
