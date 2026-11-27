import ProofKit
import SwiftUI

/// What the White Balance eyedropper measures on the canvas, which the eyedropper covers: the
/// photo's pixels under a point for the loupe, and the patch a click or tap sets the white
/// balance from. Each app's eyedropper turns its own input into these points.
@MainActor
public struct WhiteBalanceSampler {
    let library: Library
    let renderer: RAWRenderer
    /// The eyedropper's size, in points, which is the canvas's.
    let size: CGSize

    /// Drawable pixels across the patch a click measures, and the least it measures of the photo
    /// itself when zoomed far in, so a single noisy pixel doesn't decide the white balance.
    private static let patchPixels: CGFloat = 5
    private static let minimumPatchPhotoPixels: CGFloat = 4

    public init(library: Library, renderer: RAWRenderer, size: CGSize) {
        self.library = library
        self.renderer = renderer
        self.size = size
    }

    /// The point on the photo under `location`, from 0 to 1 on each axis, and the photo's frame in
    /// drawable pixels; `nil` off the photo.
    private func photoPoint(at location: CGPoint) -> (point: CGPoint, frame: CGRect)? {
        let zoom = library.zoom
        guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else { return nil }
        let pixelsPerPoint = zoom.viewSize.width / size.width
        let pixel = CGPoint(x: location.x * pixelsPerPoint, y: location.y * pixelsPerPoint)
        guard let point = zoom.viewport.photoPoint(at: pixel, photo: zoom.photoSize, view: zoom.viewSize) else { return nil }
        return (point, zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize))
    }

    /// The pixels around `location` as the canvas shows them, for the loupe: from the sharp region
    /// while zoomed where there is one, otherwise from the screen-size photo.
    public func pixels(at location: CGPoint) -> CGImage? {
        guard let (point, _) = photoPoint(at: location), let shown = library.zoom.shown else { return nil }
        let source = shown.detail.flatMap { $0.region.contains(point) ? $0 : nil } ?? shown.photo
        return renderer.pixels(of: source, around: point, count: LoupeView.cells)
    }

    /// Sets the white balance that makes the patch at `location` neutral gray.
    public func pick(at location: CGPoint) {
        guard !library.isAutoAdjusting, let patch = patch(at: location) else { return }
        let library = library, renderer = renderer
        Task { await library.pickWhiteBalance(in: patch, with: renderer) }
    }

    /// Sets Temperature and Tint from the patch at `location` while the iPhone's eyedropper mode
    /// is open (#298), without closing it. A sample asked for while one is measured waits for it.
    public func sample(at location: CGPoint) {
        guard let patch = patch(at: location) else { return }
        let library = library, renderer = renderer
        Task { await library.sampleWhiteBalance(in: patch, with: renderer) }
    }

    /// The patch measured at `location`, from 0 to 1 on each axis of the photo; `nil` off it.
    private func patch(at location: CGPoint) -> CGRect? {
        guard let (point, frame) = photoPoint(at: location) else { return nil }
        let photo = library.zoom.photoSize
        let width = max(Self.patchPixels / frame.width, Self.minimumPatchPhotoPixels / photo.width)
        let height = max(Self.patchPixels / frame.height, Self.minimumPatchPhotoPixels / photo.height)
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }
}

/// The eyedropper's loupe: the pixels under the pointer enlarged on a grid, the center one, which
/// the click measures, outlined, and its red, green and blue as percentages, as Lightroom shows
/// them; the three are close to equal over something neutral.
public struct LoupeView: View {
    let pixels: CGImage
    let isMeasuring: Bool

    /// The loupe shows this many pixels on a side, each this many points wide.
    public static let cells = 11
    #if os(iOS)
    public static let cellSize: CGFloat = 12
    #else
    public static let cellSize: CGFloat = 10
    #endif
    /// The height and size of the red, green and blue values under the pixels.
    static let valuesHeight: CGFloat = 22
    #if os(iOS)
    static let valuesFontSize: CGFloat = 11
    #else
    static let valuesFontSize: CGFloat = 9
    #endif
    /// The loupe's whole size, in points.
    public static var size: CGSize {
        CGSize(width: CGFloat(cells) * cellSize, height: CGFloat(cells) * cellSize + valuesHeight)
    }

    public init(pixels: CGImage, isMeasuring: Bool) {
        self.pixels = pixels
        self.isMeasuring = isMeasuring
    }

    private var cells: Int { Self.cells }
    private var cellSize: CGFloat { Self.cellSize }

    public var body: some View {
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
            .font(.system(size: Self.valuesFontSize))
            .frame(width: side, height: Self.valuesHeight)
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
