import ProofKit
import SwiftUI

/// One row of thumbnails under the photo in Edit, showing the photos that pass the filter. The
/// current photo is marked with a ring. Click or the left and right arrow keys
/// switch to another photo without leaving Edit.
struct Filmstrip: View {
    @Bindable var library: Library
    let folder: FileReference
    let photos: [FolderContents.Photo]

    @State private var images: [String: NSImage] = [:]
    @State private var finished: Set<String> = []
    @FocusState private var isFocused: Bool

    private struct LoadKey: Equatable {
        var folder: FileReference
        var names: [String]
    }

    static let height: CGFloat = 84
    private static let spacing: CGFloat = 4

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(photos, id: \.name) { photo in
                        cell(for: photo)
                            .id(photo.name)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: library.browse.selectedPhoto) { _, name in
                guard let name else { return }
                withAnimation { scroller.scrollTo(name, anchor: .center) }
            }
            .onAppear {
                if let name = library.browse.selectedPhoto { scroller.scrollTo(name, anchor: .center) }
            }
        }
        .frame(height: Self.height)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            // A single row: left and right step through the photos and stop at the ends.
            let move: BrowseState.Move? = switch direction {
            case .left: .left
            case .right: .right
            default: nil
            }
            if let move { library.browse.move(move, in: photos, columns: photos.count) }
        }
        .onAppear { isFocused = true }
        .task(id: LoadKey(folder: folder, names: photos.map(\.name))) {
            images = [:]
            finished = []
            await ThumbnailGrid.loadThumbnails(of: photos, in: folder, library: library) { name, image in
                finished.insert(name)
                if let image { images[name] = image }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmstrip")
    }

    private func cell(for photo: FolderContents.Photo) -> some View {
        let isCurrent = library.browse.selectedPhoto == photo.name
        return ZStack {
            if let image = images[photo.name] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .ratingBadges(photo.metadata, size: 8)
            } else if finished.contains(photo.name) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("This photo couldn't be read.")
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
            }
        }
        .selectionRing(isCurrent, lineWidth: 2, gap: 2)
        .frame(width: Self.height - 12, height: Self.height - 12)
        .contentShape(Rectangle())
        .onTapGesture {
            library.browse.selectedPhoto = photo.name
            isFocused = true
        }
        .help(photo.name)
        .accessibilityElement()
        .accessibilityLabel(RatingBadges.accessibilityLabel(name: photo.name, metadata: photo.metadata))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
