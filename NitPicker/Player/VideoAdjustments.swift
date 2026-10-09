import Foundation

/// Brightness, contrast and saturation for the compatibility engine (PLAN.md, phase 4). Only libmpv can apply them: doing it on
/// the AVFoundation path would need a video composition or Core Image, which breaks HDR and Dolby Vision (CLAUDE.md).
struct VideoAdjustments: Equatable, Sendable {
    /// mpv's own scale: -100 ... 100, where 0 leaves the picture as it is.
    static let range: ClosedRange<Int> = -100...100

    var brightness = 0
    var contrast = 0
    var saturation = 0

    var isDefault: Bool { self == VideoAdjustments() }

    /// mpv's property names and the values to give them.
    var mpvProperties: [(name: String, value: Double)] {
        [("brightness", Double(brightness)), ("contrast", Double(contrast)), ("saturation", Double(saturation))]
    }

    func clamped() -> VideoAdjustments {
        func limit(_ value: Int) -> Int { min(max(value, Self.range.lowerBound), Self.range.upperBound) }
        return VideoAdjustments(brightness: limit(brightness), contrast: limit(contrast), saturation: limit(saturation))
    }
}
