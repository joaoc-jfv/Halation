import AVFoundation

enum AVTrackMapping {
    /// Maps a media selection group to `MediaTrack`s, in option order.
    /// Codec, channel count and the spatial flag are filled in by milestone 1.5.
    static func tracks(in group: AVMediaSelectionGroup?, kind: MediaTrack.Kind) -> [MediaTrack] {
        guard let group else { return [] }
        return group.options.enumerated().map { index, option in
            MediaTrack(
                id: "\(kind.rawValue)-\(index)",
                kind: kind,
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                title: option.displayName,
                codec: nil,
                channels: nil,
                isDefault: option == group.defaultOption,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isSpatial: false
            )
        }
    }
}

extension Duration {
    init?(_ time: CMTime) {
        guard time.isNumeric else { return nil }
        self = .seconds(time.seconds)
    }

    var cmTime: CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
