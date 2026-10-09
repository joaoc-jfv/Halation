import CoreMedia

enum HDRDetection {
    /// Classifies a video track from its format description (PLAN.md §5.1).
    /// Dolby Vision wins over the base layer's transfer function, since a profile 8.1
    /// file is also valid HDR10.
    static func format(of description: CMFormatDescription) -> HDRFormat {
        if let dolbyVision = dolbyVision(in: description) { return dolbyVision }
        switch transferFunction(of: description) {
        case let tf? where tf == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String: return .hdr10
        case let tf? where tf == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String: return .hlg
        default: return .sdr
        }
    }

    private static func transferFunction(of description: CMFormatDescription) -> String? {
        CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
    }

    private static let dolbyVisionSubtypes: Set<String> = ["dvh1", "dvhe", "dav1"]

    private static func dolbyVision(in description: CMFormatDescription) -> HDRFormat? {
        let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any]
        let config = (atoms?["dvcC"] ?? atoms?["dvvC"]) as? Data
        let hasDolbyVisionSubtype = dolbyVisionSubtypes.contains(CodecNames.fourCC(description.mediaSubType.rawValue))
        guard config != nil || hasDolbyVisionSubtype else { return nil }
        guard let record = config.map(configurationRecord(from:)), record.count >= 5 else {
            return .dolbyVision(profile: nil, compatibilityID: nil)
        }
        // dv_version_major, dv_version_minor, dv_profile(7) | dv_level(6), flags(5), dv_bl_signal_compatibility_id(4)
        let bytes = [UInt8](record)
        return .dolbyVision(profile: Int(bytes[2] >> 1), compatibilityID: Int(bytes[4] >> 4))
    }

    /// Drops a leading 8-byte box header if the atom data still carries one.
    private static func configurationRecord(from data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              ["dvcC", "dvvC"].contains(String(decoding: bytes[4..<8], as: UTF8.self))
        else { return data }
        return Data(bytes[8...])
    }
}
