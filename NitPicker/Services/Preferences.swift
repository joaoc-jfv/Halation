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
        static let forcesCompatibilityEngine = "forceCompatibilityEngine"
        static let autoplaysNextEpisode = "autoplayNextEpisode"
        static let cropsBlackBarsAutomatically = "cropBlackBarsAutomatically"
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

    /// Whether the next episode starts by itself when one ends. On unless the user turns it off.
    var autoplaysNextEpisode: Bool {
        get { defaults.object(forKey: Key.autoplaysNextEpisode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoplaysNextEpisode) }
    }

    /// Whether black bars are cropped off when a file opens. Off unless the user turns it on.
    var cropsBlackBarsAutomatically: Bool {
        get { defaults.bool(forKey: Key.cropsBlackBarsAutomatically) }
        set { defaults.set(newValue, forKey: Key.cropsBlackBarsAutomatically) }
    }

    /// Hidden switch (`defaults write com.joaocadide.nitpicker forceCompatibilityEngine -bool YES`): play every file with libmpv.
    /// For checking that engine on files the others would take, and for anyone who prefers it.
    var forcesCompatibilityEngine: Bool {
        get { defaults.bool(forKey: Key.forcesCompatibilityEngine) }
        set { defaults.set(newValue, forKey: Key.forcesCompatibilityEngine) }
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
