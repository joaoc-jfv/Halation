import Foundation

struct InfoRow: Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

struct InfoSection: Equatable, Identifiable {
    var title: String
    var rows: [InfoRow]
    var id: String { title }
}

/// What the expanded info panel shows (PLAN.md §6). Pure, so the wording is tested.
enum InfoSections {
    static func build(
        fileName: String, info: MediaInfo, audio: MediaTrack?, outputMode: AudioOutputMode,
        isHDRPlaybackEligible: Bool, rate: Float
    ) -> [InfoSection] {
        var sections: [InfoSection] = []

        sections.append(InfoSection(title: "File", rows: [
            InfoRow(label: "Name", value: fileName),
            InfoRow(label: "Container", value: info.container),
        ]))

        var video: [InfoRow] = []
        if let codec = info.videoCodec { video.append(InfoRow(label: "Codec", value: codec)) }
        if let size = info.resolution { video.append(InfoRow(label: "Resolution", value: InfoFormatting.size(size))) }
        if let display = info.displaySize, let coded = info.resolution,
           abs(display.width - coded.width) > 1 || abs(display.height - coded.height) > 1 {
            video.append(InfoRow(label: "Display size", value: InfoFormatting.size(display)))
        }
        if let fps = info.frameRate { video.append(InfoRow(label: "Frame rate", value: InfoFormatting.frameRate(fps))) }
        if let bitrate = info.bitrate { video.append(InfoRow(label: "Bit rate", value: InfoFormatting.bitrate(bitrate))) }
        if !video.isEmpty { sections.append(InfoSection(title: "Video", rows: video)) }

        var hdr = [InfoRow(label: "Format", value: info.hdr.detailName)]
        if let primaries = ColorDescription.primaries(info.colorPrimaries) { hdr.append(InfoRow(label: "Color primaries", value: primaries)) }
        if let transfer = ColorDescription.transfer(info.transferFunction) { hdr.append(InfoRow(label: "Transfer", value: transfer)) }
        if let note = info.hdrNote { hdr.append(InfoRow(label: "Note", value: note)) }
        if info.hdr.isHDR {
            hdr.append(InfoRow(
                label: "This display",
                value: isHDRPlaybackEligible ? "Can show HDR" : "Can't show HDR right now"
            ))
        }
        sections.append(InfoSection(title: "HDR", rows: hdr))

        var audioRows: [InfoRow] = []
        if let audio {
            audioRows.append(InfoRow(label: "Track", value: audio.displayName))
            if let codec = audio.codec ?? info.audioCodec { audioRows.append(InfoRow(label: "Codec", value: codec)) }
            if let layout = audio.channelLabel { audioRows.append(InfoRow(label: "Layout", value: layout)) }
            audioRows.append(InfoRow(label: "Spatial Audio track", value: audio.isSpatial ? "Yes" : "No"))
        } else if let codec = info.audioCodec {
            audioRows.append(InfoRow(label: "Codec", value: codec))
        }
        if !audioRows.isEmpty {
            audioRows.append(InfoRow(label: "Output", value: outputMode == .spatial ? "Spatial Audio" : "Stereo"))
            sections.append(InfoSection(title: "Audio", rows: audioRows))
        }

        sections.append(InfoSection(title: "Playback", rows: [
            InfoRow(label: "Engine", value: info.engineName),
            InfoRow(label: "Speed", value: PlaybackSpeed.label(for: rate)),
        ]))
        return sections
    }
}
