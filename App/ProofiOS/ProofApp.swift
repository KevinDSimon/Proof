import ProofKit
import ProofUI
import SwiftUI

@main
struct ProofApp: App {
    @State private var library = Library(platform: .iOS)

    var body: some Scene {
        // One window, as on the Mac. The interface is dark in both system appearances through
        // UIUserInterfaceStyle in the Info.plist, so launch, sheets and alerts follow too.
        WindowGroup {
            ContentView(library: library)
        }
    }
}

/// The library beside the grid on iPad; on iPhone, a stack of library, then grid (decision 0048).
struct ContentView: View {
    @Bindable var library: Library
    /// With no folders the sidebar is empty, so iPhone opens on the empty state instead.
    @State private var compactColumn = NavigationSplitViewColumn.detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List {}
                .navigationTitle("Library")
                .toolbar {
                    Button("Add Folder", systemImage: "folder.badge.plus") { library.requestFolder(.add) }
                }
                .scrollContentBackground(.hidden)
                .background(Color.interfaceBackground.ignoresSafeArea())
        } detail: {
            browser
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.interfaceBackground.ignoresSafeArea())
        }
    }

    // Folder access from Files is #223; until then the library stays empty.
    @ViewBuilder private var browser: some View {
        ContentUnavailableView {
            Label("No Folders", systemImage: "folder")
        } description: {
            Text("Add a folder of photos to browse and edit them.")
        } actions: {
            Button("Add Folder…") { library.requestFolder(.add) }
        }
    }
}

extension Color {
    /// The Mac app's interface gray, the default canvas color. Moves into ProofUI with the shared
    /// views (#242).
    static let interfaceBackground = Color(white: CanvasColor.darkGray.components.red)
}
