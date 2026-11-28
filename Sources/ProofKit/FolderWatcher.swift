#if os(macOS)
import CoreServices
#endif
import Foundation

/// Reports folders that change inside the watched folders. On the Mac this is through FSEvents, so
/// local disks are never polled. On a network volume FSEvents reports only changes made from this
/// Mac, so folders there are rescanned instead of watched. iOS has no FSEvents, so there each
/// folder has a file presenter, which hears of changes made through file coordination: those of
/// Files providers, such as iCloud Drive listing a folder's files after it was first read (#325).
// Its state is only changed on the main actor; presenters reach it from their queues by a Task there.
public final class FolderWatcher: @unchecked Sendable {
    /// A folder whose listing changed. When `includesSubfolders` is set, FSEvents dropped events
    /// and everything below the folder may have changed too.
    public struct Change: Equatable, Sendable {
        public var folder: URL
        public var includesSubfolders: Bool
    }

    /// Whether every change is reported. Where it isn't, as on iOS, where a presenter misses changes
    /// made without coordination or while the app is suspended, folders are read again when Proof
    /// becomes active and when the person refreshes.
    #if os(macOS)
    public static let reportsChanges = true
    #else
    public static let reportsChanges = false
    #endif

    private let folders: [URL]
    private let handler: @MainActor ([Change]) -> Void
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif
    private let latency: TimeInterval
    private var presenters: [FolderPresenter] = []
    private var pending: [Change] = []

    /// Starts watching `folders` and everything inside them. `handler` runs on the main actor,
    /// after `latency` seconds have gathered related changes into one call.
    @MainActor
    public convenience init(folders: [URL], latency: TimeInterval = 0.5, handler: @escaping @MainActor ([Change]) -> Void) {
        #if os(macOS)
        self.init(folders: folders, latency: latency, usesPresenters: false, handler: handler)
        #else
        self.init(folders: folders, latency: latency, usesPresenters: true, handler: handler)
        #endif
    }

    /// `usesPresenters` watches with file presenters instead of FSEvents, so tests on the Mac can
    /// check what iOS does.
    @MainActor
    init(folders: [URL], latency: TimeInterval, usesPresenters: Bool, handler: @escaping @MainActor ([Change]) -> Void) {
        self.folders = folders
        self.latency = latency
        self.handler = handler
        guard !folders.isEmpty else { return }
        if usesPresenters {
            presenters = folders.map { folder in
                FolderPresenter(folder: folder) { [weak self] change in
                    Task { @MainActor in self?.gather(change) }
                }
            }
            presenters.forEach(NSFileCoordinator.addFilePresenter)
            return
        }
        #if os(macOS)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let changes = (0..<count).map { index in
                Change(folder: URL(fileURLWithPath: paths[index], isDirectory: true),
                       includesSubfolders: flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0)
            }
            // The stream delivers on the main queue.
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler(changes)
            }
        }
        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        #endif
    }

    /// Reports every watched folder as changed, with its subfolders, so each one that has been read
    /// is read again. The iOS app calls this when it returns to the foreground and on pull to refresh.
    @MainActor
    public func refresh() {
        guard !folders.isEmpty else { return }
        handler(folders.map { Change(folder: $0, includesSubfolders: true) })
    }

    /// Holds presenters' changes for `latency` seconds, so a provider listing many files at once
    /// reads the folder again once.
    @MainActor
    private func gather(_ change: Change) {
        let isFirst = pending.isEmpty
        if !pending.contains(change) { pending.append(change) }
        guard isFirst else { return }
        Task { @MainActor [weak self, latency] in
            try? await Task.sleep(for: .seconds(latency))
            guard let self, !pending.isEmpty else { return }
            let changes = pending
            pending = []
            handler(changes)
        }
    }

    deinit {
        presenters.forEach(NSFileCoordinator.removeFilePresenter)
        #if os(macOS)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        #endif
    }
}

/// Presents one watched folder and reports the folder each changed item is in. A change to a
/// folder's own name or contents is reported as a change to its parent, as FSEvents does.
private final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let report: @Sendable (FolderWatcher.Change) -> Void

    init(folder: URL, report: @escaping @Sendable (FolderWatcher.Change) -> Void) {
        presentedItemURL = folder
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        self.report = report
    }

    private func changed(_ item: URL) {
        report(FolderWatcher.Change(folder: item.deletingLastPathComponent(), includesSubfolders: false))
    }

    func presentedSubitemDidAppear(at url: URL) { changed(url) }
    func presentedSubitemDidChange(at url: URL) { changed(url) }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        changed(oldURL)
        changed(newURL)
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed(url)
        completionHandler(nil)
    }

    /// The folder's own contents changed in a way no subitem was named for, such as a provider
    /// replacing its listing.
    func presentedItemDidChange() {
        guard let folder = presentedItemURL else { return }
        report(FolderWatcher.Change(folder: folder, includesSubfolders: true))
    }
}
