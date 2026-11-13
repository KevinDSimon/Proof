import ProofKit
import SwiftUI

/// The right-click menu of a photo in the grid or the filmstrip. Like the menu bar, it acts on
/// every selected photo when the photo clicked is one of them, as in Finder, and otherwise on that
/// photo alone. Actions for many photos belong here and in the menu bar, not in the toolbar.
struct PhotoContextMenu: View {
    @Bindable var library: Library
    let photo: PhotoReference

    var body: some View {
        let photos = library.menuTargets(for: photo)
        let many = photos.count > 1 ? " \(photos.count) Photos" : ""
        if !library.isEditing {
            Button("Edit") {
                if library.browse.selectedPhoto != photo { library.browse.selectedPhoto = photo }
                library.browse.edit()
            }
            Divider()
        }
        // A rating or flag the photos share is checked.
        Picker("Rating", selection: Binding(get: { library.commonRating(of: photos) ?? -1 },
                                            set: { library.setRating($0, of: photos) })) {
            ForEach(0...5, id: \.self) { rating in
                Text(RatingBadges.title(ofRating: rating)).tag(rating)
            }
        }
        Picker("Flag", selection: Binding(get: { library.commonFlag(of: photos) },
                                          set: { if let flag = $0 { library.setFlag(flag, of: photos) } })) {
            ForEach(RatingBadges.flags, id: \.self) { flag in
                Text(RatingBadges.title(of: flag)).tag(PhotoMetadata.Flag?.some(flag))
            }
        }
        Divider()
        Button("Show in Finder") { library.showInFinder(library.urls(of: photos)) }
        Button("Copy Path" + (photos.count > 1 ? "s" : "")) { library.copyPaths(library.urls(of: photos)) }
        Button(photos.count > 1 ? "Export\(many)…" : "Export…") { library.requestExport(of: photos) }
            .disabled(library.isCropping)
        ExportToMenu(library: library, photos: photos, isDisabled: library.isCropping)
        Divider()
        // Always from the photo clicked, the one whose settings are in view.
        Button("Copy Settings…") { library.chooseSettingsToCopy(from: photo) }
            .disabled(library.isCropping)
        Button("Paste Settings" + (many.isEmpty ? "" : " to\(many)")) { library.pasteSettings(to: photos) }
            .disabled(library.isCropping || library.copiedSettings == nil)
        Divider()
        let toRevert = library.photosToRevert(among: photos)
        Button(toRevert.count > 1 ? "Revert \(toRevert.count) Photos to Original…" : "Revert to Original") {
            library.requestRevert(of: photos)
        }
        .disabled(toRevert.isEmpty)
    }
}
