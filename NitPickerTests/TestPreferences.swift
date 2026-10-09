import Foundation
@testable import NitPicker

/// Preferences backed by a throwaway defaults suite, so tests never touch the real app's settings.
@MainActor
enum TestPreferences {
    static func make() -> Preferences {
        let name = "nitpicker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Preferences(defaults: defaults)
    }
}
