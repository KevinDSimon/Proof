import ProofKit
import SwiftUI

/// File › Export To and the right-click menu's Export To: each saved destination, exporting right
/// away with its folder and settings (decision 0032). On iPad and iPhone: the share sheet, Save to
/// Files and Photos, with the last export's settings.
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
        #if os(macOS)
        let destinations = library.exportDestinations?.destinations ?? []
        Menu("Export To") {
            ForEach(destinations) { destination in
                Button(destination.name) { library.export(photos, to: destination.id) }
            }
        }
        .disabled(isDisabled || destinations.isEmpty)
        #else
        // iPad and iPhone have no saved folders; the system's destinations stand in for them,
        // with the last export's settings.
        Menu("Export To") {
            Button("Share…") { library.export(photos, delivery: .share) }
            Button("Save to Files…") { library.export(photos, delivery: .files) }
            Button("Save to Photos") { library.export(photos, delivery: .photos) }
        }
        .disabled(isDisabled)
        #endif
    }
}
