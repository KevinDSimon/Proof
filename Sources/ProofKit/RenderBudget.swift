import CoreGraphics
import Foundation
#if os(iOS)
import os
#endif

/// How much memory the canvas's zoomed renders may use, which on iPhone and iPad limits how
/// sharp a zoomed region of a large photo is decoded (#236, decision 0053). The photo shown at
/// Fit, and export, are never limited.
///
/// A zoomed region is cut from the whole photo decoded at the zoom's scale, and clarity, dehaze
/// and highlights and shadows build their maps from all of it, so its memory grows with the whole
/// photo's pixels at that scale, not the region's. On an M2, a 60 MP Leica M11 photo with those
/// edits peaks at about 1.8 GB above the app's own memory at 50%, 2.6 GB at 70% and 3.2 GB at
/// 100%, about 60 bytes per decoded pixel.
public struct RenderBudget: Equatable, Sendable {
    /// The bytes a zoomed render may use, or `nil` for no limit.
    public var bytes: UInt64?

    public init(bytes: UInt64?) {
        self.bytes = bytes
    }

    public static let unlimited = RenderBudget(bytes: nil)

    /// Memory a render uses for each pixel of the whole photo at its decode scale, rounded up from
    /// what was measured, so the estimate errs toward a smaller decode.
    static let bytesPerDecodedPixel = 64.0

    /// The share of the memory iOS reports as left to the app that a zoomed render may take. The
    /// rest stays for the open photo's own render, the interface, thumbnails and an export.
    static let shareOfAvailable = 0.5

    /// The budget for `available` bytes left before the system ends the app, `nil` where there is
    /// no such limit, as on the Mac and in the simulator. Under serious or critical thermal
    /// pressure it is halved, so zoomed renders do less GPU work while the device cools.
    public static func forAvailableMemory(_ available: UInt64?, thermalState: ProcessInfo.ThermalState) -> RenderBudget {
        guard let available, available > 0 else { return .unlimited }
        var bytes = Double(available) * shareOfAvailable
        if thermalState == .serious || thermalState == .critical { bytes /= 2 }
        return RenderBudget(bytes: UInt64(bytes))
    }

    /// The budget now: on iPhone and iPad from the memory iOS reports as left to the app, and
    /// without a limit on the Mac.
    public static func current() -> RenderBudget {
        #if os(iOS)
        return forAvailableMemory(UInt64(os_proc_available_memory()), thermalState: ProcessInfo.processInfo.thermalState)
        #else
        return .unlimited
        #endif
    }

    /// The largest scale, at most 1, at which the whole of a photo of `photoSize` pixels fits the
    /// budget. Rounded down to a hundredth, so a budget read again a little later gives the same
    /// scale and doesn't ask for a new render.
    public func maxScale(photoSize: CGSize) -> Double {
        guard let bytes, photoSize.width > 0, photoSize.height > 0 else { return 1 }
        let pixels = Double(bytes) / Self.bytesPerDecodedPixel
        let scale = (pixels / (photoSize.width * photoSize.height)).squareRoot()
        return min((scale * 100).rounded(.down) / 100, 1)
    }
}
