import Foundation

/// User defaults the player remembers between files and launches.
@MainActor
final class Preferences {
    private enum Key {
        static let audioLanguage = "preferredAudioLanguage"
        static let subtitleChoice = "preferredSubtitleChoice"
        static let audioOutputMode = "audioOutputMode"
    }

    private static let offValue = "off"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var audioLanguage: String? {
        get { defaults.string(forKey: Key.audioLanguage) }
        set { defaults.set(newValue, forKey: Key.audioLanguage) }
    }

    var subtitleChoice: TrackSelectionPolicy.SubtitleChoice {
        get {
            switch defaults.string(forKey: Key.subtitleChoice) {
            case nil: .unset
            case Self.offValue?: .off
            case let language?: .language(language)
            }
        }
        set {
            switch newValue {
            case .unset: defaults.removeObject(forKey: Key.subtitleChoice)
            case .off: defaults.set(Self.offValue, forKey: Key.subtitleChoice)
            case .language(let language): defaults.set(language, forKey: Key.subtitleChoice)
            }
        }
    }

    var audioOutputMode: AudioOutputMode {
        get { defaults.string(forKey: Key.audioOutputMode) == "stereo" ? .stereo : .spatial }
        set { defaults.set(newValue == .stereo ? "stereo" : "spatial", forKey: Key.audioOutputMode) }
    }
}
