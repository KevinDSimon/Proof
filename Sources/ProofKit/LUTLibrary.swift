import Foundation

/// Why a file or folder wasn't added to the LUT library.
public struct LUTImportError: Error, LocalizedError, Equatable {
    public enum Reason: Equatable, Sendable {
        /// The file doesn't end in `.cube`.
        case notCube
        /// A folder with no `.cube` files in it or below it.
        case noLUTs
        /// The file couldn't be read or the library couldn't be written.
        case unreadable
        /// The parser refused the file.
        case invalid(CubeLUTError)
    }

    /// The file's name, or its path below the folder being imported.
    public var fileName: String
    public var reason: Reason

    public var errorDescription: String? {
        let detail = switch reason {
        case .notCube: "Proof adds LUTs from .cube files."
        case .noLUTs: "The folder has no .cube files."
        case .unreadable: "The file couldn’t be read."
        case .invalid(let error): error.errorDescription ?? ""
        }
        return "“\(fileName)” wasn’t added. \(detail)"
    }
}

/// Why a LUT or folder in the library wasn't renamed or removed.
public enum LUTLibraryError: Error, LocalizedError, Equatable {
    /// The new name is empty, starts with a period or holds a "/".
    case invalidName
    /// Another LUT or folder beside it already has the new name.
    case nameTaken(String)
    /// The library has no LUT or folder at the path.
    case notFound
    /// The file system refused the change.
    case failed

    public var errorDescription: String? {
        switch self {
        case .invalidName: "A name can’t be empty, start with a period or contain “/”."
        case .nameTaken(let name): "There’s already a look or folder named “\(name)”."
        case .notFound: "The look or folder is no longer in the library."
        case .failed: "The library couldn’t be changed."
        }
    }
}

/// The person's LUTs: `.cube` files in a folder of Proof's own, in folders of their own if they
/// were imported that way. `look.lut` names one by its path in the library, such as
/// "Portra/400.cube". Proof ships with none; every LUT is imported. Imported files are copies, so
/// the original can be moved or deleted. Loaded LUTs are prepared off the caller's thread and
/// kept, up to `memoryLimit` bytes, so switching between them doesn't read or lay out the table again.
public actor LUTLibrary {
    public static let fileExtension = "cube"

    public nonisolated let directory: URL
    private let memoryLimit: Int
    /// Prepared LUTs by path, and their paths from least to most recently used.
    private var prepared: [String: PreparedLUT] = [:]
    private var recentlyUsed: [String] = []
    private var preparing: [String: Task<PreparedLUT?, Never>] = [:]

    /// `directory` is created when the first LUT is imported.
    public init(directory: URL = .applicationSupportDirectory.appendingPathComponent("Proof/LUTs"),
                memoryLimit: Int = 512 << 20) {
        self.directory = directory
        self.memoryLimit = memoryLimit
    }

    /// The paths of the LUTs in the library, with folders separated by "/". Each folder's contents
    /// follow it, folders before the LUTs beside them, and names at each level are sorted as the
    /// Finder sorts them. Blocks on file I/O.
    public nonisolated func names() -> [String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { item -> [String]? in
            guard let url = item as? URL, url.pathExtension.lowercased() == Self.fileExtension else { return nil }
            return Array(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(root.count))
        }
        .sorted(by: Self.precedes)
        .map { $0.joined(separator: "/") }
    }

    /// A string that changes whenever the LUT at path `name` does: its file's size and
    /// modification date. `nil` if the library has no such file. Blocks on file I/O.
    public nonisolated func version(of name: String) -> String? {
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard Self.isInside(components),
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: components.reduce(directory) { $0.appendingPathComponent($1) }.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(size) \(modified.timeIntervalSinceReferenceDate)"
    }

    /// The folder the LUT at `path` is in, as a path in the library: "" for one outside any folder.
    public static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The folders that hold LUTs themselves, in the order of `names`, which is `names()`.
    public static func folders(in names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map(folder(of:)).filter { seen.insert($0).inserted }
    }

    /// The LUTs directly in `folder`, not in its subfolders, in the order of `names`.
    public static func names(_ names: [String], in folder: String) -> [String] {
        names.filter { self.folder(of: $0) == folder }
    }

    /// The folders directly below `parent`, among `folders` and the folders that hold them, in the
    /// order of `folders`, which is `folders(in:)`. A folder that holds only other folders isn't in
    /// `folders` but is listed here, so the folder menu can open it as a submenu.
    public static func childFolders(of parent: String, in folders: [String]) -> [String] {
        let depth = parent.isEmpty ? 0 : parent.split(separator: "/").count
        var children: [String] = []
        for folder in folders where !folder.isEmpty && (parent.isEmpty || folder.hasPrefix(parent + "/")) {
            let components = folder.split(separator: "/").map(String.init)
            guard components.count > depth else { continue }
            let child = components[...depth].joined(separator: "/")
            if !children.contains(child) { children.append(child) }
        }
        return children
    }

    /// Whether the LUT at path `a` is listed before the one at `b`.
    static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (index, (x, y)) in zip(a, b).enumerated() where x != y {
            let xIsFolder = index < a.count - 1, yIsFolder = index < b.count - 1
            if xIsFolder != yIsFolder { return xIsFolder }
            // Without the extension, so "Portra" comes before "Portra 2".
            let order = (x as NSString).deletingPathExtension.localizedStandardCompare((y as NSString).deletingPathExtension)
            return order == .orderedSame ? x < y : order == .orderedAscending
        }
        return a.count < b.count
    }

    /// Imports the `.cube` file at `url`, or every `.cube` file in the folder at `url` and below it.
    /// A folder keeps its name and its subfolders in the library; other files in it are left out.
    /// Returns the paths added and the files that weren't.
    public nonisolated func importItem(at url: URL) async -> (names: [String], failures: [LUTImportError]) {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            do {
                return ([try await importFile(at: url)], [])
            } catch {
                return ([], [error])
            }
        }
        let base = url.standardizedFileURL.pathComponents.count
        let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == Self.fileExtension }
        guard !files.isEmpty else { return ([], [LUTImportError(fileName: url.lastPathComponent, reason: .noLUTs)]) }
        var names: [String] = [], failures: [LUTImportError] = []
        for file in files {
            let relative = Array(file.standardizedFileURL.pathComponents.dropFirst(base))
            do {
                names.append(try await importFile(at: file, into: [url.lastPathComponent] + relative.dropLast()))
            } catch {
                failures.append(LUTImportError(fileName: ([url.lastPathComponent] + relative).joined(separator: "/"),
                                               reason: error.reason))
            }
        }
        return (names, failures)
    }

    /// Copies the `.cube` file at `url` into the library, in `folder` below its top, and returns its
    /// path there. A file the parser refuses isn't added. A file with the same name and contents as
    /// one in the folder isn't added twice; one with the same name and other contents is numbered,
    /// as in "Portra 2.cube", so the LUT an existing edit names never changes.
    public nonisolated func importFile(at url: URL, into folder: [String] = []) async throws(LUTImportError) -> String {
        let fileName = url.lastPathComponent
        guard url.pathExtension.lowercased() == Self.fileExtension else {
            throw LUTImportError(fileName: fileName, reason: .notCube)
        }
        // A URL from an Open dialog or a drop is only readable while access is held.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let data = Self.coordinatedData(at: url) else { throw LUTImportError(fileName: fileName, reason: .unreadable) }
        let lut: CubeLUT
        do {
            lut = try CubeLUT(data: data)
        } catch {
            throw LUTImportError(fileName: fileName, reason: .invalid(error))
        }
        guard Self.isInside(folder), let stored = Self.store(data, as: fileName, in: folder.reduce(directory) { $0.appendingPathComponent($1) }) else {
            throw LUTImportError(fileName: fileName, reason: .unreadable)
        }
        let name = (folder + [stored]).joined(separator: "/")
        await startPreparing(lut, as: name)
        return name
    }

    /// Renames the LUT or folder at `path` to `newName`, keeping it in the folder it is in, and
    /// returns its new path. A LUT keeps its `.cube` extension whether or not `newName` has it.
    /// Edits that name the old path no longer find it, as when a LUT is renamed in the Finder.
    public func rename(_ path: String, to newName: String) throws(LUTLibraryError) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard Self.isInside(components) else { throw .notFound }
        let source = url(of: components)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw .notFound }
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDirectory.boolValue, (name as NSString).pathExtension.lowercased() != Self.fileExtension {
            name += "." + Self.fileExtension
        }
        guard Self.isInside([name]), name != "." + Self.fileExtension else { throw .invalidName }
        let renamed = (components.dropLast() + [name]).joined(separator: "/")
        guard renamed != path else { return path }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        // A change of case alone is the same file on a case-insensitive volume.
        if FileManager.default.fileExists(atPath: target.path), name.lowercased() != components.last?.lowercased() {
            throw .nameTaken(isDirectory.boolValue ? name : (name as NSString).deletingPathExtension)
        }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw .failed
        }
        forget(below: path)
        return renamed
    }

    /// Deletes the LUT or folder at `path` from the library: Proof's copy, never the file it was
    /// imported from. Edits that name it are shown without it, as when it is removed in the Finder.
    public func remove(_ path: String) throws(LUTLibraryError) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard Self.isInside(components) else { throw .notFound }
        let item = url(of: components)
        guard FileManager.default.fileExists(atPath: item.path) else { throw .notFound }
        do {
            try FileManager.default.removeItem(at: item)
        } catch {
            throw .failed
        }
        forget(below: path)
    }

    private nonisolated func url(of components: [String]) -> URL {
        components.reduce(directory) { $0.appendingPathComponent($1) }
    }

    /// Lets go of the prepared LUT at `path` and those in the folder at `path`, so edits that name
    /// them stop finding them.
    private func forget(below path: String) {
        let isGone = { (name: String) in name == path || name.hasPrefix(path + "/") }
        for name in prepared.keys where isGone(name) { prepared[name] = nil }
        for name in preparing.keys where isGone(name) { preparing[name] = nil }
        recentlyUsed.removeAll(where: isGone)
    }

    /// The file's contents, read through a file coordinator. In iCloud Drive a file picked in Files
    /// or found in a picked folder may not be on the device yet, and coordinating downloads it first.
    static func coordinatedData(at url: URL) -> Data? {
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { data = try? Data(contentsOf: $0) }
        return data
    }

    /// Whether path components stay inside the library: none empty, hidden, or leading up and out.
    static func isInside(_ components: [String]) -> Bool {
        components.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }
    }

    /// The prepared LUT that `look` names, or `nil` for no look or a LUT the library doesn't have.
    public func lut(for look: Look?) async -> PreparedLUT? {
        guard let look else { return nil }
        return await lut(named: look.lut)
    }

    /// The prepared LUT at path `name`, read and laid out the first time it is asked for. `nil` if
    /// the library has no such file or it no longer parses.
    public func lut(named name: String) async -> PreparedLUT? {
        if let lut = prepared[name] {
            markUsed(name)
            return lut
        }
        // A name comes from a sidecar, so it must not lead out of the library.
        let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard Self.isInside(components) else { return nil }
        let task = preparing[name] ?? Task.detached { [directory] in
            guard let data = try? Data(contentsOf: components.reduce(directory) { $0.appendingPathComponent($1) }),
                  let lut = try? CubeLUT(data: data) else { return nil }
            return PreparedLUT(lut)
        }
        preparing[name] = task
        let lut = await task.value
        // Not kept when the LUT was renamed or removed while it was read, or another caller kept it.
        guard preparing[name] == task else { return lut }
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
    /// it. Returns the file name it is stored under, which is an existing file's if it holds the same bytes.
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
