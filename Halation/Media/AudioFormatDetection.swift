import AudioToolbox
import CoreMedia

struct AudioFormatInfo: Equatable, Sendable {
    var codec: String
    var channels: Int?
    /// Object-based audio (E-AC-3 JOC), which the system renders as Spatial Audio.
    var isSpatial: Bool
}

enum AudioFormatDetection {
    static func info(for description: CMFormatDescription) -> AudioFormatInfo {
        let subtype = description.mediaSubType.rawValue
        let channels = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            .map { Int($0.pointee.mChannelsPerFrame) }
            .flatMap { $0 > 0 ? $0 : nil }
        return AudioFormatInfo(
            codec: CodecNames.displayName(forFourCC: subtype),
            channels: channels,
            isSpatial: CodecNames.fourCC(subtype) == "ec-3" && hasJOC(description)
        )
    }

    /// Looks for the `dec3` record in the sample description atoms, then in the magic cookie.
    /// Which of the two CoreMedia fills for E-AC-3 is unconfirmed (PLAN.md §9), so both are checked.
    private static func hasJOC(_ description: CMFormatDescription) -> Bool {
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        if let dec3 = atoms?["dec3"] as? Data, isJOC(dec3: dec3) { return true }
        var size = 0
        if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0,
           isJOC(dec3: Data(bytes: cookie, count: size)) {
            return true
        }
        return false
    }

    /// Reads the E-AC-3 specific box (ETSI TS 102 366 Annex F.6): after the independent
    /// substreams, a JOC stream carries `flag_ec3_extension_type_a` and a non-zero
    /// `complexity_index_type_a` (the object count).
    static func isJOC(dec3 record: Data) -> Bool {
        var bytes = [UInt8](record)
        if bytes.count >= 8, String(decoding: bytes[4..<8], as: UTF8.self) == "dec3" {
            bytes.removeFirst(8)
        }
        guard bytes.count >= 2 else { return false }
        let independentSubstreams = Int(bytes[1] & 0b111) + 1  // data_rate(13) | num_ind_sub(3)
        var offset = 2
        for _ in 0..<independentSubstreams {
            // fscod(2) bsid(5) | reserved asvc bsmod(3) acmod(3) lfeon | reserved(3) num_dep_sub(4) chan_loc(9) or reserved(1)
            guard bytes.count >= offset + 3 else { return false }
            let dependentSubstreams = Int(bytes[offset + 2] >> 1 & 0b1111)
            offset += dependentSubstreams > 0 ? 4 : 3
        }
        guard bytes.count >= offset + 2 else { return false }
        return bytes[offset] & 1 == 1 && bytes[offset + 1] > 0
    }

    static func channelLabel(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 3: "3.0"
        case 4: "4.0"
        case 5: "5.0"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }
}
