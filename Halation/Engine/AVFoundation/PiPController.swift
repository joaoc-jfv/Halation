import AVFoundation
import AVKit

/// Picture in Picture for an `AVPlayerLayer`. Nil when the system doesn't support it.
@MainActor
final class PiPController: NSObject, AVPictureInPictureControllerDelegate {
    private let controller: AVPictureInPictureController
    private let onChange: @MainActor (Bool) -> Void

    init?(playerLayer: AVPlayerLayer, onChange: @escaping @MainActor (Bool) -> Void) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: playerLayer)
        else { return nil }
        self.controller = controller
        self.onChange = onChange
        super.init()
        controller.delegate = self
    }

    func toggle() {
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onChange(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onChange(false) }
    }
}
