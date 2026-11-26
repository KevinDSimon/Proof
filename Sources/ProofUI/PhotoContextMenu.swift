import ProofKit
import SwiftUI

/// The right-click menu of a photo in the grid or the filmstrip. Like the menu bar, it acts on
/// every selected photo when the photo clicked is one of them, as in Finder, and otherwise on that
/// photo alone. Actions for many photos belong here and in the menu bar, not in the toolbar.
public struct PhotoContextMenu: View {
    @Bindable var library: Library
    let photo: PhotoReference

    public init(library: Library, photo: PhotoReference) {
        self.library = library
        self.photo = photo
    }

    public var body: some View {
        let photos = library.menuTargets(for: photo)
        if !library.isEditing {
            Button("Edit") {
                if library.browse.selectedPhoto != photo { library.browse.selectedPhoto = photo }
                library.browse.edit()
            }
            .disabled(!photo.isEditable)
            // The panel describes one photo, so showing it selects only the photo clicked. iOS
            // shows Info as a sheet for the photo touched, leaving the selection as it is.
            #if os(macOS)
            Button(library.isInfoShown ? "Hide Info" : "Show Info") {
                if !library.isInfoShown, library.browse.selectedPhotos != [photo] {
                    library.browse.selectedPhoto = photo
                }
                library.isInfoShown.toggle()
            }
            #else
            Button("Show Info") { library.infoSheetPhoto = photo }
            #endif
            Divider()
        }
        RatingPicker(library: library, photos: photos)
            .submenuOnTouch()
        FlagPicker(library: library, photos: photos)
            .submenuOnTouch()
        if library.stackMarks[photo] != nil {
            Divider()
            Button(library.isStackOpen(StackMark.first(of: photo, in: library.visiblePhotos, marks: library.stackMarks) ?? photo)
                   ? "Collapse Stack" : "Open Stack") {
                library.toggleStackAnimated(of: photo)
            }
        }
        let many = photos.count > 1 ? " \(photos.count) Photos" : ""
        // JPEG and HEIC photos aren't exported or edited until #239.
        let noneEditable = !photos.contains(where: \.isEditable)
        // Files on iOS have no path worth copying, and the export sheet comes to iOS in #234.
        #if os(macOS)
        Divider()
        Button("Show in Finder") { library.showInFinder(library.urls(of: photos)) }
        Button("Copy Path" + (photos.count > 1 ? "s" : "")) { library.copyPaths(library.urls(of: photos)) }
        Button(photos.count > 1 ? "Export\(many)…" : "Export…") { library.requestExport(of: photos) }
            .disabled(library.isCropping || noneEditable)
        ExportToMenu(library: library, photos: photos, isDisabled: library.isCropping || noneEditable)
        #endif
        Divider()
        // Always from the photo clicked, the one whose settings are in view.
        Button("Copy Settings…") { library.chooseSettingsToCopy(from: photo) }
            .disabled(library.isCropping || !photo.isEditable)
        Button("Paste Settings" + (many.isEmpty ? "" : " to\(many)")) {
            library.pasteSettings(to: photos)
        }
        .disabled(library.isCropping || library.copiedSettings == nil || noneEditable)
        // One photo reverts without asking, as Undo in Edit brings it back.
        Divider()
        let toRevert = library.photosToRevert(among: photos)
        Button(toRevert.count > 1 ? "Revert \(toRevert.count) Photos to Original…" : "Revert to Original") {
            library.requestRevert(of: photos)
        }
        .disabled(toRevert.isEmpty)
    }
}

/// The rating choices for `photos`, with a rating they all share checked. In the photo menus and
/// the iOS selection toolbar.
public struct RatingPicker: View {
    let library: Library
    let photos: [PhotoReference]

    public init(library: Library, photos: [PhotoReference]) {
        self.library = library
        self.photos = photos
    }

    public var body: some View {
        Picker("Rating", selection: Binding(get: { library.commonRating(of: photos) ?? -1 },
                                            set: { library.setRating($0, of: photos) })) {
            ForEach(0...5, id: \.self) { rating in
                Text(RatingBadges.title(ofRating: rating)).tag(rating)
            }
        }
    }
}

/// The flag choices for `photos`, with a flag they all share checked.
public struct FlagPicker: View {
    let library: Library
    let photos: [PhotoReference]

    public init(library: Library, photos: [PhotoReference]) {
        self.library = library
        self.photos = photos
    }

    public var body: some View {
        Picker("Flag", selection: Binding(get: { library.commonFlag(of: photos) },
                                          set: { if let flag = $0 { library.setFlag(flag, of: photos) } })) {
            ForEach(RatingBadges.flags, id: \.self) { flag in
                Text(RatingBadges.title(of: flag)).tag(PhotoMetadata.Flag?.some(flag))
            }
        }
    }
}

private extension View {
    /// iOS lists a picker's choices in the menu itself, which makes Rating and Flag nine rows
    /// long; as submenus they read as on the Mac.
    @ViewBuilder func submenuOnTouch() -> some View {
        #if os(iOS)
        pickerStyle(.menu)
        #else
        self
        #endif
    }
}
