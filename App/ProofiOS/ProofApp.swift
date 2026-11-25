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
            FolderList(library: library)
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
        .fileImporter(isPresented: $library.isChoosingFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: library.folderPickerAllowsSeveral) { result in
            switch result {
            case .success(let urls): library.chose(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fileDialogMessage(Text(library.folderPickerMessage))
        .fileDialogConfirmationLabel(Text(library.folderPickerConfirmation))
        .alert("Something Went Wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        // Folders that were added open on the library, so they can be seen; with none, the empty state.
        .onChange(of: library.locations.isEmpty, initial: true) { _, isEmpty in
            compactColumn = isEmpty ? .detail : .sidebar
        }
    }

    // The thumbnail grid is #224; until then a folder shows how many photos Proof found in it.
    @ViewBuilder private var browser: some View {
        if library.locations.isEmpty {
            ContentUnavailableView {
                Label("No Folders", systemImage: "folder")
            } description: {
                Text("Add a folder of photos to browse and edit them.")
            } actions: {
                Button("Add Folder…") { library.requestFolder(.add) }
            }
        } else if let folder = library.selection?.folder,
                  let location = library.locations.first(where: { $0.id == folder.locationID }) {
            switch library.status(of: location.id) {
            case .available:
                let count = library.contents[folder]?.photos.count ?? 0
                ContentUnavailableView(location.name, systemImage: "photo.on.rectangle",
                                       description: Text(count == 1 ? "1 photo" : "\(count) photos"))
            case .offline:
                ContentUnavailableView(location.name, systemImage: "externaldrive.badge.xmark",
                                       description: Text("The drive or server this folder is on isn't connected."))
            case .missing:
                ContentUnavailableView {
                    Label(location.name, systemImage: "questionmark.folder")
                } description: {
                    Text("Proof can't find this folder. It may have been moved or deleted.")
                } actions: {
                    Button("Locate…") { library.requestFolder(.locate(location)) }
                }
            }
        } else {
            ContentUnavailableView("No Folder Selected", systemImage: "folder",
                                   description: Text("Choose a folder in the library."))
        }
    }
}

extension Color {
    /// The Mac app's interface gray, the default canvas color. Moves into ProofUI with the shared
    /// views (#242).
    static let interfaceBackground = Color(white: CanvasColor.darkGray.components.red)
}
