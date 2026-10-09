import Foundation

extension HDRFormat {
    /// The short HDR name in the badge. Written once here: "Dolby Vision" is the descriptive name of the
    /// format; swap the string if a neutral label is wanted instead (PLAN.md §9, open question 5).
    var badge: String? {
        switch self {
        case .sdr: nil
        case .hdr10: "HDR10"
        case .hdr10Plus: "HDR10+"
        case .hlg: "HLG"
        case .dolbyVision: "Dolby Vision"
        }
    }

    /// The name with its profile, for the info panel: `Dolby Vision 8.1`, `HDR10`, `SDR`.
    var detailName: String {
        guard case .dolbyVision(let profile, let compatibility) = self else { return badge ?? "SDR" }
        switch (profile, compatibility) {
        case (let profile?, let compatibility?) where profile == 8 && compatibility > 0: return "Dolby Vision 8.\(compatibility)"
        case (let profile?, _): return "Dolby Vision \(profile)"
        default: return "Dolby Vision"
        }
    }
}

extension MediaInfo {
    /// `4K`, `1080p`, ... from the longer side, so cropped widescreen (3840×1600) still reads as 4K.
    var resolutionBadge: String? {
        guard let size = resolution ?? displaySize, size.width > 0, size.height > 0 else { return nil }
        let long = max(size.width, size.height), short = min(size.width, size.height)
        switch long {
        case 7680...: return "8K"
        case 3840...: return "4K"
        case 2560...: return "1440p"
        case 1920...: return "1080p"
        case 1280...: return "720p"
        default: return "\(Int(short))p"
        }
    }

    /// The pieces of the HUD pill: `["4K", "HDR10", "Spatial Audio"]`.
    func formatBadges(spatialAudio: Bool) -> [String] {
        [resolutionBadge, hdr.badge, spatialAudio ? "Spatial Audio" : nil].compactMap { $0 }
    }
}

enum InfoFormatting {
    /// `24 fps`, `23.976 fps`, `29.97 fps`
    static func frameRate(_ fps: Double) -> String {
        let text = String(format: "%.3f", fps).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(text) fps"
    }

    /// `12.5 Mb/s`, `640 kb/s`
    static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kb/s", bitsPerSecond / 1000)
    }

    static func size(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}
