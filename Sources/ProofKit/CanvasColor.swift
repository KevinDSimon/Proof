import Foundation

/// The color around the photo in Edit (#42). The rest of the interface stays dark; only the canvas
/// takes this color, so the photo can also be judged on black, white or any other surround.
public enum CanvasColor: Hashable, Codable, Sendable {
    case darkGray
    case black
    case middleGray
    case white
    /// A color picked in the system color panel, in Display P3 components from 0 to 1.
    case custom(red: Double, green: Double, blue: Double)

    /// The choices View › Canvas Color lists before Custom…, in order.
    public static let presets: [CanvasColor] = [.darkGray, .black, .middleGray, .white]

    public var title: String {
        switch self {
        case .darkGray: "Dark Gray"
        case .black: "Black"
        case .middleGray: "Middle Gray"
        case .white: "White"
        case .custom: "Custom…"
        }
    }

    public var isCustom: Bool {
        if case .custom = self { true } else { false }
    }

    /// Display P3 components from 0 to 1. Neutral grays are the same in Display P3 and sRGB, so the
    /// Metal canvas and the SwiftUI backdrop around it meet without a seam.
    public var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .darkGray: (0.13, 0.13, 0.13)
        case .black: (0, 0, 0)
        // 18% reflectance, sRGB-encoded.
        case .middleGray: (0.46, 0.46, 0.46)
        case .white: (1, 1, 1)
        case let .custom(red, green, blue): (Self.clamped(red), Self.clamped(green), Self.clamped(blue))
        }
    }

    /// The stored form, for `UserDefaults`.
    public var encoded: Data? { try? JSONEncoder().encode(self) }

    /// The color stored as `data`, or Dark Gray when there is none or it can't be read.
    public init(stored data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .darkGray
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}
