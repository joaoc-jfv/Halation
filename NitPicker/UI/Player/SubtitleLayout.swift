import CoreGraphics

enum SubtitleLayout {
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
