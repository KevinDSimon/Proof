import CoreImage
import Metal

public enum RAWRendererError: Error, Equatable {
    case noMetalDevice
    case unsupportedFile(URL)
    case noPhotoOpen
    case renderFailed
}

/// A photo, or the part of it zoom shows, rendered at screen size. The texture is written once by
/// `RAWRenderer` and only read afterwards, which is what makes passing it between threads safe.
public struct RenderedPhoto: @unchecked Sendable {
    public let texture: MTLTexture
    /// The part of the photo the texture holds, from 0 to 1 on each axis from the top left.
    public var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The whole cropped photo's size at full resolution, in pixels.
    public var photoSize: CGSize = .zero
    /// The whole photo before the black-and-white mix, while it is on, so the hue graph keeps
    /// showing the colors Selective Color adjusts. Rendered only when the histogram is measured.
    var colors: CIImage?
}

/// Decodes one RAW file with `CIRAWFilter` and renders it into Metal textures sized for the screen.
/// It is an actor so that decoding and GPU work never run on the main thread.
public actor RAWRenderer {
    public nonisolated let device: MTLDevice
    private let context: CIContext
    private let commandQueue: MTLCommandQueue
    private var filter: CIRAWFilter?
    private var openURL: URL?
    /// The open photo's camera white balance, read before any render changes the filter's.
    private var asShot = WhiteBalance(temperature: 6500, tint: 0)
    /// The open photo's default sharpening and noise reduction, read before any render changes the filter's.
    private var cameraDetail = CameraDetail(sharpness: 0, luminanceNoiseReduction: 0, detail: 0, colorNoiseReduction: 0)
    /// The open photo's lens profile and its default, read before any render changes the filter's.
    private var cameraLens = CameraLens()
    /// Separate from `context` and without cached intermediates, so thumbnails of many photos
    /// don't fill GPU memory or evict the open photo's decode.
    private lazy var thumbnailContext = CIContext(mtlCommandQueue: commandQueue, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    /// For the histogram only. Float, so sparse bins keep their precision; nonisolated, so
    /// measuring never queues behind the next render on the actor. `CIContext` is thread-safe.
    private nonisolated let histogramContext: CIContext

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            throw RAWRendererError.noMetalDevice
        }
        self.device = device
        self.commandQueue = commandQueue
        // Intermediates stay in linear extended sRGB so later tone and color stages don't clip.
        // They are cached so that a slider change reuses the RAW decode instead of repeating it:
        // about 150 ms at scaleFactor 0.25 without the cache. `open` clears the cache.
        context = CIContext(mtlCommandQueue: commandQueue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ])
        histogramContext = CIContext(mtlCommandQueue: commandQueue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false,
        ])
    }

    /// Opens the file once; later renders reuse the decoder so a resize doesn't re-read the file
    /// from a slow network volume.
    public func open(_ url: URL) throws {
        guard url != openURL else { return }
        // CIRAWFilter(imageURL:) succeeds for any file; an unreadable one shows up as no size.
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero, filter.outputImage != nil else {
            throw RAWRendererError.unsupportedFile(url)
        }
        // Only one photo's decode stays in GPU memory.
        context.clearCaches()
        self.filter = filter
        asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        cameraDetail = CameraDetail(of: filter)
        cameraLens = CameraLens(of: filter)
        openURL = url
    }

    /// Renders the open photo with `recipe` applied, scaled to fit `targetSize` (in pixels) and
    /// never larger than the sensor. The texture has the cropped photo's aspect ratio, not the target's.
    /// `lut` is the loaded LUT that `recipe.look` names; without one the look is skipped.
    public func render(fitting targetSize: CGSize, recipe: EditRecipe = EditRecipe(),
                       lut: PreparedLUT? = nil) throws -> RenderedPhoto {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        let scale = Self.scaleFactor(
            nativeSize: filter.nativeSize,
            orientation: filter.orientation,
            crop: recipe.crop,
            fitting: targetSize
        )
        return try render(scaleFactor: scale, recipe: recipe, lut: lut)
    }

    /// The straighten angle that levels the horizon in the open photo, from `Horizon`, or `nil`
    /// when none is found. Vision looks at the photo with `recipe` applied, turned and flipped
    /// but not straightened or cropped, at about `targetSize`.
    public func horizonCorrection(fitting targetSize: CGSize, recipe: EditRecipe,
                                  lut: PreparedLUT? = nil) async throws -> Double? {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        var recipe = recipe
        recipe.crop = recipe.crop?.turnedOnly
        // A vignette's darkened edges, grain and glow could read as lines or hide them; they
        // aren't part of the scene.
        recipe.removeEffects()
        filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                    crop: recipe.crop, fitting: targetSize))
        guard let image = Self.apply(recipe, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens, lut: lut),
              let cgImage = context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                  colorSpace: Self.colorSpace)
        else { throw RAWRendererError.renderFailed }
        return try await Horizon.correction(in: cgImage)
    }

    /// The white balance Auto chooses for the open photo, as cropped in `recipe`, from
    /// `AutoAdjust`. It depends only on the photo and the crop, so choosing it again gives the same.
    public func autoWhiteBalance(recipe: EditRecipe) throws -> WhiteBalance {
        var measured = Self.measuring(recipe)
        let found = try AutoAdjust.whiteBalance(from: asShot) { whiteBalance in
            measured.basic.temperature = whiteBalance.temperature
            measured.basic.tint = whiteBalance.tint
            return AutoAdjust.cast(of: try samples(of: measured))
        }
        guard let found else { throw RAWRendererError.renderFailed }
        return found
    }

    /// The white balance that makes `patch` of the open photo neutral gray, for the eyedropper.
    /// `patch` is from 0 to 1 on each axis of the photo as cropped in `recipe`, from the top left.
    /// Found as Auto's is, measuring only the patch. The search starts from the camera's white
    /// balance rather than the current one, which may be far enough off to push a channel of the
    /// patch below zero; so picking the same spot always gives the same result. `nil` when the
    /// patch is too dark to tell its color.
    public func whiteBalance(neutralIn patch: CGRect, recipe: EditRecipe) throws -> WhiteBalance? {
        var measured = Self.measuring(recipe)
        return try AutoAdjust.whiteBalance(from: asShot) { whiteBalance in
            measured.basic.temperature = whiteBalance.temperature
            measured.basic.tint = whiteBalance.tint
            return AutoAdjust.cast(ofNeutral: try samples(of: measured, in: patch))
        }
    }

    /// The Tone sliders Auto chooses for the open photo, as cropped and white balanced in
    /// `recipe`, from `AutoAdjust`. They don't depend on the Tone sliders already set.
    public func autoTone(recipe: EditRecipe) throws -> AutoAdjust.Tone {
        AutoAdjust.tone(luminances: try samples(of: Self.measuring(recipe)).map(AutoAdjust.luminance))
    }

    /// The chromatic aberration Remove Chromatic Aberration corrects in the open photo, measured
    /// on the whole uncropped photo with `recipe`'s white balance, detail and lens profile, so the
    /// measurement doesn't depend on the crop or the tone. Only the render runs on the actor; the
    /// measuring runs beside it, so renders of the canvas go on meanwhile.
    public func chromaticAberration(recipe: EditRecipe) async throws -> ChromaticAberration {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        var measured = Self.measuring(recipe)
        measured.crop = nil
        // Measured on the photo as the lens drew it, since the correction comes before the
        // manual distortion and vignetting.
        measured.lens.chromaticAberration = nil
        measured.lens.distortion = nil
        measured.lens.vignetting = nil
        measured.transform = PerspectiveTransform()
        let size = CGSize(width: ChromaticAberration.measuringSize, height: ChromaticAberration.measuringSize)
        filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                    fitting: size))
        guard let image = Self.apply(measured, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens)
        else { throw RAWRendererError.renderFailed }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw RAWRendererError.renderFailed }
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        histogramContext.render(image, toBitmap: &bitmap, rowBytes: width * 4 * MemoryLayout<Float>.size,
                                bounds: extent, format: .RGBAf,
                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return await Task.detached(priority: .userInitiated) { [bitmap] in
            ChromaticAberration.measure(rgba: bitmap, width: width, height: height)
        }.value
    }

    /// The straight edges Upright goes by in the open photo, in pixels of an image of the
    /// returned size: the whole photo as the camera oriented it, with `recipe`'s white balance,
    /// detail and lens corrections, but no perspective correction, crop or tone. Only the render
    /// runs on the actor; the finding runs beside it.
    public func uprightSegments(recipe: EditRecipe) async throws -> (segments: [LineSegment], size: CGSize) {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        var measured = Self.measuring(recipe)
        measured.crop = nil
        measured.transform = PerspectiveTransform()
        let size = CGSize(width: LineDetector.measuringSize, height: LineDetector.measuringSize)
        filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                    fitting: size))
        guard let image = Self.apply(measured, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens)
        else { throw RAWRendererError.renderFailed }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 2, height > 2 else { throw RAWRendererError.renderFailed }
        // Gamma-encoded, so an edge counts the same in the shadows as in the highlights.
        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        histogramContext.render(image, toBitmap: &bitmap, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let segments = await Task.detached(priority: .userInitiated) { [bitmap] in
            var gray = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                gray[i] = (0.2126 * Float(bitmap[4 * i]) + 0.7152 * Float(bitmap[4 * i + 1])
                    + 0.0722 * Float(bitmap[4 * i + 2])) / 255
            }
            return LineDetector.segments(in: gray, width: width, height: height)
        }.value
        return (segments, CGSize(width: width, height: height))
    }

    /// `recipe`'s white balance, detail, lens corrections, perspective and crop with every other adjustment at its default, so
    /// Auto measures the photo itself and not the tone, color or look already applied.
    static func measuring(_ recipe: EditRecipe) -> EditRecipe {
        var measured = EditRecipe()
        measured.basic.whiteBalance = recipe.basic.whiteBalance
        measured.basic.temperature = recipe.basic.temperature
        measured.basic.tint = recipe.basic.tint
        measured.detail = recipe.detail
        measured.lens = recipe.lens
        measured.transform = recipe.transform
        measured.crop = recipe.crop
        return measured
    }

    /// The linear RGB pixels of the open photo with `recipe`, at about `AutoAdjust.sampleSize`.
    /// With `region`, from 0 to 1 on each axis from the top left, only that part, at a scale that
    /// makes it about `AutoAdjust.patchSize` pixels across, up to full resolution.
    private func samples(of recipe: EditRecipe, in region: CGRect? = nil) throws -> [SIMD3<Float>] {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        if let region {
            let photo = Self.photoSize(nativeSize: filter.nativeSize, orientation: filter.orientation, crop: recipe.crop)
            let across = max(region.width * photo.width, region.height * photo.height, 1)
            filter.scaleFactor = Float(min(AutoAdjust.patchSize / across, 1))
        } else {
            let size = CGSize(width: AutoAdjust.sampleSize, height: AutoAdjust.sampleSize)
            filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                        crop: recipe.crop, fitting: size))
        }
        guard let image = Self.apply(recipe, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens) else {
            throw RAWRendererError.renderFailed
        }
        var extent = image.extent.integral
        if let region {
            // Core Image's y axis points up. A patch narrower than a pixel still gets one.
            let full = extent
            let x = full.minX + region.midX * full.width, y = full.maxY - region.midY * full.height
            let half = CGSize(width: max(region.width * full.width, 1) / 2, height: max(region.height * full.height, 1) / 2)
            extent = CGRect(x: x - half.width, y: y - half.height, width: half.width * 2, height: half.height * 2)
                .integral.intersection(full)
            guard !extent.isNull else { throw RAWRendererError.renderFailed }
        }
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw RAWRendererError.renderFailed }
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        histogramContext.render(image, toBitmap: &bitmap, rowBytes: width * 4 * MemoryLayout<Float>.size,
                                bounds: extent, format: .RGBAf,
                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return stride(from: 0, to: bitmap.count, by: 4).map { SIMD3(bitmap[$0], bitmap[$0 + 1], bitmap[$0 + 2]) }
    }

    /// The photo's size in pixels as the camera oriented it, before any crop or turn. Blocks on
    /// file I/O; `nil` if it isn't a RAW photo.
    public static func orientedSize(of url: URL) -> CGSize? {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
        return oriented(filter.nativeSize, filter.orientation)
    }

    /// Renders `region` of the open photo, from 0 to 1 on each axis from the top left, at `scale`
    /// of full resolution, at most 1, for zoom. The caller keeps the region small enough at that
    /// scale to cover about the view, so only the visible part of a large photo is rendered. The
    /// result's region is `region` grown to whole pixels and kept within the photo.
    public func render(region: CGRect, scale: CGFloat, recipe: EditRecipe = EditRecipe(),
                       lut: PreparedLUT? = nil) throws -> RenderedPhoto {
        try render(scaleFactor: min(max(scale, 0.01), 1), region: region, recipe: recipe, lut: lut)
    }

    /// The cropped photo's size at full resolution, in whole pixels as `applyGeometry` makes it.
    static func photoSize(nativeSize: CGSize, orientation: CGImagePropertyOrientation, crop: Crop?) -> CGSize {
        let oriented = oriented(nativeSize, orientation)
        guard let crop else { return oriented }
        let turned = crop.turnedSize(of: oriented)
        guard crop.hasRectangle else { return turned }
        return CGSize(width: max((crop.width * turned.width).rounded(.down), 1),
                      height: max((crop.height * turned.height).rounded(.down), 1))
    }

    /// Renders at an exact `CIRAWFilter.scaleFactor`. Internal so that only export and timing
    /// tests can ask for full sensor resolution of the whole photo; the app goes through
    /// `render(fitting:)` and `render(region:scale:)`.
    func render(scaleFactor scale: CGFloat, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                recipe: EditRecipe, lut: PreparedLUT? = nil) throws -> RenderedPhoto {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        filter.scaleFactor = Float(scale)
        guard let whole = Self.apply(recipe, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens, lut: lut) else { throw RAWRendererError.renderFailed }

        // The region in Core Image's coordinates, whose y axis points up, in whole pixels.
        let full = whole.extent.integral
        // Edges within a hair of a whole pixel are taken as on it, so a region given in whole pixels
        // isn't grown by a pixel of rounding error; others grow outward to whole pixels.
        func snapped(_ value: CGFloat, _ round: FloatingPointRoundingRule) -> CGFloat {
            abs(value - value.rounded()) < 0.001 ? value.rounded() : value.rounded(round)
        }
        let minX = snapped(full.minX + region.minX * full.width, .down)
        let maxX = snapped(full.minX + region.maxX * full.width, .up)
        let minY = snapped(full.minY + (1 - region.maxY) * full.height, .down)
        let maxY = snapped(full.minY + (1 - region.minY) * full.height, .up)
        let extent = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(full)
        guard !extent.isNull, extent.width >= 1, extent.height >= 1 else { throw RAWRendererError.renderFailed }
        let image = whole.cropped(to: extent)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: max(Int(extent.width), 1),
            height: max(Int(extent.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RAWRendererError.renderFailed
        }

        // Not flipped: row 0 holds the bottom of the photo, which is what
        // `CIImage(mtlTexture:)` expects when `draw` reads it back.
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = Self.colorSpace
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        try context.startTask(toRender: origin, to: destination).waitUntilCompleted()
        let shown = CGRect(x: (extent.minX - full.minX) / full.width, y: (full.maxY - extent.maxY) / full.height,
                           width: extent.width / full.width, height: extent.height / full.height)
        var colors: CIImage?
        if recipe.blackAndWhite.isOn {
            var colored = recipe
            colored.blackAndWhite.isOn = false
            colors = Self.apply(colored, to: filter, asShot: asShot, cameraDetail: cameraDetail, cameraLens: cameraLens, lut: lut)
        }
        return RenderedPhoto(texture: texture, region: shown,
                             photoSize: Self.photoSize(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                       crop: recipe.crop),
                             colors: colors)
    }

    /// A thumbnail of `url` with `recipe` applied, at most `maxPixelSize` on the long edge, for
    /// the grid and the filmstrip. It doesn't change the open photo or its cached intermediates.
    public func thumbnail(of url: URL, recipe: EditRecipe, lut: PreparedLUT? = nil, maxPixelSize: Int) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else {
            throw RAWRendererError.unsupportedFile(url)
        }
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                    crop: recipe.crop, fitting: size))
        let asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        guard let image = Self.apply(recipe, to: filter, asShot: asShot, cameraDetail: CameraDetail(of: filter),
                                       cameraLens: CameraLens(of: filter), lut: lut),
              let thumbnail = thumbnailContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                             colorSpace: Self.colorSpace)
        else { throw RAWRendererError.renderFailed }
        return thumbnail
    }

    /// `lut` applied in full to `thumbnail`, a thumbnail of an edit with no look, for previews of
    /// looks. A LUT changes each pixel on its own, so applying it after the crop and to an 8-bit
    /// thumbnail looks the same at this size as step 4 of a full render, without decoding the photo again.
    public func applying(_ lut: PreparedLUT, to thumbnail: CGImage) throws -> CGImage {
        let image = CIImage(cgImage: thumbnail)
        let looked = LUTStage.apply(lut, strength: 1, to: image)
        guard let result = thumbnailContext.createCGImage(looked, from: image.extent, format: .RGBA8,
                                                          colorSpace: Self.colorSpace)
        else { throw RAWRendererError.renderFailed }
        return result
    }

    /// The histogram of a photo from `render(fitting:)`: what the canvas shows, at screen size,
    /// not the full-resolution photo. It reads the finished texture and renders nothing again,
    /// except a small copy in color for the hues while the photo is black and white.
    public nonisolated func histogram(of photo: RenderedPhoto) throws -> Histogram {
        guard let image = CIImage(mtlTexture: photo.texture, options: [.colorSpace: Self.colorSpace]),
              let histogram = Histogram.measure(image, hues: photo.colors, colorSpace: Self.colorSpace, context: histogramContext)
        else { throw RAWRendererError.renderFailed }
        return histogram
    }

    /// A small copy of a photo from `render(fitting:)`, at most `maxPixelSize` on the long edge,
    /// for the navigator. It reads the finished texture and renders nothing again.
    public nonisolated func preview(of photo: RenderedPhoto, maxPixelSize: Int) throws -> CGImage {
        guard let image = CIImage(mtlTexture: photo.texture, options: [.colorSpace: Self.colorSpace]) else {
            throw RAWRendererError.renderFailed
        }
        let scale = min(CGFloat(maxPixelSize) / max(image.extent.width, image.extent.height), 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let preview = histogramContext.createCGImage(small, from: small.extent.integral, format: .RGBA8,
                                                           colorSpace: Self.colorSpace)
        else { throw RAWRendererError.renderFailed }
        return preview
    }

    /// The `count` × `count` pixels of a rendered photo centered on `point`, from 0 to 1 on each
    /// axis of the whole photo from the top left, as shown, for the eyedropper's loupe. Pixels
    /// past the photo's edge are clear. `nil` when `point` is outside the part the photo holds.
    public nonisolated func pixels(of photo: RenderedPhoto, around point: CGPoint, count: Int) -> CGImage? {
        guard photo.region.contains(point),
              let image = CIImage(mtlTexture: photo.texture, options: [.colorSpace: Self.colorSpace])
        else { return nil }
        // The texture's row 0 is the photo's bottom, as Core Image's y axis points up.
        let x = (point.x - photo.region.minX) / photo.region.width * image.extent.width
        let y = (1 - (point.y - photo.region.minY) / photo.region.height) * image.extent.height
        let half = CGFloat(count / 2)
        let rect = CGRect(x: x.rounded(.down) - half, y: y.rounded(.down) - half, width: CGFloat(count), height: CGFloat(count))
        return histogramContext.createCGImage(image.cropped(to: rect), from: rect, format: .RGBA8,
                                              colorSpace: Self.colorSpace)
    }

    /// Draws a photo from `render(fitting:)` into `drawable` over `background`: centered and
    /// scaled to fit, or filling `frame`, the whole photo's place in the drawable in pixels from
    /// the top left, as `Viewport` gives it when zoomed. `detail`, from `render(region:scale:)`, is
    /// drawn over its part of the photo, so a zoomed view shows the sharp region where there is
    /// one and the screen-size photo, enlarged, everywhere else. Cheap enough to run in a view's
    /// draw callback while a new render is pending. The crop tool passes `angle`, in degrees
    /// clockwise, to straighten the photo around its center as it is dragged; the photo is scaled
    /// to fit as if upright.
    public nonisolated func draw(
        _ photo: RenderedPhoto?,
        detail: RenderedPhoto? = nil,
        frame: CGRect? = nil,
        into drawable: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        background: CIColor,
        angle: Double = 0
    ) throws {
        let bounds = CGRect(x: 0, y: 0, width: drawable.width, height: drawable.height)
        var composed = CIImage(color: background).cropped(to: bounds)
        if let photo {
            let frame = frame ?? Viewport().frame(photo: photo.photoSize == .zero ? CGSize(width: photo.texture.width,
                                                                                          height: photo.texture.height)
                                                                                : photo.photoSize,
                                                 view: bounds.size)
            var placed = try Self.place(photo, in: frame, bounds: bounds)
            if let detail {
                placed = try Self.place(detail, in: frame, bounds: bounds).composited(over: placed)
            }
            if angle != 0 {
                // Core Image's y axis points up here too, so a clockwise turn is a negative angle.
                let center = CGPoint(x: frame.midX, y: bounds.height - frame.midY)
                placed = placed.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(rotationAngle: -angle * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
            }
            composed = placed.composited(over: composed).cropped(to: bounds)
        }

        let destination = CIRenderDestination(mtlTexture: drawable, commandBuffer: commandBuffer)
        destination.colorSpace = Self.colorSpace
        destination.isFlipped = true
        try context.startTask(toRender: composed, to: destination)
    }

    /// `photo`'s texture scaled onto its region of `frame`, in Core Image's coordinates for a
    /// drawable of `bounds`. Enlarged textures are sampled from the nearest pixel, so pixels stay
    /// crisp when zoomed past 100%; at exactly 100% nothing is resampled.
    private static func place(_ photo: RenderedPhoto, in frame: CGRect, bounds: CGRect) throws -> CIImage {
        guard let image = CIImage(mtlTexture: photo.texture, options: [.colorSpace: colorSpace]) else {
            throw RAWRendererError.renderFailed
        }
        let target = CGRect(x: frame.minX + photo.region.minX * frame.width,
                            y: frame.minY + photo.region.minY * frame.height,
                            width: photo.region.width * frame.width, height: photo.region.height * frame.height)
        let scaleX = target.width / image.extent.width
        let scaleY = target.height / image.extent.height
        let sampled = scaleX > 1.01 && photo.region != CGRect(x: 0, y: 0, width: 1, height: 1) ? image.samplingNearest() : image
        return sampled.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(translationX: target.minX, y: bounds.height - target.maxY)))
    }

    /// Builds the Core Image graph for `recipe` in the order set out in docs/architecture.md. The
    /// canvas, thumbnails and export all go through here, so they can't drift apart. Stages that
    /// have no controls yet pass the image through; each one is filled in by its own issue.
    /// `asShot` is the camera's white balance, which a filter reused across renders has lost.
    /// `cameraDetail` is its default sharpening and noise reduction, which it has lost too.
    /// `cameraLens` is its lens profile and default, which it has lost too.
    /// `lut` is the loaded LUT that `recipe.look` names; the look is skipped without one.
    static func apply(_ recipe: EditRecipe, to filter: CIRAWFilter, asShot: WhiteBalance,
                      cameraDetail: CameraDetail, cameraLens: CameraLens,
                      lut: PreparedLUT? = nil) -> CIImage? {
        // 1. RAW decode in linear light, with the lens profile, then chromatic aberration, lens
        // vignetting, distortion and perspective. White
        // balance is in Kelvin and tint; exposure in stops.
        // Sharpening and noise reduction are the decoder's own; it sharpens only above half size.
        let whiteBalance = recipe.basic.whiteBalance(asShot: asShot)
        filter.neutralTemperature = Float(whiteBalance.temperature)
        filter.neutralTint = Float(whiteBalance.tint)
        filter.exposure = Float(recipe.basic.exposure)
        recipe.detail.decoded(camera: cameraDetail).apply(to: filter)
        // The lens profile corrects distortion and vignetting as the decoder reads the file.
        // A photo without one is left alone.
        if cameraLens.hasProfile { filter.isLensCorrectionEnabled = recipe.lens.appliesProfile(for: cameraLens) }
        guard let raw = filter.outputImage else { return nil }
        // Chromatic aberration next, about the center of the whole photo, where the lens's was.
        let aligned = ChromaticAberration.apply(recipe.lens.chromaticAberration, to: raw)
        // Manual lens vignetting and distortion, for lenses without a profile. Vignetting first,
        // since the lens's falloff is centered where the sensor recorded it.
        let undistorted = LensDistortion.apply(recipe.lens.distortion,
                                               to: LensVignetting.apply(recipe.lens.vignetting, to: aligned))
        // Then perspective, on lines the lens corrections have made straight, and before the
        // crop's turns, so it stays with the photo as it is turned.
        let decoded = PerspectiveTransform.apply(recipe.transform, to: undistorted)
        // Then halation and bloom, light spreading from the highlights as it reached the film,
        // over the whole photo so light from outside the crop still spreads into it.
        let glowing = Glow.apply(halation: recipe.halation, bloom: recipe.bloom, to: decoded)
        // 2. Tone: highlights and shadows first, then texture and clarity, then dehaze, then
        // contrast, whites, blacks and the tone curve as one lookup.
        let shaded = HighlightsShadows.apply(to: glowing, highlights: recipe.basic.highlights, shadows: recipe.basic.shadows)
        let detailed = TextureClarity.apply(to: shaded, texture: recipe.basic.texture, clarity: recipe.basic.clarity)
        let dehazed = Dehaze.apply(to: detailed, amount: recipe.basic.dehaze)
        let toned = ToneLookup(contrast: recipe.basic.contrast, whites: recipe.basic.whites, blacks: recipe.basic.blacks,
                               curve: recipe.curve)
            .apply(to: dehazed)
        // 3. Color: vibrance, then saturation, then selective color, then the black-and-white
        // mix, so the colors the others shape still set how light each turns out in gray.
        let saturated = ColorAdjustments.apply(to: toned, vibrance: recipe.basic.vibrance, saturation: recipe.basic.saturation)
        let colored = BlackAndWhiteStage.apply(recipe.blackAndWhite,
                                               to: SelectiveColorStage.apply(recipe.selectiveColor, to: saturated))
        // 4. LUT, blended by strength.
        let looked = recipe.look.map { LUTStage.apply(lut, strength: $0.strength, to: colored) } ?? colored
        // 5. Layers follow here when masks are built.
        // 6. Turn, flip, straighten and crop.
        let framed = recipe.crop.map { Self.applyGeometry($0, to: looked) } ?? looked
        // 7. Vignette, then grain, on the cropped frame so they follow the crop.
        return Grain.apply(recipe.grain, to: Vignette.apply(recipe.vignette, to: framed))
    }

    /// Turns and flips `image`, then straightens and crops it, as `Crop` describes. The result
    /// starts at the origin.
    static func applyGeometry(_ crop: Crop, to image: CIImage) -> CIImage {
        // Core Image's y axis points up, so a clockwise turn on screen is a negative angle.
        var turn = CGAffineTransform(rotationAngle: -Double(crop.rotation) * .pi / 180)
        if crop.flipHorizontal { turn = turn.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if crop.flipVertical { turn = turn.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        var turned = image.transformed(by: turn)
        turned = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
        guard crop.width != 1 || crop.height != 1 || crop.x != 0 || crop.y != 0 || crop.angle != 0 else { return turned }

        let (w, h) = (turned.extent.width, turned.extent.height)
        // The crop's center, from a top-left origin to Core Image's bottom-left one.
        let center = CGPoint(x: (crop.x + crop.width / 2) * w, y: (1 - crop.y - crop.height / 2) * h)
        // Whole pixels, rounded down so the result never outgrows the size it was scaled to fit:
        // Core Image rounds a fractional crop outward, which would show an edge.
        let rect = CGRect(x: -(crop.width * w / 2).rounded(.down), y: -(crop.height * h / 2).rounded(.down),
                          width: max((crop.width * w).rounded(.down), 1), height: max((crop.height * h).rounded(.down), 1))
        // Clamped so the rectangle's edges, which may touch the photo's, don't blend with nothing.
        // Cropped last, at the origin, so the extent is exactly the rectangle's.
        return turned.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(rotationAngle: -crop.angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)))
            .cropped(to: CGRect(origin: .zero, size: rect.size))
    }

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    public static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The `CIRAWFilter.scaleFactor` that fits the photo, cropped by `crop`, inside `targetSize`.
    /// `nativeSize` is the sensor's size before orientation, so portrait photos swap width and height.
    static func scaleFactor(
        nativeSize: CGSize,
        orientation: CGImagePropertyOrientation,
        crop: Crop? = nil,
        fitting targetSize: CGSize
    ) -> CGFloat {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return 1 }
        let oriented = oriented(nativeSize, orientation)
        let shown = crop?.outputSize(of: oriented) ?? oriented
        guard shown.width > 0, shown.height > 0 else { return 1 }
        let scale = min(targetSize.width / shown.width, targetSize.height / shown.height)
        return min(max(scale, 0.01), 1)
    }

    private static func oriented(_ nativeSize: CGSize, _ orientation: CGImagePropertyOrientation) -> CGSize {
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        return quarterTurn.contains(orientation) ? CGSize(width: nativeSize.height, height: nativeSize.width) : nativeSize
    }
}
