import SwiftUI

/// Hosts the active engine's video view. Milestone 1.3 adds window sizing and crop containers.
struct VideoSurfaceView: NSViewRepresentable {
    let videoView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard videoView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)
    }
}
