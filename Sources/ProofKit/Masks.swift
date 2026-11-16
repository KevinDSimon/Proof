import CoreGraphics
import Foundation

/// A mask with its own adjustments, applied to the parts of the photo the mask covers. Layers
/// apply in order, each to the result of the one before. See docs/decisions/0040-masks.md.
public struct Layer: Codable, Equatable, Sendable {
    public var name: String
    public var isEnabled: Bool
    public var mask: Mask
    public var adjustments: LocalAdjustments

    private enum CodingKeys: String, CodingKey {
        case name, isEnabled, mask, adjustments
    }

    public init(name: String, isEnabled: Bool = true, mask: Mask, adjustments: LocalAdjustments = LocalAdjustments()) {
        self.name = name
        self.isEnabled = isEnabled
        self.mask = mask
        self.adjustments = adjustments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // No version of Proof wrote a layer before masks, so one without a mask or adjustments
        // is hand-made; it covers nothing and changes nothing, as layers rendered then.
        mask = try c.decodeIfPresent(Mask.self, forKey: .mask) ?? Mask(.brush(BrushMask()))
        adjustments = try c.decodeIfPresent(LocalAdjustments.self, forKey: .adjustments) ?? LocalAdjustments()
    }
}

/// Where a layer applies: weights from 0, untouched, to 1, fully adjusted. Positions are from 0
/// to 1 on each axis, from the top left, of the whole photo after spot removal and before the
/// crop, as spots' are, so a mask stays on what it covers when the crop changes.
public struct Mask: Codable, Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case linear(LinearMask)
        case radial(RadialMask)
        case brush(BrushMask)
        case subject(SubjectMask)
        /// A kind of mask from a newer Proof, by its type. It covers nothing here, so the layer
        /// changes nothing rather than applying to the wrong part of the photo, and its type is
        /// written back as it was, with the fields the newer Proof keeps for it.
        case unknown(String)
    }

    public var shape: Shape
    /// Applies the layer where the mask doesn't, and not where it does.
    public var isInverted: Bool

    public init(_ shape: Shape, isInverted: Bool = false) {
        self.shape = shape
        self.isInverted = isInverted
    }

    private enum CodingKeys: String, CodingKey {
        case type, isInverted, linear, radial, brush, subject
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isInverted = try c.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        let type = try c.decodeIfPresent(String.self, forKey: .type)
        switch type {
        case "linear": shape = .linear(try c.decode(LinearMask.self, forKey: .linear))
        case "radial": shape = .radial(try c.decode(RadialMask.self, forKey: .radial))
        case "brush": shape = .brush(try c.decode(BrushMask.self, forKey: .brush))
        case "subject": shape = .subject(try c.decode(SubjectMask.self, forKey: .subject))
        default: shape = .unknown(type ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isInverted, forKey: .isInverted)
        switch shape {
        case let .linear(gradient):
            try c.encode("linear", forKey: .type)
            try c.encode(gradient, forKey: .linear)
        case let .radial(gradient):
            try c.encode("radial", forKey: .type)
            try c.encode(gradient, forKey: .radial)
        case let .brush(brush):
            try c.encode("brush", forKey: .type)
            try c.encode(brush, forKey: .brush)
        case let .subject(subject):
            try c.encode("subject", forKey: .type)
            try c.encode(subject, forKey: .subject)
        case let .unknown(type):
            try c.encode(type, forKey: .type)
        }
    }

    /// The kind of mask, for names and menus; `nil` for one from a newer Proof.
    public var kind: Kind? {
        switch shape {
        case .linear: .linear
        case .radial: .radial
        case .brush: .brush
        case .subject: .subject
        case .unknown: nil
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case linear, radial, brush, subject

        public var title: String {
            switch self {
            case .linear: "Linear Gradient"
            case .radial: "Radial Gradient"
            case .brush: "Brush"
            case .subject: "Subject"
            }
        }
    }
}

/// Full effect on the start's side of the line through `start`, fading to none at the line
/// through `end`; both lines are square to the line from start to end.
public struct LinearMask: Codable, Equatable, Sendable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double

    public init(start: CGPoint, end: CGPoint) {
        startX = start.x
        startY = start.y
        endX = end.x
        endY = end.y
    }

    public var start: CGPoint {
        get { CGPoint(x: startX, y: startY) }
        set { startX = newValue.x; startY = newValue.y }
    }

    public var end: CGPoint {
        get { CGPoint(x: endX, y: endY) }
        set { endX = newValue.x; endY = newValue.y }
    }
}

/// Full effect inside an ellipse, fading out toward its edge by `feather`.
public struct RadialMask: Codable, Equatable, Sendable {
    public var centerX: Double
    public var centerY: Double
    /// Half the ellipse's width and height before it is turned, as fractions of the photo's long
    /// edge, so a circle stays round on a photo of any shape.
    public var radiusX: Double
    public var radiusY: Double
    /// Degrees clockwise.
    public var angle: Double
    /// 0 is a hard edge; 100 fades from the center out.
    public var feather: Double

    public static let radiusRange = 0.005...2.0
    public static let featherRange = 0.0...100.0
    public static let defaultFeather = 50.0

    public init(center: CGPoint, radiusX: Double, radiusY: Double, angle: Double = 0,
                feather: Double = RadialMask.defaultFeather) {
        centerX = center.x
        centerY = center.y
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.angle = angle
        self.feather = feather
    }

    public var center: CGPoint {
        get { CGPoint(x: centerX, y: centerY) }
        set { centerX = newValue.x; centerY = newValue.y }
    }
}

/// Painted strokes. Each adds to the mask, or with `erases`, takes away from it.
public struct BrushMask: Codable, Equatable, Hashable, Sendable {
    public var strokes: [BrushStroke]

    public init(strokes: [BrushStroke] = []) {
        self.strokes = strokes
    }
}

public struct BrushStroke: Codable, Equatable, Hashable, Sendable {
    /// The pointer's path, as x and y pairs in a flat list, which keeps long strokes short in the file.
    public var points: [Double]
    /// The brush's radius as a fraction of the photo's long edge.
    public var radius: Double
    /// 0 is a hard edge; 100 fades from the center out.
    public var feather: Double
    /// How much one stroke adds, from 0 to 100. Going over a stroke again adds more.
    public var flow: Double
    public var erases: Bool

    public static let radiusRange = 0.001...0.25
    public static let featherRange = 0.0...100.0
    public static let flowRange = 0.0...100.0
    public static let defaultRadius = 0.03
    public static let defaultFeather = 50.0
    public static let defaultFlow = 100.0

    public init(points: [CGPoint] = [], radius: Double = BrushStroke.defaultRadius,
                feather: Double = BrushStroke.defaultFeather, flow: Double = BrushStroke.defaultFlow, erases: Bool = false) {
        self.points = points.flatMap { [$0.x, $0.y] }
        self.radius = radius
        self.feather = feather
        self.flow = flow
        self.erases = erases
    }

    private enum CodingKeys: String, CodingKey {
        case points, radius, feather, flow, erases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? Self.defaultFeather
        flow = try c.decodeIfPresent(Double.self, forKey: .flow) ?? Self.defaultFlow
        erases = try c.decodeIfPresent(Bool.self, forKey: .erases) ?? false
    }

    public var path: [CGPoint] {
        stride(from: 0, to: points.count - 1, by: 2).map { CGPoint(x: points[$0], y: points[$0 + 1]) }
    }

    public mutating func append(_ point: CGPoint) {
        points += [point.x, point.y]
    }
}

/// The photo's main subject, as Vision found it when the mask was made. The mask itself is
/// kept, not found again at each render, so the edit renders the same when Vision changes.
public struct SubjectMask: Codable, Equatable, Sendable {
    /// A grayscale PNG of the whole photo, white where the subject is, at most
    /// `SubjectMask.maxPixelSize` on its long edge.
    public var png: Data

    public static let maxPixelSize = 1536

    public init(png: Data) {
        self.png = png
    }
}

/// A layer's adjustments. Each runs from −100 to +100 but exposure, in stops from −4 to +4, and
/// all are 0 by default. They act like the global sliders of the same name, on the photo as
/// those have left it. Temperature and tint shift the color warmer (positive) or cooler, and
/// toward magenta (positive) or green, without changing brightness.
public struct LocalAdjustments: Codable, Equatable, Sendable {
    public var temperature: Double = 0
    public var tint: Double = 0
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var saturation: Double = 0

    public static let range = -100.0...100.0
    public static let exposureRange = -4.0...4.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze, saturation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        temperature = try value(.temperature)
        tint = try value(.tint)
        exposure = try value(.exposure)
        contrast = try value(.contrast)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        whites = try value(.whites)
        blacks = try value(.blacks)
        texture = try value(.texture)
        clarity = try value(.clarity)
        dehaze = try value(.dehaze)
        saturation = try value(.saturation)
    }

    public var isNeutral: Bool { self == LocalAdjustments() }
}
