import CoreGraphics
import Foundation

/// Finds the black bars baked into a picture (letterbox above and below, pillarbox at the sides) from a few stills of it
/// (PLAN.md, phase 4). A bar has to be black in every still, so a dark scene can only make the result more cautious.
enum BlackBarDetector {
    /// How much of the picture each bar takes, as a fraction of its height (top, bottom) or width (left, right).
    struct Bars: Equatable, Sendable {
        var top = 0.0, bottom = 0.0, left = 0.0, right = 0.0

        var isNone: Bool { self == Bars() }
    }

    /// Luma (0...255) up to which a pixel counts as black. Limited-range video has its black at 16.
    static let blackLevel = 28
    /// Bars thinner than this fraction of the picture aren't worth cropping.
    static let minimumBar = 0.02
    /// A still with less picture than this (a fade, a black frame) says nothing.
    static let minimumContent = 0.04

    /// The bars in one still, or nil when it is (nearly) all black.
    static func bars(in image: CGImage) -> Bars? {
        let scale = min(1, 200.0 / Double(max(image.width, image.height)))
        let width = max(8, Int((Double(image.width) * scale).rounded()))
        let height = max(8, Int((Double(image.height) * scale).rounded()))
        var luma = [UInt8](repeating: 0, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return bars(luma: luma, width: width, height: height)
    }

    /// The bars in a grayscale picture, row by row from the top.
    static func bars(luma: [UInt8], width: Int, height: Int) -> Bars? {
        // A row or column is picture when more than about 2% of its pixels are brighter than black (so a stray bright pixel
        // or a logo corner in a bar doesn't count, while thin subtitles in a bar don't either once the frames are combined).
        func isPicture(_ values: some Sequence<UInt8>, count: Int) -> Bool {
            var bright = 0
            for value in values where Int(value) > blackLevel { bright += 1 }
            return Double(bright) / Double(count) > 0.02
        }
        let rows = (0..<height).map { row in isPicture(luma[(row * width)..<((row + 1) * width)], count: width) }
        let columns = (0..<width).map { column in isPicture((0..<height).lazy.map { luma[$0 * width + column] }, count: height) }
        guard let firstRow = rows.firstIndex(of: true), let lastRow = rows.lastIndex(of: true),
              let firstColumn = columns.firstIndex(of: true), let lastColumn = columns.lastIndex(of: true)
        else { return nil }
        let content = Double(lastRow - firstRow + 1) / Double(height) * Double(lastColumn - firstColumn + 1) / Double(width)
        guard content >= minimumContent else { return nil }
        return Bars(
            top: Double(firstRow) / Double(height), bottom: Double(height - 1 - lastRow) / Double(height),
            left: Double(firstColumn) / Double(width), right: Double(width - 1 - lastColumn) / Double(width)
        )
    }

    /// The bars every still agrees on: the smallest of each side. Nil when fewer than `minimumStills` had any picture.
    static func commonBars(_ stills: [Bars?], minimumStills: Int = 4) -> Bars? {
        let usable = stills.compactMap { $0 }
        guard usable.count >= minimumStills else { return nil }
        return Bars(
            top: usable.map(\.top).min()!, bottom: usable.map(\.bottom).min()!,
            left: usable.map(\.left).min()!, right: usable.map(\.right).min()!
        )
    }

    /// The aspect ratio of what is left after cutting the bars off a picture shown at `displaySize`. The crop is centred, so only
    /// the thinner bar of each pair counts. Nil when no bar is worth cutting.
    static func cropRatio(bars: Bars, displaySize: CGSize) -> CGFloat? {
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        let vertical = min(bars.top, bars.bottom), horizontal = min(bars.left, bars.right)
        guard vertical >= minimumBar || horizontal >= minimumBar else { return nil }
        let keptHeight = 1 - 2 * (vertical >= minimumBar ? vertical : 0)
        let keptWidth = 1 - 2 * (horizontal >= minimumBar ? horizontal : 0)
        return displaySize.width * keptWidth / (displaySize.height * keptHeight)
    }
}
