import ProofKit
import SwiftUI

/// The photo's History panel in Edit (#56): each change since it was opened, newest first, with
/// Original at the bottom and Opened above it when the photo already had an edit. Clicking a step
/// shows the photo as it was then, as Undo and Redo do. The steps last until Proof quits, as undo
/// does; they aren't saved with the edit. Original is there after a restart too.
public struct HistorySidebar: View {
    let library: Library

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        let history = library.selectedEdit?.history
        let steps = Array((history?.steps ?? []).enumerated()).reversed()
        List(selection: Binding(get: { history?.currentIndex },
                                set: { if let index = $0 { library.goToHistoryStep(index) } })) {
            #if os(macOS)
            Section("History") { rows(steps, current: history?.currentIndex) }
            #else
            // In a popover on iOS, whose title already names it.
            rows(steps, current: history?.currentIndex)
            #endif
        }
        #if os(macOS)
        // The same plain color as the folder sidebar. On iOS the popover keeps its own glass.
        .scrollContentBackground(.hidden)
        .background(Color.interfaceBackground.ignoresSafeArea())
        #endif
        .disabled(library.isCropping)
    }

    private func rows(_ steps: ReversedCollection<[(offset: Int, element: EditHistory.Step)]>, current: Int?) -> some View {
        ForEach(steps, id: \.offset) { index, step in
            Text(step.label)
                .monospacedDigit()
                // Steps after the one shown are what Redo brings back, and a new change drops them.
                .foregroundStyle(index > current ?? 0 ? .secondary : .primary)
                .tag(index)
        }
    }

    /// How many rows the panel lists, so a popover can fit its height to them.
    public static func rowCount(for library: Library) -> Int {
        library.selectedEdit?.history.steps.count ?? 0
    }
}
