import SwiftUI

public extension View {
    /// The system's soft scroll edge under the top bar on iPad and iPhone, so content fades out
    /// beneath the bar as it scrolls rather than meeting it at a hard line. Every iOS scroll view
    /// under a navigation bar uses this one modifier, so the screens match (decision 0060). The
    /// Mac keeps the edges it sets itself.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        #if os(macOS)
        self
        #else
        scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }
}
