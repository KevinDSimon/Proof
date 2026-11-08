import SwiftUI

extension View {
    /// Fades scrolled content into the canvas color before it reaches the window title. The
    /// toolbar's own background is hidden, and the soft scroll edge alone leaves the title on top
    /// of dark or busy photos. Opaque behind the title, clear just below the toolbar, no line.
    func toolbarFade(gray: Double) -> some View {
        modifier(ToolbarFade(gray: gray))
    }
}

private struct ToolbarFade: ViewModifier {
    let gray: Double
    @State private var toolbarHeight: CGFloat = 0

    /// How far below the toolbar the fade reaches. Less than the grid's top margin, so the first
    /// row is untouched until it scrolls.
    private static let reach: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarHeight = $0 }
            .overlay(alignment: .top) {
                let canvas = Color(white: gray)
                let height = toolbarHeight + Self.reach
                LinearGradient(stops: [.init(color: canvas, location: 0),
                                       .init(color: canvas, location: toolbarHeight * 0.6 / max(height, 1)),
                                       .init(color: canvas.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .offset(y: -toolbarHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
