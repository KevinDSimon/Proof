import ProofKit
import SwiftUI

/// File › Export To and the right-click menu's Export To: each saved destination, exporting right
/// away with its folder and settings (decision 0032).
public struct ExportToMenu: View {
    let library: Library
    /// The photos to export; `nil` for the selected photos.
    var photos: [PhotoReference]?
    var isDisabled = false

    public init(library: Library, photos: [PhotoReference]? = nil, isDisabled: Bool = false) {
        self.library = library
        self.photos = photos
        self.isDisabled = isDisabled
    }

    public var body: some View {
        let destinations = library.exportDestinations?.destinations ?? []
        Menu("Export To") {
            ForEach(destinations) { destination in
                Button(destination.name) { library.export(photos, to: destination.id) }
            }
        }
        .disabled(isDisabled || destinations.isEmpty)
    }
}
