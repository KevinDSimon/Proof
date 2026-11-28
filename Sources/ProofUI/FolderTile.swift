import ProofKit
import SwiftUI

extension Image {
    /// A manila folder, as a darkroom keeps prints in, for folders on every platform (decision 0059).
    static let manilaFolder = Image(decorative: "ManilaFolder", bundle: .module)
}

/// The manila folder at the size of a list row's symbol, larger with the text.
struct FolderIcon: View {
    #if os(macOS)
    @ScaledMetric private var width: CGFloat = 18
    #else
    @ScaledMetric private var width: CGFloat = 26
    #endif
    /// A folder that can't be reached is dimmed, as its name is.
    var isDimmed = false

    var body: some View {
        Image.manilaFolder
            .resizable()
            .scaledToFit()
            .frame(width: width)
            .opacity(isDimmed ? 0.5 : 1)
    }
}

public extension EnvironmentValues {
    /// What opening a subfolder's tile in the grid does. iPhone pushes the subfolder's grid (#313);
    /// elsewhere, when this isn't set, the tile selects the subfolder, and the sidebar shows it.
    @Entry var openSubfolder: ((FileReference) -> Void)? = nil
    /// Set on iPhone, where the library's folder rows follow Files: the disclosure arrow leads the
    /// row and the tree starts expanded (#313). The Mac and iPad keep the standard sidebar.
    @Entry var foldersFollowFiles = false
}

/// A subfolder at the start of its folder's grid: the manila folder centered in a thumbnail's
/// square, with its name under it, in line with the photos' names. A tap opens it on iPad and
/// iPhone; on the Mac a double-click does, as it opens a photo and as in Finder.
struct FolderTile: View {
    let library: Library
    let folder: FileReference
    let open: (FileReference) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Rating and flagging are for photos, so folders step back while selecting.
        let isSelecting = library.isSelectingPhotos
        VStack(spacing: 6) {
            // The manila folder about three quarters of the square's width, as Files sizes folders
            // beside photos, centered in it (decision 0059).
            GeometryReader { proxy in
                Image.manilaFolder
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width * 0.76)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            // Styled as a photo's name, so the two read as one row.
            Text(library.name(of: folder))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: .infinity)
        }
        // The same padding as a photo's, so the tiles line up with the thumbnails.
        .selectionOutline(false)
        .contentShape(Rectangle())
        #if os(macOS)
        .onTapGesture(count: 2) { open(folder) }
        #else
        .onTapGesture { open(folder) }
        #endif
        .opacity(isSelecting ? 0.4 : 1)
        .allowsHitTesting(!isSelecting)
        .accessibilityElement()
        .accessibilityLabel("\(library.name(of: folder)), folder")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(folder) }
    }
}
