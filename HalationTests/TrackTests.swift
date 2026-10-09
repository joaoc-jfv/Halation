import AudioToolbox
import CoreMedia
import Foundation
import Testing
@testable import Halation

/// Builds `dec3` records the way ETSI TS 102 366 Annex F.6 lays them out.
private func dec3(jocObjects: UInt8? = nil, dependentSubstreams: Int = 0, independentSubstreams: Int = 1) -> Data {
    var bytes: [UInt8] = [0x02, 0x00 | UInt8(independentSubstreams - 1)]  // data_rate(13) | num_ind_sub(3)
    for _ in 0..<independentSubstreams {
        bytes += [0b0100_0000, 0b0010_1111, UInt8(dependentSubstreams) << 1]
        if dependentSubstreams > 0 { bytes.append(0b0001_1111) }  // chan_loc continues into a 4th byte
    }
    if let jocObjects { bytes += [0x01, jocObjects] }  // reserved(7) flag_ec3_extension_type_a(1), complexity_index_type_a(8)
    return Data(bytes)
}

@Suite struct AudioFormatDetectionTests {
    @Test func detectsJOC() {
        #expect(AudioFormatDetection.isJOC(dec3: dec3(jocObjects: 16)))
    }

    @Test func plainEAC3IsNotJOC() {
        #expect(!AudioFormatDetection.isJOC(dec3: dec3()))
    }

    @Test func extensionFlagWithoutObjectsIsNotJOC() {
        #expect(!AudioFormatDetection.isJOC(dec3: dec3(jocObjects: 0)))
    }

    @Test func readsPastDependentSubstreams() {
        #expect(AudioFormatDetection.isJOC(dec3: dec3(jocObjects: 12, dependentSubstreams: 1)))
        #expect(!AudioFormatDetection.isJOC(dec3: dec3(dependentSubstreams: 1)))
    }

    @Test func readsPastSeveralIndependentSubstreams() {
        #expect(AudioFormatDetection.isJOC(dec3: dec3(jocObjects: 8, independentSubstreams: 2)))
    }

    @Test func toleratesABoxHeader() {
        let boxed = Data([0, 0, 0, 16]) + Data("dec3".utf8) + dec3(jocObjects: 16)
        #expect(AudioFormatDetection.isJOC(dec3: boxed))
    }

    @Test func toleratesTruncatedRecords() {
        #expect(!AudioFormatDetection.isJOC(dec3: Data()))
        #expect(!AudioFormatDetection.isJOC(dec3: Data([0x02])))
        #expect(!AudioFormatDetection.isJOC(dec3: Data([0x02, 0x00, 0x40])))
    }

    private func eac3Description(channels: UInt32, cookie: Data?, atoms: [String: Data]? = nil) throws -> CMFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatEnhancedAC3, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )
        var extensions: CFDictionary?
        if let atoms {
            extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        }
        var result: CMAudioFormatDescription?
        let status = (cookie ?? Data()).withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie?.count ?? 0, magicCookie: cookie == nil ? nil : raw.baseAddress,
                extensions: extensions, formatDescriptionOut: &result
            )
        }
        #expect(status == noErr)
        return try #require(result)
    }

    @Test func classifiesFromTheSampleDescriptionAtom() throws {
        let info = AudioFormatDetection.info(for: try eac3Description(channels: 6, cookie: nil, atoms: ["dec3": dec3(jocObjects: 16)]))
        #expect(info == AudioFormatInfo(codec: "E-AC-3", channels: 6, isSpatial: true))
    }

    @Test func classifiesFromTheMagicCookie() throws {
        let info = AudioFormatDetection.info(for: try eac3Description(channels: 8, cookie: dec3(jocObjects: 16)))
        #expect(info.isSpatial)
        #expect(info.channels == 8)
    }

    @Test func plainEAC3FromEitherSourceIsNotSpatial() throws {
        #expect(!AudioFormatDetection.info(for: try eac3Description(channels: 6, cookie: dec3())).isSpatial)
        #expect(!AudioFormatDetection.info(for: try eac3Description(channels: 6, cookie: nil)).isSpatial)
    }

    @Test func otherCodecsAreNeverSpatial() throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        let info = AudioFormatDetection.info(for: try #require(description))
        #expect(info == AudioFormatInfo(codec: "AAC", channels: 2, isSpatial: false))
    }

    @Test func labelsChannelCounts() {
        #expect(AudioFormatDetection.channelLabel(2) == "Stereo")
        #expect(AudioFormatDetection.channelLabel(6) == "5.1")
        #expect(AudioFormatDetection.channelLabel(8) == "7.1")
        #expect(AudioFormatDetection.channelLabel(12) == "12 ch")
    }
}

@Suite struct LanguageMatchingTests {
    @Test func comparesPrimaryLanguages() {
        #expect(LanguageMatching.matches("en", "en-US"))
        #expect(LanguageMatching.matches("en_GB", "en-AU"))
        #expect(!LanguageMatching.matches("en", "fr"))
    }

    @Test func understandsThreeLetterCodes() {
        #expect(LanguageMatching.matches("eng", "en"))
        #expect(LanguageMatching.matches("fra", "fr-CA"))
        #expect(LanguageMatching.matches("por", "pt-BR"))
    }

    @Test func missingLanguagesNeverMatch() {
        #expect(!LanguageMatching.matches(nil, "en"))
        #expect(!LanguageMatching.matches("en", nil))
        #expect(!LanguageMatching.matches("", ""))
    }
}

@Suite struct MediaTrackLabelTests {
    private func track(
        title: String? = "English", language: String? = "en", codec: String? = "E-AC-3",
        channels: Int? = 6, spatial: Bool = false, forced: Bool = false
    ) -> MediaTrack {
        MediaTrack(id: "t", kind: .audio, language: language, title: title, codec: codec, channels: channels,
                   isDefault: false, isForced: forced, isSpatial: spatial)
    }

    @Test func summaryListsChannelsAndSpatial() {
        #expect(track(spatial: true).summary == "English · 5.1 · Spatial")
        #expect(track().summary == "English · 5.1")
        #expect(track(channels: nil).summary == "English")
    }

    @Test func detailListsCodecAndChannels() {
        #expect(track().detail == "E-AC-3 · 5.1")
        #expect(track(codec: nil, channels: nil).detail == nil)
    }

    @Test func fallsBackToTheLanguageName() {
        #expect(track(title: nil, language: "en").displayName == Locale.current.localizedString(forIdentifier: "en"))
        #expect(track(title: nil, language: nil).displayName == "Track")
    }
}

@Suite struct TrackSelectionPolicyTests {
    private func track(_ id: String, _ language: String, kind: MediaTrack.Kind = .audio, forced: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: kind, language: language, title: nil, codec: nil, channels: nil,
                   isDefault: false, isForced: forced, isSpatial: false)
    }

    @Test func picksTheAudioTrackInThePreferredLanguage() {
        let tracks = [track("a0", "en"), track("a1", "fr")]
        #expect(TrackSelectionPolicy.audio(from: tracks, preferredLanguage: "fra")?.id == "a1")
        #expect(TrackSelectionPolicy.audio(from: tracks, preferredLanguage: "de") == nil)
        #expect(TrackSelectionPolicy.audio(from: tracks, preferredLanguage: nil) == nil)
    }

    private let subs = [
        MediaTrack(id: "s0", kind: .subtitle, language: "en", title: nil, codec: nil, channels: nil, isDefault: false, isForced: false, isSpatial: false),
        MediaTrack(id: "s1", kind: .subtitle, language: "fr", title: nil, codec: nil, channels: nil, isDefault: false, isForced: false, isSpatial: false),
        MediaTrack(id: "s2", kind: .subtitle, language: "en", title: nil, codec: nil, channels: nil, isDefault: false, isForced: true, isSpatial: false),
    ]

    @Test func leavesTheDefaultAloneWhenNothingWasChosen() {
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .unset, audioLanguage: "en") == .keepDefault)
    }

    @Test func offStillShowsAForcedTrackInTheAudioLanguage() {
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .off, audioLanguage: "en") == .select(subs[2]))
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .off, audioLanguage: "de") == .select(nil))
    }

    @Test func prefersARegularTrackOverAForcedOne() {
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .language("en"), audioLanguage: "en") == .select(subs[0]))
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .language("fr"), audioLanguage: "en") == .select(subs[1]))
    }

    @Test func missingPreferredLanguageFallsBackToForcedOnly() {
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .language("de"), audioLanguage: "en") == .select(subs[2]))
        #expect(TrackSelectionPolicy.subtitle(from: subs, choice: .language("de"), audioLanguage: "ja") == .select(nil))
    }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func rememberValuesAcrossInstances() {
        let name = "halation-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let first = Preferences(defaults: defaults)
        #expect(first.audioLanguage == nil)
        #expect(first.subtitleChoice == .unset)
        #expect(first.audioOutputMode == .spatial)

        first.audioLanguage = "fr"
        first.subtitleChoice = .language("en")
        first.audioOutputMode = .stereo

        let second = Preferences(defaults: defaults)
        #expect(second.audioLanguage == "fr")
        #expect(second.subtitleChoice == .language("en"))
        #expect(second.audioOutputMode == .stereo)

        second.subtitleChoice = .off
        #expect(Preferences(defaults: defaults).subtitleChoice == .off)
        second.subtitleChoice = .unset
        #expect(Preferences(defaults: defaults).subtitleChoice == .unset)
    }
}
