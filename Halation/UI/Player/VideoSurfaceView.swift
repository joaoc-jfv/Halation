import SwiftUI

/// Hosts the active engine's video view inside a clipping container, so aspect overrides, crops and
/// zoom are just frames: no video composition, no Core Image, so HDR and Dolby Vision are untouched.
struct VideoSurfaceView: NSViewRepresentable {
    let videoView: NSView
    var videoSize: CGSize?
    var layout = VideoLayout()
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> SurfaceContainerView {
        SurfaceContainerView()
    }

    func updateNSView(_ container: SurfaceContainerView, context: Context) {
        container.onDoubleClick = onDoubleClick
        container.setVideoView(videoView)
        container.update(videoSize: videoSize, layout: layout)
    }

    final class SurfaceContainerView: NSView {
        var onDoubleClick: () -> Void = {}
        private let clipView = NSView()
        private var videoSize: CGSize?
        private var layoutSpec = VideoLayout()
        private var hasLaidOut = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            clipView.wantsLayer = true
            clipView.layer?.masksToBounds = true
            addSubview(clipView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func setVideoView(_ view: NSView) {
            guard view.superview !== clipView else { return }
            clipView.subviews.forEach { $0.removeFromSuperview() }
            clipView.addSubview(view)
            needsLayout = true
        }

        func update(videoSize: CGSize?, layout: VideoLayout) {
            guard videoSize != self.videoSize || layout != layoutSpec else { return }
            self.videoSize = videoSize
            layoutSpec = layout
            applyPlacement(animated: hasLaidOut)
        }

        override func layout() {
            super.layout()
            applyPlacement(animated: false)
            hasLaidOut = true
        }

        private func applyPlacement(animated: Bool) {
            guard let video = clipView.subviews.first else { return }
            let placement = VideoGeometry.placement(container: bounds.size, videoSize: videoSize, layout: layoutSpec)
            let videoFrame = placement.videoRect.offsetBy(dx: -placement.clipRect.minX, dy: -placement.clipRect.minY)
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if animated, !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    clipView.animator().frame = placement.clipRect
                    video.animator().frame = videoFrame
                }
            } else {
                clipView.frame = placement.clipRect
                video.frame = videoFrame
            }
        }

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
