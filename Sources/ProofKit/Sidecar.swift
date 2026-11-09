import Foundation

/// A photo's `.proof` sidecar as Proof last read or wrote it. It keeps the file's JSON so that
/// fields this version doesn't recognize, such as ones a newer Proof wrote, survive a save.
/// When the file is created and deleted is set out in decision 0007.
public struct Sidecar: Equatable, Sendable {
    public private(set) var recipe: EditRecipe
    /// The file has fields `EditRecipe` doesn't read. Such a file is never deleted for being neutral.
    public private(set) var hasUnrecognizedFields: Bool
    /// The JSON as read or written, which a save merges the new recipe over.
    private var json: JSONValue

    /// Reads a sidecar's contents. Unrecognized fields are kept; recognized ones that are
    /// missing take their defaults.
    public init(data: Data) throws {
        recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
        json = try JSONDecoder().decode(JSONValue.self, from: data)
        hasUnrecognizedFields = json.hasFields(missingFrom: try JSONValue(recipe))
    }

    /// The JSON for `recipe`, written over this sidecar's so unrecognized fields stay as they were.
    public func data(saving recipe: EditRecipe) throws -> Data {
        try Self.encoder.encode(JSONValue(recipe).merged(over: json))
    }

    /// The JSON for a new sidecar.
    public static func data(for recipe: EditRecipe) throws -> Data {
        try encoder.encode(recipe)
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
    /// `nil` if there was none), with `NSFileCoordinator`. A neutral recipe deletes the file
    /// instead, unless it has unrecognized fields. Returns the sidecar now on disk. Blocks on file I/O.
    @discardableResult
    public static func save(_ recipe: EditRecipe, for original: URL, over existing: Sidecar?) throws -> Sidecar? {
        let url = EditRecipe.sidecarURL(for: original)
        if recipe.isNeutral, existing?.hasUnrecognizedFields != true {
            try coordinate { coordinator, error in
                coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: error) { url in
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch CocoaError.fileNoSuchFile {
                    } catch let caught {
                        error?.pointee = caught as NSError
                    }
                }
            }
            return nil
        }
        let data = try existing.map { try $0.data(saving: recipe) } ?? data(for: recipe)
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
