import Foundation
import Photos

/// Adds exported photos to the photo library, for Save to Photos on iPad and iPhone. Proof asks
/// only for add-only access, so it never sees the library's photos.
enum PhotoLibrary {
    static let deniedReason = "Proof isn't allowed to add photos to your library. You can allow it in Settings › Apps › Proof › Photos."

    /// Asks for add-only access the first time; afterwards returns the answer given.
    static func requestAddAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    /// Adds `file` as a new photo, moving it into the library.
    static func add(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
        }
    }
}
