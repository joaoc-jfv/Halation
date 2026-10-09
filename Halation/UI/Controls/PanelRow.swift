import SwiftUI

/// A checkable row in a glass panel.
struct PanelRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 14)
                Text(title).foregroundStyle(.white)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// The look shared by the control bar's panels: dark-tinted glass.
    func panelGlass(width: CGFloat) -> some View {
        padding(22)
            .frame(width: width)
            .glassEffect(.regular.tint(.black.opacity(0.4)), in: .rect(cornerRadius: 28))
    }
}

func panelHeading(_ title: LocalizedStringKey) -> some View {
    Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
}
