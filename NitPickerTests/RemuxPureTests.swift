import Foundation
import Testing
@testable import NitPicker

/// Builds ISO-BMFF boxes by hand, so the parser and the timestamp rewrite are tested without FFmpeg.
enum BoxBuilder {
    static func u32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * (3 - $0))) & 0xFF) } }
    static func u64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8((value >> (8 * (7 - $0))) & 0xFF) } }
    static func box(_ type: String, _ payload: [UInt8] = []) -> [UInt8] { u32(8 + payload.count) + Array(type.utf8) + payload }
    static func full(_ type: String, version: Int = 0, flags: Int = 0, _ payload: [UInt8] = []) -> [UInt8] {
        box(type, [UInt8(version)] + [UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + payload)
    }

    /// `trak` with an id, a media timescale and optional edit-list entries `(segmentDuration, mediaTime)`.
    static func track(id: Int, timescale: Int, edits: [(Int, Int)] = [], version: Int = 0) -> [UInt8] {
        var children = full("tkhd", u32(0) + u32(0) + u32(id))
        if !edits.isEmpty {
            let entries = edits.flatMap { version == 1 ? u64($0.0) + u64($0.1) + u32(0x10000) : u32($0.0) + u32($0.1) + u32(0x10000) }
            children += box("edts", full("elst", version: version, u32(edits.count) + entries))
        }
        children += box("mdia", full("mdhd", u32(0) + u32(0) + u32(timescale) + u32(0)))
        return box("trak", children)
    }

    static func initSegment(movieTimescale: Int = 1000, tracks: [[UInt8]]) -> [UInt8] {
        box("ftyp", Array("isom".utf8) + u32(0)) + box("moov", full("mvhd", u32(0) + u32(0) + u32(movieTimescale) + u32(0)) + tracks.flatMap { $0 })
    }

    /// A `moof` with one `traf` per `(trackID, baseDecodeTime, firstCompositionOffset)`, followed by an `mdat`.
    static func fragment(sequence: Int, tracks: [(id: Int, time: Int, cts: Int?)], wide: Bool = true) -> [UInt8] {
        var trafs: [UInt8] = []
        for track in tracks {
            var children = full("tfhd", flags: 0x020000, u32(track.id))
            children += wide ? full("tfdt", version: 1, u64(track.time)) : full("tfdt", version: 0, u32(track.time))
            // One sample: duration, size, flags, and a composition offset if wanted.
            let flags = 0x100 | 0x200 | 0x400 | (track.cts != nil ? 0x800 : 0)
            var sample = u32(1000) + u32(10) + u32(0)
            if let cts = track.cts { sample += u32(cts & 0xFFFFFFFF) }
            children += full("trun", flags: flags, u32(1) + sample)
            trafs += box("traf", children)
        }
        return box("moof", full("mfhd", u32(sequence)) + trafs) + box("mdat", [UInt8](repeating: 0, count: 10))
    }
}

@Suite struct MP4BoxTests {
    @Test func listsBoxesAndFindsChildren() {
        let bytes = BoxBuilder.box("free", [1, 2, 3]) + BoxBuilder.box("moov", BoxBuilder.box("trak"))
        let top = MP4Boxes.children(of: bytes)
        #expect(top.map(\.type) == ["free", "moov"])
        #expect(top[0].size == 11)
        #expect(MP4Boxes.child("trak", of: top[1], in: bytes)?.size == 8)
        #expect(MP4Boxes.child("udta", of: top[1], in: bytes) == nil)
    }

    @Test func stopsAtTruncatedOrMalformedBoxes() {
        let good = BoxBuilder.box("free", [1])
        #expect(MP4Boxes.children(of: good + [0, 0, 0, 40, 0x6D, 0x6F, 0x6F, 0x76]).map(\.type) == ["free"])  // claims 40 bytes, has 8
        #expect(MP4Boxes.children(of: good + [0, 0, 0, 4, 0x6D, 0x6F, 0x6F, 0x76]).map(\.type) == ["free"])  // size under 8
        #expect(MP4Boxes.children(of: []).isEmpty)
    }

    @Test func readsA64BitBoxSizeAndABoxThatRunsToTheEnd() {
        let wide = BoxBuilder.u32(1) + Array("mdat".utf8) + BoxBuilder.u64(20) + [1, 2, 3, 4]
        #expect(MP4Boxes.children(of: wide).first?.size == 20)
        let open = BoxBuilder.u32(0) + Array("mdat".utf8) + [9, 9, 9]
        #expect(MP4Boxes.children(of: open).first?.size == 11)
    }

    @Test func readsTimescalesTrackIDsAndEditLists() throws {
        let bytes = BoxBuilder.initSegment(movieTimescale: 1000, tracks: [
            BoxBuilder.track(id: 1, timescale: 16000, edits: [(0, 2624)]),
            BoxBuilder.track(id: 2, timescale: 48000),
        ])
        let info = try #require(MP4Boxes.initInfo(bytes))
        #expect(info.movieTimescale == 1000)
        #expect(info.tracks.map(\.timescale) == [16000, 48000])
        #expect(info.tracks.map(\.trackID) == [1, 2])
        #expect(info.mediaTime(track: 0) == 2624)
        #expect(info.mediaTime(track: 1) == 0)
        #expect(info.emptyEditTicks(track: 0) == 0)
    }

    @Test func countsAnEmptyEditAsADelayInTrackTicks() throws {
        // 250 ms of nothing (movie timescale 1000), then the media from time 960.
        let bytes = BoxBuilder.initSegment(movieTimescale: 1000, tracks: [
            BoxBuilder.track(id: 1, timescale: 48000, edits: [(250, -1), (5000, 960)]),
        ])
        let info = try #require(MP4Boxes.initInfo(bytes))
        #expect(info.emptyEditTicks(track: 0) == 12000)  // 0.25 s at 48 kHz
        #expect(info.mediaTime(track: 0) == 960)
    }

    @Test func readsVersionOneEditLists() throws {
        let bytes = BoxBuilder.initSegment(tracks: [BoxBuilder.track(id: 1, timescale: 90000, edits: [(1000, 4500)], version: 1)])
        #expect(try #require(MP4Boxes.initInfo(bytes)).mediaTime(track: 0) == 4500)
    }

    @Test func readsTheFirstFragmentsTiming() {
        let bytes = BoxBuilder.fragment(sequence: 1, tracks: [(1, 48672, 2000), (2, 138240, nil)])
        let timing = MP4Boxes.firstFragmentTiming(bytes, trackIDs: [1, 2])
        #expect(timing == [
            MP4Boxes.FragmentTiming(track: 0, baseDecodeTime: 48672, firstCompositionOffset: 2000),
            MP4Boxes.FragmentTiming(track: 1, baseDecodeTime: 138240, firstCompositionOffset: 0),
        ])
    }

    @Test func readsNegativeCompositionOffsets() {
        let bytes = BoxBuilder.fragment(sequence: 1, tracks: [(1, 0, -1500)])
        #expect(MP4Boxes.firstFragmentTiming(bytes, trackIDs: [1]).first?.firstCompositionOffset == -1500)
    }

    @Test func shiftsEveryFragmentAndRenumbersThem() {
        var bytes = BoxBuilder.fragment(sequence: 1, tracks: [(1, 0, 100), (2, 0, nil)])
            + BoxBuilder.fragment(sequence: 1, tracks: [(1, 48000, 100), (2, 46080, nil)])
        MP4Boxes.rewrite(&bytes, trackIDs: [1, 2], deltas: [1_000_000, 500], firstSequenceNumber: 3001)

        let moofs = MP4Boxes.children(of: bytes).filter { $0.type == "moof" }
        #expect(moofs.count == 2)
        func tfdts(_ moof: MP4Boxes.Box) -> [Int] {
            MP4Boxes.children(of: bytes, from: moof.payload, to: moof.end).filter { $0.type == "traf" }.map { traf in
                let tfdt = MP4Boxes.child("tfdt", of: traf, in: bytes)!
                return Int(MP4Boxes.u64(bytes, tfdt.payload + 4))
            }
        }
        #expect(tfdts(moofs[0]) == [1_000_000, 500])
        #expect(tfdts(moofs[1]) == [1_048_000, 46_580])  // later fragments keep their distance from the first
        let sequences = moofs.map { MP4Boxes.u32(bytes, MP4Boxes.child("mfhd", of: $0, in: bytes)!.payload + 4) }
        #expect(sequences == [3001, 3002])
    }

    @Test func rewritesNarrowTimestampsAndNeverGoesNegative() {
        var bytes = BoxBuilder.fragment(sequence: 1, tracks: [(1, 1000, nil)], wide: false)
        MP4Boxes.rewrite(&bytes, trackIDs: [1], deltas: [-5000], firstSequenceNumber: 1)
        let moof = MP4Boxes.children(of: bytes).first!
        let tfdt = MP4Boxes.child("tfdt", of: MP4Boxes.children(of: bytes, from: moof.payload, to: moof.end).first { $0.type == "traf" }!, in: bytes)!
        #expect(MP4Boxes.u32(bytes, tfdt.payload + 4) == 0)
    }

    /// The records a real muxer wrote for a 4K Dolby Vision 8.1 + HDR10 base layer HEVC track (the phase 2 spike).
    private let realHvcC = "012220000000b0000000000096f000fcfdfafa00000f03a00001001840010c01ffff222000000300b000000300000300"
    private let realDvvC = "010010351000000000000000000000000000000000000000"

    private func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)! }
    }

    @Test func buildsCodecStringsFromRealConfigurationRecords() {
        let bytes = BoxBuilder.box("hvc1", BoxBuilder.box("hvcC", hex(realHvcC)) + BoxBuilder.box("dvvC", hex(realDvvC)))
        #expect(MP4Boxes.hevcCodecString(bytes) == "hvc1.2.4.H150.B0")
        let dolby = MP4Boxes.dolbyVision(bytes)
        #expect(dolby?.profile == 8 && dolby?.level == 6 && dolby?.compatibilityID == 1)
    }

    @Test func buildsAnAVCCodecString() {
        // High profile (0x64), no constraints, level 4.0 (0x28).
        let bytes = BoxBuilder.box("avc1", BoxBuilder.box("avcC", [1, 0x64, 0x00, 0x28, 0xFF]))
        #expect(MP4Boxes.avcCodecString(bytes) == "avc1.640028")
    }

    @Test func missingRecordsGiveNil() {
        #expect(MP4Boxes.hevcCodecString(BoxBuilder.box("free", [1, 2, 3])) == nil)
        #expect(MP4Boxes.dolbyVision([]) == nil)
        #expect(MP4Boxes.avcCodecString(BoxBuilder.box("avcC", [1])) == nil)
    }
}

@Suite struct SegmentPlannerTests {
    private func seconds(_ values: Double...) -> [Duration] { values.map { .seconds($0) } }

    @Test func groupsKeyframesIntoSegmentsOfAtLeastTheTarget() {
        let plan = SegmentPlanner.plan(keyframes: seconds(0, 3.5, 7, 10.5, 14, 17.5, 21), duration: .seconds(24))
        #expect(plan.map { $0.start.seconds } == [0, 7, 14, 21].dropLast(0).map { $0 })
        #expect(plan.map(\.index) == Array(0..<plan.count))
        #expect(plan.dropLast().allSatisfy { $0.duration >= .seconds(6) })
        #expect(plan.last?.end == nil)  // the last segment runs to the end of the file
    }

    @Test func eachSegmentEndsWhereTheNextBegins() {
        let plan = SegmentPlanner.plan(keyframes: seconds(0, 4, 8, 12, 16, 20), duration: .seconds(24))
        for (a, b) in zip(plan, plan.dropFirst()) { #expect(a.end == b.start) }
        let total = plan.reduce(Duration.zero) { $0 + $1.duration }
        #expect(abs(total.seconds - 24) < 0.001)
    }

    @Test func foldsAShortTailIntoThePreviousSegment() {
        let plan = SegmentPlanner.plan(keyframes: seconds(0, 6, 12, 18), duration: .seconds(19.5))
        #expect(plan.map { $0.start.seconds } == [0, 6, 12])
        #expect(plan.last?.duration == .seconds(7.5))
    }

    @Test func handlesAFileWithOneKeyframeOrNone() {
        #expect(SegmentPlanner.plan(keyframes: [], duration: .seconds(10)).isEmpty)
        let single = SegmentPlanner.plan(keyframes: seconds(0), duration: .seconds(10))
        #expect(single.count == 1 && single[0].duration == .seconds(10) && single[0].end == nil)
    }

    @Test func startsAtTheFirstKeyframeEvenWhenItIsNotZero() {
        let plan = SegmentPlanner.plan(keyframes: seconds(0.042, 3, 6.5), duration: .seconds(12))
        #expect(plan[0].start == .seconds(0.042))
    }

    @Test func findsTheSegmentAtATime() {
        let plan = SegmentPlanner.plan(keyframes: seconds(0, 6, 12), duration: .seconds(18))
        #expect(SegmentPlanner.index(at: .zero, in: plan) == 0)
        #expect(SegmentPlanner.index(at: .seconds(5.99), in: plan) == 0)
        #expect(SegmentPlanner.index(at: .seconds(6), in: plan) == 1)
        #expect(SegmentPlanner.index(at: .seconds(99), in: plan) == 2)
    }
}

@Suite struct RemuxDecisionTests {
    private func audio(_ id: Int, _ codec: String, _ language: String?, isDefault: Bool = false) -> ProbedStream {
        ProbedStream(id: id, kind: .audio, codec: codec, language: language, isDefault: isDefault, channels: 6, sampleRate: 48000)
    }

    @Test func choosesAudioByPreferenceThenDefaultThenFirst() {
        let streams = [audio(1, "eac3", "ita"), audio(2, "eac3", "eng", isDefault: true), audio(3, "ac3", "fra")]
        #expect(RemuxSupport.chooseAudio(from: streams, preferredLanguage: "fr")?.id == 3)
        #expect(RemuxSupport.chooseAudio(from: streams, preferredLanguage: "en")?.id == 2)
        #expect(RemuxSupport.chooseAudio(from: streams, preferredLanguage: "de")?.id == 2)  // no match: the default
        #expect(RemuxSupport.chooseAudio(from: streams, preferredLanguage: nil)?.id == 2)
        #expect(RemuxSupport.chooseAudio(from: [audio(5, "aac", "jpn")], preferredLanguage: nil)?.id == 5)
    }

    @Test func prefersAudioThatCanBeCopiedAndConvertsTheRestOnlyWhenNothingElseIsLeft() {
        let streams = [audio(1, "dts", "eng", isDefault: true), audio(2, "truehd", "eng"), audio(3, "ac3", "eng")]
        #expect(RemuxSupport.chooseAudio(from: streams, preferredLanguage: "en")?.id == 3)
        #expect(RemuxSupport.chooseAudio(from: [audio(1, "dts", "eng")], preferredLanguage: "en")?.id == 1)
        #expect(RemuxSupport.chooseAudio(from: [audio(1, "notacodec", "eng")], preferredLanguage: "en") == nil)
    }

    @Test func listsWhatCanBeCopied() {
        #expect(RemuxSupport.canCopyVideo(codec: "hevc") && RemuxSupport.canCopyVideo(codec: "h264"))
        #expect(!RemuxSupport.canCopyVideo(codec: "vp9") && !RemuxSupport.canCopyVideo(codec: "mpeg4"))
        for codec in ["aac", "ac3", "eac3", "alac", "flac"] { #expect(RemuxSupport.canCopyAudio(codec: codec)) }
        for codec in ["dts", "truehd", "vorbis", "opus", "mp3"] { #expect(!RemuxSupport.canCopyAudio(codec: codec)) }
    }

    private func probe(video: String = "hevc", audio audioCodecs: [String] = ["eac3"], keyframes: [Double] = [0, 3, 6, 9]) -> MKVProbeResult {
        MKVProbeResult(
            formatName: "matroska,webm", duration: .seconds(12),
            streams: [ProbedStream(id: 0, kind: .video, codec: video, width: 3840, height: 1920)]
                + audioCodecs.enumerated().map { audio($0.offset + 1, $0.element, "eng") },
            chapters: [], keyframes: keyframes.map { .seconds($0) }
        )
    }

    @Test func planPicksTheTracksAndSegments() throws {
        let plan = try RemuxSession.plan(for: probe(), preferredAudioLanguage: nil)
        #expect(plan.video.id == 0 && plan.audio?.id == 1)
        #expect(!plan.segments.isEmpty)
    }

    @Test func planRefusesWithAMessageForEachUnsupportedCase() {
        func message(_ probe: MKVProbeResult) -> String? {
            do { _ = try RemuxSession.plan(for: probe, preferredAudioLanguage: nil); return nil } catch { return error.localizedDescription }
        }
        #expect(message(probe(video: "vp9")) == "This file's video (VP9) isn't supported yet.")
        #expect(message(probe(audio: ["notacodec", "alsonot"])) == "This file's audio (ALSONOT, NOTACODEC) isn't supported yet.")
        #expect(message(probe(keyframes: [])) == "This file has no seek index, which isn't supported yet.")
        var noVideo = probe()
        noVideo.streams.removeFirst()
        #expect(message(noVideo) == "This file has no video.")
    }

    @Test func audioAVPlayerCannotPlayIsConvertedAndNeverBeatsOneThatCanBeCopied() throws {
        for codec in ["dts", "truehd", "opus", "vorbis", "mp3", "pcm_s16le"] {
            #expect(RemuxSupport.canTranscodeAudio(codec: codec), "\(codec) should be convertible")
            #expect(try RemuxSession.plan(for: probe(audio: [codec]), preferredAudioLanguage: nil).audio?.id == 1)
        }
        #expect(!RemuxSupport.canTranscodeAudio(codec: "eac3"))  // copied, not converted
        #expect(!RemuxSupport.canTranscodeAudio(codec: "notacodec"))
        // TrueHD first and default, an AC-3 core in the same language after it: the core plays as it is.
        let plan = try RemuxSession.plan(for: probe(audio: ["truehd", "ac3"]), preferredAudioLanguage: "en")
        #expect(plan.audio?.codec == "ac3")
        // A language the user asked for still wins over the copy-first rule.
        var mixed = probe(audio: ["ac3", "dts"])
        mixed.streams[2].language = "ita"
        #expect(try RemuxSession.plan(for: mixed, preferredAudioLanguage: "it").audio?.codec == "dts")
    }

    @Test func aFileWithoutAudioStillPlansVideoOnly() throws {
        let plan = try RemuxSession.plan(for: probe(audio: []), preferredAudioLanguage: nil)
        #expect(plan.audio == nil)
    }
}

@Suite struct HLSPlaylistTests {
    private let init4K = BoxBuilder.box("hvc1",
        BoxBuilder.box("hvcC", Array(repeating: 0, count: 0) + [1, 0x22, 0x20, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 0x96, 0xF0, 0, 0xFC])
            + BoxBuilder.box("dvvC", [1, 0, 0x10, 0x35, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))

    private func video(_ hdr: HDRFormat, codec: String = "hevc") -> ProbedStream {
        ProbedStream(id: 0, kind: .video, codec: codec, hdr: hdr)
    }

    private func variant(_ hdr: HDRFormat, audioCodec: String? = "eac3") -> HLSPlaylists.Variant? {
        var stream = video(hdr)
        stream.width = 3840; stream.height = 1920; stream.frameRate = 23.976
        let audio = audioCodec.map { ProbedStream(id: 1, kind: .audio, codec: $0) }
        return HLSPlaylists.variant(video: stream, audio: audio, initSegment: init4K, fileBytes: 1_000_000_000, duration: .seconds(1000))
    }

    @Test func mediaPlaylistListsEverySegmentWithItsDuration() {
        let segments = SegmentPlanner.plan(keyframes: [.zero, .seconds(6.089), .seconds(12.179)], duration: .seconds(19))
        let text = HLSPlaylists.media(segments: segments)
        #expect(text.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:7\n"))
        #expect(text.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(text.contains("#EXTINF:6.089,\nseg_00000.m4s\n"))
        #expect(text.contains("#EXTINF:6.090,\nseg_00001.m4s\n"))
        #expect(text.contains("seg_00002.m4s"))
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func masterSignalsDolbyVisionOnTopOfItsHDR10BaseLayer() throws {
        let variant = try #require(variant(.dolbyVision(profile: 8, compatibilityID: 1)))
        #expect(variant.codecs == "hvc1.2.4.H150.B0,ec-3")
        #expect(variant.supplementalCodecs == "dvh1.08.06/db1p")
        #expect(variant.videoRange == "PQ")
        let text = HLSPlaylists.master(variant)
        #expect(text.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(text.contains("VIDEO-RANGE=PQ,RESOLUTION=3840x1920,FRAME-RATE=23.976"))
        #expect(text.hasSuffix("video.m3u8\n"))
    }

    @Test func masterNamesTheVideoRange() throws {
        #expect(try #require(variant(.hdr10)).videoRange == "PQ")
        #expect(try #require(variant(.hlg)).videoRange == "HLG")
        #expect(try #require(variant(.sdr)).videoRange == "SDR")
        #expect(try #require(variant(.hdr10)).supplementalCodecs == nil)
    }

    @Test func bandwidthComesFromTheFileSize() throws {
        let variant = try #require(variant(.hdr10))
        #expect(variant.averageBandwidth == 8_000_000)  // 1 GB over 1000 s
        #expect(variant.bandwidth > variant.averageBandwidth)
    }

    @Test func audioCodecStringsAndMissingAudio() throws {
        #expect(try #require(variant(.sdr, audioCodec: "ac3")).codecs.hasSuffix(",ac-3"))
        #expect(try #require(variant(.sdr, audioCodec: "aac")).codecs.hasSuffix(",mp4a.40.2"))
        #expect(try #require(variant(.sdr, audioCodec: nil)).codecs == "hvc1.2.4.H150.B0")
        #expect(variant(.sdr, audioCodec: "dts") == nil)
    }

    @Test func h264NeedsItsOwnConfigurationRecord() {
        let avc = BoxBuilder.box("avc1", BoxBuilder.box("avcC", [1, 0x64, 0, 0x28, 0xFF]))
        let variant = HLSPlaylists.variant(video: video(.sdr, codec: "h264"), audio: nil, initSegment: avc, fileBytes: 1000, duration: .seconds(10))
        #expect(variant?.codecs == "avc1.640028")
        #expect(HLSPlaylists.variant(video: video(.sdr, codec: "vp9"), audio: nil, initSegment: avc, fileBytes: 1000, duration: .seconds(10)) == nil)
    }
}
