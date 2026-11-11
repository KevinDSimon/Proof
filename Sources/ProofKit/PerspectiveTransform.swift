import CoreImage
import CoreImage.CIFilterBuiltins
import simd

/// Perspective correction, as in Lightroom's Transform panel: turns the photo as if the camera had
/// been aimed differently, so lines that converge, such as a building's sides shot from below,
/// become parallel. It acts on the whole photo as the camera oriented it, after the lens
/// corrections and before the crop. See docs/decisions/0025-perspective.md.
///
/// The sliders are the edit. Upright fills them in from lines in the photo and records which mode
/// it used, so the buttons can show it; the sliders stay editable afterward.
public struct PerspectiveTransform: Codable, Equatable, Sendable {
    /// Tilts the photo about a horizontal axis. Negative widens the top, which straightens a
    /// building that leans back because the camera pointed up.
    public var vertical: Double = 0
    /// Tilts the photo about a vertical axis. Negative widens the left side.
    public var horizontal: Double = 0
    /// Turns the photo, in degrees clockwise.
    public var rotate: Double = 0
    /// Stretches the photo across (positive) or upward (negative), to undo the stretch a strong
    /// correction leaves.
    public var aspect: Double = 0
    /// Percent, about the center.
    public var scale: Double = 100
    /// Moves the photo right (positive) or left, in percent of a quarter of its width.
    public var xOffset: Double = 0
    /// Moves the photo up (positive) or down, in percent of a quarter of its height.
    public var yOffset: Double = 0
    /// Enlarges the corrected photo so it fills the frame, leaving no empty edges.
    public var constrainCrop: Bool = true
    /// The Upright mode that last set the sliders, or `nil` when none has.
    public var upright: UprightMode?
    /// The lines Guided straightened, kept so they can be changed later.
    public var guides: [GuideLine] = []

    public static let tiltRange = -100.0...100.0
    public static let rotateRange = -10.0...10.0
    public static let aspectRange = -100.0...100.0
    public static let scaleRange = 50.0...150.0
    public static let offsetRange = -100.0...100.0

    /// The tilt, in degrees, with Vertical or Horizontal at 100.
    static let maximumTilt = 45.0

    private enum CodingKeys: String, CodingKey {
        case vertical, horizontal, rotate, aspect, scale, xOffset, yOffset, constrainCrop, upright, guides
    }

    public init(vertical: Double = 0, horizontal: Double = 0, rotate: Double = 0, aspect: Double = 0,
                scale: Double = 100, xOffset: Double = 0, yOffset: Double = 0, constrainCrop: Bool = true,
                upright: UprightMode? = nil, guides: [GuideLine] = []) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.rotate = rotate
        self.aspect = aspect
        self.scale = scale
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.constrainCrop = constrainCrop
        self.upright = upright
        self.guides = guides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vertical = try c.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
        horizontal = try c.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
        rotate = try c.decodeIfPresent(Double.self, forKey: .rotate) ?? 0
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 100
        xOffset = try c.decodeIfPresent(Double.self, forKey: .xOffset) ?? 0
        yOffset = try c.decodeIfPresent(Double.self, forKey: .yOffset) ?? 0
        constrainCrop = try c.decodeIfPresent(Bool.self, forKey: .constrainCrop) ?? true
        upright = try c.decodeIfPresent(UprightMode.self, forKey: .upright)
        guides = try c.decodeIfPresent([GuideLine].self, forKey: .guides) ?? []
    }

    /// Writes `upright` as `null` when there is none, so saving over a sidecar that had one
    /// replaces it (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vertical, forKey: .vertical)
        try c.encode(horizontal, forKey: .horizontal)
        try c.encode(rotate, forKey: .rotate)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(scale, forKey: .scale)
        try c.encode(xOffset, forKey: .xOffset)
        try c.encode(yOffset, forKey: .yOffset)
        try c.encode(constrainCrop, forKey: .constrainCrop)
        try c.encode(upright, forKey: .upright)
        try c.encode(guides, forKey: .guides)
    }

    /// Whether the photo comes out as it went in. Constrain Crop and the Upright mode alone change nothing.
    public var isNeutral: Bool {
        vertical == 0 && horizontal == 0 && rotate == 0 && aspect == 0 && scale == 100 && xOffset == 0 && yOffset == 0
    }

    /// The same sliders with Vertical, Horizontal and Rotate replaced, clamped to their ranges.
    public func with(vertical: Double, horizontal: Double, rotate: Double) -> PerspectiveTransform {
        var copy = self
        copy.vertical = Self.clamp(vertical, Self.tiltRange)
        copy.horizontal = Self.clamp(horizontal, Self.tiltRange)
        copy.rotate = Self.clamp(rotate, Self.rotateRange)
        return copy
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Geometry

    /// The map from the uncorrected photo to the corrected one, for a photo of `size`: both in
    /// pixels from the top left, with y increasing downward. Includes Constrain Crop, Scale and
    /// the offsets. The identity when the sliders are neutral.
    public func homography(for size: CGSize) -> simd_double3x3 {
        guard !isNeutral, size.width > 0, size.height > 0 else { return matrix_identity_double3x3 }
        let (w, h) = (Double(size.width), Double(size.height))
        // About the center, so the tilts and turn pivot there.
        let centered = Self.translation(-w / 2, -h / 2)
        let tilted = Self.recentered(Self.aspectMatrix(aspect) * tilt(for: size))
        var map = tilted * centered
        if constrainCrop, let fill = Self.fill(Self.corners(of: size).map { Self.apply(map, to: $0) }, size: size) {
            map = fill * map
        }
        let s = Self.clamp(scale, Self.scaleRange) / 100
        let offset = Self.translation(Self.clamp(xOffset, Self.offsetRange) / 400 * w,
                                      -Self.clamp(yOffset, Self.offsetRange) / 400 * h)
        return Self.translation(w / 2, h / 2) * offset * Self.scaleMatrix(s) * map
    }

    /// The tilts and turn, about the photo's center, as a camera with a focal length of the
    /// photo's diagonal would see them: the field of view of a 43 mm lens on a full-frame
    /// camera. The real lens doesn't change whether lines come out parallel, only how much the
    /// photo stretches, which Aspect undoes.
    func tilt(for size: CGSize) -> simd_double3x3 {
        let f = Double((size.width * size.width + size.height * size.height).squareRoot())
        let radians = Self.maximumTilt * .pi / 180 / 100
        // Negative Vertical widens the top: the rotation that brings the top nearer the camera.
        let a = -Self.clamp(vertical, Self.tiltRange) * radians
        let b = Self.clamp(horizontal, Self.tiltRange) * radians
        let c = Self.clamp(rotate, Self.rotateRange) * .pi / 180
        // Columns, as simd stores them. With y downward, a positive turn is clockwise on screen.
        let rx = simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(a), sin(a)), SIMD3(0, -sin(a), cos(a))))
        let ry = simd_double3x3(columns: (SIMD3(cos(b), 0, -sin(b)), SIMD3(0, 1, 0), SIMD3(sin(b), 0, cos(b))))
        let rz = simd_double3x3(columns: (SIMD3(cos(c), sin(c), 0), SIMD3(-sin(c), cos(c), 0), SIMD3(0, 0, 1)))
        let k = simd_double3x3(diagonal: SIMD3(f, f, 1))
        let kInverse = simd_double3x3(diagonal: SIMD3(1 / f, 1 / f, 1))
        return k * rz * ry * rx * kInverse
    }

    /// `map` followed by the move that brings the photo's center back to where it was, so a tilt
    /// doesn't slide the photo off the frame.
    static func recentered(_ map: simd_double3x3) -> simd_double3x3 {
        let center = apply(map, to: .zero)
        return translation(-center.x, -center.y) * map
    }

    static func aspectMatrix(_ aspect: Double) -> simd_double3x3 {
        let stretch = exp2(clamp(aspect, aspectRange) / 100 / 2)
        return simd_double3x3(diagonal: SIMD3(stretch, 1 / stretch, 1))
    }

    /// The enlargement and move that fills a frame of `size`, centered on the origin, with the
    /// largest rectangle of the frame's shape inside `quad`, the corrected photo's corners in
    /// order around it. `nil` when there is no such rectangle.
    ///
    /// The rectangle's center and half size are three unknowns, and each of its corners must sit
    /// inside each of the quad's edges: sixteen linear limits. The largest rectangle sits where
    /// three of them meet, so every three are tried.
    static func fill(_ quad: [SIMD2<Double>], size: CGSize) -> simd_double3x3? {
        let half = SIMD2(Double(size.width) / 2, Double(size.height) / 2)
        // Inward normals, whichever way the corners run.
        let area = (0..<4).reduce(0.0) { sum, i in
            let (p, q) = (quad[i], quad[(i + 1) % 4])
            return sum + p.x * q.y - q.x * p.y
        }
        let turn = area > 0 ? 1.0 : -1.0
        var limits: [(SIMD3<Double>, Double)] = []
        for i in 0..<4 {
            let (p, q) = (quad[i], quad[(i + 1) % 4])
            let normal = SIMD2(-(q.y - p.y), q.x - p.x) * turn
            for corner in [SIMD2(-1.0, -1.0), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)] {
                // normal · (center + s × corner × half) ≥ normal · p
                limits.append((SIMD3(normal.x, normal.y, simd_dot(normal, corner * half)), simd_dot(normal, p)))
            }
        }
        var best: SIMD3<Double>?
        for i in 0..<limits.count {
            for j in (i + 1)..<limits.count {
                for k in (j + 1)..<limits.count {
                    let m = simd_double3x3(rows: [limits[i].0, limits[j].0, limits[k].0])
                    guard abs(m.determinant) > 1e-9 else { continue }
                    let x = m.inverse * SIMD3(limits[i].1, limits[j].1, limits[k].1)
                    guard x.z > 0, x.z > (best?.z ?? 0),
                          limits.allSatisfy({ simd_dot($0.0, x) >= $0.1 - 1e-6 * max(1, abs($0.1)) }) else { continue }
                    best = x
                }
            }
        }
        guard let best else { return nil }
        // A hair smaller, so the photo's soft edge stays outside the frame.
        let s = best.z * (1 - 2 / Double(min(size.width, size.height)))
        return scaleMatrix(1 / s) * translation(-best.x, -best.y)
    }

    static func corners(of size: CGSize) -> [SIMD2<Double>] {
        let (w, h) = (Double(size.width), Double(size.height))
        return [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]
    }

    static func translation(_ x: Double, _ y: Double) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(x, y, 1)))
    }

    static func scaleMatrix(_ s: Double) -> simd_double3x3 {
        simd_double3x3(diagonal: SIMD3(s, s, 1))
    }

    /// `point` through `map`, dividing out the projective part.
    public static func apply(_ map: simd_double3x3, to point: SIMD2<Double>) -> SIMD2<Double> {
        let p = map * SIMD3(point.x, point.y, 1)
        return SIMD2(p.x / p.z, p.y / p.z)
    }

    // MARK: - Rendering

    /// Corrects `image`, the whole photo as the camera oriented it. The result keeps the image's
    /// extent; with Constrain Crop off, the parts the photo no longer covers are clear.
    static func apply(_ transform: PerspectiveTransform, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !transform.isNeutral, extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let map = transform.homography(for: extent.size)
        // Each corner of the photo in Core Image's coordinates, whose y axis points up.
        func placed(_ x: Double, _ y: Double) -> CGPoint? {
            let p = map * SIMD3(x, y, 1)
            // A corner behind the camera can't be drawn; the tilt range keeps them in front.
            guard p.z > 1e-9 else { return nil }
            return CGPoint(x: extent.minX + p.x / p.z, y: extent.maxY - p.y / p.z)
        }
        let (w, h) = (Double(extent.width), Double(extent.height))
        guard let topLeft = placed(0, 0), let topRight = placed(w, 0),
              let bottomRight = placed(w, h), let bottomLeft = placed(0, h) else { return image }
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomRight = bottomRight
        filter.bottomLeft = bottomLeft
        return filter.outputImage?.cropped(to: extent) ?? image
    }
}

/// How Upright chose the sliders, named as in Lightroom.
public enum UprightMode: String, Codable, CaseIterable, Sendable {
    /// Levels the photo and corrects the perspective where lines show it, but holds back
    /// strong corrections so the photo still looks natural.
    case auto
    /// Turns the photo so it is level. No perspective correction.
    case level
    /// Levels the photo and makes vertical lines parallel.
    case vertical
    /// Levels the photo and makes both vertical and horizontal lines parallel.
    case full
    /// Straightens the lines the person drew.
    case guided
}

/// A line drawn along something that should be upright or level, from 0 to 1 on each axis of the
/// photo as the camera oriented it, uncorrected, from the top left.
public struct GuideLine: Codable, Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = CGPoint(x: try c.decode(Double.self), y: try c.decode(Double.self))
        end = CGPoint(x: try c.decode(Double.self), y: try c.decode(Double.self))
    }

    /// `[x1, y1, x2, y2]`, as compact as the curve points.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Double(start.x)); try c.encode(Double(start.y))
        try c.encode(Double(end.x)); try c.encode(Double(end.y))
    }
}
