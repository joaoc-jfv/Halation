import Foundation

/// User defaults the player remembers between files and launches.
@MainActor
final class Preferences {
    private enum Key {
        static let audioLanguage = "preferredAudioLanguage"
        static let subtitleChoice = "preferredSubtitleChoice"
        static let audioOutputMode = "audioOutputMode"
        static let subtitleSize = "subtitleSize"
        static let subtitleBackground = "subtitleBackground"
        static let subtitleOffset = "subtitleOffset"
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

    var subtitleStyle: SubtitleStyle {
        get {
            var style = SubtitleStyle()
            style.size = defaults.string(forKey: Key.subtitleSize).flatMap(SubtitleStyle.Size.init) ?? style.size
            style.background = defaults.string(forKey: Key.subtitleBackground).flatMap(SubtitleStyle.Background.init) ?? style.background
            if defaults.object(forKey: Key.subtitleOffset) != nil {
                let offset = defaults.double(forKey: Key.subtitleOffset)
                style.verticalOffset = min(max(offset, SubtitleStyle.offsetRange.lowerBound), SubtitleStyle.offsetRange.upperBound)
            }
            return style
        }
        set {
            defaults.set(newValue.size.rawValue, forKey: Key.subtitleSize)
            defaults.set(newValue.background.rawValue, forKey: Key.subtitleBackground)
            defaults.set(newValue.verticalOffset, forKey: Key.subtitleOffset)
        }
    }
}
