import FFmpegKit

/// What FFmpeg build the app is linked against, for the About text and for bug reports.
enum FFmpegInfo {
    static var version: String {
        let value = avformat_version()
        return "libavformat \(value >> 16).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// `LGPL version 3 or later` for the build we ship. A GPL build here would be a licensing problem.
    static var license: String { String(cString: avformat_license()) }
}
