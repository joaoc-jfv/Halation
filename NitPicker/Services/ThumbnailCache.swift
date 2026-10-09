import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Poster frames for the welcome screen, kept as small JPEGs in the app's caches folder.
@MainActor
final class ThumbnailCache {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Posters", isDirectory: true)
    }

    func fileURL(forPath path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("jpg")
    }

    func save(_ image: CGImage, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fileURL(forPath: url.standardizedFileURL.path)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    func image(forPath path: String) -> NSImage? {
        NSImage(contentsOf: fileURL(forPath: path))
    }

    func remove(forPath path: String) {
        try? FileManager.default.removeItem(at: fileURL(forPath: path))
    }
}
