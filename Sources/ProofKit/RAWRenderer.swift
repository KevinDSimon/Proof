import CoreImage
import Metal

public enum RAWRendererError: Error, Equatable {
    case noMetalDevice
    case unsupportedFile(URL)
    case noPhotoOpen
    case renderFailed
}

/// A photo rendered at screen size. The texture is written once by `RAWRenderer` and only
/// read afterwards, which is what makes passing it between threads safe.
public struct RenderedPhoto: @unchecked Sendable {
    public let texture: MTLTexture
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
    /// Separate from `context` and without cached intermediates, so thumbnails of many photos
    /// don't fill GPU memory or evict the open photo's decode.
    private lazy var thumbnailContext = CIContext(mtlCommandQueue: commandQueue, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

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
        openURL = url
    }

    /// Renders the open photo with `recipe` applied, scaled to fit `targetSize` (in pixels) and
    /// never larger than the sensor. The texture has the photo's aspect ratio, not the target's.
    public func render(fitting targetSize: CGSize, recipe: EditRecipe = EditRecipe()) throws -> RenderedPhoto {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        let scale = Self.scaleFactor(
            nativeSize: filter.nativeSize,
            orientation: filter.orientation,
            fitting: targetSize
        )
        return try render(scaleFactor: scale, recipe: recipe)
    }

    /// Renders at an exact `CIRAWFilter.scaleFactor`. Internal so that only export and timing
    /// tests can ask for full sensor resolution; the app goes through `render(fitting:)`.
    func render(scaleFactor scale: CGFloat, recipe: EditRecipe) throws -> RenderedPhoto {
        guard let filter else { throw RAWRendererError.noPhotoOpen }
        filter.scaleFactor = Float(scale)
        guard let image = Self.apply(recipe, to: filter, asShot: asShot) else { throw RAWRendererError.renderFailed }

        let extent = image.extent.integral
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
        return RenderedPhoto(texture: texture)
    }

    /// A thumbnail of `url` with `recipe` applied, at most `maxPixelSize` on the long edge, for
    /// the grid and the filmstrip. It doesn't change the open photo or its cached intermediates.
    public func thumbnail(of url: URL, recipe: EditRecipe, maxPixelSize: Int) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else {
            throw RAWRendererError.unsupportedFile(url)
        }
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        filter.scaleFactor = Float(Self.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation, fitting: size))
        let asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        guard let image = Self.apply(recipe, to: filter, asShot: asShot),
              let thumbnail = thumbnailContext.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                             colorSpace: Self.colorSpace)
        else { throw RAWRendererError.renderFailed }
        return thumbnail
    }

    /// Draws a photo from `render(fitting:)` centered in `drawable`, scaled to fit, over
    /// `background`. Cheap enough to run in a view's draw callback while a new render is pending.
    public nonisolated func draw(
        _ photo: RenderedPhoto?,
        into drawable: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        background: CIColor
    ) throws {
        let bounds = CGRect(x: 0, y: 0, width: drawable.width, height: drawable.height)
        var composed = CIImage(color: background).cropped(to: bounds)
        if let photo {
            guard let image = CIImage(mtlTexture: photo.texture, options: [.colorSpace: Self.colorSpace]) else {
                throw RAWRendererError.renderFailed
            }
            let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = scaled.transformed(by: CGAffineTransform(
                translationX: ((bounds.width - scaled.extent.width) / 2).rounded(),
                y: ((bounds.height - scaled.extent.height) / 2).rounded()
            ))
            composed = placed.composited(over: composed)
        }

        let destination = CIRenderDestination(mtlTexture: drawable, commandBuffer: commandBuffer)
        destination.colorSpace = Self.colorSpace
        destination.isFlipped = true
        try context.startTask(toRender: composed, to: destination)
    }

    /// Builds the Core Image graph for `recipe` in the order set out in docs/architecture.md. The
    /// canvas, thumbnails and export all go through here, so they can't drift apart. Stages that
    /// have no controls yet pass the image through; each one is filled in by its own issue.
    /// `asShot` is the camera's white balance, which a filter reused across renders has lost.
    static func apply(_ recipe: EditRecipe, to filter: CIRAWFilter, asShot: WhiteBalance) -> CIImage? {
        // 1. RAW decode in linear light. White balance is in Kelvin and tint; exposure in stops.
        let whiteBalance = recipe.basic.whiteBalance(asShot: asShot)
        filter.neutralTemperature = Float(whiteBalance.temperature)
        filter.neutralTint = Float(whiteBalance.tint)
        filter.exposure = Float(recipe.basic.exposure)
        guard let decoded = filter.outputImage else { return nil }
        // 2. Tone: highlights and shadows first, then contrast, whites and blacks as one lookup,
        // which the tone curve will join.
        let shaded = HighlightsShadows.apply(to: decoded, highlights: recipe.basic.highlights, shadows: recipe.basic.shadows)
        let toned = ToneLookup(contrast: recipe.basic.contrast, whites: recipe.basic.whites, blacks: recipe.basic.blacks)
            .apply(to: shaded)
        // 3. Color: vibrance, then saturation.
        let colored = ColorAdjustments.apply(to: toned, vibrance: recipe.basic.vibrance, saturation: recipe.basic.saturation)
        // 4. LUT, 5. layers and 6. crop follow here as they are built.
        return colored
    }

    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    public static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The `CIRAWFilter.scaleFactor` that fits the photo inside `targetSize`. `nativeSize` is
    /// the sensor's size before orientation, so portrait photos swap width and height.
    static func scaleFactor(
        nativeSize: CGSize,
        orientation: CGImagePropertyOrientation,
        fitting targetSize: CGSize
    ) -> CGFloat {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return 1 }
        let quarterTurn: Set<CGImagePropertyOrientation> = [.left, .leftMirrored, .right, .rightMirrored]
        let oriented = quarterTurn.contains(orientation)
            ? CGSize(width: nativeSize.height, height: nativeSize.width)
            : nativeSize
        let scale = min(targetSize.width / oriented.width, targetSize.height / oriented.height)
        return min(max(scale, 0.01), 1)
    }
}
