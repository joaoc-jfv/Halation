import Foundation

/// A short on-screen message (volume, speed, seek amount, track changes).
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String?
}
