import Foundation
import Testing
@testable import ProofKit

struct ExportStagingTests {
    let parent: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("ExportStagingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    @Test("Each export gets a new, empty folder, removed with what is in it")
    func folderLifetime() throws {
        let first = try ExportStaging(in: parent)
        let second = try ExportStaging(in: parent)
        #expect(first.folder != second.folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.folder.path).isEmpty)
        try Data([1]).write(to: first.folder.appendingPathComponent("photo.jpg"))
        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.folder.path))
        #expect(FileManager.default.fileExists(atPath: second.folder.path))
    }

    @Test("Leftover export folders are removed and other files are kept")
    func leftovers() throws {
        let staging = try ExportStaging(in: parent)
        let other = parent.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        ExportStaging.removeLeftovers(in: parent)
        #expect(!FileManager.default.fileExists(atPath: staging.folder.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}

@MainActor
struct PauseGateTests {
    @Test("Work waits while paused and carries on when unpaused")
    func waitsWhilePaused() async {
        let gate = PauseGate()
        await gate.waitWhilePaused()  // Not paused: returns at once.
        gate.isPaused = true
        var passed = false
        let work = Task { @MainActor in
            await gate.waitWhilePaused()
            passed = true
        }
        while gate.waitingCount == 0 { await Task.yield() }
        #expect(!passed)
        gate.isPaused = false
        await work.value
        #expect(passed)
    }

    @Test("Counts each pause, so work can tell one came and went")
    func countsPauses() {
        let gate = PauseGate()
        gate.isPaused = true
        gate.isPaused = true
        gate.isPaused = false
        gate.isPaused = true
        #expect(gate.pauses == 2)
    }

    @Test("Release lets waiters go while still paused, as stopping an export does")
    func release() async {
        let gate = PauseGate()
        gate.isPaused = true
        let work = Task { @MainActor in await gate.waitWhilePaused() }
        while gate.waitingCount == 0 { await Task.yield() }
        gate.release()
        await work.value
        #expect(gate.isPaused)
    }
}

struct RememberedExportSettingsTests {
    @Test("The last export's settings are remembered, with the defaults before the first")
    func remembered() throws {
        let suite = "RememberedExportSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ExportSettings.remembered(in: defaults) == ExportSettings())
        let settings = ExportSettings(format: .heic, quality: 0.7, size: .longEdge, longEdge: 3000,
                                      colorSpace: .displayP3, removesLocation: true)
        settings.remember(in: defaults)
        #expect(ExportSettings.remembered(in: defaults) == settings)
    }

    @Test("A size of 0 can't be exported")
    func validity() {
        #expect(ExportSettings().isValid)
        #expect(!ExportSettings(size: .longEdge, longEdge: 0).isValid)
        #expect(ExportSettings(size: .original, longEdge: 0).isValid)
        #expect(!ExportSettings(size: .longEdge, longEdge: 10, unit: .inches, resolution: 0).isValid)
        #expect(ExportSettings(size: .longEdge, longEdge: 10, unit: .inches, resolution: 300).isValid)
    }
}
