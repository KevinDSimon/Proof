/// The crop tool's aspect ratio menu, in its order.
public enum AspectChoice: CaseIterable, Sendable {
    case freeform, original, square, fourFive, fiveSeven, threeTwo, sixteenNine, custom

    public var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "1:1"
        case .fourFive: "4:5"
        case .fiveSeven: "5:7"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .custom: "Custom"
        }
    }

    /// The preset's shape, `nil` for those that depend on the photo or the person.
    public var ratio: AspectRatio? {
        switch self {
        case .square: AspectRatio(1, 1)
        case .fourFive: AspectRatio(4, 5)
        case .fiveSeven: AspectRatio(5, 7)
        case .threeTwo: AspectRatio(3, 2)
        case .sixteenNine: AspectRatio(16, 9)
        case .freeform, .original, .custom: nil
        }
    }

    /// The menu item for a crop locked to `aspect`, in either orientation: Freeform when it isn't
    /// locked, Original for the photo's own shape, a preset's shape, and Custom for any other.
    /// `choseCustom` keeps Custom shown after it was picked, even for a shape the menu has.
    public static func shown(for aspect: AspectRatio?, original: AspectRatio?, choseCustom: Bool = false) -> AspectChoice {
        guard let aspect else { return .freeform }
        if choseCustom { return .custom }
        if let original, aspect.matches(original) || aspect.matches(original.swapped) { return .original }
        return allCases.first { $0.ratio.map { aspect.matches($0) || aspect.matches($0.swapped) } ?? false } ?? .custom
    }
}
