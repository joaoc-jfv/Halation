import CoreMedia

/// Readable names for the color metadata CoreMedia reports as constants.
enum ColorDescription {
    /// CoreMedia's name for a primaries name as FFmpeg spells it (`bt2020`), or the FFmpeg name if there is no match.
    static func coreMediaPrimaries(fromFFmpeg name: String?) -> String? {
        guard let name else { return nil }
        let names: [String: CFString] = [
            "bt709": kCMFormatDescriptionColorPrimaries_ITU_R_709_2, "bt2020": kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            "smpte432": kCMFormatDescriptionColorPrimaries_P3_D65, "smpte431": kCMFormatDescriptionColorPrimaries_DCI_P3,
            "smpte170m": kCMFormatDescriptionColorPrimaries_SMPTE_C, "smpte240m": kCMFormatDescriptionColorPrimaries_SMPTE_C,
        ]
        return names[name].map { $0 as String } ?? name
    }

    /// CoreMedia's name for a transfer function as FFmpeg spells it (`smpte2084`), or the FFmpeg name if there is no match.
    static func coreMediaTransfer(fromFFmpeg name: String?) -> String? {
        guard let name else { return nil }
        let names: [String: CFString] = [
            "bt709": kCMFormatDescriptionTransferFunction_ITU_R_709_2, "smpte2084": kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            "arib-std-b67": kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, "bt2020-10": kCMFormatDescriptionTransferFunction_ITU_R_2020,
            "bt2020-12": kCMFormatDescriptionTransferFunction_ITU_R_2020, "smpte240m": kCMFormatDescriptionTransferFunction_SMPTE_240M_1995,
            "iec61966-2-1": kCMFormatDescriptionTransferFunction_sRGB, "linear": kCMFormatDescriptionTransferFunction_Linear,
        ]
        return names[name].map { $0 as String } ?? name
    }

    static func primaries(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let names: [(CFString, String)] = [
            (kCMFormatDescriptionColorPrimaries_ITU_R_709_2, "BT.709"),
            (kCMFormatDescriptionColorPrimaries_ITU_R_2020, "BT.2020"),
            (kCMFormatDescriptionColorPrimaries_P3_D65, "Display P3"),
            (kCMFormatDescriptionColorPrimaries_DCI_P3, "DCI-P3"),
            (kCMFormatDescriptionColorPrimaries_SMPTE_C, "SMPTE-C"),
            (kCMFormatDescriptionColorPrimaries_EBU_3213, "EBU 3213"),
        ]
        return names.first { $0.0 as String == raw }?.1 ?? raw
    }

    static func transfer(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let names: [(CFString, String)] = [
            (kCMFormatDescriptionTransferFunction_ITU_R_709_2, "BT.709"),
            (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, "PQ (SMPTE ST 2084)"),
            (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, "HLG"),
            (kCMFormatDescriptionTransferFunction_ITU_R_2020, "BT.2020"),
            (kCMFormatDescriptionTransferFunction_SMPTE_240M_1995, "SMPTE 240M"),
            (kCMFormatDescriptionTransferFunction_sRGB, "sRGB"),
            (kCMFormatDescriptionTransferFunction_Linear, "Linear"),
        ]
        return names.first { $0.0 as String == raw }?.1 ?? raw
    }
}
