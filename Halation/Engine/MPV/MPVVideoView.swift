import AppKit

private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

/// The layer mpv draws into (Vulkan on Metal through MoltenVK). MPVKit's demo needs the same two workarounds.
final class MPVMetalLayer: CAMetalLayer {
    /// MoltenVK sets the drawable size to 1x1 to complete a presentation, which flickers and can leave it there.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1, Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }

    private func setEDR(_ value: Bool) { super.wantsExtendedDynamicRangeContent = value }

    /// The screen only enters its HDR mode when this is switched on from the main thread, and mpv does it from its own. Hand
    /// it over without waiting: mpv's video thread blocking on the main thread while the main thread waits on mpv's core (to read
    /// a property, say) is a deadlock, which MPVKit's own demo, with its `main.sync`, runs into.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                let setter = Unchecked(value: setEDR)
                DispatchQueue.main.async { setter.value(newValue) }
            }
        }
    }
}

/// View hosting the mpv layer. Keeps the layer's drawable at the view's size in pixels.
final class MPVVideoView: NSView {
    let metalLayer = MPVMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer = metalLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }

    private func resizeDrawable() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
