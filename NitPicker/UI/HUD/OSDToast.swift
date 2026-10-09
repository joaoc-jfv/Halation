import SwiftUI

struct OSDToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = toast.symbol {
                Image(systemName: symbol)
            }
            Text(toast.text).monospacedDigit()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// "Resume from 42:10" with a button, shown when a file with a saved position opens.
struct ResumeOfferView: View {
    @Environment(PlayerModel.self) private var player
    let offer: ResumeOffer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
            Text(offer.label).monospacedDigit()
            Button("Resume") { player.acceptResumeOffer() }
                .buttonStyle(.plain)
                .font(.callout.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.white.opacity(0.25), in: .capsule)
                .accessibilityLabel(offer.label)
            Button { player.dismissResumeOffer() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .capsule)
    }
}
