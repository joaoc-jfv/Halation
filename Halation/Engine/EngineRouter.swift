import Foundation

/// Picks the engine for a file. Only AVFoundation exists so far (see PLAN.md §3.2);
/// containers it can't open are rejected with a clear error until phases 2 and 3 land.
enum EngineRouter {
    enum Route: Equatable {
        case avFoundation
        case unsupported
    }

    private static let nonNativeExtensions: Set<String> = [
        "mkv", "mka", "webm", "avi", "wmv", "asf", "flv", "ogv", "ogm", "rm", "rmvb", "divx", "xvid",
    ]

    static func route(forExtension pathExtension: String) -> Route {
        nonNativeExtensions.contains(pathExtension.lowercased()) ? .unsupported : .avFoundation
    }

    @MainActor
    static func engine(for url: URL) throws -> any PlaybackEngine {
        switch route(forExtension: url.pathExtension) {
        case .avFoundation: AVFoundationEngine()
        case .unsupported: throw PlaybackError.unsupportedFormat
        }
    }
}
