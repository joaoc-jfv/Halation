import SwiftUI

/// Hosts the active engine's video view. Milestone 1.7 adds the crop container.
struct VideoSurfaceView: NSViewRepresentable {
    let videoView: NSView
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> SurfaceContainerView {
        let container = SurfaceContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: SurfaceContainerView, context: Context) {
        container.onDoubleClick = onDoubleClick
        guard videoView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)
    }

    final class SurfaceContainerView: NSView {
        var onDoubleClick: () -> Void = {}

        // Keep dragging the window by its background working over the video.
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
