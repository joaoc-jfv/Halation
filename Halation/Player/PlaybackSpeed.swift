import Foundation

enum PlaybackSpeed {
    /// The ladder `[` and `]` walk along.
    static let steps: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]
    /// Presets shown in the control bar's speed menu.
    static let presets: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func stepped(from rate: Float, up: Bool) -> Float {
        let epsilon: Float = 0.001
        if up { return steps.first { $0 > rate + epsilon } ?? steps[steps.count - 1] }
        return steps.last { $0 < rate - epsilon } ?? steps[0]
    }

    /// `1×`, `1.25×`, `0.5×`
    static func label(for rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
