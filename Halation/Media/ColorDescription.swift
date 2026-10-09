import CoreMedia

/// Readable names for the color metadata CoreMedia reports as constants.
enum ColorDescription {
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
