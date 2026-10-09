# MKV remux spike (phase 2)

Throwaway experiments that answer PLAN.md §9 risk 1: *can an MKV be presented to AVPlayer as HLS, by copying packets
(no re-encode), with HDR / Dolby Vision and Spatial Audio intact?* Not part of the app target and not built by
`xcodegen`. Run it by hand with a test file in `../../TestMedia/` (never committed).

FFmpeg comes from [MPVKit](https://github.com/mpvkit/MPVKit) `1.1.0-n9.0.2` (FFmpeg n9, **LGPL** build, static).

| Tool | What it does |
|---|---|
| `mkvremux <mkv> <dir> [--start S] [--duration S] [--audio LANG] [--keep-timestamps]` | One muxer for a stretch of the file. Writes `init.mp4`, `seg_NNN.m4s`, `combined.mp4` (playable as a file) and `segments.txt`. |
| `mkvsegments <mkv> <dir> [--audio LANG] [--seg-target S] [--limit S] [--index-only]` | The on-demand design: the init comes from the first segment, then **each segment is cut by seeking and using a fresh muxer**, with `tfdt` rewritten to the true timeline. `--index-only` prints what the Matroska Cues provide. |
| `hlsprobe <dir> <http\|loader> [--master] [--seek S] [--until S] [--redirect-file\|--redirect-all]` | Plays `<dir>` as VOD HLS in a headless AVPlayer, pulling decoded frames through `AVPlayerItemVideoOutput`, and reports frame timeline, stalls and dropped frames. |

```bash
cd Spikes/MKVRemux && swift build
.build/debug/mkvsegments ../../TestMedia/<file>.mkv /tmp/seg --audio eng --seg-target 6 --limit 30
.build/debug/hlsprobe /tmp/seg http --master --until 22
```

## What it found

Test file: 2160p-class HEVC 3840×1920 Dolby Vision profile 8.1 + two E-AC-3 5.1 JOC tracks + 46 text subtitle tracks,
3281 s, 10.6 GB.

**Works**
- Copying HEVC + E-AC-3 into fragmented MP4 needs no re-encode. The muxer writes `hvc1` + `hvcC` + `colr` (BT.2020/PQ)
  + **`dvvC`** (profile 8, level 6, compatibility ID 1) and `ec-3` + **`dec3` with the JOC flag and complexity index 16**.
  The phase 1 app's own detection reads both from the remuxed file (Dolby Vision 8.1, Spatial Audio track).
- AVPlayer plays it as HLS over a loopback HTTP server, with or without a master playlist: first 4K frame in
  ~0.35 s, tagged ITU_R_2020 / SMPTE_ST_2084_PQ, 10-bit 4:2:0.
- **Independently muxed segments with one shared init play seamlessly**: 648 frames from 0.000 to 26.985 s across three
  segment boundaries, constant 42 ms spacing, 0 out of order, 0 stalls, 0 dropped frames. Seeks (also across a
  boundary) show their first frame 77–91 ms later.
- The whole file's keyframe index is available almost for free: after open + first seek, libavformat exposes the Matroska
  Cues, **996 keyframes across 3279 s** (spacing 0.33–3.96 s, median 3.46 s). Open + probe + index takes ~0.26 s.
- Cutting a 7 s stretch of 4K at a 30-minute offset (cold seek, 28 MB of video) takes ~16 ms of copying.

**Does not work**
- **`AVAssetResourceLoader` with a custom scheme cannot feed HLS media.** The delegate is asked for the playlist, init
  and segments and can answer with data, but AVPlayer then fails with `CoreMediaErrorDomain -12881 "custom url not
  redirect"`, also when redirecting to `file://` URLs. Only a redirect to a real http(s) URL would be accepted, so
  a loopback server is needed. This is also how AetherEngine does it.

**Needed to make FFmpeg's mp4 muxer do it** (all in `mkvsegments/main.swift`)
- `strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL`, or the muxer refuses to write the `dvcC`/`dvvC` box.
- `movflags = frag_keyframe+delay_moov+default_base_moof`: with `empty_moov` the muxer can't write `dec3` because it
  derives it from the first E-AC-3 packets (that parse is also what finds the JOC extension, which MKV can't declare).
- `codecpar.frame_size = 1536` for E-AC-3 (Matroska doesn't carry it) and `codec_tag = hvc1` for HEVC.
- **Rewrite `tfdt` after muxing.** Every muxer run rebases to zero, so a segment's `tfdt` must be set to
  `(pts - origin) * timescale + edit-list media_time - first composition offset` per track, and every later fragment in
  the same segment shifted by the same amount (forgetting that made AVPlayer drop the second GOP of a segment).
- Copy stream metadata (language, title) so the audio tracks keep their languages.

**Still open** (not covered by the spike)
- Whether the loopback listener and AVPlayer's connection to it work in the **sandbox** with `network.server` +
  `network.client` (this Mac's sandbox didn't restrict file reads, so a test here wouldn't prove it).
- Dolby Vision actually engaging on a DV-capable display, and how the Atmos/JOC audio sounds on AirPods.
- Subtitles (46 SRT tracks here), audio tracks that AVPlayer can't play (DTS, TrueHD), AV1/VP9, files without Cues.
- Matroska timestamps have 1 ms resolution, so video sample durations jitter 41–42 ms; fine, but worth regularising.
