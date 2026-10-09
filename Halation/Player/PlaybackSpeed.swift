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

    static let range: ClosedRange<Float> = 0.25...4

    /// The fine slider is logarithmic, so the area around 1× has room: 0 is 0.25×, 0.5 is 1×, 1 is 4×.
    static func rate(forSliderPosition position: Double) -> Float {
        let clamped = min(max(position, 0), 1)
        let raw = 0.25 * pow(16.0, clamped)
        return Float((raw * 20).rounded() / 20)  // nearest 0.05
    }

    static func sliderPosition(forRate rate: Float) -> Double {
        let clamped = Double(min(max(rate, range.lowerBound), range.upperBound))
        return log(clamped / 0.25) / log(16.0)
    }
}
