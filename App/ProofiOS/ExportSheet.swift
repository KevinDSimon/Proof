import ProofKit
import ProofUI
import SwiftUI
import UIKit

/// Export on iPad and iPhone: the Mac's format, size, color space and Remove Location, then the
/// share sheet, Save to Files or Photos (decision 0048). The settings are remembered for the next
/// export, as on the Mac. Once a destination is tapped the sheet shows the export's progress, then
/// hands the photos over, and stays until Done, so an export is never missed.
struct ExportSheet: View {
    let library: Library

    var body: some View {
        if library.photosToExport.isEmpty {
            ExportProgressView(exports: library.exports)
        } else {
            ExportSettingsSheet(library: library, photos: library.photosToExport)
        }
    }
}

extension Library {
    /// Whether the export sheet is up where `presents` says it is presented from: Browse, Edit,
    /// or the inspector's sheet in Edit. Swiping a finished export's sheet away ends it, as Done does.
    func exportSheet(presentedWhere presents: @escaping () -> Bool) -> Binding<Bool> {
        Binding(get: { presents() && (!self.photosToExport.isEmpty || self.exports.isVisible) },
                set: {
                    guard !$0 else { return }
                    self.photosToExport = []
                    self.exports.clear()
                })
    }
}

private struct ExportSettingsSheet: View {
    let library: Library
    let photos: [PhotoReference]
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings.remembered()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    destination("Share…", systemImage: "square.and.arrow.up", .share)
                    destination("Save to Files…", systemImage: "folder", .files)
                    destination("Save to Photos", systemImage: "photo.on.rectangle", .photos)
                }
                // White, not the app's yellow tint, which is for small marks of state only (decision 0041).
                .foregroundStyle(.primary)
                ExportSettingsForm(settings: $settings)
            }
            .softTopScrollEdge()
            .navigationTitle(photos.count == 1 ? "Export Photo" : "Export \(photos.count) Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func destination(_ title: String, systemImage: String, _ delivery: ExportQueue.Delivery) -> some View {
        Button(title, systemImage: systemImage) {
            settings.remember()
            library.export(photos, settings: settings, delivery: delivery)
        }
        .disabled(!settings.isValid)
    }
}

/// Which photo is being exported, a bar and Stop, then how many photos were exported, which
/// failed and why. When every photo is ready, the share sheet or Save to Files opens on its own;
/// a button opens it again if it was closed without saving. A render can't report how far it
/// has got, so for one photo the bar runs without a value; for several it counts the photos done.
private struct ExportProgressView: View {
    let exports: ExportQueue
    @State private var isSavingToFiles = false
    /// The share sheet or Save to Files has opened on its own for this export.
    @State private var hasOffered = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if exports.isRunning {
                    Group {
                        if exports.total == 1 {
                            ProgressView()
                        } else {
                            ProgressView(value: exports.fractionDone)
                        }
                    }
                    .progressViewStyle(.linear)
                    // A render can't be stopped once it starts, so Stop takes effect after this photo.
                    Text(exports.wasCancelled ? "Stopping after this photo…" : exports.current ?? " ")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Label(exports.summary, systemImage: exports.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.headline)
                    if !exports.failures.isEmpty {
                        Text(exports.failures.count == 1 ? "1 photo couldn't be exported:" : "\(exports.failures.count) photos couldn't be exported:")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(exports.failures) { failure in
                                    Text("\(failure.name): \(failure.reason)")
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    deliveryButton
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(exports.isRunning ? title : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if exports.isRunning {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") { exports.cancel() }
                            .disabled(exports.wasCancelled)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { exports.clear() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(exports.isRunning)
        .fileMover(isPresented: $isSavingToFiles, files: exports.exported) { result in
            if case .success = result { exports.isDelivered = true }
        }
        .onChange(of: exports.isRunning, initial: true) {
            guard !exports.isRunning, !hasOffered else { return }
            hasOffered = true
            deliver()
        }
    }

    private var title: String {
        exports.total == 1 ? "Exporting 1 Photo" : "Exporting \(exports.position) of \(exports.total)"
    }

    @ViewBuilder private var deliveryButton: some View {
        if !exports.exported.isEmpty, !exports.isDelivered {
            switch exports.delivery {
            case .share: Button("Share…", systemImage: "square.and.arrow.up") { deliver() }
            case .files: Button("Save to Files…", systemImage: "folder") { deliver() }
            case .photos:
                Button("Open Photos", systemImage: "photo.on.rectangle") {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                }
            case nil: EmptyView()
            }
        }
    }

    /// Hands the exported photos to the share sheet or Save to Files. Photos already has them.
    private func deliver() {
        guard !exports.exported.isEmpty else { return }
        switch exports.delivery {
        case .share: ShareSheet.present(exports.exported) { if $0 { exports.isDelivered = true } }
        case .files: isSavingToFiles = true
        case .photos, nil: break
        }
    }
}

private extension ExportQueue {
    /// How the finished export went, as the sheet says it.
    var summary: String {
        let count = exported.count
        let photos = count == 1 ? "1 Photo" : "\(count) Photos"
        let done = delivery == .photos ? "Saved \(photos) to Photos" : "Exported \(photos)"
        return wasCancelled ? "Export Stopped: \(done)" : done
    }
}

/// The system share sheet, presented over whatever is on screen. SwiftUI's `ShareLink` opens
/// only when tapped, and the sheet should open on its own once the photos are ready.
@MainActor
enum ShareSheet {
    /// Presents the share sheet for `files`; `completion` says whether they were shared or saved.
    static func present(_ files: [URL], completion: @escaping @MainActor (Bool) -> Void) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            MainActor.assumeIsolated { completion(completed) }
        }
        // On iPad the share sheet is a popover; centered on the export sheet, without an arrow.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
