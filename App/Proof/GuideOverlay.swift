import ProofKit
import ProofUI
import SwiftUI

/// Guided Upright's tool on the photo, as in Lightroom: a drag draws a line along something that
/// should be upright or level, and the photo is corrected to it when the drag ends. Dragging a
/// guide's end moves that end, dragging its line moves the whole guide, and clicking either
/// selects the guide for Delete to remove. The guides are shown where they now fall on the
/// corrected photo, as cropped and zoomed, so opening the tool moves nothing. A temporary tool,
/// so it may sit on the photo.
struct GuideOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The correction the canvas shows.
    let transform: PerspectiveTransform
    /// The crop the canvas shows, which comes after the correction.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space the correction works in.
    let photoSize: CGSize

    @State private var press = GuidePress()
    /// The part under the pointer, which takes an open-hand pointer to show it can be moved.
    @State private var hovered: GuidePart?
    /// Held while a guide is selected, so Delete reaches it.
    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = GuideLayout(size: geometry.size, zoom: zoom, transform: transform, crop: crop, photoSize: photoSize)
            GuideMarks(library: library, layout: layout, press: press, hovered: hovered)
                .contentShape(Rectangle())
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                // Delete, and Edit › Delete, remove the selected guide.
                .onDeleteCommand {
                    guard let index = library.selectedGuide, transform.guides.indices.contains(index) else { return }
                    library.removeGuide(at: index)
                }
                .onChange(of: library.selectedGuide) { if library.selectedGuide != nil { isFocused = true } }
                .accessibilityElement()
                .accessibilityLabel("Guides")
                .accessibilityValue("\(transform.guides.count) of \(Library.maximumGuides) drawn")
                .pointerStyle(pointer)
                .onContinuousHover { phase in
                    if case let .active(location) = phase { hovered = layout.part(at: location) } else { hovered = nil }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in press.moved(from: value.startLocation, to: value.location, layout: layout) }
                        .onEnded { value in
                            press.ended(from: value.startLocation, at: value.location, layout: layout, library: library)
                        })
        }
        // Return and Esc stop drawing, wherever the keyboard focus is. Clear All is in the
        // Transform card, so nothing covers the photo but the guides.
        .background {
            Group {
                Button("Done Drawing Guides") { library.isDrawingGuides = false }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Stop Drawing Guides") { library.isDrawingGuides = false }
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var pointer: PointerStyle {
        if press.isActive { return press.isDrawing ? .rectSelection : .grabActive }
        return hovered == nil ? .rectSelection : .grabIdle
    }
}
