import ProofKit
import ProofUI
import SwiftUI

/// File › Export…: a saved destination or a folder chosen at export, then the format, size, color
/// space and metadata of the export. A destination brings its own folder and settings (decision
/// 0032); without one, the last settings are remembered for the next export (decision 0031).
struct ExportSheet: View {
    let library: Library
    let photos: [PhotoReference]
    @Environment(\.dismiss) private var dismiss
    /// The last export's settings without a destination, as JSON. Empty until the first export.
    @AppStorage(ExportSettings.rememberedKey) private var storedSettings = Data()
    /// The folder last exported to, where the open panel starts.
    @AppStorage("exportFolderPath") private var lastFolderPath = ""
    @AppStorage(ExportQueue.destinationKey) private var storedDestination = ""
    @State private var settings = ExportSettings()
    @State private var destinationID: UUID?
    /// The chosen destination's folder, resolved when it is chosen; `nil` when it can't be found.
    @State private var destinationFolder: URL?
    @State private var folderPurpose: FolderPurpose?
    @State private var isChoosingFolder = false
    /// The folder of a destination being saved, while its name is asked for.
    @State private var newDestinationFolder: URL?
    @State private var isNaming = false
    @State private var nameDraft = ""
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var failure: String?

    /// Why the open panel is showing. One panel serves all three, as a view can have only one.
    private enum FolderPurpose {
        case export, newDestination, changeFolder
    }

    private func chooseFolder(for purpose: FolderPurpose) {
        folderPurpose = purpose
        isChoosingFolder = true
    }

    private var destinations: ExportDestinations? { library.exportDestinations }
    private var destination: ExportDestination? { destinationID.flatMap { destinations?.destination($0) } }
    /// The settings differ from the chosen destination's, for this export only until it is updated.
    private var isEdited: Bool { destination.map { $0.settings != settings } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Text(photos.count == 1 ? "Export Photo" : "Export \(photos.count) Photos")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                if let destinations {
                    destinationSection(destinations)
                }
                ExportSettingsForm(settings: $settings)
            }
            .formStyle(.grouped)
            // The sheet's own background, so the title above and the buttons below sit on the same surface.
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            HStack {
                if destinations != nil {
                    destinationsMenu
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(destination == nil ? "Export…" : "Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!settings.isValid || (destination != nil && destinationFolder == nil))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        // The panel is closed before the result arrives, so the purpose is kept until it is read.
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result, let purpose = folderPurpose else { return }
            chose(folder, for: purpose)
        }
        .fileDialogDefaultDirectory(panelDirectory)
        .fileDialogMessage(Text(panelMessage))
        .fileDialogConfirmationLabel(Text(folderPurpose == .export ? "Export" : "Choose"))
        .alert("Save Destination", isPresented: $isNaming) {
            TextField("Name", text: $nameDraft)
            Button("Save") { saveNewDestination() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Exports to “\(newDestinationFolder?.lastPathComponent ?? "")” with the settings in this sheet.")
        }
        .alert("Rename Destination", isPresented: $isRenaming) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { attempt { if let destinationID { try destinations?.rename(destinationID, to: nameDraft) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the destination “\(destination?.name ?? "")”?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { deleteDestination() }
        } message: {
            Text("Its folder and the photos already exported to it stay as they are.")
        }
        .alert("The destination couldn’t be saved.", isPresented: Binding(get: { failure != nil },
                                                                          set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
        .onAppear {
            if let saved = try? JSONDecoder().decode(ExportSettings.self, from: storedSettings) { settings = saved }
            if let id = UUID(uuidString: storedDestination), destinations?.destination(id) != nil { choose(id) }
        }
    }

    @ViewBuilder
    private func destinationSection(_ destinations: ExportDestinations) -> some View {
        Section {
            Picker("Export To", selection: Binding(get: { destinationID }, set: { choose($0) })) {
                Text("Choose Folder").tag(UUID?.none)
                if !destinations.destinations.isEmpty {
                    Divider()
                }
                ForEach(destinations.destinations) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            if let destination {
                if let destinationFolder {
                    LabeledContent("Folder") {
                        Text((destinationFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destinationFolder.path)
                    }
                } else {
                    LabeledContent {
                        Button("Choose Folder…") { chooseFolder(for: .changeFolder) }
                    } label: {
                        Text("The folder “\(destination.lastKnownURL.lastPathComponent)” can’t be found.")
                            .foregroundStyle(.secondary)
                    }
                }
                if isEdited {
                    LabeledContent {
                        Button("Update Destination") {
                            attempt { try destinations.update(destination.id, settings: settings) }
                        }
                    } label: {
                        Text("Edited. These settings are used for this export only.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var destinationsMenu: some View {
        Menu("Destinations") {
            Button("Save as New Destination…") { chooseFolder(for: .newDestination) }
            if let destination {
                Divider()
                Button("Rename “\(destination.name)”…") {
                    nameDraft = destination.name
                    isRenaming = true
                }
                Button("Change Folder…") { chooseFolder(for: .changeFolder) }
                Button("Delete “\(destination.name)”…") { isConfirmingDelete = true }
            }
        }
        .fixedSize()
    }

    /// Switches to a destination, taking its settings, or back to Choose Folder,
    /// taking the last settings used that way.
    private func choose(_ id: UUID?) {
        destinationID = id
        if let id, let destination = destinations?.destination(id) {
            settings = destination.settings
            destinationFolder = destinations?.folder(of: id)
        } else {
            destinationFolder = nil
            if let saved = try? JSONDecoder().decode(ExportSettings.self, from: storedSettings) { settings = saved }
        }
    }

    private func export() {
        guard destination != nil else {
            chooseFolder(for: .export)
            return
        }
        guard let destinationFolder, let destinationID else { return }
        storedDestination = destinationID.uuidString
        library.export(photos, settings: settings, to: destinationFolder)
    }

    private func chose(_ folder: URL, for purpose: FolderPurpose) {
        lastFolderPath = folder.path
        switch purpose {
        case .export:
            storedSettings = (try? JSONEncoder().encode(settings)) ?? Data()
            storedDestination = ""
            library.export(photos, settings: settings, to: folder)
        case .newDestination:
            nameDraft = folder.lastPathComponent
            newDestinationFolder = folder
            isNaming = true
        case .changeFolder:
            guard let destinationID else { return }
            attempt {
                try destinations?.changeFolder(of: destinationID, to: folder)
                destinationFolder = destinations?.folder(of: destinationID)
            }
        }
    }

    private func saveNewDestination() {
        guard let folder = newDestinationFolder else { return }
        attempt {
            if let added = try destinations?.add(name: nameDraft, folder: folder, settings: settings) {
                choose(added.id)
            }
        }
    }

    private func deleteDestination() {
        guard let destinationID else { return }
        attempt { try destinations?.remove(destinationID) }
        if storedDestination == destinationID.uuidString { storedDestination = "" }
        choose(nil)
    }

    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }

    /// The panel starts in the destination's folder when changing it, otherwise the last folder used.
    private var panelDirectory: URL? {
        if folderPurpose == .changeFolder, let destination { return destination.lastKnownURL }
        return lastFolderPath.isEmpty ? nil : URL(fileURLWithPath: lastFolderPath)
    }

    private var panelMessage: String {
        switch folderPurpose {
        case .newDestination: "Choose the folder this destination exports to."
        case .changeFolder: "Choose a new folder for “\(destination?.name ?? "")”."
        case .export, nil: photos.count == 1 ? "Choose a folder for the photo." : "Choose a folder for the \(photos.count) photos."
        }
    }
}
