import Foundation

/// A short on-screen message (volume, speed, seek amount, track changes).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String?
}

extension MediaTrack {
    /// Name shown in toasts and menus. Milestone 1.5 adds codec and channel details.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let language, let name = Locale.current.localizedString(forIdentifier: language) { return name }
        return "Track"
    }
}
