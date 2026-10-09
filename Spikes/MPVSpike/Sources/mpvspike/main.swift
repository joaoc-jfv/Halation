import AppKit
import Libmpv

// mpvspike <file> [--hdr] [--seconds N] [--shot path] [--vo gpu-next|gpu] [--sid N] [--aid N]
// Opens a window, plays the file with libmpv and prints what mpv reports.

final class MetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to complete a presentation, which flickers; ignore that.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }
    // EDR must be switched on from the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: mpvspike <file> [--hdr] [--seconds N] [--shot path]"); exit(2) }
let file = args[1]
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let hdr = args.contains("--hdr")
let seconds = Double(option("--seconds") ?? "12") ?? 12
let vo = option("--vo") ?? "gpu-next"

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "mpvspike"
let layer = MetalLayer()
layer.contentsScale = window.backingScaleFactor
layer.framebufferOnly = true
layer.backgroundColor = NSColor.black.cgColor
let view = NSView(frame: window.contentView!.bounds)
view.autoresizingMask = [.width, .height]
view.layer = layer
view.wantsLayer = true
window.contentView = view
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
layer.frame = view.bounds
layer.drawableSize = CGSize(width: view.bounds.width * window.backingScaleFactor, height: view.bounds.height * window.backingScaleFactor)

let mpv = mpv_create()!
func check(_ code: Int32, _ what: String) { if code < 0 { print("mpv error \(code) \(String(cString: mpv_error_string(code))) at \(what)") } }
check(mpv_request_log_messages(mpv, "warn"), "log")
var layerPointer = unsafeBitCast(layer, to: Int64.self)
check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPointer), "wid")
for (key, value) in [("vo", vo), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"), ("hwdec", "videotoolbox"), ("ytdl", "no"),
                     ("target-colorspace-hint", hdr ? "yes" : "no"), ("keep-open", "yes")] {
    check(mpv_set_option_string(mpv, key, value), key)
}
if let sid = option("--sid") { check(mpv_set_option_string(mpv, "sid", sid), "sid") }
if let aid = option("--aid") { check(mpv_set_option_string(mpv, "aid", aid), "aid") }
check(mpv_initialize(mpv), "initialize")

func property(_ name: String) -> String {
    guard let c = mpv_get_property_string(mpv, name) else { return "-" }
    defer { mpv_free(c) }
    return String(cString: c)
}
func command(_ parts: [String]) {
    var cargs: [UnsafePointer<CChar>?] = parts.map { UnsafePointer(strdup($0)) } + [nil]
    defer { for p in cargs { if let p { free(UnsafeMutablePointer(mutating: p)) } } }
    check(mpv_command(mpv, &cargs), parts[0])
}

// Drain events (logs, end of file) on a thread.
let events = Thread {
    while true {
        guard let event = mpv_wait_event(mpv, 0.5) else { continue }
        switch event.pointee.event_id {
        case MPV_EVENT_LOG_MESSAGE:
            let message = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            print("[mpv] \(String(cString: message.prefix)): \(String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines))")
        case MPV_EVENT_END_FILE: print("[mpv] end of file")
        case MPV_EVENT_FILE_LOADED: print("[mpv] file loaded")
        case MPV_EVENT_SHUTDOWN: return
        default: break
        }
    }
}
events.start()

command(["loadfile", file, "replace"])
let started = Date()
let report = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let screen = window.screen ?? NSScreen.main!
    print(String(format: "t=%@ pause=%@ hwdec=%@ codec=%@ %@x%@ fps=%@ dropped=%@ primaries=%@ gamma=%@ sig-peak=%@ edr=%.2f cpu-vo=%@",
                 property("time-pos"), property("pause"), property("hwdec-current"), property("video-codec"),
                 property("video-params/w"), property("video-params/h"), property("estimated-vf-fps"), property("frame-drop-count"),
                 property("video-params/primaries"), property("video-params/gamma"), property("video-params/sig-peak"),
                 screen.maximumExtendedDynamicRangeColorComponentValue, property("current-vo")))
    print("  audio: \(property("audio-codec-name")) ch=\(property("audio-params/channel-count")) tracks=\(property("track-list/count"))")
}
_ = report
DispatchQueue.main.asyncAfter(deadline: .now() + seconds - 1) {
    if let path = option("--shot") { command(["screenshot-to-file", path, "window"]) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("done after \(Date().timeIntervalSince(started)) s")
    command(["quit"])
    exit(0)
}
app.run()
