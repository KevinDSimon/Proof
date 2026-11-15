import ProofKit
import SwiftUI

/// The photo's History panel in Edit (#56): each change since it was opened, newest first, with
/// Opened at the bottom. Clicking a step shows the photo as it was then, as Undo and Redo do.
/// It lasts until Proof quits, as undo does; it isn't saved with the edit. Original, pinned
/// above the list, is there even after Proof restarts, when the steps before Opened are gone.
struct HistorySidebar: View {
    let library: Library

    var body: some View {
        let history = library.selectedEdit?.history
        let steps = Array((history?.steps ?? []).enumerated()).reversed()
        List(selection: Binding(get: { history?.currentIndex },
                                set: { if let index = $0 { library.goToHistoryStep(index) } })) {
            Section("History") {
                ForEach(steps, id: \.offset) { index, step in
                    Text(step.label)
                        .monospacedDigit()
                        // Steps after the one shown are what Redo brings back, and a new change drops them.
                        .foregroundStyle(index > history?.currentIndex ?? 0 ? .secondary : .primary)
                        .tag(index)
                }
            }
        }
        // The same plain color as the folder sidebar.
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { original }
        .background(Color.interfaceBackground.ignoresSafeArea())
        .disabled(library.isCropping)
    }

    /// Revert to Original as a row: one step at the top of the list, which Undo takes back.
    /// Dimmed while the photo has no edit to remove.
    private var original: some View {
        let photo = library.browse.selectedPhoto
        let canRevert = photo.map { !library.photosToRevert(among: [$0]).isEmpty } ?? false
        return VStack(spacing: 0) {
            Button {
                if let photo { library.requestRevert(of: [photo]) }
            } label: {
                Label("Original", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .disabled(!canRevert)
            .help("Revert to Original: remove every adjustment, as one step that Undo takes back")
            Divider()
                .padding(.horizontal, 10)
        }
    }
}
