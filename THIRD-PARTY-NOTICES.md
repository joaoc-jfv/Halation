# Third-party software

Halation's own code is MIT-licensed (see `LICENSE`). The app links these libraries, which keep their own licenses:

- **FFmpeg** (libavformat, libavcodec, libavutil, libavfilter, libswscale and others), **libmpv**, **libass**, **libplacebo** and related libraries, from the [MPVKit](https://github.com/mpvkit/MPVKit) project, release `1.1.0-n9.0.2`, the **LGPL** variant. They are linked statically.
  - FFmpeg: https://ffmpeg.org (LGPL v2.1 or later in this build). mpv: https://mpv.io.
  - Relinking: the LGPL lets you replace these libraries. The build uses `Packages/FFmpegKit`, which pins MPVKit by version; point it at your own build of the libraries and rebuild the app.
  - Halation does not use MPVKit's GPL variant.
