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
        Picker("Flag", selection: $library.filter.flag) {
            Text("Any Flag").tag(PhotoMetadata.Flag?.none)
            Text("Flagged").tag(PhotoMetadata.Flag?.some(.flagged))
            Text("Unflagged").tag(PhotoMetadata.Flag?.some(.unflagged))
            Text("Rejected").tag(PhotoMetadata.Flag?.some(.rejected))
        }
        .pickerStyle(.inline)
        Picker("Rating", selection: $library.filter.rating) {
            Text("Any Rating").tag(Int?.none)
            ForEach([5, 4, 3, 2, 1], id: \.self) { stars in
                Text(stars == 1 ? "1 Star" : "\(stars) Stars").tag(Int?.some(stars))
            }
        }
        .pickerStyle(.inline)
        Toggle("Include Higher Ratings", isOn: $library.filter.includesHigherRatings)
            .disabled(library.filter.rating == nil || library.filter.rating == 5)
        Divider()
        Picker("Edits", selection: $library.filter.edits) {
            Text("Edited or Not").tag(FilterCriteria.Edits?.none)
            Text("Edited").tag(FilterCriteria.Edits?.some(.edited))
            Text("Unedited").tag(FilterCriteria.Edits?.some(.unedited))
        }
        .pickerStyle(.inline)
    }
}
