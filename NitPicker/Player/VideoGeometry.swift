import CoreGraphics

/// Where the player layer and its clip go inside the video container.
struct VideoPlacement: Equatable {
    /// The part of the container that shows picture. Everything outside it stays black.
    var clipRect: CGRect
    /// The whole video, in container coordinates. It can extend past `clipRect`, which clips it.
    var videoRect: CGRect
    /// `true` when the layer must stretch the picture to `videoRect` (an aspect override).
    var stretches: Bool
}

enum VideoGeometry {
    /// - Parameters:
    ///   - container: Size of the view holding the video.
    ///   - videoSize: The picture's display size.
    static func placement(container: CGSize, videoSize: CGSize?, layout: VideoLayout) -> VideoPlacement {
        let bounds = CGRect(origin: .zero, size: container)
        guard container.width > 0, container.height > 0,
              let videoSize, videoSize.width > 0, videoSize.height > 0
        else { return VideoPlacement(clipRect: bounds, videoRect: bounds, stretches: false) }

        // The picture after any aspect override, in arbitrary units.
        var picture = videoSize
        if let ratio = layout.aspect.ratio { picture = CGSize(width: videoSize.height * ratio, height: videoSize.height) }

        // The region of it that stays visible: the whole picture, or a centered crop.
        var region = picture
        if let ratio = layout.crop.ratio {
            region = ratio >= picture.width / picture.height
                ? CGSize(width: picture.width, height: picture.width / ratio)
                : CGSize(width: picture.height * ratio, height: picture.height)
        }

        let fitScale = min(container.width / region.width, container.height / region.height)
        let fillScale = max(container.width / region.width, container.height / region.height)
        let scale = layout.zoom == .fit ? fitScale : fillScale

        let clip = layout.zoom == .fit
            ? centered(CGSize(width: region.width * scale, height: region.height * scale), in: container)
            : bounds
        let video = centered(CGSize(width: picture.width * scale, height: picture.height * scale), in: container)
        return VideoPlacement(clipRect: clip, videoRect: video, stretches: layout.aspect != .auto)
    }

    private static func centered(_ size: CGSize, in container: CGSize) -> CGRect {
        CGRect(
            x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }
}
