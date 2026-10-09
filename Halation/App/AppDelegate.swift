import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A single-window player: closing the window ends playback by quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
