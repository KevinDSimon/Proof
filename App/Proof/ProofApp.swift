import SwiftUI
import ProofKit

@main
struct ProofApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        Color.clear
            .frame(minWidth: 800, minHeight: 500)
            // Shown only so the window proves ProofKit is linked; the panels replace it.
            .navigationSubtitle("Process version \(EditRecipe.currentProcessVersion)")
    }
}
