import ProofKit
import SwiftUI

/// One row of thumbnails under the photo in Edit, showing the photos that pass the filter. The
/// current photo is marked with a ring. Click or the left and right arrow keys
/// switch to another photo without leaving Edit.
struct Filmstrip: View {
    @Bindable var library: Library
    let photos: [ListedPhoto]

    @State private var images: [PhotoReference: NSImage] = [:]
    @State private var finished: Set<PhotoReference> = []
    @FocusState private var isFocused: Bool

    static let height: CGFloat = 84
    private static let spacing: CGFloat = 4

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(photos) { photo in
                        cell(for: photo)
                            .id(photo.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: library.browse.selectedPhoto) { _, photo in
                guard let photo else { return }
                withAnimation { scroller.scrollTo(photo, anchor: .center) }
            }
            .onAppear {
                if let photo = library.browse.selectedPhoto { scroller.scrollTo(photo, anchor: .center) }
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
        .task(id: photos.map(\.id)) {
            await ThumbnailGrid.loadThumbnails(of: photos, images: $images, finished: $finished, library: library)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filmstrip")
    }

    private func cell(for photo: ListedPhoto) -> some View {
        let isCurrent = library.browse.selectedPhoto == photo.id
        return ZStack {
            if let image = library.editedThumbnails[photo.id] ?? images[photo.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .ratingBadges(photo.photo.metadata, size: 8)
            } else if finished.contains(photo.id) {
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
            library.browse.selectedPhoto = photo.id
            isFocused = true
        }
        .help(photo.name)
        .accessibilityElement()
        .accessibilityLabel(RatingBadges.accessibilityLabel(name: photo.name, metadata: photo.photo.metadata))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
