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
    @State private var fileAccess = try? FileAccess(storeURL: URL.applicationSupportDirectory
        .appendingPathComponent("Proof/locations.json"))
    @AppStorage("lastPhoto") private var lastPhoto: Data?
    @State private var photoURL: URL?
    @State private var exposure = 0.0
    @State private var isChoosingPhoto = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let renderer, let photoURL {
                PhotoCanvas(url: photoURL, renderer: renderer, exposure: exposure) { error in
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
        .onAppear(perform: reopenLastPhoto)
        .navigationTitle(photoURL?.lastPathComponent ?? "Proof")
        .toolbar {
            if photoURL != nil {
                ExposureSlider(value: $exposure)
            }
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

    private func open(_ url: URL) {
        guard let fileAccess else {
            errorMessage = "Proof couldn't load its saved locations."
            return
        }
        let previous = currentReference
        do {
            let location = try fileAccess.add(url)
            guard let reference = fileAccess.reference(for: url), let resolved = fileAccess.url(for: reference) else {
                errorMessage = "Proof wasn't given permission to read \(url.lastPathComponent)."
                return
            }
            // Until the Folders panel exists, Open remembers only the last photo it opened.
            if let previous, previous.locationID != location.id, previous.relativePath.isEmpty {
                try fileAccess.remove(previous.locationID)
            }
            lastPhoto = try JSONEncoder().encode(reference)
            photoURL = resolved
            exposure = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var currentReference: FileReference? {
        lastPhoto.flatMap { try? JSONDecoder().decode(FileReference.self, from: $0) }
    }

    /// A photo that moved or whose drive isn't connected is skipped quietly; Open still works.
    private func reopenLastPhoto() {
        guard photoURL == nil, let reference = currentReference else { return }
        photoURL = fileAccess?.url(for: reference)
    }
}

/// Exposure in stops, −5 to +5, the range the edit format allows. Double-click the value to reset.
struct ExposureSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack {
            Slider(value: $value, in: -5...5) {
                Text("Exposure")
            }
            .frame(width: 180)
            .accessibilityValue(String(format: "%+.2f stops", value))
            Text(value, format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .onTapGesture(count: 2) { value = 0 }
                .help("Double-click to reset")
                .accessibilityHidden(true)
        }
    }
}
