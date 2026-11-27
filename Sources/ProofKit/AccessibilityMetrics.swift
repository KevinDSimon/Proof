import CoreGraphics
import Foundation

/// The numbers behind the app's accessibility (#237): how far a VoiceOver swipe moves a slider,
/// how large a touch target must be, and the contrast of the interface's grays. Kept here, apart
/// from the views, so they can be tested.
public enum AccessibilityMetrics {
    /// The smallest side of something tapped with a finger, from Apple's Human Interface Guidelines.
    public static let minimumTouchTarget: CGFloat = 44

    /// How much a control of `size` must grow on each side to reach the minimum touch target:
    /// half the shortfall in each direction, or nothing where it is already large enough.
    public static func touchTargetOutset(for size: CGSize, minimum: CGFloat = minimumTouchTarget) -> CGSize {
        CGSize(width: max(0, (minimum - size.width) / 2), height: max(0, (minimum - size.height) / 2))
    }

    /// The share of a slider's travel one VoiceOver swipe up or down moves it: twenty swipes from
    /// end to end. The system's own step is a tenth, too coarse for an edit; the slider's own
    /// steps, a tenth of a stop or one point of contrast, would take a hundred swipes or more.
    /// A value can be typed in the field beside the slider where an exact one is wanted.
    public static let sliderSwipeFraction = 0.05

    /// The value a VoiceOver swipe moves a slider to from `value`: one `sliderSwipeFraction` of its
    /// travel up or down, measured along the slider as drawn (`position` maps a value to 0–1 and
    /// `valueAtPosition` back, as temperature's mireds do), then rounded to a multiple of `step`
    /// and kept in `range`. It always moves at least one `step` until it reaches an end.
    public static func sliderValue(afterSwipe increments: Bool, from value: Double, in range: ClosedRange<Double>,
                                   step: Double, position: ((Double) -> Double)? = nil,
                                   valueAtPosition: ((Double) -> Double)? = nil) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return value }
        let toPosition = position ?? { ($0 - range.lowerBound) / span }
        let toValue = valueAtPosition ?? { range.lowerBound + $0 * span }
        let sign: Double = increments ? 1 : -1
        let target = min(max(toPosition(value) + sign * sliderSwipeFraction, 0), 1)
        var stepped = toValue(target)
        if step > 0 {
            stepped = (stepped / step).rounded() * step
            if increments ? stepped <= value : stepped >= value { stepped = value + sign * step }
        }
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// The contrast ratio between two grays, each 0–1 in sRGB, by WCAG's formula: 1 for the same
    /// gray, 21 for black on white. Text needs 4.5 and other marks 3.
    public static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// White at `opacity` laid over a gray, as `Color.primary.opacity(_:)` draws in the dark interface.
    public static func white(_ opacity: Double, over gray: Double) -> Double {
        gray + (1 - gray) * opacity
    }

    private static func luminance(_ gray: Double) -> Double {
        gray <= 0.04045 ? gray / 12.92 : pow((gray + 0.055) / 1.055, 2.4)
    }
}
