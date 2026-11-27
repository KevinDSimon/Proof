import SwiftUI
import UIKit

extension PresentationDetent {
    /// A sheet height of `points` at the default text size, grown with Dynamic Type as body text
    /// grows, so a sheet's first controls still show at larger sizes (#237). It stops at half the
    /// space a sheet can take, where the medium height begins, unless `points` is already more.
    static func scaledHeight(_ points: CGFloat, in context: Context) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(context.dynamicTypeSize))
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: points, compatibleWith: traits)
        return min(scaled, max(points, context.maxDetentValue / 2))
    }
}
