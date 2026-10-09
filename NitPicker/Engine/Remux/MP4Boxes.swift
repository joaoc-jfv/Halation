import Foundation

/// Just enough ISO base media file format parsing to turn FFmpeg's muxer output into HLS segments: split the init
/// segment from the fragments, read track timescales and edit lists, and rewrite fragment timestamps.
/// Works on `[UInt8]` so indices are always zero-based (a `Data` slice keeps its parent's indices).
enum MP4Boxes {
    struct Box: Equatable {
        var type: String
        var offset: Int
        var size: Int
        var end: Int { offset + size }
        /// Where the box's children (or its payload, for a plain box) start.
        var payload: Int { offset + 8 }
    }

    static func u16(_ bytes: [UInt8], _ index: Int) -> Int { Int(bytes[index]) << 8 | Int(bytes[index + 1]) }
    static func u32(_ bytes: [UInt8], _ index: Int) -> Int {
        (0..<4).reduce(0) { $0 << 8 | Int(bytes[index + $1]) }
    }
    static func u64(_ bytes: [UInt8], _ index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[index + $1]) }
    }
    static func s32(_ bytes: [UInt8], _ index: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(bytes, index))) }
    static func s64(_ bytes: [UInt8], _ index: Int) -> Int { Int(Int64(bitPattern: u64(bytes, index))) }

    static func write(_ bytes: inout [UInt8], at index: Int, value: UInt64, width: Int) {
        for position in 0..<width {
            bytes[index + position] = UInt8((value >> UInt64(8 * (width - 1 - position))) & 0xFF)
        }
    }

    /// The boxes between `start` and `end`. Stops at the first malformed one.
    static func children(of bytes: [UInt8], from start: Int = 0, to end: Int? = nil) -> [Box] {
        let limit = end ?? bytes.count
        var result: [Box] = []
        var index = start
        while index + 8 <= limit {
            var size = u32(bytes, index)
            let type = String(decoding: bytes[index + 4..<index + 8], as: UTF8.self)
            if size == 1, index + 16 <= limit { size = Int(u64(bytes, index + 8)) }  // 64-bit size
            if size == 0 { size = limit - index }  // runs to the end
            guard size >= 8, index + size <= limit else { break }
            result.append(Box(type: type, offset: index, size: size))
            index += size
        }
        return result
    }

    static func child(_ type: String, of parent: Box, in bytes: [UInt8]) -> Box? {
        children(of: bytes, from: parent.payload, to: parent.end).first { $0.type == type }
    }

    // MARK: Init segment information

    struct TrackInfo: Equatable {
        /// Media timescale (`mdhd`).
        var timescale: Int
        /// `elst` entries as `(segmentDuration in movie timescale, mediaTime in track timescale)`; -1 is an empty edit.
        var edits: [(duration: Int, mediaTime: Int)]
        var trackID: Int

        static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
            lhs.timescale == rhs.timescale && lhs.trackID == rhs.trackID
                && lhs.edits.map(\.duration) == rhs.edits.map(\.duration) && lhs.edits.map(\.mediaTime) == rhs.edits.map(\.mediaTime)
        }
    }

    struct InitInfo: Equatable {
        var movieTimescale: Int
        var tracks: [TrackInfo]

        /// Track ticks by which the presentation of the first sample is pushed later by empty edits.
        func emptyEditTicks(track index: Int) -> Int {
            let track = tracks[index]
            let movieTicks = track.edits.prefix { $0.mediaTime < 0 }.reduce(0) { $0 + $1.duration }
            return movieTimescale > 0 ? Int((Double(movieTicks) * Double(track.timescale) / Double(movieTimescale)).rounded()) : 0
        }

        /// `media_time` of the first real edit: the sample time that shows at the start of the track.
        func mediaTime(track index: Int) -> Int {
            tracks[index].edits.first { $0.mediaTime >= 0 }?.mediaTime ?? 0
        }
    }

    /// Reads track order, timescales and edit lists from an init segment (`ftyp` + `moov`).
    static func initInfo(_ bytes: [UInt8]) -> InitInfo? {
        guard let moov = children(of: bytes).first(where: { $0.type == "moov" }) else { return nil }
        var movieTimescale = 0
        if let mvhd = child("mvhd", of: moov, in: bytes) {
            movieTimescale = u32(bytes, mvhd.payload + 4 + (bytes[mvhd.payload] == 1 ? 16 : 8))
        }
        var tracks: [TrackInfo] = []
        for trak in children(of: bytes, from: moov.payload, to: moov.end) where trak.type == "trak" {
            var info = TrackInfo(timescale: 0, edits: [], trackID: 0)
            if let tkhd = child("tkhd", of: trak, in: bytes) {
                info.trackID = u32(bytes, tkhd.payload + 4 + (bytes[tkhd.payload] == 1 ? 16 : 8))
            }
            if let mdia = child("mdia", of: trak, in: bytes), let mdhd = child("mdhd", of: mdia, in: bytes) {
                info.timescale = u32(bytes, mdhd.payload + 4 + (bytes[mdhd.payload] == 1 ? 16 : 8))
            }
            if let edts = child("edts", of: trak, in: bytes), let elst = child("elst", of: edts, in: bytes) {
                let version = Int(bytes[elst.payload])
                let count = u32(bytes, elst.payload + 4)
                var position = elst.payload + 8
                for _ in 0..<count {
                    if version == 1 {
                        info.edits.append((s64(bytes, position), s64(bytes, position + 8)))
                        position += 20
                    } else {
                        info.edits.append((u32(bytes, position), s32(bytes, position + 4)))
                        position += 12
                    }
                }
            }
            tracks.append(info)
        }
        return tracks.isEmpty ? nil : InitInfo(movieTimescale: movieTimescale, tracks: tracks)
    }

    // MARK: Fragment rewriting

    struct FragmentTiming: Equatable {
        /// 0-based position of the track in the init segment.
        var track: Int
        var baseDecodeTime: Int
        /// Composition offset of the first sample in decode order (0 when the trun has none).
        var firstCompositionOffset: Int
    }

    /// The first fragment's timing for each track.
    static func firstFragmentTiming(_ bytes: [UInt8], trackIDs: [Int]) -> [FragmentTiming] {
        guard let moof = children(of: bytes).first(where: { $0.type == "moof" }) else { return [] }
        var result: [FragmentTiming] = []
        for traf in children(of: bytes, from: moof.payload, to: moof.end) where traf.type == "traf" {
            guard let tfhd = child("tfhd", of: traf, in: bytes), let tfdt = child("tfdt", of: traf, in: bytes),
                  let track = trackIDs.firstIndex(of: u32(bytes, tfhd.payload + 4)) else { continue }
            let trun = child("trun", of: traf, in: bytes)
            result.append(FragmentTiming(
                track: track,
                baseDecodeTime: baseDecodeTime(bytes, tfdt),
                firstCompositionOffset: trun.map { firstCompositionOffset(bytes, $0) } ?? 0
            ))
        }
        return result
    }

    private static func baseDecodeTime(_ bytes: [UInt8], _ tfdt: Box) -> Int {
        bytes[tfdt.payload] == 1 ? Int(u64(bytes, tfdt.payload + 4)) : u32(bytes, tfdt.payload + 4)
    }

    /// Composition offset of the first sample, if the `trun` carries them.
    private static func firstCompositionOffset(_ bytes: [UInt8], _ trun: Box) -> Int {
        let flags = u32(bytes, trun.payload) & 0xFFFFFF
        guard flags & 0x800 != 0 else { return 0 }
        var position = trun.payload + 8
        if flags & 0x001 != 0 { position += 4 }  // data offset
        if flags & 0x004 != 0 { position += 4 }  // first sample flags
        if flags & 0x100 != 0 { position += 4 }  // duration
        if flags & 0x200 != 0 { position += 4 }  // size
        if flags & 0x400 != 0 { position += 4 }  // flags
        return s32(bytes, position)
    }

    /// Shifts every `tfdt` in `bytes` by `deltas[track]` ticks and renumbers the fragments' `mfhd` sequence numbers
    /// from `firstSequenceNumber`. A segment can hold several fragments (one per keyframe), and they all move together.
    static func rewrite(_ bytes: inout [UInt8], trackIDs: [Int], deltas: [Int], firstSequenceNumber: Int) {
        var sequence = firstSequenceNumber
        for moof in children(of: bytes) where moof.type == "moof" {
            if let mfhd = child("mfhd", of: moof, in: bytes) {
                write(&bytes, at: mfhd.payload + 4, value: UInt64(sequence), width: 4)
                sequence += 1
            }
            for traf in children(of: bytes, from: moof.payload, to: moof.end) where traf.type == "traf" {
                guard let tfhd = child("tfhd", of: traf, in: bytes), let tfdt = child("tfdt", of: traf, in: bytes),
                      let track = trackIDs.firstIndex(of: u32(bytes, tfhd.payload + 4)), track < deltas.count else { continue }
                let wide = bytes[tfdt.payload] == 1
                let shifted = max(0, baseDecodeTime(bytes, tfdt) + deltas[track])
                write(&bytes, at: tfdt.payload + 4, value: UInt64(shifted), width: wide ? 8 : 4)
            }
        }
    }

    // MARK: Codec strings for the master playlist

    /// `hvc1.2.4.H150.B0`, from the `hvcC` record in the init segment.
    static func hevcCodecString(_ bytes: [UInt8]) -> String? {
        guard let record = configurationRecord("hvcC", in: bytes, length: 13) else { return nil }
        let profile = Int(record[1] & 0x1F)
        let tier = (record[1] >> 5) & 1 == 1 ? "H" : "L"
        var compatibility = UInt32(record[2]) << 24 | UInt32(record[3]) << 16 | UInt32(record[4]) << 8 | UInt32(record[5])
        var reversed: UInt32 = 0
        for _ in 0..<32 {
            reversed = reversed << 1 | (compatibility & 1)
            compatibility >>= 1
        }
        let constraints = record[6..<12].reversed().drop { $0 == 0 }.reversed().map { String(format: "%X", $0) }.joined(separator: ".")
        return "hvc1.\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(record[12]).\(constraints.isEmpty ? "0" : constraints)"
    }

    /// `avc1.640028`, from the `avcC` record.
    static func avcCodecString(_ bytes: [UInt8]) -> String? {
        guard let record = configurationRecord("avcC", in: bytes, length: 4) else { return nil }
        return String(format: "avc1.%02X%02X%02X", record[1], record[2], record[3])
    }

    /// `(profile, level, compatibilityID)` from the `dvvC` or `dvcC` record.
    static func dolbyVision(_ bytes: [UInt8]) -> (profile: Int, level: Int, compatibilityID: Int)? {
        guard let record = configurationRecord("dvvC", in: bytes, length: 5) ?? configurationRecord("dvcC", in: bytes, length: 5) else { return nil }
        return (Int(record[2] >> 1), Int(record[2] & 1) << 5 | Int(record[3] >> 3), Int(record[4] >> 4))
    }

    /// The whole payload of the first box called `type` found anywhere in `bytes` (for variable-length records like `dec3`).
    static func payload(of type: String, in bytes: [UInt8]) -> [UInt8]? {
        let marker = Array(type.utf8)
        guard bytes.count >= marker.count + 4 else { return nil }
        for index in 4...(bytes.count - marker.count) where bytes[index..<index + 4].elementsEqual(marker) {
            let size = u32(bytes, index - 4)
            if size >= 8, index - 4 + size <= bytes.count { return Array(bytes[index + 4..<index - 4 + size]) }
        }
        return nil
    }

    /// The payload of the first box called `type` found anywhere in the init segment.
    private static func configurationRecord(_ type: String, in bytes: [UInt8], length: Int) -> [UInt8]? {
        let marker = Array(type.utf8)
        let lastStart = bytes.count - marker.count - length  // the last index where the marker and the record still fit
        guard lastStart >= 4 else { return nil }
        for index in 4...lastStart where bytes[index..<index + 4].elementsEqual(marker) {
            // The four bytes before the type are the box size; make sure they plausibly belong to a box.
            let size = u32(bytes, index - 4)
            if size >= 8 + length, index - 4 + size <= bytes.count { return Array(bytes[index + 4..<index + 4 + length]) }
        }
        return nil
    }
}
