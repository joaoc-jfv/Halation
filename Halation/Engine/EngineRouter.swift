import Foundation

/// Picks the engine for a file (PLAN.md §3.2): AVFoundation for what it opens itself, the remux engine for Matroska
/// and WebM, and libmpv ("compatibility mode") for containers neither can open. A file the first two then turn out
/// not to be able to play (a codec AVPlayer lacks) is handed to libmpv by `PlayerModel`.
enum EngineRouter {
    enum Route: Equatable {
        case avFoundation
        case remux
        case compatibility
    }

    private static let remuxExtensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    private static let nonNativeExtensions: Set<String> = [
        "avi", "wmv", "asf", "flv", "ogv", "ogm", "rm", "rmvb", "divx", "xvid",
    ]

    static func route(forExtension pathExtension: String) -> Route {
        let value = pathExtension.lowercased()
        if remuxExtensions.contains(value) { return .remux }
        return nonNativeExtensions.contains(value) ? .compatibility : .avFoundation
    }

    /// libmpv, for files another engine gave up on.
    @MainActor
    static func compatibilityEngine(for url: URL) throws -> any PlaybackEngine { MPVEngine() }

    @MainActor
    static func engine(for url: URL) throws -> any PlaybackEngine {
        switch route(forExtension: url.pathExtension) {
        case .avFoundation: AVFoundationEngine()
        case .remux: RemuxEngine()
        case .compatibility: MPVEngine()
        }
    }
}
