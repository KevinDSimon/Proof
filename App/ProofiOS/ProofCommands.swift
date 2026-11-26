import ProofKit
import ProofUI
import SwiftUI
import UIKit

/// The menu bar on iPad, and the list that holding ⌘ shows, with the Mac's keys for what the
/// mobile workflow needs: rating and flagging, quick edits, Copy and Paste Settings, zoom and
/// sharing (#235, decision 0051). The Mac's other commands, such as the White Balance Selector,
/// Looks, Flip and the canvas color, stay on the Mac.
struct ProofCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Folder…") { library.requestFolder(.add) }
                .keyboardShortcut("o")
            Divider()
            // Export on iPad and iPhone is the share sheet, Files and Photos (#234).
            Button("Share…") { library.requestExport(of: targets) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(library.isCropping || library.exports.isVisible || !targets.contains(where: \.isEditable))
        }
        // Undo steps through the edit of the photo open in Edit, as on the Mac.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { library.undoEdit() }
                .keyboardShortcut("z")
                .disabled(!library.isEditing || library.isCropping || !library.canUndoEdit)
            Button("Redo") { library.redoEdit() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!library.isEditing || library.isCropping || !library.canRedoEdit)
        }
        // ⌘C and ⌘V copy and paste the photo's settings, as on the Mac, except while a field is
        // being typed in, where they act on its text.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Self.sendToTextField(#selector(UIResponderStandardEditActions.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") {
                if canCopySettings && !Self.isTyping {
                    library.chooseSettingsToCopy(from: targets.first)
                } else {
                    Self.sendToTextField(#selector(UIResponderStandardEditActions.copy(_:)))
                }
            }
            .keyboardShortcut("c")
            Button("Paste") {
                if canPasteSettings && !Self.isTyping {
                    library.pasteSettings(to: targets)
                } else {
                    Self.sendToTextField(#selector(UIResponderStandardEditActions.paste(_:)))
                }
            }
            .keyboardShortcut("v")
            // In Browse, starts Select with every photo shown selected.
            Button("Select All") {
                if !library.isEditing && library.canSelectPhotos && !Self.isTyping {
                    library.isSelectingPhotos = true
                    library.browse.selectAll(library.shownPhotos)
                } else {
                    Self.sendToTextField(#selector(UIResponderStandardEditActions.selectAll(_:)))
                }
            }
            .keyboardShortcut("a")
            Divider()
            Button("Copy Settings…") { library.chooseSettingsToCopy(from: targets.first) }
                .disabled(!canCopySettings)
            Button("Paste Settings") { library.pasteSettings(to: targets) }
                .disabled(!canPasteSettings)
        }
        CommandGroup(before: .toolbar) {
            Button("Show Info") { library.infoSheetPhoto = targets.first }
                .keyboardShortcut("i")
                .disabled(targets.count != 1 || library.isCropping)
            Button(library.isInspectorShown ? "Hide Adjustments" : "Show Adjustments") {
                library.isInspectorShown.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .control])
            .disabled(!library.isEditing)
            Button(library.isFilmstripShown ? "Hide Filmstrip" : "Show Filmstrip") {
                library.isFilmstripShown.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(!library.isEditing)
            Button(library.isHistoryShown ? "Hide History" : "Show History") {
                library.isHistoryShown.toggle()
            }
            .keyboardShortcut("y")
            .disabled(!library.isEditing || library.isCropping)
            Divider()
            Button("Zoom In") { library.zoom.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!library.isEditing || !library.zoom.canZoomIn)
            Button("Zoom Out") { library.zoom.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!library.isEditing || !library.zoom.canZoomOut)
            Button("Zoom to Fit") { library.zoom.zoom(to: nil) }
                .keyboardShortcut("0")
                .disabled(!library.isEditing || !library.zoom.isEnabled || library.zoom.viewport.isFit)
            Button("Actual Size") { library.zoom.zoom(to: 1) }
                .keyboardShortcut("1")
                .disabled(!library.isEditing || !library.zoom.isEnabled || library.zoom.viewport.scale == 1)
            Divider()
        }
        CommandMenu("Photo") {
            // Return opens the photo the arrow keys outlined in Browse; in Edit it's left to the tools.
            Button("Edit") { library.browse.edit() }
            .keyboardShortcut(library.isEditing ? nil : KeyboardShortcut(.return, modifiers: []))
            .disabled(library.isEditing || !library.isSelectionFromKeyboard
                      || library.browse.selectedPhoto?.isEditable != true)
            // The arrows step through the photos in Edit, as the filmstrip's do on the Mac and a
            // swipe does here. Menu items rather than keys the photo watches, so they work wherever
            // the focus is; in Browse the grid takes the arrows.
            Button("Next Photo") { step(.right) }
                .keyboardShortcut(library.isEditing ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                .disabled(!canStep)
            Button("Previous Photo") { step(.left) }
                .keyboardShortcut(library.isEditing ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                .disabled(!canStep)
            Button("Back to Folder") { library.browse.finishEditing() }
                .keyboardShortcut(.upArrow)
                .disabled(!library.isEditing || library.isCropping)
            Toggle("Show Original", isOn: Binding(get: { library.browse.isShowingOriginal },
                                                  set: { _ in library.toggleOriginal() }))
                .keyboardShortcut("\\", modifiers: [])
                .disabled(!library.isEditing || library.isCropping || library.isRemovingSpots || library.isMasking
                          || library.selectedEdit == nil)
            Divider()
            if library.isCropping {
                Button("Done Cropping") { library.finishCropping() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Cancel Cropping") { library.cancelCropping() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Swap Crop Orientation") { library.swapCropOrientation() }
                    .keyboardShortcut("x", modifiers: [])
            } else {
                // The crop controls take the adjustments' place, as from the toolbar.
                Button("Crop") {
                    library.startCropping()
                    library.isInspectorShown = true
                }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!canUseTools)
            }
            Toggle("Spot Removal", isOn: Binding(get: { library.isRemovingSpots }, set: { _ in
                library.toggleSpotRemoval()
                if library.isRemovingSpots { library.isInspectorShown = true }
            }))
            .keyboardShortcut("q", modifiers: [])
            .disabled(!canUseTools)
            // ] and [ size the selected spot, and the next one, as on the Mac.
            if library.isRemovingSpots {
                Button("Larger Spot") { library.changeSpot { $0 = $0.resized(larger: true) } }
                    .keyboardShortcut("]", modifiers: [])
                Button("Smaller Spot") { library.changeSpot { $0 = $0.resized(larger: false) } }
                    .keyboardShortcut("[", modifiers: [])
                Button("Delete Spot") { if let index = library.selectedSpot { library.removeSpot(at: index) } }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(library.selectedSpot == nil)
            }
            Toggle("Masks", isOn: Binding(get: { library.isMasking }, set: { _ in
                library.toggleMasks()
                if library.isMasking { library.isInspectorShown = true }
            }))
            .keyboardShortcut("m", modifiers: [])
            .disabled(!canUseTools)
            Button("Rotate Left") { library.rotate(clockwise: false) }
                .keyboardShortcut("[")
                .disabled(!canUseTools)
            Button("Rotate Right") { library.rotate(clockwise: true) }
                .keyboardShortcut("]")
                .disabled(!canUseTools)
            Divider()
            // Lightroom's keys: 0 to 5 for stars, P, U and X for the flag.
            Picker("Rating", selection: Binding(get: { library.commonRating(of: targets) ?? -1 },
                                                set: { library.setRating($0, of: targets) })) {
                ForEach(0...5, id: \.self) { rating in
                    Text(RatingBadges.title(ofRating: rating)).tag(rating)
                        .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [])
                }
            }
            .pickerStyle(.inline)
            .disabled(targets.isEmpty)
            Divider()
            Picker("Flag", selection: Binding(get: { library.commonFlag(of: targets) },
                                              set: { if let flag = $0 { library.setFlag(flag, of: targets) } })) {
                Text("Flagged").tag(PhotoMetadata.Flag?.some(.flagged)).keyboardShortcut("p", modifiers: [])
                Text("Unflagged").tag(PhotoMetadata.Flag?.some(.unflagged)).keyboardShortcut("u", modifiers: [])
                // While cropping, X swaps the crop's orientation instead, as on the Mac.
                Text("Rejected").tag(PhotoMetadata.Flag?.some(.rejected))
                    .keyboardShortcut(library.isCropping ? nil : KeyboardShortcut("x", modifiers: []))
            }
            .pickerStyle(.inline)
            .disabled(targets.isEmpty)
        }
    }

    /// The photos the keys act on, only ever ones marked on screen: the photo in Edit, the photos
    /// selected in Select, or the photo the arrow keys outlined in Browse. A tap opens a photo, so
    /// Browse otherwise has no photo marked, though one may still be selected from the last Edit.
    private var targets: [PhotoReference] {
        if library.isEditing { return library.browse.selectedPhoto.map { [$0] } ?? [] }
        guard library.isSelectingPhotos || library.isSelectionFromKeyboard else { return [] }
        return library.selectedPhotosInOrder
    }

    /// Copy Settings starts from one photo, as in its touch-and-hold menu.
    private var canCopySettings: Bool {
        targets.count == 1 && targets[0].isEditable && !library.isCropping
            && (!library.isEditing || library.selectedEdit != nil)
    }

    private var canPasteSettings: Bool {
        library.copiedSettings != nil && !library.isCropping && targets.contains(where: \.isEditable)
    }

    /// Crop, Spot Removal, Masks and Rotate: in Edit, on a RAW photo, with no other tool open.
    private var canUseTools: Bool {
        library.isEditing && !library.isCropping && library.selectedEdit != nil
            && library.browse.selectedPhoto?.isEditable != false
    }

    /// In Edit with no tool open, as a swipe.
    private var canStep: Bool {
        library.isEditing && !library.isCropping && !library.isRemovingSpots && !library.isMasking
            && library.shownPhotos.count > 1
    }

    private func step(_ move: BrowseState.Move) {
        let photos = library.shownPhotos
        library.browse.move(move, in: photos, columns: photos.count)
    }

    /// A text field is being typed in, so the pasteboard commands act on its text.
    private static var isTyping: Bool {
        FirstResponder.current is UITextInput
    }

    private static func sendToTextField(_ action: Selector) {
        UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil)
    }
}

/// UIKit has no public way to ask for the first responder; an action sent to nil reaches it.
@MainActor
private enum FirstResponder {
    static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.proofReportFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }
}

private extension UIResponder {
    @objc func proofReportFirstResponder(_ sender: Any?) {
        FirstResponder.found = self
    }
}
