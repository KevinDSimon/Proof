import ProofKit
import SwiftUI

/// The toolbar filter's parts, for the toolbar's filter menu and View › Filter: Clear Filter, then
/// a flag, a rating and edited photos, which combine.
public struct FilterMenu: View {
    @Bindable var library: Library

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        Button("Clear Filter") { library.filter = .none }
            .disabled(library.filter.isEmpty)
        #if os(iOS)
        // On iOS the filter sits in the grid's More menu, where its 16 choices in a row would
        // scroll; each part is a submenu that names its choice instead.
        flagPicker.pickerStyle(.menu)
        Menu {
            ratingPicker.pickerStyle(.inline)
            higherRatings
        } label: {
            Text("Rating")
            Text(library.filter.rating.map { $0 == 1 ? "1 Star" : "\($0) Stars" } ?? "Any Rating")
        }
        editsPicker.pickerStyle(.menu)
        #else
        flagPicker.pickerStyle(.inline)
        ratingPicker.pickerStyle(.inline)
        higherRatings
        Divider()
        editsPicker.pickerStyle(.inline)
        #endif
    }

    private var flagPicker: some View {
        Picker("Flag", selection: $library.filter.flag) {
            Text("Any Flag").tag(PhotoMetadata.Flag?.none)
            Text("Flagged").tag(PhotoMetadata.Flag?.some(.flagged))
            Text("Unflagged").tag(PhotoMetadata.Flag?.some(.unflagged))
            Text("Rejected").tag(PhotoMetadata.Flag?.some(.rejected))
        }
    }

    private var ratingPicker: some View {
        Picker("Rating", selection: $library.filter.rating) {
            Text("Any Rating").tag(Int?.none)
            ForEach([5, 4, 3, 2, 1], id: \.self) { stars in
                Text(stars == 1 ? "1 Star" : "\(stars) Stars").tag(Int?.some(stars))
            }
        }
    }

    private var higherRatings: some View {
        Toggle("Include Higher Ratings", isOn: $library.filter.includesHigherRatings)
            .disabled(library.filter.rating == nil || library.filter.rating == 5)
    }

    private var editsPicker: some View {
        Picker("Edits", selection: $library.filter.edits) {
            Text("Edited or Not").tag(FilterCriteria.Edits?.none)
            Text("Edited").tag(FilterCriteria.Edits?.some(.edited))
            Text("Unedited").tag(FilterCriteria.Edits?.some(.unedited))
        }
    }
}
