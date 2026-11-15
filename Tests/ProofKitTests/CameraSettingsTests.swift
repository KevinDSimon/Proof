import CoreGraphics
import Foundation
import ImageIO
import simd
import Testing
import UniformTypeIdentifiers
@testable import ProofKit

/// The XMP a Leica M11 embeds in its DNGs, taken from a real file. That photo was shot with
/// the perspective correction recorded but not marked to apply automatically.
private let leicaM11XMP = try! String(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Samples/leica-m11-perspective.xmp"), encoding: .utf8)

/// The M11 sample with the correction marked to apply automatically, as the camera writes it when
/// Perspective Control is on.
private let leicaM11AutomaticXMP = leicaM11XMP.replacingOccurrences(
    of: #"xmpDSA:ApplyAutomatically="False""#, with: #"xmpDSA:ApplyAutomatically="True""#)

private func metadata(_ xmp: String) throws -> CGImageMetadata {
    try #require(CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData))
}

/// The properties ImageIO reads from a DNG with `DefaultUserCrop`, as from a Leica Q's 9504 × 6320 sensor.
private func properties(userCrop: [Double], orientation: Int = 1) -> [CFString: Any] {
    [kCGImagePropertyPixelWidth: 9504, kCGImagePropertyPixelHeight: 6320,
     kCGImagePropertyOrientation: orientation,
     kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGDefaultUserCrop: userCrop.map { NSNumber(value: $0) }]]
}

struct CameraSettingsTests {
    // MARK: Perspective

    @Test("A Leica correction not marked to apply automatically is left off")
    func leicaNotAutomatic() throws {
        let settings = CameraSettings(properties: [:], metadata: try metadata(leicaM11XMP))
        #expect(settings == CameraSettings())
        #expect(EditRecipe(asShot: settings).isNeutral)
    }

    @Test("A Leica correction marked to apply automatically becomes Vertical and Rotate")
    func leicaAutomatic() throws {
        let transform = try #require(CameraSettings(properties: [:], metadata: try metadata(leicaM11AutomaticXMP)).transform)
        // Pitch 0.136° up through a 35 mm lens, as the 43 mm lens Proof assumes: the top widens.
        let tilt = atan(tan(0.136 * .pi / 180) * CameraSettings.fullFrameDiagonal / 35) * 180 / .pi
        #expect(abs(transform.vertical - -tilt / 45 * 100) < 1e-6)
        #expect(transform.vertical < 0)
        #expect(abs(transform.rotate - -0.567) < 1e-6)
        #expect(transform.horizontal == 0)
        #expect(transform.constrainCrop)
    }

    @Test("The Leica correction frames the photo as the corners the camera recorded do")
    func leicaMatchesCameraCorners() throws {
        let transform = try #require(CameraSettings(properties: [:], metadata: try metadata(leicaM11AutomaticXMP)).transform)
        let size = CGSize(width: 9528, height: 6328)
        let inverse = transform.homography(for: size).inverse
        // The frame's corners, back on the uncorrected photo, from 0 to 1.
        let quad = PerspectiveTransform.corners(of: size).map {
            let p = PerspectiveTransform.apply(inverse, to: $0)
            return SIMD2(p.x / size.width, p.y / size.height)
        }
        // Top left, top right, bottom right, bottom left, as the camera recorded them.
        let camera = [SIMD2(0.0110372696, 0.0001638428), SIMD2(0.9954617023, 0.0147771406),
                      SIMD2(0.9897516965, 1.0), SIMD2(0.0037473079, 0.9853632450)]
        func shape(_ q: [SIMD2<Double>]) -> (topSlope: Double, leftSlope: Double, topOverBottom: Double) {
            ((q[1].y - q[0].y) / (q[1].x - q[0].x), (q[3].x - q[0].x) / (q[3].y - q[0].y),
             (q[1].x - q[0].x) / (q[2].x - q[3].x))
        }
        let (ours, theirs) = (shape(quad), shape(camera))
        // The turn shows in the slope of the edges, the tilt in the top being narrower than the bottom.
        #expect(abs(ours.topSlope - theirs.topSlope) < 0.0002)
        #expect(abs(ours.leftSlope - theirs.leftSlope) < 0.0002)
        #expect(abs(ours.topOverBottom - theirs.topOverBottom) < 0.0002)
    }

    @Test("A Leica correction the camera already applied to the image isn't applied again")
    func leicaAlreadyApplied() throws {
        let xmp = leicaM11AutomaticXMP.replacingOccurrences(
            of: #"xmpDSA:CorrectionAlreadyApplied="False""#, with: #"xmpDSA:CorrectionAlreadyApplied="True""#)
        #expect(CameraSettings(properties: [:], metadata: try metadata(xmp)).transform == nil)
    }

    // MARK: Crop

    @Test("A digital-zoom framing in DefaultUserCrop becomes the crop, locked to its shape")
    func userCrop() throws {
        // A 50 mm framing on a 28 mm lens.
        let crop = try #require(CameraSettings(properties: properties(userCrop: [0.22, 0.22, 0.78, 0.78]), metadata: nil).crop)
        #expect(abs(crop.x - 0.22) < 1e-9 && abs(crop.y - 0.22) < 1e-9)
        #expect(abs(crop.width - 0.56) < 1e-9 && abs(crop.height - 0.56) < 1e-9)
        #expect(crop.angle == 0 && crop.rotation == 0)
        #expect(try #require(crop.aspect).matches(AspectRatio(9504, 6320)))
    }

    @Test("DefaultUserCrop in a photo the camera held upright follows the turn")
    func userCropTurned() throws {
        // Orientation 6: the stored image turns a quarter clockwise, so its top becomes the right.
        let crop = try #require(CameraSettings(properties: properties(userCrop: [0.1, 0.2, 0.5, 0.6], orientation: 6), metadata: nil).crop)
        #expect(abs(crop.x - 0.5) < 1e-9 && abs(crop.width - 0.4) < 1e-9)
        #expect(abs(crop.y - 0.2) < 1e-9 && abs(crop.height - 0.4) < 1e-9)
        #expect(try #require(crop.aspect).matches(AspectRatio(0.4 * 6320, 0.4 * 9504)))
    }

    @Test("A DefaultUserCrop of the whole photo, or an invalid one, is no crop")
    func noUserCrop() {
        #expect(CameraSettings(properties: properties(userCrop: [0, 0, 1, 1]), metadata: nil).crop == nil)
        #expect(CameraSettings(properties: properties(userCrop: [0.6, 0.2, 0.4, 0.8]), metadata: nil).crop == nil)
        #expect(CameraSettings(properties: properties(userCrop: [0.1, 0.1]), metadata: nil).crop == nil)
        #expect(CameraSettings(properties: [:], metadata: nil) == CameraSettings())
    }

    // MARK: The edit a photo opens with

    @Test("A photo opens with the camera's crop and correction, and changing them is an edit")
    func asShotEdit() throws {
        let camera = CameraSettings(crop: Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                    transform: PerspectiveTransform(rotate: 1))
        let asShot = EditRecipe(asShot: camera)
        #expect(asShot.crop == camera.crop && asShot.transform == camera.transform)
        #expect(asShot.isAsShot(asShot))
        #expect(!EditRecipe().isAsShot(asShot))
        #expect(EditRecipe().isAsShot(EditRecipe()))
    }

    @Test("Saving the edit a photo opens with writes no sidecar; saving a reset one does")
    func asShotSidecar() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("L1000001.DNG")
        try Data("raw".utf8).write(to: photo)
        let asShot = EditRecipe(asShot: CameraSettings(crop: Crop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)))
        #expect(try Sidecar.save(asShot, for: photo, over: nil, asShot: asShot) == nil)
        #expect(try Sidecar.read(for: photo) == nil)
        // Back to the whole photo: the sidecar keeps the camera's crop from coming back.
        let saved = try Sidecar.save(EditRecipe(), for: photo, over: nil, asShot: asShot)
        #expect(try Sidecar.read(for: photo)?.recipe == EditRecipe())
        // And returning to the camera's crop removes it again.
        #expect(try Sidecar.save(asShot, for: photo, over: saved, asShot: asShot) == nil)
        #expect(try Sidecar.read(for: photo) == nil)
    }

    @Test("The settings are read from the file's own metadata, which is never written to")
    func readsFile() throws {
        let photo = try makePhoto(xmp: leicaM11AutomaticXMP)
        let before = try Data(contentsOf: photo)
        let settings = CameraSettings(contentsOf: photo)
        #expect(settings.transform == CameraSettings(properties: [:], metadata: try metadata(leicaM11AutomaticXMP)).transform)
        #expect(settings.crop == nil)
        #expect(try Data(contentsOf: photo) == before)
    }

    // MARK: Thumbnails

    @Test("An unedited photo's thumbnail shows the camera's settings, and a reset one the original")
    func thumbnails() async throws {
        let photo = try makePhoto(xmp: leicaM11AutomaticXMP)
        let asShot = EditRecipe(asShot: CameraSettings(contentsOf: photo))
        let rendered = Rendered()
        let cache = ThumbnailCache(directory: photo.deletingLastPathComponent().appendingPathComponent("Cache"),
                                   renderEdit: { _, edit in await rendered.add(edit); return Self.gray() })
        _ = try #require(await cache.thumbnail(for: photo, edit: nil))
        #expect(await rendered.edits == [asShot])
        // The edit it opens with shares that thumbnail.
        #expect(cache.cachedThumbnail(for: photo, edit: asShot) != nil)
        // A neutral edit is the original, from the preview, not rendered.
        #expect(cache.cachedThumbnail(for: photo, edit: EditRecipe()) == nil)
        _ = try #require(await cache.thumbnail(for: photo, edit: EditRecipe()))
        #expect(await rendered.edits == [asShot])
    }

    actor Rendered {
        var edits: [EditRecipe] = []
        func add(_ edit: EditRecipe) { edits.append(edit) }
    }

    static func gray() -> CGImage? {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(gray: 0.5, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context?.makeImage()
    }

    /// A TIFF with `xmp` stands in for a RAW file, since RAW files can't be committed.
    func makePhoto(xmp: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CameraSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("L1000002.TIF")
        let image = try #require(Self.gray())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, image, try metadata(xmp), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
