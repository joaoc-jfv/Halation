import Foundation

/// Finds subtitle files that sit next to a video: `movie.srt`, `movie.en.srt`, `movie.English.forced.vtt`, ...
enum SidecarSubtitles {
    struct Candidate: Equatable, Sendable {
        var url: URL
        var language: String?
        var label: String
    }

    private static let flags: [String: String] = [
        "forced": "Forced", "sdh": "SDH", "cc": "CC", "default": "",
    ]

    /// Formats only an engine that draws subtitles itself can show: styled ASS/SSA, and the image formats.
    static let nativeExtensions: Set<String> = ["ass", "ssa", "sup", "idx"]

    /// Candidates among `directoryContents` for `media`, sorted by label. Pure, so it is easy to test.
    static func candidates(forMedia media: URL, in directoryContents: [URL]) -> [Candidate] {
        candidates(forMedia: media, in: directoryContents, extensions: SubtitleLoader.supportedExtensions)
    }

    /// Like `candidates`, for the formats in `nativeExtensions`.
    static func nativeCandidates(forMedia media: URL, in directoryContents: [URL]) -> [Candidate] {
        candidates(forMedia: media, in: directoryContents, extensions: nativeExtensions)
    }

    private static func candidates(forMedia media: URL, in directoryContents: [URL], extensions: Set<String>) -> [Candidate] {
        let base = media.deletingPathExtension().lastPathComponent.lowercased()
        return directoryContents
            .compactMap { candidate(for: $0, mediaBase: base, extensions: extensions) }
            .sorted { ($0.label, $0.url.lastPathComponent) < ($1.label, $1.url.lastPathComponent) }
    }

    private static func candidate(for url: URL, mediaBase: String, extensions: Set<String>) -> Candidate? {
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.lowercased().hasPrefix(mediaBase) else { return nil }
        let remainder = name.dropFirst(mediaBase.count)
        guard remainder.isEmpty || remainder.hasPrefix(".") else { return nil }

        var language: String?
        var extras: [String] = []
        var unknown: [String] = []
        for token in remainder.split(separator: ".").map(String.init) {
            if let flag = flags[token.lowercased()] {
                if !flag.isEmpty { extras.append(flag) }
            } else if language == nil, let code = languageCode(forToken: token) {
                language = code
            } else {
                unknown.append(token)
            }
        }
        let languageName = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let label = ([languageName ?? unknown.first] + extras).compactMap { $0 }.joined(separator: " · ")
        return Candidate(url: url, language: language, label: label.isEmpty ? "Subtitles" : label)
    }

    /// `en`, `eng` and `English` all give `en`; anything else gives nil.
    static func languageCode(forToken token: String) -> String? {
        let lower = token.lowercased()
        if lower.count == 2 || lower.count == 3, Locale.LanguageCode(lower).isISOLanguage {
            return LanguageMatching.primaryLanguage(lower)
        }
        let namesIn = [Locale(identifier: "en"), Locale.current]
        for code in Locale.LanguageCode.isoLanguageCodes {
            for locale in namesIn where locale.localizedString(forLanguageCode: code.identifier)?.lowercased() == lower {
                return code.identifier
            }
        }
        return nil
    }
}
