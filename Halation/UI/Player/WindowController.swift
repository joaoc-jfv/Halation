import AppKit
import SwiftUI

/// Window chrome, sizing and full screen for the player window.
@MainActor
final class WindowController {
    private weak var window: NSWindow?

    func configure(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    /// Fades the traffic lights with the player controls.
    func setChromeVisible(_ visible: Bool) {
        guard let window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    func exitFullScreen() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    /// Resizes the window to fit a video, keeping its center and staying on screen.
    func fit(toVideoSize videoSize: CGSize) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let content = WindowSizing.contentSize(forVideo: videoSize, in: visible.size)
        // Whatever chrome the window adds around its content view (none with a full-size content view).
        let chrome = CGSize(
            width: window.frame.width - (window.contentView?.bounds.width ?? window.frame.width),
            height: window.frame.height - (window.contentView?.bounds.height ?? window.frame.height)
        )
        let size = CGSize(width: content.width + chrome.width, height: content.height + chrome.height)
        let frame = NSRect(
            x: min(max(window.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(window.frame.midY - size.height / 2, visible.minY), visible.maxY - size.height),
            width: size.width,
            height: size.height
        )
        window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

/// Reports the hosting window once the view is in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            guard let window, let onWindow else { return }
            Task { @MainActor in onWindow(window) }
        }
    }
}
