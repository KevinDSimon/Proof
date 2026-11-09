#if os(macOS)
import Foundation
import Testing
@testable import ProofKit

@MainActor
struct FolderWatcherTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2025"), withIntermediateDirectories: true)
    }

    /// The first changes the watcher reports after `change` runs, or none after five seconds.
    func changes(watching folder: URL, after change: () throws -> Void) async throws -> [FolderWatcher.Change] {
        let (stream, continuation) = AsyncStream.makeStream(of: [FolderWatcher.Change].self)
        let watcher = FolderWatcher(folders: [folder], latency: 0.1) { continuation.yield($0) }
        try change()
        let timeout = Task { try await Task.sleep(for: .seconds(5)); continuation.finish() }
        defer { timeout.cancel() }
        var iterator = stream.makeAsyncIterator()
        let changes = await iterator.next() ?? []
        withExtendedLifetime(watcher) {}
        return changes
    }

    func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("A photo added to a subfolder is reported as a change to that subfolder")
    func reportsNewFile() async throws {
        let subfolder = root.appendingPathComponent("2025")
        let changes = try await changes(watching: root) {
            try Data("raw".utf8).write(to: subfolder.appendingPathComponent("L1000957.DNG"))
        }
        #expect(changes.map { path($0.folder) }.contains(path(subfolder)))
    }

    @Test("A new subfolder is reported as a change to its parent")
    func reportsNewFolder() async throws {
        let changes = try await changes(watching: root) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("2026"),
                                                    withIntermediateDirectories: false)
        }
        #expect(changes.map { path($0.folder) }.contains(path(root)))
    }
}
#endif
