import AVFoundation

enum AVTrackMapping {
    /// Subtitle (or any non-audio) options, in option order. Codec details only exist for audio.
    static func tracks(in group: AVMediaSelectionGroup?, kind: MediaTrack.Kind) -> [MediaTrack] {
        guard let group else { return [] }
        return group.options.enumerated().map { index, option in
            track(for: option, at: index, in: group, kind: kind, format: nil)
        }
    }

    /// Audio options, in option order, with codec, channel count and the spatial flag taken from
    /// the audio track behind each option. AVFoundation has no public option-to-track link, so
    /// the two are paired with `pair(options:tracks:)`.
    static func audioTracks(in group: AVMediaSelectionGroup?, asset: AVAsset) async throws -> [MediaTrack] {
        guard let group else { return [] }
        var candidates: [TrackCandidate] = []
        var formats: [AudioFormatInfo] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let (descriptions, tag, code) = try await track.load(.formatDescriptions, .extendedLanguageTag, .languageCode)
            guard let description = descriptions.first else { continue }
            candidates.append(TrackCandidate(language: tag ?? code, subtype: description.mediaSubType.rawValue))
            formats.append(AudioFormatDetection.info(for: description))
        }
        let optionKeys = group.options.map {
            OptionKey(
                language: $0.extendedLanguageTag ?? $0.locale?.identifier,
                subtypes: Set($0.mediaSubTypes.map(\.uint32Value))
            )
        }
        let pairing = pair(options: optionKeys, tracks: candidates)
        return group.options.enumerated().map { index, option in
            track(for: option, at: index, in: group, kind: .audio, format: pairing[index].map { formats[$0] })
        }
    }

    struct OptionKey: Equatable {
        var language: String?
        /// Codec subtypes of the option's media; empty when unknown.
        var subtypes: Set<UInt32>
    }

    struct TrackCandidate: Equatable {
        var language: String?
        var subtype: UInt32
    }

    /// For each option, the index of the audio track behind it (nil if none could be found).
    /// Equal counts pair by position, as long as the codecs agree; otherwise each option takes the
    /// first unused track with the same language and codec.
    static func pair(options: [OptionKey], tracks: [TrackCandidate]) -> [Int?] {
        func codecMatches(_ option: OptionKey, _ track: TrackCandidate) -> Bool {
            option.subtypes.isEmpty || option.subtypes.contains(track.subtype)
        }
        if options.count == tracks.count,
           zip(options, tracks).allSatisfy({ codecMatches($0, $1) }) {
            return Array(tracks.indices)
        }
        var used = Set<Int>()
        return options.map { option in
            let match = tracks.indices.first { index in
                !used.contains(index)
                    && codecMatches(option, tracks[index])
                    && (option.language == nil || tracks[index].language == nil
                        || LanguageMatching.matches(option.language, tracks[index].language))
            }
            if let match { used.insert(match) }
            return match
        }
    }

    private static func track(
        for option: AVMediaSelectionOption, at index: Int, in group: AVMediaSelectionGroup,
        kind: MediaTrack.Kind, format: AudioFormatInfo?
    ) -> MediaTrack {
        MediaTrack(
            id: "\(kind.rawValue)-\(index)",
            kind: kind,
            language: option.extendedLanguageTag ?? option.locale?.identifier,
            title: option.displayName,
            codec: format?.codec,
            channels: format?.channels,
            isDefault: option == group.defaultOption,
            isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
            isSpatial: format?.isSpatial ?? false
        )
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
