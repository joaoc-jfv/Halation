import SwiftUI

/// What shows when nothing is playing: a drop zone and the recent files (PLAN.md §6).
struct WelcomeView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isDropTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            dropZone
            if !player.recentFiles.entries.isEmpty {
                RecentGrid()
            }
        }
        .padding(32)
        .frame(maxWidth: 760)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: player.errorMessage == nil ? "play.rectangle" : "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
            Text(player.errorMessage ?? "Drop a video to play")
                .font(.title3)
                .multilineTextAlignment(.center)
            Button("Open…") {
                OpenPanel.chooseVideo { player.open($0) }
            }
            .keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white.opacity(isDropTargeted ? 1 : 0.85))
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .glassEffect(.regular.tint(isDropTargeted ? .white.opacity(0.3) : .black.opacity(0.35)), in: .rect(cornerRadius: 28))
        .scaleEffect(isDropTargeted && !reduceMotion ? 1.03 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isDropTargeted)
        .accessibilityElement(children: .contain)
    }
}

private struct RecentGrid: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 14)], spacing: 14) {
                    ForEach(player.recentFiles.entries.prefix(12)) { entry in
                        RecentCard(entry: entry)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 280)
        }
    }
}

private struct RecentCard: View {
    @Environment(PlayerModel.self) private var player
    let entry: RecentEntry
    @State private var poster: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button { player.openRecent(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.08))
                    if let poster {
                        Image(nsImage: poster).resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.35))
                    }
                    if let progress = player.recentProgress(for: entry) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle().fill(.white).frame(width: geometry.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(isHovering ? 0.6 : 0.15), lineWidth: 1) }
                Text(entry.name)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task(id: entry.id) { poster = player.recentPoster(for: entry) }
        .contextMenu {
            Button("Remove from Recents") { player.removeRecent(entry) }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let progress = player.recentProgress(for: entry) {
            return "\(entry.name), \(Int((progress * 100).rounded())) percent watched"
        }
        return entry.name
    }
}
