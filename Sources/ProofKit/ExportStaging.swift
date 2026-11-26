import Foundation

/// The temporary folder an export renders into on iPad and iPhone, where the destination is
/// chosen after the photos are ready: the share sheet, Save to Files or Photos (decision 0048).
/// The files are only Proof's own copies, so the folder is removed once they are delivered.
public struct ExportStaging: Sendable, Equatable {
    static let prefix = "Proof Export "

    public let folder: URL

    /// Makes a new, empty folder inside `parent`.
    public init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        folder = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Removes the folder and whatever is still in it.
    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the folders of exports that ended without being cleared, such as when the app was
    /// quit during one. Other files in `parent` are left alone.
    public static func removeLeftovers(in parent: URL = FileManager.default.temporaryDirectory) {
        let contents = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Holds work back while it is paused, such as an export while the iOS app is in the background,
/// where it can't use the GPU. Work waits at `waitWhilePaused()` between steps, and every waiter
/// carries on once the gate is unpaused.
@MainActor
public final class PauseGate {
    public var isPaused = false {
        didSet {
            if !isPaused { release() } else if !oldValue { pauses += 1 }
        }
    }
    /// How many times the gate has been paused, so work can tell a pause came and went while it ran.
    public private(set) var pauses = 0

    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waitingCount: Int { waiters.count }

    public init() {}

    /// Returns at once when not paused; otherwise once `isPaused` turns false or `release()` is
    /// called, such as to stop the work.
    public func waitWhilePaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Lets every waiter carry on, paused or not.
    public func release() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
