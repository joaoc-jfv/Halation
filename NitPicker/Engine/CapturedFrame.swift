import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One frame taken from the playing video, for a screenshot (PLAN.md, phase 4).
enum CapturedFrame: @unchecked Sendable {
    /// An ordinary picture.
    case sdr(CGImage)
    /// A decoded frame that still carries its HDR colour (10-bit, PQ or HLG), so it can be saved as HDR.
    case hdr(CVPixelBuffer, transfer: HDRTransfer)

    enum HDRTransfer: Sendable {
        case pq, hlg
    }

    /// PQ and HLG from the buffer's own colour tags; nil for an SDR buffer.
    static func hdrTransfer(of buffer: CVPixelBuffer) -> HDRTransfer? {
        guard let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String else { return nil }
        if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        return nil
    }
}

/// Turns a captured frame into a file's bytes: HDR frames become 10-bit HEIC in their own colour space (so they stay HDR in
/// Photos and Preview), everything else becomes a PNG. Core Image is used here, for stills only; the playback path never touches it.
enum ScreenshotEncoder {
    struct Output {
        var data: Data
        var fileExtension: String
        var isHDR: Bool
    }

    static func encode(_ frame: CapturedFrame) -> Output? {
        let context = CIContext()
        switch frame {
        case .sdr(let image):
            return png(image).map { Output(data: $0, fileExtension: "png", isHDR: false) }
        case .hdr(let buffer, let transfer):
            let image = CIImage(cvPixelBuffer: buffer)
            let name = transfer == .pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG
            if let space = CGColorSpace(name: name),
               let data = try? context.heif10Representation(of: image, colorSpace: space, options: [:]) {
                return Output(data: data, fileExtension: "heic", isHDR: true)
            }
            // A machine that can't write HDR HEIC still gets a picture.
            guard let sdr = context.createCGImage(image, from: image.extent), let data = png(sdr) else { return nil }
            return Output(data: data, fileExtension: "png", isHDR: false)
        }
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
