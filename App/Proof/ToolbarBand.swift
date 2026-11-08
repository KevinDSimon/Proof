import SwiftUI

extension View {
    /// Fills the area under the toolbar with the canvas color and draws a line along its bottom
    /// edge, so content scrolling up disappears before it reaches the title. It is drawn per
    /// column rather than as the window toolbar's background, which would cut the sidebar and
    /// inspector dividers off at the toolbar instead of letting them run to the top.
    func toolbarBand(gray: Double) -> some View {
        modifier(ToolbarBand(gray: gray))
    }
}

private struct ToolbarBand: ViewModifier {
    let gray: Double
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            VStack(spacing: 0) {
                // No height of its own: ignoring the safe area stretches it up over the toolbar.
                Color(white: gray)
                    .ignoresSafeArea(edges: .top)
                    .frame(height: 0)
                // The color and one-pixel width of the sidebar and inspector dividers.
                Color(nsColor: .separatorColor)
                    .frame(height: 1 / displayScale)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
