import ProofKit
import SwiftUI

/// A small copy of the whole photo with a box around the part in view, shown while zoomed, as
/// in Lightroom. Clicking or dragging on it moves the view there.
struct Navigator: View {
    let zoom: CanvasZoom
    let preview: CGImage
    /// The canvas's gray, which the inspector beside it shares.
    let backdropGray: Double
    /// The long edge, in points.
    private static let length: CGFloat = 160

    var body: some View {
        let size = fittedSize
        let region = zoom.visibleRegion
        Image(decorative: preview, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                if !region.isNull {
                    // White inside black, so the box reads on light and dark photos alike.
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 1.5)
                        .padding(1)
                        .overlay(Rectangle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                        .frame(width: max(region.width * size.width, 6), height: max(region.height * size.height, 6))
                        .offset(x: region.minX * size.width, y: region.minY * size.height)
                }
            }
            .clipShape(.rect(cornerRadius: 4))
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                zoom.center(on: CGPoint(x: value.location.x / size.width, y: value.location.y / size.height))
            })
            .padding(6)
            // Solid and outlined like the inspector's sections, so it reads crisply over the photo.
            .background(Color(white: backdropGray), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .help("Click or drag to move around the photo")
            .accessibilityElement()
            .accessibilityLabel("Navigator")
            .accessibilityValue(description(of: region))
            .accessibilityAdjustableAction { direction in
                // Steps a fifth of the photo down or up, for VoiceOver.
                let step = direction == .increment ? 0.2 : -0.2
                zoom.center(on: CGPoint(x: region.midX, y: region.midY + step))
            }
    }

    private var fittedSize: CGSize {
        let width = CGFloat(preview.width), height = CGFloat(preview.height)
        guard width > 0, height > 0 else { return CGSize(width: Self.length, height: Self.length) }
        let scale = Self.length / max(width, height)
        return CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    private func description(of region: CGRect) -> String {
        guard !region.isNull else { return "" }
        let across = Double(region.midX).formatted(.percent.precision(.fractionLength(0)))
        let down = Double(region.midY).formatted(.percent.precision(.fractionLength(0)))
        return "Showing \(zoom.title), centered \(across) across and \(down) down"
    }
}
