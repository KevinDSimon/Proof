import Foundation

/// Why a file wasn't added to the LUT library.
public struct LUTImportError: Error, LocalizedError, Equatable {
    public enum Reason: Equatable, Sendable {
        /// The file doesn't end in `.cube`.
        case notCube
        /// The file couldn't be read or the library couldn't be written.
        case unreadable
        /// The parser refused the file.
        case invalid(CubeLUTError)
    }

    public var fileName: String
    public var reason: Reason

    public var errorDescription: String? {
        let detail = switch reason {
        case .notCube: "Proof adds LUTs from .cube files."
        case .unreadable: "The file couldn’t be read."
        case .invalid(let error): error.errorDescription ?? ""
        }
        return "“\(fileName)” wasn’t added. \(detail)"
    }
}

/// The person's LUTs: `.cube` files in a folder of Proof's own, which `look.lut` names by file
/// name. Proof ships with none; every LUT is imported. Imported files are copies, so the original
/// can be moved or deleted. Loaded LUTs are prepared off the caller's thread and kept, up to
/// `memoryLimit` bytes, so switching between them doesn't read or lay out the table again.
public actor LUTLibrary {
    public static let fileExtension = "cube"

    public nonisolated let directory: URL
    private let memoryLimit: Int
    /// Prepared LUTs by file name, and their names from least to most recently used.
    private var prepared: [String: PreparedLUT] = [:]
    private var recentlyUsed: [String] = []
    private var preparing: [String: Task<PreparedLUT?, Never>] = [:]

    /// `directory` is created when the first LUT is imported.
    public init(directory: URL = .applicationSupportDirectory.appendingPathComponent("Proof/LUTs"),
                memoryLimit: Int = 512 << 20) {
        self.directory = directory
        self.memoryLimit = memoryLimit
    }

    /// The file names of the LUTs in the library, sorted as the Finder sorts them. Blocks on file I/O.
    public nonisolated func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files
            .filter { (($0 as NSString).pathExtension).lowercased() == Self.fileExtension && !$0.hasPrefix(".") }
            // Without the extension, so "Portra" comes before "Portra 2".
            .sorted { ($0 as NSString).deletingPathExtension.localizedStandardCompare(($1 as NSString).deletingPathExtension) == .orderedAscending }
    }

    /// Copies the `.cube` file at `url` into the library and returns its name there. A file the
    /// parser refuses isn't added. A file with the same name and contents as one in the library
    /// isn't added twice; one with the same name and other contents is numbered, as in
    /// "Portra 2.cube", so the LUT an existing edit names never changes.
    public nonisolated func importFile(at url: URL) async throws(LUTImportError) -> String {
        let fileName = url.lastPathComponent
        guard url.pathExtension.lowercased() == Self.fileExtension else {
            throw LUTImportError(fileName: fileName, reason: .notCube)
        }
        // A URL from an Open dialog or a drop is only readable while access is held.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw LUTImportError(fileName: fileName, reason: .unreadable) }
        let lut: CubeLUT
        do {
            lut = try CubeLUT(data: data)
        } catch {
            throw LUTImportError(fileName: fileName, reason: .invalid(error))
        }
        guard let name = Self.store(data, as: fileName, in: directory) else {
            throw LUTImportError(fileName: fileName, reason: .unreadable)
        }
        await startPreparing(lut, as: name)
        return name
    }

    /// The prepared LUT that `look` names, or `nil` for no look or a LUT the library doesn't have.
    public func lut(for look: Look?) async -> PreparedLUT? {
        guard let look else { return nil }
        return await lut(named: look.lut)
    }

    /// The prepared LUT named `name`, read and laid out the first time it is asked for. `nil` if
    /// the library has no such file or it no longer parses.
    public func lut(named name: String) async -> PreparedLUT? {
        if let lut = prepared[name] {
            markUsed(name)
            return lut
        }
        // A name comes from a sidecar, so it must not lead out of the library.
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let task = preparing[name] ?? Task.detached { [directory] in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let lut = try? CubeLUT(data: data) else { return nil }
            return PreparedLUT(lut)
        }
        preparing[name] = task
        let lut = await task.value
        finish(lut, as: name)
        return lut
    }

    /// The names of the LUTs held prepared, least recently used first. For tests.
    var cachedNames: [String] { recentlyUsed }

    private func startPreparing(_ lut: CubeLUT, as name: String) {
        guard prepared[name] == nil, preparing[name] == nil else { return }
        preparing[name] = Task.detached { PreparedLUT(lut) }
    }

    private func finish(_ lut: PreparedLUT?, as name: String) {
        preparing[name] = nil
        guard let lut else { return }
        if prepared[name] == nil { prepared[name] = lut }
        markUsed(name)
        // The LUT just used stays, even alone over the limit.
        var total = prepared.values.reduce(0) { $0 + $1.data.count }
        while total > memoryLimit, recentlyUsed.count > 1 {
            let oldest = recentlyUsed.removeFirst()
            total -= prepared.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    private func markUsed(_ name: String) {
        recentlyUsed.removeAll { $0 == name }
        recentlyUsed.append(name)
    }

    /// Writes `data` into `directory` under `fileName`, or a numbered name if another file has
    /// it. Returns the name it is stored under, which is an existing file's if it holds the same bytes.
    private static func store(_ data: Data, as fileName: String, in directory: URL) -> String? {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for number in 1... {
            let name = number == 1 ? fileName : "\(base) \(number).\(ext)"
            let target = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == data { return name }
                continue
            }
            return (try? data.write(to: target, options: .withoutOverwriting)) != nil ? name : nil
        }
        return nil
    }
}
