import CoreGraphics

enum WindowSizing {
    static let minimumWidth: CGFloat = 640
    static let maximumScreenFraction: CGFloat = 0.8
    static let fallbackSize = CGSize(width: 960, height: 540)

    /// Content size for a video: its native size, at least `minimumWidth` wide, and never
    /// more than 80% of the available screen area. The video's aspect ratio is kept.
    static func contentSize(forVideo video: CGSize, in available: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0, available.width > 0, available.height > 0 else {
            return fallbackSize
        }
        let largestScale = min(
            available.width * maximumScreenFraction / video.width,
            available.height * maximumScreenFraction / video.height
        )
        let scale = min(largestScale, max(1, minimumWidth / video.width))
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
    }
}
