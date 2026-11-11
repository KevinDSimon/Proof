import CoreGraphics
import Foundation

/// The photo's geometry: quarter turns and flips, then a straightened, cropped rectangle.
///
/// The rectangle is normalized (0...1) in the photo as turned and flipped, with its origin at the
/// top left. `angle` turns the photo under the rectangle around the rectangle's center, so the
/// rectangle is upright in the result and covers a tilted part of the photo. The layout is
/// documented in docs/edit-format.md.
public struct Crop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Straighten, in degrees from −45 to 45. Positive turns the photo clockwise.
    public var angle: Double
    /// Quarter turns clockwise: 0, 90, 180 or 270. Applied before the flips.
    public var rotation: Int
    /// Mirrors the turned photo left to right.
    public var flipHorizontal: Bool
    /// Mirrors the turned photo top to bottom.
    public var flipVertical: Bool
    /// The locked width-to-height ratio of the rectangle, `nil` for freeform.
    public var aspect: AspectRatio?

    public static let angleRange = -45.0...45.0

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1, angle: Double = 0,
                rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false,
                aspect: AspectRatio? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.angle = angle
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.aspect = aspect
    }

    /// No crop yet, locked to the photo's own shape: where the crop tool starts. `size` is the
    /// photo's size as the camera oriented it.
    public static func uncropped(photoSize size: CGSize?) -> Crop {
        Crop(aspect: size.flatMap { $0.width > 0 && $0.height > 0 ? AspectRatio($0.width, $0.height) : nil })
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, width, height, angle, rotation, flipHorizontal, flipVertical, aspect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        rotation = Self.normalized(try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0)
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        aspect = try c.decodeIfPresent(AspectRatio.self, forKey: .aspect)
    }

    /// Writes a freeform `aspect` as `null`, so saving over a locked one replaces it (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(angle, forKey: .angle)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(flipHorizontal, forKey: .flipHorizontal)
        try c.encode(flipVertical, forKey: .flipVertical)
        try c.encode(aspect, forKey: .aspect)
    }

    /// Whether the crop leaves the photo as it is. A recipe stores `nil` instead.
    /// The locked ratio doesn't count: it changes nothing until the rectangle does.
    public var isIdentity: Bool {
        var unlocked = self
        unlocked.aspect = nil
        return unlocked == Crop()
    }

    /// Whether the rectangle or straighten changes the photo, apart from the turn and flips.
    public var hasRectangle: Bool {
        x != 0 || y != 0 || width != 1 || height != 1 || angle != 0
    }

    /// The photo's size once turned, from its size as the camera oriented it.
    public func turnedSize(of size: CGSize) -> CGSize {
        rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The size of the result, from the photo's size as the camera oriented it.
    public func outputSize(of size: CGSize) -> CGSize {
        let turned = turnedSize(of: size)
        return CGSize(width: turned.width * width, height: turned.height * height)
    }

    /// The same geometry without the rectangle and straighten: what the crop tool shows.
    public var turnedOnly: Crop {
        Crop(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
    }

    // MARK: Points

    /// Where `point` of the result, from 0 to 1 on each axis from the top left, lies on the photo
    /// as the camera oriented it, also from 0 to 1: through the rectangle, the straighten angle,
    /// the flips and the turn, undone in that order. `size` is the photo's size as the camera
    /// oriented it. Points outside the result map outside the rectangle.
    public func photoPoint(of point: CGPoint, photoSize size: CGSize) -> CGPoint {
        let turned = turnedSize(of: size)
        guard turned.width > 0, turned.height > 0 else { return point }
        // In pixels of the turned photo, about the rectangle's center. A positive angle turns
        // the photo clockwise, so the result's axes are the photo's turned clockwise as well.
        let (w, h) = (Double(turned.width), Double(turned.height))
        let local = SIMD2((point.x - 0.5) * width * w, (point.y - 0.5) * height * h)
        let radians = angle * .pi / 180
        let unturned = SIMD2(local.x * cos(radians) + local.y * sin(radians), -local.x * sin(radians) + local.y * cos(radians))
        var p = SIMD2((x + width / 2) + unturned.x / w, (y + height / 2) + unturned.y / h)
        if flipVertical { p.y = 1 - p.y }
        if flipHorizontal { p.x = 1 - p.x }
        // Back a quarter turn counterclockwise for each clockwise one: (x, y) came from (y, 1 − x).
        for _ in 0..<(Self.normalized(rotation) / 90) { p = SIMD2(p.y, 1 - p.x) }
        return CGPoint(x: p.x, y: p.y)
    }

    /// Where `point` of the photo as the camera oriented it, from 0 to 1, shows in the result,
    /// from 0 to 1: the reverse of `photoPoint(of:photoSize:)`.
    public func resultPoint(of point: CGPoint, photoSize size: CGSize) -> CGPoint {
        let turned = turnedSize(of: size)
        guard turned.width > 0, turned.height > 0 else { return point }
        var p = SIMD2(Double(point.x), Double(point.y))
        // A quarter turn clockwise takes (x, y) to (1 − y, x).
        for _ in 0..<(Self.normalized(rotation) / 90) { p = SIMD2(1 - p.y, p.x) }
        if flipHorizontal { p.x = 1 - p.x }
        if flipVertical { p.y = 1 - p.y }
        let (w, h) = (Double(turned.width), Double(turned.height))
        let offset = SIMD2((p.x - (x + width / 2)) * w, (p.y - (y + height / 2)) * h)
        let radians = angle * .pi / 180
        let local = SIMD2(offset.x * cos(radians) - offset.y * sin(radians), offset.x * sin(radians) + offset.y * cos(radians))
        return CGPoint(x: local.x / (width * w) + 0.5, y: local.y / (height * h) + 0.5)
    }

    // MARK: Turning and flipping, as seen on screen

    /// Turns the result a quarter turn clockwise, or counterclockwise. The rectangle and the
    /// straighten turn with the photo.
    public mutating func rotate(clockwise: Bool) {
        let (x, y, width, height) = (self.x, self.y, self.width, self.height)
        if clockwise {
            self.x = 1 - (y + height)
            self.y = x
        } else {
            self.x = y
            self.y = 1 - (x + width)
        }
        self.width = height
        self.height = width
        aspect = aspect?.swapped
        // The flips apply after the turn, and one flip mirrors the direction of a turn before it.
        let mirrored = flipHorizontal != flipVertical
        rotation = Self.normalized(rotation + (clockwise != mirrored ? 90 : -90))
    }

    /// Mirrors the result left to right.
    public mutating func flipHorizontally() {
        x = 1 - (x + width)
        angle = -angle
        flipHorizontal.toggle()
        simplifyFlips()
    }

    /// Mirrors the result top to bottom.
    public mutating func flipVertically() {
        y = 1 - (y + height)
        angle = -angle
        flipVertical.toggle()
        simplifyFlips()
    }

    /// Both flips together are a half turn.
    private mutating func simplifyFlips() {
        guard flipHorizontal, flipVertical else { return }
        flipHorizontal = false
        flipVertical = false
        rotation = Self.normalized(rotation + 180)
    }

    private static func normalized(_ degrees: Int) -> Int {
        ((degrees / 90 * 90) % 360 + 360) % 360
    }
}

/// A width-to-height ratio, such as 3:2, written as `[3, 2]`.
public struct AspectRatio: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    public var value: Double { width / height }
    public var swapped: AspectRatio { AspectRatio(height, width) }
    public var isPortrait: Bool { height > width }

    /// The same ratio, wider than tall or taller than wide.
    public func oriented(portrait: Bool) -> AspectRatio {
        isPortrait == portrait ? self : swapped
    }

    /// Whether the two describe the same shape, within rounding.
    public func matches(_ other: AspectRatio) -> Bool {
        abs(value - other.value) < 0.001 * value
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        width = try c.decode(Double.self)
        height = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(width)
        try c.encode(height)
    }
}

/// The parts of the crop rectangle that can be dragged.
public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which edges move: −1 the left or top edge, 1 the right or bottom edge, 0 neither.
    public var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    public var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }
}

/// The crop rectangle in the units of the turned photo, which is `imageSize` with its origin at
/// the top left. The crop tool edits this; `Crop` stores it normalized.
public struct CropFrame: Equatable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    /// Degrees; positive turns the photo clockwise under the rectangle.
    public var angle: Double
    public var imageSize: CGSize

    /// The smallest side of the rectangle, as a fraction of the photo's shorter side.
    public static let minimumSide = 0.05

    public init(center: CGPoint, size: CGSize, angle: Double, imageSize: CGSize) {
        self.center = center
        self.size = size
        self.angle = angle
        self.imageSize = imageSize
    }

    /// The frame of `crop` in a turned photo of `imageSize`.
    public init(_ crop: Crop, imageSize: CGSize) {
        let (w, h) = (imageSize.width, imageSize.height)
        center = CGPoint(x: (crop.x + crop.width / 2) * w, y: (crop.y + crop.height / 2) * h)
        size = CGSize(width: crop.width * w, height: crop.height * h)
        angle = crop.angle
        self.imageSize = imageSize
    }

    /// The whole photo, upright.
    public static func whole(_ imageSize: CGSize) -> CropFrame {
        CropFrame(center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2), size: imageSize,
                  angle: 0, imageSize: imageSize)
    }

    /// Writes the rectangle and straighten into `crop`, keeping its turn, flips and ratio.
    public func applied(to crop: Crop) -> Crop {
        var crop = crop
        let (w, h) = (imageSize.width, imageSize.height)
        crop.width = size.width / w
        crop.height = size.height / h
        crop.x = center.x / w - crop.width / 2
        crop.y = center.y / h - crop.height / 2
        crop.angle = angle
        return crop
    }

    /// The rectangle's corners in the photo: top left, top right, bottom right, bottom left.
    public var corners: [CGPoint] {
        let radians = -angle * .pi / 180
        let (cosine, sine) = (cos(radians), sin(radians))
        let halves = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
        return halves.map { sx, sy in
            let dx = sx * size.width / 2, dy = sy * size.height / 2
            return CGPoint(x: center.x + dx * cosine - dy * sine, y: center.y + dx * sine + dy * cosine)
        }
    }

    /// The same rectangle, within a thousandth of a pixel; saved values pass through rounding.
    public func isClose(to other: CropFrame) -> Bool {
        let tolerance = 1e-3
        return abs(center.x - other.center.x) < tolerance && abs(center.y - other.center.y) < tolerance
            && abs(size.width - other.size.width) < tolerance && abs(size.height - other.size.height) < tolerance
            && abs(angle - other.angle) < 1e-6 && imageSize == other.imageSize
    }

    /// Whether the whole rectangle lies on the photo, so no empty corners show.
    public var fits: Bool {
        let tolerance = 1e-6 * max(imageSize.width, imageSize.height)
        return corners.allSatisfy {
            $0.x >= -tolerance && $0.x <= imageSize.width + tolerance
                && $0.y >= -tolerance && $0.y <= imageSize.height + tolerance
        }
    }

    /// Shrinks the rectangle around its center, keeping its shape, until it lies on the photo.
    public func shrunkToFit() -> CropFrame {
        var frame = self
        frame.center.x = min(max(center.x, 0), imageSize.width)
        frame.center.y = min(max(center.y, 0), imageSize.height)
        var scale = 1.0
        for corner in frame.corners {
            let dx = corner.x - frame.center.x, dy = corner.y - frame.center.y
            if dx > 0 { scale = min(scale, (imageSize.width - frame.center.x) / dx) }
            if dx < 0 { scale = min(scale, frame.center.x / -dx) }
            if dy > 0 { scale = min(scale, (imageSize.height - frame.center.y) / dy) }
            if dy < 0 { scale = min(scale, frame.center.y / -dy) }
        }
        frame.size = CGSize(width: size.width * max(scale, 0), height: size.height * max(scale, 0))
        return frame
    }

    /// At `angle`, as large as this rectangle but shrunk to lie on the photo. The crop tool keeps
    /// the rectangle from before straightening, so it grows back as the angle returns to zero.
    public func straightened(_ angle: Double) -> CropFrame {
        var frame = self
        frame.angle = min(max(angle, Crop.angleRange.lowerBound), Crop.angleRange.upperBound)
        return frame.shrunkToFit()
    }

    /// The largest rectangle of `aspect` around this one's center that lies on the photo; the
    /// whole photo's width or height for freeform.
    public func withAspect(_ aspect: AspectRatio?) -> CropFrame {
        var frame = self
        let (w, h) = (imageSize.width, imageSize.height)
        if let aspect {
            frame.size = w / h > aspect.value ? CGSize(width: h * aspect.value, height: h)
                                              : CGSize(width: w, height: w / aspect.value)
        } else {
            frame.size = imageSize
        }
        return frame.shrunkToFit()
    }

    /// Moves `handle` by `delta`, measured along the rectangle's own edges, keeping the opposite
    /// edges in place. With `aspect`, the rectangle keeps that shape. It stops at the photo's
    /// edges and at the smallest size.
    public func dragging(_ handle: CropHandle, by delta: CGVector, aspect: AspectRatio?) -> CropFrame {
        var edges = Edges(size: size)
        let minimum = Self.minimumSide * min(imageSize.width, imageSize.height)
        if handle.horizontal < 0 { edges.left = min(edges.left + delta.dx, edges.right - minimum) }
        if handle.horizontal > 0 { edges.right = max(edges.right + delta.dx, edges.left + minimum) }
        if handle.vertical < 0 { edges.top = min(edges.top + delta.dy, edges.bottom - minimum) }
        if handle.vertical > 0 { edges.bottom = max(edges.bottom + delta.dy, edges.top + minimum) }

        guard let aspect else {
            // Freeform: each direction stops at the photo's edge on its own, so the other keeps going.
            let across = clamped(from: Edges(size: size), to: Edges(size: size).with(horizontalOf: edges))
            return across.clamped(from: Edges(size: across.size), to: Edges(size: across.size).with(verticalOf: edges, offset: across.offset(from: self)))
        }
        edges.constrain(to: aspect.value, handle: handle, minimum: minimum)
        return clamped(from: Edges(size: size), to: edges)
    }

    /// Moves the rectangle over the photo by `delta`, measured along its own edges, stopping at
    /// the photo's edges.
    public func moved(by delta: CGVector) -> CropFrame {
        let start = Edges(size: size)
        let across = clamped(from: start, to: start.offset(dx: delta.dx, dy: 0))
        let next = Edges(size: across.size)
        return across.clamped(from: next, to: next.offset(dx: 0, dy: delta.dy))
    }

    // MARK: Edges along the rectangle's axes

    /// Edge positions along the rectangle's own axes, relative to its center.
    struct Edges {
        var left, right, top, bottom: Double

        init(size: CGSize) {
            left = -size.width / 2
            right = size.width / 2
            top = -size.height / 2
            bottom = size.height / 2
        }

        func offset(dx: Double, dy: Double) -> Edges {
            var edges = self
            edges.left += dx; edges.right += dx; edges.top += dy; edges.bottom += dy
            return edges
        }

        func with(horizontalOf other: Edges) -> Edges {
            var edges = self
            edges.left = other.left; edges.right = other.right
            return edges
        }

        /// Takes `other`'s top and bottom, which are measured from a center `offset` away.
        func with(verticalOf other: Edges, offset: CGVector) -> Edges {
            var edges = self
            edges.top = other.top - offset.dy; edges.bottom = other.bottom - offset.dy
            return edges
        }

        static func interpolated(_ a: Edges, _ b: Edges, _ t: Double) -> Edges {
            var edges = a
            edges.left += (b.left - a.left) * t
            edges.right += (b.right - a.right) * t
            edges.top += (b.top - a.top) * t
            edges.bottom += (b.bottom - a.bottom) * t
            return edges
        }

        /// Gives the edges the shape `ratio`, keeping the dragged handle's opposite side in place.
        mutating func constrain(to ratio: Double, handle: CropHandle, minimum: Double) {
            var width = right - left, height = bottom - top
            if handle.horizontal != 0 && handle.vertical != 0 {
                // A corner follows whichever side was pulled further.
                if width / ratio > height { height = width / ratio } else { width = height * ratio }
            } else if handle.horizontal != 0 {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let smallest = max(minimum / width, minimum / height, 1)
            width *= smallest
            height *= smallest
            switch handle.horizontal {
            case -1: left = right - width
            case 1: right = left + width
            default: let middle = (left + right) / 2; left = middle - width / 2; right = middle + width / 2
            }
            switch handle.vertical {
            case -1: top = bottom - height
            case 1: bottom = top + height
            default: let middle = (top + bottom) / 2; top = middle - height / 2; bottom = middle + height / 2
            }
        }
    }

    /// The frame `edges` describe, with edges measured from this frame's center.
    func frame(_ edges: Edges) -> CropFrame {
        let radians = -angle * .pi / 180
        let (cosine, sine) = (cos(radians), sin(radians))
        let mx = (edges.left + edges.right) / 2, my = (edges.top + edges.bottom) / 2
        var frame = self
        frame.center = CGPoint(x: center.x + mx * cosine - my * sine, y: center.y + mx * sine + my * cosine)
        frame.size = CGSize(width: edges.right - edges.left, height: edges.bottom - edges.top)
        return frame
    }

    /// How far this frame's center is from `other`'s, along the rectangle's own axes.
    func offset(from other: CropFrame) -> CGVector {
        let radians = angle * .pi / 180
        let (cosine, sine) = (cos(radians), sin(radians))
        let dx = center.x - other.center.x, dy = center.y - other.center.y
        return CGVector(dx: dx * cosine - dy * sine, dy: dx * sine + dy * cosine)
    }

    /// Goes as far from `start` toward `end` as the photo allows. `start` must fit. The corners
    /// move in straight lines and the photo is convex, so what fits is one stretch from `start`.
    func clamped(from start: Edges, to end: Edges) -> CropFrame {
        let target = frame(end)
        if target.fits { return target }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if frame(.interpolated(start, end, middle)).fits { low = middle } else { high = middle }
        }
        return frame(.interpolated(start, end, low))
    }
}
