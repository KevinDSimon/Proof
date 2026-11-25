import ProofKit
import SwiftUI

/// A photo in iCloud while it downloads: the system's thumbnail on the canvas, with a spinner.
/// Edit's canvas replaces it once the photo is on the device (decision 0050).
public struct CloudPhotoPreview: View {
    let url: URL
    let backdrop: Color
    @State private var image: CGImage?

    public init(url: URL, backdrop: Color) {
        self.url = url
        self.backdrop = backdrop
    }

    public var body: some View {
        ZStack {
            backdrop
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
            // A temporary indicator, so it may sit on the photo.
            ProgressView("Downloading from iCloud…")
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
        .task(id: url) { image = await ThumbnailCache.shared.thumbnail(for: url, edit: nil) }
    }
}
