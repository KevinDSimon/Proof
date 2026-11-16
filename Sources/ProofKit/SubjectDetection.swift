import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Finds a photo's main subject with Vision's foreground instance mask, for a Subject mask: every
/// foreground object Vision separates from the background, together.
public enum SubjectDetection {
    /// The subject in `image`, the whole uncropped photo, as a mask of the same size. `nil` when
    /// Vision finds nothing in front of the background.
    public static func mask(in image: CGImage) async throws -> SubjectMask? {
        try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return png(of: buffer).map(SubjectMask.init(png:))
        }.value
    }

    /// The one-channel float mask Vision gives, as an 8-bit grayscale PNG.
    static func png(of buffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        else { return nil }
        var weights = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width { weights[y * width + x] = row[x] }
        }
        guard let image = BrushRaster.grayImage(weights, width: width, height: height) else { return nil }
        return png(of: image)
    }

    static func png(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
