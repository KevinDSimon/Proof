import ProofKit

extension LUTLibrary {
    /// The person's LUTs, in Application Support. The canvas, thumbnails and the Looks section
    /// share it, so a LUT is read and prepared once.
    public static let shared = LUTLibrary()
}

extension ThumbnailCache {
    /// Its own renderer, so making thumbnails never waits behind, or evicts, the photo in Edit.
    nonisolated private static let renderer = try? RAWRenderer()

    /// The thumbnails the grid, the filmstrip and edited photos share.
    nonisolated public static let shared = ThumbnailCache(renderEdit: { url, edit in
        let lut = await LUTLibrary.shared.lut(for: edit.look)
        return try? await renderer?.thumbnail(of: url, recipe: edit, lut: lut, maxPixelSize: ThumbnailCache.maxPixelSize)
    }, lutVersion: { LUTLibrary.shared.version(of: $0) })
}
