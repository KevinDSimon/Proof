import ProofKit
import SwiftUI

/// The photo's History panel in Edit (#56): each change since it was opened, newest first, with
/// Original at the bottom and Opened above it when the photo already had an edit. Clicking a step
/// shows the photo as it was then, as Undo and Redo do. The steps last until Proof quits, as undo
/// does; they aren't saved with the edit. Original is there after a restart too.
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
        .background(Color.interfaceBackground.ignoresSafeArea())
        .disabled(library.isCropping)
    }
}
