import CoreGraphics
import Foundation
import ImageIO

/// The crop and perspective correction a camera saves in a RAW file without changing the image
/// data, which `CIRAWFilter` doesn't apply. A photo with no Proof edit opens with them as its edit,
/// editable like any other. See docs/decisions/0035-camera-settings.md.
///
/// - The crop is the DNG `DefaultUserCrop` tag, which the Leica Q writes for its digital-zoom
///   framings while keeping the whole sensor image. It is relative to the DNG default crop,
///   which `CIRAWFilter` has already applied, in the file's stored orientation.
/// - The perspective correction is Leica's Digital Shift Assistant (M11 and later), in the
///   embedded XMP. It is used only when the camera marked it to apply automatically.
public struct CameraSettings: Equatable, Sendable {
    public var crop: Crop?
    public var transform: PerspectiveTransform?

    public init(crop: Crop? = nil, transform: PerspectiveTransform? = nil) {
        self.crop = crop
        self.transform = transform
    }

    /// Reads the settings saved in `url`. Only the file's header and metadata are read. Blocks on
    /// file I/O.
    public init(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { self.init(); return }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        self.init(properties: properties, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    /// The settings in a file's image properties and XMP, as ImageIO reads them.
    public init(properties: [CFString: Any], metadata: CGImageMetadata?) {
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size: CGSize? = {
            guard let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
            return CGSize(width: w, height: h)
        }()
        let userCrop = (dng?[kCGImagePropertyDNGDefaultUserCrop] as? [NSNumber])?.map(\.doubleValue)
        self.init(crop: userCrop.flatMap { Self.crop(fromDefaultUserCrop: $0, orientation: orientation, storedSize: size) },
                  transform: metadata.flatMap(Self.shiftAssistant))
    }

    // MARK: Crop

    /// The crop for a `DefaultUserCrop` of top, left, bottom and right, from 0 to 1, in a file
    /// stored with EXIF `orientation`. `storedSize` is the image's size as stored, used for the
    /// locked ratio. `nil` when the values don't describe a crop.
    static func crop(fromDefaultUserCrop values: [Double], orientation: Int, storedSize: CGSize?) -> Crop? {
        guard values.count == 4 else { return nil }
        let (top, left, bottom, right) = (values[0], values[1], values[2], values[3])
        guard 0 <= top, top < bottom, bottom <= 1, 0 <= left, left < right, right <= 1 else { return nil }
        let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard rect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return nil }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)].map { oriented($0, orientation) }
        let (x0, x1) = (min(corners[0].x, corners[1].x), max(corners[0].x, corners[1].x))
        let (y0, y1) = (min(corners[0].y, corners[1].y), max(corners[0].y, corners[1].y))
        var crop = Crop(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let storedSize, storedSize.width > 0, storedSize.height > 0 {
            let turns = (5...8).contains(orientation)
            let size = turns ? CGSize(width: storedSize.height, height: storedSize.width) : storedSize
            crop.aspect = AspectRatio(crop.width * size.width, crop.height * size.height)
        }
        return crop
    }

    /// Where `point`, from 0 to 1 in the image as stored, shows once EXIF `orientation` is applied.
    static func oriented(_ p: CGPoint, _ orientation: Int) -> CGPoint {
        switch orientation {
        case 2: CGPoint(x: 1 - p.x, y: p.y)
        case 3: CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 4: CGPoint(x: p.x, y: 1 - p.y)
        case 5: CGPoint(x: p.y, y: p.x)
        case 6: CGPoint(x: 1 - p.y, y: p.x)
        case 7: CGPoint(x: 1 - p.y, y: 1 - p.x)
        case 8: CGPoint(x: p.y, y: 1 - p.x)
        default: p
        }
    }

    // MARK: Perspective

    /// The diagonal of a full-frame sensor, in millimeters: the focal length
    /// `PerspectiveTransform` assumes, in full-frame terms.
    static let fullFrameDiagonal = (36.0 * 36.0 + 24.0 * 24.0).squareRoot()

    /// Leica's Digital Shift Assistant, as Transform sliders. `nil` unless the camera marked it to
    /// apply automatically and hasn't applied it to the image data itself.
    ///
    /// The camera records how far it was tilted up (pitch) and turned (roll), in degrees. Pitch
    /// becomes Vertical, at the tilt that makes vertical lines parallel through Proof's assumed
    /// lens rather than the real one, and roll becomes Rotate. The signs were checked against the
    /// crop corners the camera also records.
    static func shiftAssistant(in metadata: CGImageMetadata) -> PerspectiveTransform? {
        func value(_ name: String) -> String? {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmpDSA:\(name)" as CFString) else { return nil }
            return CGImageMetadataTagCopyValue(tag) as? String
        }
        guard value("ApplyAutomatically")?.lowercased() == "true",
              value("CorrectionAlreadyApplied")?.lowercased() != "true",
              let pitch = value("PitchAngle").flatMap(Double.init),
              let roll = value("RollAngle").flatMap(Double.init) else { return nil }
        let focalLength = value("FocalLength35mm").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? fullFrameDiagonal
        let tilt = atan(tan(pitch * .pi / 180) * fullFrameDiagonal / focalLength) * 180 / .pi
        let transform = PerspectiveTransform().with(vertical: -tilt / PerspectiveTransform.maximumTilt * 100,
                                                    horizontal: 0, rotate: roll)
        return transform.isNeutral ? nil : transform
    }
}

extension EditRecipe {
    /// The edit a photo opens with when it has no Proof edit: neutral, with the crop and
    /// perspective correction the camera saved in the file.
    public init(asShot camera: CameraSettings) {
        self.init(transform: camera.transform ?? PerspectiveTransform(), crop: camera.crop)
    }

    /// Whether this edit is where a photo whose camera settings open as `asShot` starts, so it
    /// needs no sidecar. With nothing from the camera, that is any neutral edit.
    public func isAsShot(_ asShot: EditRecipe) -> Bool {
        asShot.isNeutral ? isNeutral : self == asShot
    }
}
