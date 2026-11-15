import Foundation

/// A photo's `.proof` sidecar as Proof last read or wrote it. It keeps the file's JSON so that
/// fields this version doesn't recognize, such as ones a newer Proof wrote, survive a save.
/// When the file is created and deleted is set out in decision 0007.
public struct Sidecar: Equatable, Sendable {
    public private(set) var recipe: EditRecipe
    /// The photo the sidecar was first written for, which relinks it after a rename. `nil` in
    /// sidecars written before Proof stored it; the next save adds it.
    public private(set) var original: OriginalFingerprint?
    /// The file has fields `EditRecipe` doesn't read. Such a file is never deleted for being neutral.
    public private(set) var hasUnrecognizedFields: Bool
    /// The JSON as read or written, which a save merges the new recipe over.
    private var json: JSONValue

    /// Reads a sidecar's contents. Unrecognized fields are kept; recognized ones that are
    /// missing take their defaults.
    public init(data: Data) throws {
        recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
        json = try JSONDecoder().decode(JSONValue.self, from: data)
        original = (try? JSONDecoder().decode(OriginalField.self, from: data))?.original
        hasUnrecognizedFields = json.removingField(Self.originalKey).hasFields(missingFrom: try JSONValue(recipe))
    }

    /// The JSON for `recipe`, written over this sidecar's so unrecognized fields stay as they were.
    /// `original` is stored only when the sidecar has no fingerprint yet.
    public func data(saving recipe: EditRecipe, original: OriginalFingerprint? = nil) throws -> Data {
        var merged = try JSONValue(recipe).merged(over: json)
        if self.original == nil, let original { merged = try merged.settingField(Self.originalKey, to: JSONValue(original)) }
        return try Self.encoder.encode(merged)
    }

    /// The JSON for a new sidecar.
    public static func data(for recipe: EditRecipe, original: OriginalFingerprint? = nil) throws -> Data {
        var json = try JSONValue(recipe)
        if let original { json = try json.settingField(originalKey, to: JSONValue(original)) }
        return try encoder.encode(json)
    }

    /// The sidecar field that holds `original`, beside the recipe's fields.
    static let originalKey = "original"

    private struct OriginalField: Decodable {
        var original: OriginalFingerprint?
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: Files

    /// Reads the sidecar next to `original` with `NSFileCoordinator`; `nil` when there is none.
    /// Blocks on file I/O.
    public static func read(for original: URL) throws -> Sidecar? {
        let url = EditRecipe.sidecarURL(for: original)
        var result: Result<Sidecar?, Error> = .success(nil)
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: url, options: [], error: error) { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                result = Result { try Sidecar(data: Data(contentsOf: url)) as Sidecar? }
            }
        }
        return try result.get()
    }

    /// Saves `recipe` next to `original`, over `existing` (the sidecar as last read or written,
    /// `nil` if there was none), with `NSFileCoordinator`. A recipe the photo opens with anyway,
    /// `asShot` (see `CameraSettings`), deletes the file instead, unless it has unrecognized
    /// fields. A sidecar without a fingerprint of the original gets one. Returns the sidecar now
    /// on disk. Blocks on file I/O.
    @discardableResult
    public static func save(_ recipe: EditRecipe, for original: URL, over existing: Sidecar?,
                            asShot: EditRecipe = EditRecipe()) throws -> Sidecar? {
        let url = EditRecipe.sidecarURL(for: original)
        if recipe.isAsShot(asShot), existing?.hasUnrecognizedFields != true {
            try delete(for: original)
            return nil
        }
        let fingerprint = existing?.original == nil ? OriginalFingerprint(contentsOf: original) : nil
        let data = try existing.map { try $0.data(saving: recipe, original: fingerprint) }
            ?? data(for: recipe, original: fingerprint)
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: error) { url in
                do {
                    try data.write(to: url, options: .atomic)
                } catch let caught {
                    error?.pointee = caught as NSError
                }
            }
        }
        return try Sidecar(data: data)
    }

    /// Deletes the sidecar next to `original` with `NSFileCoordinator`, whatever it holds, as
    /// Revert to Original does. Nothing happens when there is none. Blocks on file I/O.
    public static func delete(for original: URL) throws {
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: EditRecipe.sidecarURL(for: original), options: .forDeleting, error: error) { url in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch CocoaError.fileNoSuchFile {
                } catch let caught {
                    error?.pointee = caught as NSError
                }
            }
        }
    }

    // MARK: Relinking

    /// Renames the sidecars in `folder` whose photo is gone to the photo they were written for,
    /// when that photo was renamed in the same folder (decision 0007). A sidecar is renamed only
    /// when exactly one photo without a sidecar has its fingerprint, and no other sidecar matches
    /// that photo; otherwise it is left alone. Returns the photos that got a sidecar, keyed by
    /// new name with the old name as value. Blocks on file I/O, so call it off the main thread.
    @discardableResult
    public static func relink(in folder: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let names = Set(entries.map(\.lastPathComponent))
        let orphans: [(name: String, original: OriginalFingerprint)] = entries.compactMap { entry in
            let name = entry.deletingPathExtension().lastPathComponent
            guard entry.pathExtension == "proof", !names.contains(name),
                  let sidecar = try? read(for: folder.appendingPathComponent(name)),
                  let original = sidecar.original else { return nil }
            return (name, original)
        }
        guard !orphans.isEmpty else { return [:] }

        // The size rules out most photos without opening them, which on a NAS is slow.
        let sizes = Set(orphans.map(\.original.size))
        let candidates: [(name: String, original: OriginalFingerprint)] = entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard !names.contains(name + ".proof"),
                  let values = try? entry.resourceValues(forKeys: keys), FolderContents.isRAW(values),
                  let size = values.fileSize, sizes.contains(size),
                  let original = OriginalFingerprint(contentsOf: entry) else { return nil }
            return (name, original)
        }

        var relinked: [String: String] = [:]
        for orphan in orphans {
            let matches = candidates.filter { $0.original == orphan.original }
            guard matches.count == 1, let photo = matches.first,
                  orphans.filter({ $0.original == photo.original }).count == 1 else { continue }
            try move(from: folder.appendingPathComponent(orphan.name + ".proof"),
                     to: folder.appendingPathComponent(photo.name + ".proof"))
            relinked[photo.name] = orphan.name
        }
        return relinked
    }

    /// Renames a sidecar with `NSFileCoordinator`. Fails rather than replace a file already there.
    private static func move(from source: URL, to destination: URL) throws {
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                                   writingItemAt: destination, options: .forReplacing, error: error) { source, destination in
                do {
                    coordinator.item(at: source, willMoveTo: destination)
                    try FileManager.default.moveItem(at: source, to: destination)
                    coordinator.item(at: source, didMoveTo: destination)
                } catch let caught {
                    error?.pointee = caught as NSError
                }
            }
        }
    }

    /// Runs one coordinated access and throws the error the coordinator or the accessor reported.
    private static func coordinate(_ access: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        var error: NSError?
        access(NSFileCoordinator(filePresenter: nil), &error)
        if let error { throw error }
    }
}

/// Any JSON, so a sidecar's fields can be kept without knowing what they mean. Numbers are
/// `Double`, as in the edit format.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    /// This value with the fields of `original` it doesn't have. Objects are merged key by key,
    /// and arrays of the same length element by element, so unrecognized fields inside a layer survive.
    func merged(over original: JSONValue) -> JSONValue {
        switch (self, original) {
        case (.object(let known), .object(var merged)):
            for (key, value) in known {
                merged[key] = merged[key].map { value.merged(over: $0) } ?? value
            }
            return .object(merged)
        case (.array(let known), .array(let original)) where known.count == original.count:
            return .array(zip(known, original).map { $0.merged(over: $1) })
        default:
            return self
        }
    }

    /// This object without the field `key`. Other values are returned as they are.
    func removingField(_ key: String) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = nil
        return .object(fields)
    }

    /// This object with `key` set to `value`. Other values are returned as they are.
    func settingField(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }

    /// Whether this value has a field, at any depth, that `known` lacks. A `null` doesn't count.
    func hasFields(missingFrom known: JSONValue) -> Bool {
        switch (self, known) {
        case (.object(let fields), .object(let knownFields)):
            return fields.contains { key, value in
                guard let knownValue = knownFields[key] else { return value != .null }
                return value.hasFields(missingFrom: knownValue)
            }
        case (.array(let values), .array(let knownValues)) where values.count == knownValues.count:
            return zip(values, knownValues).contains { $0.hasFields(missingFrom: $1) }
        default:
            return false
        }
    }
}
