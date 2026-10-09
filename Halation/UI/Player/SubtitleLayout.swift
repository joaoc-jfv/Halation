import CoreGraphics

enum SubtitleLayout {
    /// Where the video is drawn inside `container` when it is aspect-fit. Without a video size,
    /// the whole container.
    static func videoRect(in container: CGSize, videoSize: CGSize?) -> CGRect {
        guard let videoSize, videoSize.width > 0, videoSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    /// Distance from the bottom of the video to the bottom of the subtitle block. Subtitles sit 6% up,
    /// plus the user's offset, and lift clear of the control bar while it shows.
    static func bottomInset(
        videoRect: CGRect, container: CGSize, style: SubtitleStyle,
        controlsVisible: Bool, controlsClearance: CGFloat = 100
    ) -> CGFloat {
        let base = videoRect.height * (0.06 + style.verticalOffset)
        guard controlsVisible else { return base }
        // Letterbox bars below the video already keep some of the clearance.
        let spaceBelowVideo = container.height - videoRect.maxY
        return max(base, controlsClearance - spaceBelowVideo)
    }
}
