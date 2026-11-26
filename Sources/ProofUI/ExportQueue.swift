import Foundation
import Observation
import ProofKit

/// Exports photos one at a time in the background, so browsing and editing carry on (decision
/// 0031). Exports started while others run join the end of the queue. It has a renderer of its
/// own, so a full-resolution render never holds up the canvas; one photo at a time keeps a single
/// full-size render in GPU memory.
@Observable @MainActor
public final class ExportQueue {
    /// The destination last exported to, as a UUID string; empty for Choose Folder.
    public static let destinationKey = "exportDestination"

    /// Where an export goes on iPad and iPhone, chosen with the settings rather than as a folder
    /// beforehand (decision 0048). The photos render into an `ExportStaging` folder first.
    public enum Delivery: Sendable {
        /// The share sheet, once every photo is ready.
        case share
        /// Save to Files, once every photo is ready.
        case files
        /// The photo library, each photo as soon as it is ready.
        case photos
    }

    /// A photo as it was when Export was clicked.
    public struct Item: Sendable {
        public let url: URL
        /// The edit Proof has in memory, or `nil` to read the photo's sidecar.
        public let recipe: EditRecipe?
        public let rating: Int
    }

    public struct Failure: Identifiable {
        public let id = UUID()
        public let name: String
        public let reason: String
    }

    private struct Job {
        public let url: URL
        public let recipe: EditRecipe
        public let rating: Int
        public let settings: ExportSettings
        public let folder: URL
    }

    /// Photos queued since the queue was last cleared, and how many of them are done or failed.
    public private(set) var total = 0
    public private(set) var finished = 0
    /// The name of the photo being exported.
    public private(set) var current: String?
    public private(set) var exported: [URL] = []
    public private(set) var failures: [Failure] = []
    public private(set) var wasCancelled = false
    /// Where this export goes on iPad and iPhone; `nil` for a folder.
    public private(set) var delivery: Delivery?
    /// The share sheet or Save to Files has taken the exported photos.
    public var isDelivered = false
    /// Holds the next photo back, as while the iOS app is in the background.
    public let pause = PauseGate()

    private var jobs: [Job] = []
    private var task: Task<Void, Never>?
    /// Batches whose sidecars are still being read.
    private var reading = 0
    /// Folders chosen in the open panel, whose access lasts until the queue is cleared.
    private var accessedFolders: Set<URL> = []
    private var staging: ExportStaging?
    private let renderer = try? RAWRenderer()

    public var isRunning: Bool { task != nil || reading > 0 }
    /// The toolbar shows the queue while it runs and until its summary is dismissed.
    public var isVisible: Bool { total > 0 }
    public var fractionDone: Double { total > 0 ? Double(finished) / Double(total) : 0 }
    /// The number of the photo being exported, counting from 1.
    public var position: Int { min(finished + 1, total) }

    /// Queues `items` for `folder`, a folder chosen in the open panel, with `settings`. The
    /// photos' sidecars are read first, so each export has the edit it had when Export was clicked.
    public func start(_ items: [Item], settings: ExportSettings, folder: URL) {
        guard !items.isEmpty else { return }
        if !isRunning { clear() }
        if accessedFolders.insert(folder).inserted { _ = folder.startAccessingSecurityScopedResource() }
        queue(items, settings: settings, folder: folder)
    }

    /// Queues `items` for `delivery` on iPad and iPhone, rendered into a temporary folder that
    /// `clear()` removes. One delivery at a time: the export sheet stays up until it ends.
    public func start(_ items: [Item], settings: ExportSettings, delivery: Delivery) {
        guard !items.isEmpty, !isRunning else { return }
        clear()
        ExportStaging.removeLeftovers()
        do {
            staging = try ExportStaging()
        } catch {
            failures = items.map { Failure(name: $0.url.lastPathComponent, reason: error.localizedDescription) }
            total = items.count
            finished = items.count
            return
        }
        self.delivery = delivery
        queue(items, settings: settings, folder: staging!.folder)
    }

    private func queue(_ items: [Item], settings: ExportSettings, folder: URL) {
        wasCancelled = false
        total += items.count
        reading += 1
        Task {
            let read = await Task.detached(priority: .utility) {
                items.map { item in
                    Job(url: item.url, recipe: item.recipe ?? (try? Sidecar.read(for: item.url))??.recipe
                                ?? EditRecipe(asShot: CameraSettings(contentsOf: item.url)),
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
    public func cancel() {
        guard isRunning else { return }
        wasCancelled = true
        jobs = []
        pause.release()
    }

    /// Dismisses the summary and ends access to the folders exported to.
    public func clear() {
        guard !isRunning else { return }
        total = 0
        finished = 0
        current = nil
        exported = []
        failures = []
        wasCancelled = false
        delivery = nil
        isDelivered = false
        staging?.remove()
        staging = nil
        for folder in accessedFolders { folder.stopAccessingSecurityScopedResource() }
        accessedFolders = []
    }

    private func run() async {
        guard let renderer else {
            failures += jobs.map { Failure(name: $0.url.lastPathComponent, reason: "Proof needs a Metal GPU to export.") }
            finished += jobs.count
            jobs = []
            return
        }
        if delivery == .photos, await !PhotoLibrary.requestAddAccess() {
            failures += jobs.map { Failure(name: $0.url.lastPathComponent, reason: PhotoLibrary.deniedReason) }
            finished += jobs.count
            jobs = []
            return
        }
        while !jobs.isEmpty, !wasCancelled {
            await pause.waitWhilePaused()
            guard !jobs.isEmpty, !wasCancelled else { break }
            let job = jobs.removeFirst()
            current = job.url.lastPathComponent
            // A photo in iCloud is downloaded first, one at a time, as the queue goes (decision 0050).
            if !CloudDownload.isDownloaded(job.url), await !CloudDownload.download(job.url) {
                failures.append(Failure(name: job.url.lastPathComponent, reason: "It couldn't be downloaded from iCloud."))
                finished += 1
                continue
            }
            // iOS takes the GPU from an app in the background, which fails a render in flight;
            // that photo goes back in the queue for when the app returns.
            let pausesBefore = pause.pauses
            let result = await Task.detached(priority: .utility) {
                let lut = await LUTLibrary.shared.lut(for: job.recipe.look)
                let details = PhotoExport.Details(rating: job.rating, description: PhotoDescription.read(for: job.url))
                return try await PhotoExport.export(job.url, recipe: job.recipe, lut: lut, details: details,
                                                    settings: job.settings, into: job.folder, with: renderer)
            }.result
            switch result {
            case .success(let url) where delivery == .photos:
                do {
                    try await PhotoLibrary.add(url)
                    exported.append(url)
                } catch {
                    failures.append(Failure(name: job.url.lastPathComponent,
                                            reason: "It couldn't be added to Photos. \(error.localizedDescription)"))
                }
            case .success(let url): exported.append(url)
            case .failure where pause.pauses != pausesBefore:
                jobs.insert(job, at: 0)
                continue
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
