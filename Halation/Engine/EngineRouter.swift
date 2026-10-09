import Foundation

/// Picks the engine for a file (PLAN.md §3.2): AVFoundation for what it opens itself, the remux engine for Matroska
/// and WebM, and a clear error for containers that need the phase 3 engine.
enum EngineRouter {
    enum Route: Equatable {
        case avFoundation
        case remux
        case unsupported
    }

    private static let remuxExtensions: Set<String> = ["mkv", "mka", "mk3d", "webm"]

    private static let nonNativeExtensions: Set<String> = [
        "avi", "wmv", "asf", "flv", "ogv", "ogm", "rm", "rmvb", "divx", "xvid",
    ]

    static func route(forExtension pathExtension: String) -> Route {
        let value = pathExtension.lowercased()
        if remuxExtensions.contains(value) { return .remux }
        return nonNativeExtensions.contains(value) ? .unsupported : .avFoundation
    }

    @MainActor
    static func engine(for url: URL) throws -> any PlaybackEngine {
        switch route(forExtension: url.pathExtension) {
        case .avFoundation: AVFoundationEngine()
        case .remux: RemuxEngine()
        case .unsupported: throw PlaybackError.unsupportedFormat
        }
    }
}
