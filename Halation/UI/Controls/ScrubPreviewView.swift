import SwiftUI

/// The thumbnail and time floating above the scrubber, following the pointer.
struct ScrubPreviewView: View {
    let preview: ScrubPreview
    var chapter: String?

    private let width: CGFloat = 176
    private var height: CGFloat { width * 9 / 16 }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(.black.opacity(0.5))
                    if let image = preview.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: 10))
                VStack(spacing: 0) {
                    Text(preview.time.clockString).font(.callout.monospacedDigit().weight(.semibold))
                    if let chapter {
                        Text(chapter).font(.caption2).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            }
            .frame(width: width)
            .padding(6)
            .glassEffect(.regular.tint(.black.opacity(0.35)), in: .rect(cornerRadius: 16))
            .offset(
                x: min(max(geometry.size.width * preview.fraction - width / 2, -80), geometry.size.width - width + 80),
                y: -(height + 62)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
