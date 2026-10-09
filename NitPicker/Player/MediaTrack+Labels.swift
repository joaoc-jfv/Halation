import Foundation

extension MediaTrack {
    /// Name shown in the panel and in toasts: the track's own title, else its language.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let language, let name = Locale.current.localizedString(forIdentifier: language) { return name }
        return "Track"
    }

    var channelLabel: String? {
        channels.map(AudioFormatDetection.channelLabel)
    }

    /// Second line in the track list, e.g. `E-AC-3 · 5.1`.
    var detail: String? {
        let parts = [codec, channelLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One-line description for toasts, e.g. `English · 5.1 · Spatial`.
    var summary: String {
        ([displayName, channelLabel] + [isSpatial ? "Spatial" : nil]).compactMap { $0 }.joined(separator: " · ")
    }
}
