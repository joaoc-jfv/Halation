import CoreGraphics

/// Aspect-ratio override, crop and zoom for the picture (PLAN.md §5.5). All of it is done by sizing
/// and clipping the player layer, never with a video composition, so HDR and Dolby Vision stay intact.
struct VideoLayout: Equatable, Sendable {
    /// Stretches or squeezes the picture to a different display aspect ratio.
    enum Aspect: String, CaseIterable, Sendable {
        case auto, r16x9, r4x3, r239, r200, r185, r1x1

        var ratio: CGFloat? {
            switch self {
            case .auto: nil
            case .r16x9: 16.0 / 9
            case .r4x3: 4.0 / 3
            case .r239: 2.39
            case .r200: 2.0
            case .r185: 1.85
            case .r1x1: 1
            }
        }

        var label: String {
            switch self {
            case .auto: "Auto"
            case .r16x9: "16:9"
            case .r4x3: "4:3"
            case .r239: "2.39:1"
            case .r200: "2.00:1"
            case .r185: "1.85:1"
            case .r1x1: "1:1"
            }
        }
    }

    /// Cuts the picture down to a centered region of this ratio, which removes baked-in letterbox
    /// or pillarbox bars.
    enum Crop: String, CaseIterable, Sendable {
        case none, r239, r200, r185, r16x9, r4x3

        var ratio: CGFloat? {
            switch self {
            case .none: nil
            case .r239: 2.39
            case .r200: 2.0
            case .r185: 1.85
            case .r16x9: 16.0 / 9
            case .r4x3: 4.0 / 3
            }
        }

        var label: String {
            switch self {
            case .none: "None"
            case .r239: "2.39:1"
            case .r200: "2.00:1"
            case .r185: "1.85:1"
            case .r16x9: "16:9"
            case .r4x3: "4:3"
            }
        }

        /// The next preset for the `C` key, wrapping back to None.
        var next: Crop {
            let all = Crop.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    enum Zoom: String, CaseIterable, Sendable {
        /// The whole visible region fits inside the window.
        case fit
        /// The visible region fills the window, cutting off what overflows.
        case fill

        var label: String { self == .fit ? "Fit" : "Fill" }
    }

    var aspect: Aspect = .auto
    var crop: Crop = .none
    var zoom: Zoom = .fit

    var isDefault: Bool { self == VideoLayout() }
}
