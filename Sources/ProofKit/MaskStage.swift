import CoreImage
import ImageIO
import os

/// Applies layers: each layer's adjustments, blended into the photo by its mask. Runs after the
/// global tone and before color, on the whole uncropped photo in linear light, so a mask stays
/// on what it covers when the crop changes, and the look and color sliders apply on top.
enum MaskStage {
    /// Applies the enabled layers to `image`, the whole photo, in order.
    static func apply(_ layers: [Layer], to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !layers.isEmpty, extent.width >= 1, extent.height >= 1, !extent.isInfinite, let kernels else { return image }
        return layers.reduce(image) { current, layer in
            guard layer.isEnabled, !layer.adjustments.isNeutral, let weights = weights(of: layer.mask, extent: extent)
            else { return current }
            let adjusted = layer.adjustments.apply(to: current)
            return kernels.blend.apply(extent: extent, arguments: [
                adjusted, current, weights, Float(layer.mask.isInverted ? 1 : 0),
            ]) ?? current
        }
    }

    /// Tints the parts of `image`, the whole photo, that the mask of `layers[index]` covers in red,
    /// so the mask can be seen. Shown whether or not the layer is on.
    static func overlay(_ layers: [Layer], index: Int?, on image: CIImage) -> CIImage {
        let extent = image.extent
        guard let index, layers.indices.contains(index), extent.width >= 1, extent.height >= 1, !extent.isInfinite,
              let kernels, let weights = weights(of: layers[index].mask, extent: extent)
        else { return image }
        return kernels.overlay.apply(extent: extent, arguments: [
            image, weights, Float(layers[index].mask.isInverted ? 1 : 0),
        ]) ?? image
    }

    /// The mask's weights over `extent`, the whole photo, before inverting: gray from 0 to 1.
    static func weights(of mask: Mask, extent: CGRect) -> CIImage? {
        guard let kernels else { return nil }
        let long = max(extent.width, extent.height)
        // Core Image's y axis points up.
        func placed(_ point: CGPoint) -> CIVector {
            CIVector(x: extent.minX + point.x * extent.width, y: extent.maxY - point.y * extent.height)
        }
        switch mask.shape {
        case let .linear(gradient):
            var start = placed(gradient.start), end = placed(gradient.end)
            // At least a pixel apart, so the gradient has a direction; a hard edge then.
            if hypot(end.x - start.x, end.y - start.y) < 1 {
                start = CIVector(x: start.x, y: start.y + 0.5)
                end = CIVector(x: end.x, y: end.y - 0.5)
            }
            return kernels.linear.apply(extent: extent, arguments: [start, end])
        case let .radial(gradient):
            let radii = CIVector(x: max(clamped(gradient.radiusX, to: RadialMask.radiusRange) * long, 1),
                                 y: max(clamped(gradient.radiusY, to: RadialMask.radiusRange) * long, 1))
            // Clockwise on screen, where y points down; in Core Image's coordinates the x axis
            // turns toward negative y.
            let angle = gradient.angle * .pi / 180
            let axisX = CIVector(x: cos(angle), y: -sin(angle))
            let axisY = CIVector(x: sin(angle), y: cos(angle))
            let feather = clamped(gradient.feather, to: RadialMask.featherRange) / 100
            // At least about a pixel and a half wide, so a hard edge isn't jagged.
            let inner = min(1 - feather, 1 - 1.5 / min(radii.x, radii.y))
            return kernels.radial.apply(extent: extent, arguments: [
                placed(gradient.center), axisX, axisY, radii, Float(max(inner, 0)),
            ])
        case let .brush(brush):
            guard let raster = BrushRaster.image(of: brush, aspect: extent.size) else { return nil }
            return stretched(raster, over: extent)
        case let .subject(subject):
            guard let raster = SubjectRaster.image(of: subject) else { return nil }
            return stretched(raster, over: extent)        case .unknown:
            return nil
        }
    }

    /// `image`, gray, scaled to cover `extent`. Not color managed, so its values are the weights.
    private static func stretched(_ image: CGImage, over extent: CGRect) -> CIImage {
        let source = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        return source
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(image.width),
                                               y: extent.height / CGFloat(image.height))
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
            .clampedToExtent()
            .cropped(to: extent)
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private struct Kernels {
        let linear: CIColorKernel
        let radial: CIColorKernel
        let blend: CIColorKernel
        let overlay: CIColorKernel
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where layers then
    /// have no effect rather than failing the whole render.
    private static let kernels: Kernels? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source),
              let linear = compiled.first(where: { $0.name == "proofLinearMask" }) as? CIColorKernel,
              let radial = compiled.first(where: { $0.name == "proofRadialMask" }) as? CIColorKernel,
              let blend = compiled.first(where: { $0.name == "proofMaskBlend" }) as? CIColorKernel,
              let overlay = compiled.first(where: { $0.name == "proofMaskOverlay" }) as? CIColorKernel
        else { return nil }
        return Kernels(linear: linear, radial: radial, blend: blend, overlay: overlay)
    }()

    /// Gradients ease in and out with `smoothstep`, so neither end of the fade shows as a line.
    /// The overlay's red is in linear light, at about half strength where the mask is full.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofLinearMask(float2 start, float2 end, destination dest) {
            float2 along = end - start;
            float t = dot(dest.coord() - start, along) / dot(along, along);
            float w = 1.0 - smoothstep(0.0, 1.0, t);
            return float4(w, w, w, 1.0);
        }

        [[stitchable]] float4 proofRadialMask(float2 center, float2 axisX, float2 axisY, float2 radii,
                                              float inner, destination dest) {
            float2 d = dest.coord() - center;
            float2 p = float2(dot(d, axisX) / radii.x, dot(d, axisY) / radii.y);
            float w = 1.0 - smoothstep(inner, 1.0, length(p));
            return float4(w, w, w, 1.0);
        }

        [[stitchable]] float4 proofMaskBlend(sample_t adjusted, sample_t original, sample_t mask, float invert) {
            float m = mix(mask.r, 1.0 - mask.r, invert);
            return float4(mix(original.rgb, adjusted.rgb, m), original.a);
        }

        [[stitchable]] float4 proofMaskOverlay(sample_t pixel, sample_t mask, float invert) {
            float m = mix(mask.r, 1.0 - mask.r, invert);
            return float4(mix(pixel.rgb, float3(0.8, 0.0, 0.0), 0.55 * m), pixel.a);
        }
    }
    }
    """
}

extension LocalAdjustments {
    /// The adjustments applied to the whole of `image`, which is in linear light, through the
    /// same stages as the global sliders, in the same order. Values outside their ranges, which
    /// only a hand-edited sidecar can hold, are clamped.
    func apply(to image: CIImage) -> CIImage {
        func value(_ v: Double) -> Double { MaskStage.clamped(v, to: Self.range) }
        let stops = MaskStage.clamped(exposure, to: Self.exposureRange)
        let warm = value(temperature) / 100, magenta = value(tint) / 100
        // Half a stop on red against blue at the ends of Temperature, and two fifths of a stop
        // off green at the ends of Tint, scaled together so a gray's brightness stays the same.
        var gains = SIMD3<Double>(pow(2, warm / 2), pow(2, -magenta * 0.4), pow(2, -warm / 2))
        gains /= 0.2126 * gains.x + 0.7152 * gains.y + 0.0722 * gains.z
        gains *= pow(2, stops)
        var result = image
        if gains != SIMD3(1, 1, 1) {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gains.x, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gains.y, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gains.z, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ]).cropped(to: image.extent)
        }
        result = HighlightsShadows.apply(to: result, highlights: value(highlights), shadows: value(shadows))
        result = TextureClarity.apply(to: result, texture: value(texture), clarity: value(clarity))
        result = Dehaze.apply(to: result, amount: value(dehaze))
        result = ToneLookup(contrast: value(contrast), whites: value(whites), blacks: value(blacks)).apply(to: result)
        return ColorAdjustments.apply(to: result, vibrance: 0, saturation: value(saturation))
    }
}

/// Brush strokes drawn into a grayscale image of the whole photo, `longEdge` pixels on its long
/// edge whatever the render's size, so the canvas, thumbnails and export use the same mask.
/// The last few images are kept, since a render repeats while a slider moves. The last brush
/// drawn is kept too, so while a stroke is painted only its newest part is drawn.
enum BrushRaster {
    static let longEdge = 2048

    private static let cache = OSAllocatedUnfairLock(initialState: [(key: Key, image: CGImage)]())
    private static let last = OSAllocatedUnfairLock<Canvas?>(initialState: nil)

    private struct Key: Hashable {
        var brush: BrushMask
        var width: Int
        var height: Int
    }

    static func image(of brush: BrushMask, aspect: CGSize) -> CGImage? {
        guard aspect.width > 0, aspect.height > 0 else { return nil }
        let scale = Double(longEdge) / max(aspect.width, aspect.height)
        let key = Key(brush: brush, width: max(Int((aspect.width * scale).rounded()), 1),
                      height: max(Int((aspect.height * scale).rounded()), 1))
        if let hit = cache.withLock({ $0.first { $0.key == key }?.image }) { return hit }
        let image = last.withLock { canvas -> CGImage? in
            if canvas == nil || !canvas!.extend(to: brush, width: key.width, height: key.height) {
                canvas = Canvas(brush, width: key.width, height: key.height)
            }
            return canvas!.image
        }
        guard let image else { return nil }
        cache.withLock { entries in
            entries.removeAll { $0.key == key }
            entries.insert((key, image), at: 0)
            if entries.count > 6 { entries.removeLast() }
        }
        return image
    }

    /// The mask's weights, from the top row down.
    static func draw(_ brush: BrushMask, width: Int, height: Int) -> [Float] {
        Canvas(brush, width: width, height: height).mask
    }

    /// Each stroke is drawn on its own as the farthest its brush reached each pixel, so going
    /// back and forth within one stroke doesn't build up; then it adds to the mask, or takes
    /// away from it, by its flow. The mask before the last stroke and the last stroke's reach are
    /// kept, so the last stroke can grow without drawing the others again.
    private struct Canvas {
        var brush: BrushMask
        let width: Int
        let height: Int
        /// The mask before the last stroke.
        var base: [Float]
        /// How far the last stroke's brush reached each pixel.
        var reach: [Float]
        var mask: [Float]
        var bytes: [UInt8]

        init(_ brush: BrushMask, width: Int, height: Int) {
            self.brush = brush
            self.width = width
            self.height = height
            let count = width * height
            base = [Float](repeating: 0, count: count)
            reach = base
            mask = base
            bytes = [UInt8](repeating: 0, count: count)
            for (index, stroke) in brush.strokes.enumerated() {
                let isLast = index == brush.strokes.count - 1
                if isLast { base = mask }
                guard let box = paint(stroke, from: 0) else { continue }
                if isLast {
                    composite(stroke, in: box)
                } else {
                    // Earlier strokes go straight into the mask, and their reach is cleared.
                    let flow = Self.flow(of: stroke)
                    for y in box.minY...box.maxY {
                        for x in box.minX...box.maxX {
                            let i = y * width + x
                            let r = reach[i] * flow
                            reach[i] = 0
                            guard r > 0 else { continue }
                            mask[i] = stroke.erases ? mask[i] * (1 - r) : mask[i] + (1 - mask[i]) * r
                        }
                    }
                }
            }
            for i in 0..<count { bytes[i] = Self.byte(mask[i]) }
        }

        /// Draws only what `brush` adds to this one: the newest part of its last stroke, or a new
        /// stroke after it. `false` when it changes more than that.
        mutating func extend(to brush: BrushMask, width: Int, height: Int) -> Bool {
            guard width == self.width, height == self.height else { return false }
            let old = self.brush.strokes, new = brush.strokes
            if old == new { return true }
            if new.count == old.count, let lastOld = old.last, let lastNew = new.last,
               Array(old.dropLast()) == Array(new.dropLast()),
               lastNew.radius == lastOld.radius, lastNew.feather == lastOld.feather,
               lastNew.flow == lastOld.flow, lastNew.erases == lastOld.erases,
               lastNew.points.count > lastOld.points.count, lastNew.points.starts(with: lastOld.points) {
                self.brush = brush
                // From the last point already drawn, so the segment joining it is drawn too.
                if let box = paint(lastNew, from: max(lastOld.points.count / 2 - 1, 0)) { composite(lastNew, in: box) }
                return true
            }
            if new.count == old.count + 1, Array(new.dropLast()) == old, let stroke = new.last {
                self.brush = brush
                base = mask
                reach = [Float](repeating: 0, count: width * height)
                if let box = paint(stroke, from: 0) { composite(stroke, in: box) }
                return true
            }
            return false
        }

        var image: CGImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        /// Puts the last stroke onto the mask before it, within `box`.
        private mutating func composite(_ stroke: BrushStroke, in box: Box) {
            let flow = Self.flow(of: stroke)
            for y in box.minY...box.maxY {
                for x in box.minX...box.maxX {
                    let i = y * width + x
                    let r = reach[i] * flow
                    mask[i] = stroke.erases ? base[i] * (1 - r) : base[i] + (1 - base[i]) * r
                    bytes[i] = Self.byte(mask[i])
                }
            }
        }

        private struct Box {
            var minX: Int, maxX: Int, minY: Int, maxY: Int
        }

        /// Raises `reach` to how far the stroke's brush reaches along its path from the point at
        /// `first`, and returns the pixels it may have changed; `nil` for none.
        private mutating func paint(_ stroke: BrushStroke, from first: Int) -> Box? {
            let points = stroke.path.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
            guard first < points.count, Self.flow(of: stroke) > 0 else { return nil }
            let long = Double(max(width, height))
            let radius = max(MaskStage.clamped(stroke.radius, to: BrushStroke.radiusRange) * long, 0.75)
            let feather = MaskStage.clamped(stroke.feather, to: BrushStroke.featherRange) / 100
            // At least about a pixel of fade, so a hard brush isn't jagged.
            let inner = min(radius * (1 - feather), radius - 1)
            let segments = points.count == 1 ? [(points[0], points[0])]
                : Array(zip(points[first...], points[first...].dropFirst()))
            var box: Box?
            for (a, b) in segments {
                let x0 = max(Int((min(a.x, b.x) - radius).rounded(.down)), 0)
                let x1 = min(Int((max(a.x, b.x) + radius).rounded(.up)), width - 1)
                let y0 = max(Int((min(a.y, b.y) - radius).rounded(.down)), 0)
                let y1 = min(Int((max(a.y, b.y) + radius).rounded(.up)), height - 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                box = Box(minX: min(box?.minX ?? x0, x0), maxX: max(box?.maxX ?? x1, x1),
                          minY: min(box?.minY ?? y0, y0), maxY: max(box?.maxY ?? y1, y1))
                let dx = b.x - a.x, dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                for y in y0...y1 {
                    let py = Double(y) + 0.5
                    for x in x0...x1 {
                        let px = Double(x) + 0.5
                        // Distance to the segment.
                        var t = lengthSquared > 0 ? ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared : 0
                        t = min(max(t, 0), 1)
                        let distance = hypot(px - (a.x + t * dx), py - (a.y + t * dy))
                        guard distance < radius else { continue }
                        var w = 1.0
                        if distance > inner {
                            let s = (distance - inner) / (radius - inner)
                            w = 1 - s * s * (3 - 2 * s)
                        }
                        let i = y * width + x
                        reach[i] = max(reach[i], Float(w))
                    }
                }
            }
            return box
        }

        static func flow(of stroke: BrushStroke) -> Float {
            Float(MaskStage.clamped(stroke.flow, to: BrushStroke.flowRange) / 100)
        }

        static func byte(_ weight: Float) -> UInt8 {
            UInt8((min(max(weight, 0), 1) * 255).rounded())
        }
    }

    static func grayImage(_ weights: [Float], width: Int, height: Int) -> CGImage? {
        let bytes = weights.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A subject mask's PNG, decoded once and kept while it is in use, with its middle.
enum SubjectRaster {
    private struct Entry {
        var png: Data
        var image: CGImage
        var center: CGPoint?
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Entry]())

    static func image(of subject: SubjectMask) -> CGImage? {
        entry(of: subject)?.image
    }

    static func center(of subject: SubjectMask) -> CGPoint? {
        entry(of: subject)?.center
    }

    private static func entry(of subject: SubjectMask) -> Entry? {
        if let hit = cache.withLock({ $0.first { $0.png == subject.png } }) { return hit }
        guard let source = CGImageSourceCreateWithData(subject.png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let entry = Entry(png: subject.png, image: image, center: center(of: image))
        cache.withLock { entries in
            entries.insert(entry, at: 0)
            if entries.count > 4 { entries.removeLast() }
        }
        return entry
    }

    /// The mask's center of weight, from 0 to 1 from the top left, measured on a small copy.
    private static func center(of image: CGImage) -> CGPoint? {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0, x = 0.0, y = 0.0
        // The context's first row is the image's top.
        for row in 0..<height {
            for column in 0..<width {
                let w = Double(pixels[row * width + column])
                total += w
                x += w * (Double(column) + 0.5)
                y += w * (Double(row) + 0.5)
            }
        }
        guard total > 0 else { return nil }
        return CGPoint(x: x / total / Double(width), y: y / total / Double(height))
    }
}

extension SubjectMask {
    /// The middle of the subject, from 0 to 1 from the top left of the photo, where the Masks
    /// tool puts the mask's pin. `nil` for an empty mask.
    public var center: CGPoint? { SubjectRaster.center(of: self) }
}
