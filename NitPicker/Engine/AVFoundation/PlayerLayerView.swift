import AVFoundation
import AppKit

/// Layer-backed view whose layer is the `AVPlayerLayer`. No video composition or
/// Core Image in the path, so HDR and Dolby Vision stay intact.
@MainActor
final class PlayerLayerView: NSView {
    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var avPlayerLayer: AVPlayerLayer { playerLayer }

    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
