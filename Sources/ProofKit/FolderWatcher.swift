#if os(macOS)
import CoreServices
#endif
import Foundation

/// Reports folders that change inside the watched folders. On the Mac this is through FSEvents, so
/// local disks are never polled. On a network volume FSEvents reports only changes made from this
/// Mac, so folders there are rescanned instead of watched. iOS has no FSEvents, so there nothing is
/// reported until `refresh()` is called.
public final class FolderWatcher {
    /// A folder whose listing changed. When `includesSubfolders` is set, FSEvents dropped events
    /// and everything below the folder may have changed too.
    public struct Change: Equatable, Sendable {
        public var folder: URL
        public var includesSubfolders: Bool
    }

    private let folders: [URL]
    private let handler: @MainActor ([Change]) -> Void
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif

    /// Starts watching `folders` and everything inside them. `handler` runs on the main actor,
    /// after `latency` seconds have gathered related changes into one call.
    @MainActor
    public init(folders: [URL], latency: TimeInterval = 0.5, handler: @escaping @MainActor ([Change]) -> Void) {
        self.folders = folders
        self.handler = handler
        #if os(macOS)
        guard !folders.isEmpty else { return }
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

    #if os(macOS)
    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
    #endif
}
