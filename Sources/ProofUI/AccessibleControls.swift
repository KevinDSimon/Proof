import ProofKit
import SwiftUI

public extension View {
    /// On touch, lets a small control take taps across at least 44 by 44 points around it without
    /// changing its layout, so a compact control beside a title still meets Apple's minimum
    /// touch target (#237). Apply it inside a button's label, where the button takes the taps.
    /// The Mac's pointer needs no more than the control's own size.
    func minimumTouchTarget() -> some View {
        modifier(MinimumTouchTarget())
    }

    /// The inspector's labels: a step dimmer than titles, and as bright as titles when Increase
    /// Contrast is on.
    func inspectorLabelStyle() -> some View {
        modifier(InspectorLabelStyle())
    }
}

private struct MinimumTouchTarget: ViewModifier {
    @State private var outset = CGSize.zero

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                outset = AccessibilityMetrics.touchTargetOutset(for: $0)
            }
            .padding(.horizontal, outset.width)
            .padding(.vertical, outset.height)
            .contentShape(.rect)
            .padding(.horizontal, -outset.width)
            .padding(.vertical, -outset.height)
        #else
        content
        #endif
    }
}

private struct InspectorLabelStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(contrast == .increased ? Color.primary : InspectorCard<EmptyView>.labelColor)
    }
}
