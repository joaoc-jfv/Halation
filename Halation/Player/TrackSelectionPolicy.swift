import Foundation

/// Picks tracks when a file opens, from the remembered language preferences (PLAN.md §5.3, §5.4).
enum TrackSelectionPolicy {
    enum SubtitleChoice: Equatable, Sendable {
        /// Nothing chosen yet: keep what the file and system would pick.
        case unset
        case off
        case language(String)
    }

    enum Decision: Equatable {
        case keepDefault
        case select(MediaTrack?)
    }

    static func audio(from tracks: [MediaTrack], preferredLanguage: String?) -> MediaTrack? {
        guard let preferredLanguage else { return nil }
        return tracks.first { LanguageMatching.matches($0.language, preferredLanguage) }
    }

    /// Off still shows a forced track that matches the audio language (foreign-dialogue subtitles).
    static func subtitle(from tracks: [MediaTrack], choice: SubtitleChoice, audioLanguage: String?) -> Decision {
        let forced = tracks.first { $0.isForced && LanguageMatching.matches($0.language, audioLanguage) }
        switch choice {
        case .unset:
            return .keepDefault
        case .off:
            return .select(forced)
        case .language(let language):
            let match = tracks.first { !$0.isForced && LanguageMatching.matches($0.language, language) }
            return .select(match ?? forced)
        }
    }
}
