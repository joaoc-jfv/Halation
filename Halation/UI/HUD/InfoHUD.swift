import SwiftUI

/// The top-right pill (`4K · HDR10 · Spatial Audio`) and, when expanded with `I`, the detailed panel.
struct InfoHUD: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !player.formatBadges.isEmpty {
                Button { player.toggleInfoPanel() } label: {
                    Text(player.formatBadges.joined(separator: " · "))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .capsule)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Format: \(player.formatBadges.joined(separator: ", "))")
                .accessibilityHint("Shows or hides detailed information")
            }
            if player.showsInfoPanel {
                InfoPanel()
                    .transition(.opacity)
            }
        }
    }
}

private struct InfoPanel: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(player.infoSections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.label).foregroundStyle(.white.opacity(0.7))
                            Spacer(minLength: 16)
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 330)
        .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media information")
    }
}
