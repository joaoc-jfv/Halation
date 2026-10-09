import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenPanel {
    static func chooseVideo(then handler: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
            + ["mkv", "webm"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handler(url)
        }
    }
}
