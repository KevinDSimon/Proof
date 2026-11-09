import CoreImage

/// The Vibrance and Saturation sliders, applied in linear light after the tone stages.
enum ColorAdjustments {
    static let range: ClosedRange<Double> = -100...100

    /// Vibrance first, through `CIVibrance`, which changes muted colors more than vivid ones and
    /// leaves grays alone; then saturation, through `CIColorControls`, which changes all colors
    /// alike. Saturation −100 leaves the photo black and white. Values outside −100…100, which
    /// only a hand-edited sidecar can hold, are clamped. A slider at 0 skips its filter.
    static func apply(to image: CIImage, vibrance: Double, saturation: Double) -> CIImage {
        let vibrance = clamped(vibrance), saturation = clamped(saturation)
        var result = image
        if vibrance != 0 {
            result = result.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance / 100])
        }
        if saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + saturation / 100,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1,
            ])
        }
        return result
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
