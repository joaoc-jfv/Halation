import CoreGraphics
import Foundation

/// How sidecar subtitles are drawn (PLAN.md §5.3).
struct SubtitleStyle: Equatable, Sendable {
    enum Size: String, CaseIterable, Sendable {
        case small, medium, large, extraLarge

        /// Font size as a fraction of the video's height, so text scales with the window.
        var heightFraction: CGFloat {
            switch self {
            case .small: 0.034
            case .medium: 0.045
            case .large: 0.057
            case .extraLarge: 0.072
            }
        }

        var label: String {
            switch self {
            case .small: "S"
            case .medium: "M"
            case .large: "L"
            case .extraLarge: "XL"
            }
        }
    }

    enum Background: String, CaseIterable, Sendable {
        case none, shadow, box
    }

    var size: Size = .medium
    var background: Background = .shadow
    /// Extra lift above the default position, as a fraction of the video height (-0.05 ... 0.25).
    var verticalOffset: Double = 0

    static let offsetRange: ClosedRange<Double> = -0.05...0.25

    func fontSize(forVideoHeight height: CGFloat) -> CGFloat {
        max(12, (height * size.heightFraction).rounded())
    }
}
