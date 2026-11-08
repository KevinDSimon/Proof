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
    @State private var renderer = try? RAWRenderer()
    @State private var photoURL: URL?
    @State private var isChoosingPhoto = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let renderer, let photoURL {
                PhotoCanvas(url: photoURL, renderer: renderer) { error in
                    errorMessage = "The photo couldn't be shown. (\(error))"
                }
            } else if renderer == nil {
                ContentUnavailableView("Metal Isn't Available", systemImage: "exclamationmark.triangle",
                                       description: Text("Proof needs a Mac with a Metal GPU to show photos."))
            } else {
                ContentUnavailableView {
                    Label("No Photo", systemImage: "photo")
                } description: {
                    Text("Open a RAW photo to view it.")
                } actions: {
                    Button("Open…") { isChoosingPhoto = true }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(photoURL?.lastPathComponent ?? "Proof")
        .toolbar {
            Button("Open", systemImage: "folder") { isChoosingPhoto = true }
                .keyboardShortcut("o")
                .help("Open a RAW photo")
        }
        .fileImporter(isPresented: $isChoosingPhoto, allowedContentTypes: [.rawImage]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Can't Open Photo", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// The sandbox grants access to a picked file only while it is held, and the renderer
    /// reads the file again at each new size, so access lasts until another photo is opened.
    /// Replaced by `FileAccess` in Phase 1.
    private func open(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Proof wasn't given permission to read \(url.lastPathComponent)."
            return
        }
        photoURL?.stopAccessingSecurityScopedResource()
        photoURL = url
    }
}
