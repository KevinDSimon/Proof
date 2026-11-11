import AppKit
import ProofKit
import SwiftUI

/// The White Balance eyedropper over the photo while it is open, as in Lightroom: a crosshair, a
/// loupe beside it of the pixels under it with the center one's RGB values, and a click that sets
/// the white balance that makes the spot neutral gray. Zoom works as usual from the keyboard and
/// the navigator, so a small gray area can be picked at any scale.
struct WhiteBalancePicker: View {
    let library: Library
    let renderer: RAWRenderer

    /// The pointer, in points from the top left, and the loupe's pixels under it.
    @State private var pointer: CGPoint?
    @State private var loupe: CGImage?

    /// The loupe shows this many pixels on a side, each this many points wide.
    private static let cells = 11
    private static let cellSize: CGFloat = 10
    /// Drawable pixels across the patch a click measures, and the least it measures of the photo
    /// itself when zoomed far in, so a single noisy pixel doesn't decide the white balance.
    private static let patchPixels: CGFloat = 5
    private static let minimumPatchPhotoPixels: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            // Esc reaches the window before the menu bar, so this holds it, as the crop tool's
            // Cancel button does, as well as the Photo menu.
            Button("Cancel White Balance Selector") { library.isPickingWhiteBalance = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Color.clear
                .contentShape(Rectangle())
                .pointerStyle(.image(Image(nsImage: NSCursor.crosshair.image), hotSpot: Self.crosshairHotSpot))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointer = location
                        loupe = pixels(at: location, in: proxy.size)
                    case .ended:
                        pointer = nil
                        loupe = nil
                    }
                }
                .onTapGesture { location in pick(at: location, in: proxy.size) }
                .accessibilityLabel("Photo")
                .accessibilityHint("Click something neutral gray to set the white balance")
            if let pointer, let loupe {
                LoupeView(pixels: loupe, cells: Self.cells, cellSize: Self.cellSize,
                          isMeasuring: library.isAutoAdjusting)
                    .fixedSize()
                    .position(loupePosition(near: pointer, in: proxy.size))
                    .allowsHitTesting(false)
            }
        }
    }

    private static var crosshairHotSpot: UnitPoint {
        let cursor = NSCursor.crosshair
        return UnitPoint(x: cursor.hotSpot.x / max(cursor.image.size.width, 1),
                         y: cursor.hotSpot.y / max(cursor.image.size.height, 1))
    }

    /// Below and to the right of the pointer, flipped to the other side near the view's edges.
    private func loupePosition(near pointer: CGPoint, in size: CGSize) -> CGPoint {
        let side = CGFloat(Self.cells) * Self.cellSize
        let half = CGSize(width: side / 2, height: (side + 22) / 2)
        let gap: CGFloat = 24
        var x = pointer.x + gap + half.width, y = pointer.y + gap + half.height
        if x + half.width > size.width { x = pointer.x - gap - half.width }
        if y + half.height > size.height { y = pointer.y - gap - half.height }
        return CGPoint(x: x, y: y)
    }

    /// The point on the photo under `location`, from 0 to 1 on each axis, and the photo's frame in
    /// drawable pixels; `nil` off the photo.
    private func photoPoint(at location: CGPoint, in size: CGSize) -> (point: CGPoint, frame: CGRect)? {
        let zoom = library.zoom
        guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else { return nil }
        let pixelsPerPoint = zoom.viewSize.width / size.width
        let pixel = CGPoint(x: location.x * pixelsPerPoint, y: location.y * pixelsPerPoint)
        guard let point = zoom.viewport.photoPoint(at: pixel, photo: zoom.photoSize, view: zoom.viewSize) else { return nil }
        return (point, zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize))
    }

    /// The pixels around `location` as the canvas shows them: from the sharp region while zoomed
    /// where there is one, otherwise from the screen-size photo.
    private func pixels(at location: CGPoint, in size: CGSize) -> CGImage? {
        guard let (point, _) = photoPoint(at: location, in: size), let shown = library.zoom.shown else { return nil }
        let source = shown.detail.flatMap { $0.region.contains(point) ? $0 : nil } ?? shown.photo
        return renderer.pixels(of: source, around: point, count: Self.cells)
    }

    private func pick(at location: CGPoint, in size: CGSize) {
        guard !library.isAutoAdjusting, let (point, frame) = photoPoint(at: location, in: size) else { return }
        let photo = library.zoom.photoSize
        let width = max(Self.patchPixels / frame.width, Self.minimumPatchPhotoPixels / photo.width)
        let height = max(Self.patchPixels / frame.height, Self.minimumPatchPhotoPixels / photo.height)
        let patch = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        Task { await library.pickWhiteBalance(in: patch, with: renderer) }
    }
}

/// The White Balance card's eyedropper button. While the eyedropper is open it is inverted, as
/// selection is marked throughout Proof, rather than tinted.
struct EyedropperButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label("White Balance Selector", systemImage: "eyedropper")
                .labelStyle(.iconOnly)
        }
        .help("Click something neutral gray in the photo to set the white balance (W)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        if isOn {
            button.buttonStyle(.borderedProminent).tint(.primary)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

/// The eyedropper's loupe: the pixels under the pointer enlarged on a grid, the center one, which
/// the click measures, outlined, and its red, green and blue as percentages, as Lightroom shows
/// them; the three are close to equal over something neutral.
private struct LoupeView: View {
    let pixels: CGImage
    let cells: Int
    let cellSize: CGFloat
    let isMeasuring: Bool

    var body: some View {
        let side = CGFloat(cells) * cellSize
        VStack(spacing: 0) {
            Image(decorative: pixels, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: side, height: side)
                .overlay {
                    Canvas { context, size in
                        var grid = Path()
                        for i in 1..<cells {
                            let offset = CGFloat(i) * cellSize
                            grid.move(to: CGPoint(x: offset, y: 0))
                            grid.addLine(to: CGPoint(x: offset, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: offset))
                            grid.addLine(to: CGPoint(x: size.width, y: offset))
                        }
                        context.stroke(grid, with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                        let center = CGRect(x: CGFloat(cells / 2) * cellSize, y: CGFloat(cells / 2) * cellSize,
                                            width: cellSize, height: cellSize)
                        context.stroke(Path(center.insetBy(dx: -1, dy: -1)), with: .color(.black), lineWidth: 1)
                        context.stroke(Path(center), with: .color(.white), lineWidth: 1)
                    }
                }
            Group {
                if isMeasuring {
                    ProgressView().controlSize(.mini)
                } else if let rgb = Self.centerColor(of: pixels) {
                    HStack(spacing: 6) {
                        Text("R \(Self.percent(rgb.r))")
                        Text("G \(Self.percent(rgb.g))")
                        Text("B \(Self.percent(rgb.b))")
                    }
                    .monospacedDigit()
                    .accessibilityLabel("Red \(Self.percent(rgb.r)) percent, green \(Self.percent(rgb.g)) percent, blue \(Self.percent(rgb.b)) percent")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 9))
            .frame(width: side, height: 22)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .shadow(radius: 4, y: 2)
    }

    /// As a percentage without the sign, so the three fit across the loupe.
    private static func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(1)))
    }

    /// The center pixel's color, from 0 to 1 per channel; `nil` past the photo's edge.
    private static func centerColor(of image: CGImage) -> (r: Double, g: Double, b: Double)? {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        guard offset + 3 < CFDataGetLength(data), bytes[offset + 3] > 0 else { return nil }
        return (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255)
    }
}
