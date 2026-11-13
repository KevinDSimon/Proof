import Foundation
import Observation
import ProofKit

/// Exports photos one at a time in the background, so browsing and editing carry on (decision
/// 0031). Exports started while others run join the end of the queue. It has a renderer of its
/// own, so a full-resolution render never holds up the canvas; one photo at a time keeps a single
/// full-size render in GPU memory.
@Observable @MainActor
final class ExportQueue {
    /// A photo as it was when Export was clicked.
    struct Item: Sendable {
        let url: URL
        /// The edit Proof has in memory, or `nil` to read the photo's sidecar.
        let recipe: EditRecipe?
        let rating: Int
    }

    struct Failure: Identifiable {
        let id = UUID()
        let name: String
        let reason: String
    }

    private struct Job {
        let url: URL
        let recipe: EditRecipe
        let rating: Int
        let settings: ExportSettings
        let folder: URL
    }

    /// Photos queued since the queue was last cleared, and how many of them are done or failed.
    private(set) var total = 0
    private(set) var finished = 0
    /// The name of the photo being exported.
    private(set) var current: String?
    private(set) var exported: [URL] = []
    private(set) var failures: [Failure] = []
    private(set) var wasCancelled = false

    private var jobs: [Job] = []
    private var task: Task<Void, Never>?
    /// Batches whose sidecars are still being read.
    private var reading = 0
    /// Folders chosen in the open panel, whose access lasts until the queue is cleared.
    private var accessedFolders: Set<URL> = []
    private let renderer = try? RAWRenderer()

    var isRunning: Bool { task != nil || reading > 0 }
    /// The toolbar shows the queue while it runs and until its summary is dismissed.
    var isVisible: Bool { total > 0 }
    var fractionDone: Double { total > 0 ? Double(finished) / Double(total) : 0 }

    /// Queues `items` for `folder`, a folder chosen in the open panel, with `settings`. The
    /// photos' sidecars are read first, so each export has the edit it had when Export was clicked.
    func start(_ items: [Item], settings: ExportSettings, folder: URL) {
        guard !items.isEmpty else { return }
        if !isRunning { clear() }
        wasCancelled = false
        if accessedFolders.insert(folder).inserted { _ = folder.startAccessingSecurityScopedResource() }
        total += items.count
        reading += 1
        Task {
            let read = await Task.detached(priority: .utility) {
                items.map { item in
                    Job(url: item.url, recipe: item.recipe ?? (try? Sidecar.read(for: item.url))??.recipe ?? EditRecipe(),
                        rating: item.rating, settings: settings, folder: folder)
                }
            }.value
            reading -= 1
            if !wasCancelled { jobs += read }
            startWorker()
        }
    }

    private func startWorker() {
        guard task == nil, !jobs.isEmpty else { return }
        task = Task {
            await run()
            task = nil
            current = nil
            // Jobs queued after a cancel, while the last render finished.
            startWorker()
        }
    }

    /// Stops after the photo being exported, which can't be stopped once its render starts. Files
    /// already written stay.
    func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        jobs = []
    }

    /// Dismisses the summary and ends access to the folders exported to.
    func clear() {
        guard !isRunning else { return }
        total = 0
        finished = 0
        current = nil
        exported = []
        failures = []
        wasCancelled = false
        for folder in accessedFolders { folder.stopAccessingSecurityScopedResource() }
        accessedFolders = []
    }

    private func run() async {
        guard let renderer else {
            failures += jobs.map { Failure(name: $0.url.lastPathComponent, reason: "Proof needs a Mac with a Metal GPU to export.") }
            finished += jobs.count
            jobs = []
            return
        }
        while !jobs.isEmpty, !wasCancelled {
            let job = jobs.removeFirst()
            current = job.url.lastPathComponent
            let result = await Task.detached(priority: .utility) {
                let lut = await LUTLibrary.shared.lut(for: job.recipe.look)
                let details = PhotoExport.Details(rating: job.rating, description: PhotoDescription.read(for: job.url))
                return try await PhotoExport.export(job.url, recipe: job.recipe, lut: lut, details: details,
                                                    settings: job.settings, into: job.folder, with: renderer)
            }.result
            switch result {
            case .success(let url): exported.append(url)
            case .failure(let error):
                failures.append(Failure(name: job.url.lastPathComponent, reason: Self.reason(for: error)))
            }
            finished += 1
        }
    }

    private static func reason(for error: Error) -> String {
        switch error {
        case RAWRendererError.unsupportedFile: "Proof can't read this file."
        case RAWRendererError.renderFailed: "The photo couldn't be rendered."
        default: error.localizedDescription
        }
    }
}
