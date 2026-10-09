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

    static func chooseSubtitleFile(then handler: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a subtitle file (SRT or WebVTT)"
        panel.allowedContentTypes = SubtitleLoader.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handler(url)
        }
    }

    /// Asks the user to allow access to a folder, starting at `folder`.
    static func chooseFolder(startingAt folder: URL, then handler: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Allow Access"
        panel.message = "Allow Halation to look for subtitle files in this folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handler(url)
        }
    }
}
