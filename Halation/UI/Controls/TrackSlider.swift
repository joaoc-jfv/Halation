import SwiftUI

/// Thin slider used for both the scrubber and the volume control: a track, an optional
/// buffered range, and a fill that grows and shows a knob while hovered or dragged.
struct TrackSlider: View {
    /// 0...1
    let value: Double
    /// 0...1
    var buffered: Double?
    /// The value being dragged to, if any. The owner can show it elsewhere (e.g. as a time).
    @Binding var dragValue: Double?
    var label: LocalizedStringKey
    var valueDescription: String
    /// Called on every drag update.
    var onChange: (Double) -> Void = { _ in }
    /// Called with the final value when the drag ends.
    var onCommit: (Double) -> Void = { _ in }
    /// Accessibility increment (+1) or decrement (-1).
    var onAdjust: (Int) -> Void = { _ in }

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || dragValue != nil }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = min(max(dragValue ?? value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                if let buffered {
                    Capsule().fill(.white.opacity(0.3)).frame(width: width * min(max(buffered, 0), 1))
                }
                Capsule().fill(.white).frame(width: width * shown)
            }
            .frame(height: isActive ? 8 : 4)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2, y: 1)
                    .offset(x: width * shown - 7)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(max(drag.location.x / max(width, 1), 0), 1)
                        dragValue = fraction
                        onChange(fraction)
                    }
                    .onEnded { drag in
                        let fraction = min(max(drag.location.x / max(width, 1), 0), 1)
                        dragValue = nil
                        onCommit(fraction)
                    }
            )
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isActive)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(1)
            case .decrement: onAdjust(-1)
            @unknown default: break
            }
        }
    }
}
