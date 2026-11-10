import Foundation

/// A color lookup table read from a `.cube` file, in the format Adobe published as
/// Cube LUT Specification 1.0, with the input range keywords DaVinci Resolve writes.
public struct CubeLUT: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One curve per channel, `size` entries long.
        case oneDimensional
        /// A lattice of `size` × `size` × `size` colors.
        case threeDimensional
    }

    public static let oneDimensionalSizes = 2...65536
    public static let threeDimensionalSizes = 2...256

    public var title: String?
    public var kind: Kind
    public var size: Int
    /// The input value each channel's first entry stands for.
    public var domainMin: SIMD3<Float>
    /// The input value each channel's last entry stands for.
    public var domainMax: SIMD3<Float>
    /// Output colors in file order. In a 3D table red changes fastest, then green, then blue.
    public var values: [SIMD3<Float>]

    public init(title: String? = nil, kind: Kind, size: Int,
                domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one, values: [SIMD3<Float>]) {
        self.title = title
        self.kind = kind
        self.size = size
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    /// The output color at a lattice point of a 3D table.
    public subscript(red r: Int, green g: Int, blue b: Int) -> SIMD3<Float> {
        values[r + size * (g + size * b)]
    }

    public init(data: Data) throws(CubeLUTError) {
        // Most files are ASCII. Older tools sometimes write titles in Latin-1.
        // Latin-1 decodes any bytes, so control characters are what tell a binary file apart.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !"\t\r\n".unicodeScalars.contains($0) })
        else { throw .notText }
        try self.init(text: text)
    }

    public init(text: String) throws(CubeLUTError) {
        var title: String?
        var size1D: Int?, size3D: Int?
        var domainMin: SIMD3<Float>?, domainMax: SIMD3<Float>?
        var values: [SIMD3<Float>] = []

        // "\r\n" is one Character in Swift, so Windows line breaks count as one line.
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            var line = Substring(rawLine)
            if line.first == "\u{FEFF}" { line = line.dropFirst() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let keyword = words[0]

            if let first = keyword.unicodeScalars.first, CharacterSet.letters.contains(first) {
                guard values.isEmpty else { throw .keywordAfterData(line: lineNumber, keyword: String(keyword)) }
                let arguments = Array(words.dropFirst())
                switch keyword {
                case "TITLE":
                    guard title == nil else { throw .repeatedKeyword(line: lineNumber, keyword: "TITLE") }
                    title = Self.title(from: trimmed.dropFirst("TITLE".count))
                case "LUT_1D_SIZE":
                    guard size1D == nil else { throw .repeatedKeyword(line: lineNumber, keyword: String(keyword)) }
                    guard size3D == nil else { throw .bothKinds(line: lineNumber) }
                    size1D = try Self.size(arguments, line: lineNumber, kind: .oneDimensional)
                case "LUT_3D_SIZE":
                    guard size3D == nil else { throw .repeatedKeyword(line: lineNumber, keyword: String(keyword)) }
                    guard size1D == nil else { throw .bothKinds(line: lineNumber) }
                    size3D = try Self.size(arguments, line: lineNumber, kind: .threeDimensional)
                case "DOMAIN_MIN":
                    guard domainMin == nil else { throw .repeatedKeyword(line: lineNumber, keyword: String(keyword)) }
                    domainMin = try Self.triple(arguments, line: lineNumber)
                case "DOMAIN_MAX":
                    guard domainMax == nil else { throw .repeatedKeyword(line: lineNumber, keyword: String(keyword)) }
                    domainMax = try Self.triple(arguments, line: lineNumber)
                case "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                    // Resolve's form: one minimum and one maximum shared by all channels.
                    guard domainMin == nil, domainMax == nil else {
                        throw .repeatedKeyword(line: lineNumber, keyword: String(keyword))
                    }
                    let range = try Self.numbers(arguments, count: 2, line: lineNumber)
                    domainMin = SIMD3(repeating: range[0])
                    domainMax = SIMD3(repeating: range[1])
                default:
                    // The specification lets files carry keywords of their own, which readers skip.
                    continue
                }
                continue
            }

            guard size1D != nil || size3D != nil else { throw .missingSize }
            values.append(try Self.triple(Array(words), line: lineNumber))
        }

        let kind: Kind
        let size: Int
        if let size1D {
            (kind, size) = (.oneDimensional, size1D)
        } else if let size3D {
            (kind, size) = (.threeDimensional, size3D)
        } else {
            throw .missingSize
        }
        let expected = kind == .oneDimensional ? size : size * size * size
        guard values.count == expected else { throw .wrongEntryCount(expected: expected, found: values.count) }

        let min = domainMin ?? .zero, max = domainMax ?? .one
        guard all(min .< max) else { throw .invalidDomain(min: min, max: max) }

        self.init(title: title, kind: kind, size: size, domainMin: min, domainMax: max, values: values)
    }

    private static func title(from rest: Substring) -> String {
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func size(_ arguments: [Substring], line: Int, kind: Kind) throws(CubeLUTError) -> Int {
        guard arguments.count == 1, let size = Int(arguments[0]) else { throw .malformedLine(line: line) }
        let allowed = kind == .oneDimensional ? oneDimensionalSizes : threeDimensionalSizes
        guard allowed.contains(size) else { throw .unsupportedSize(line: line, size: size, allowed: allowed) }
        return size
    }

    private static func triple(_ words: [Substring], line: Int) throws(CubeLUTError) -> SIMD3<Float> {
        let n = try numbers(words, count: 3, line: line)
        return SIMD3(n[0], n[1], n[2])
    }

    private static func numbers(_ words: [Substring], count: Int, line: Int) throws(CubeLUTError) -> [Float] {
        // Some tools end data lines with a comment.
        let words = words.prefix { !$0.hasPrefix("#") }
        guard words.count == count else { throw .malformedLine(line: line) }
        var result: [Float] = []
        result.reserveCapacity(count)
        for word in words {
            guard let value = Float(word), value.isFinite else { throw .malformedLine(line: line) }
            result.append(value)
        }
        return result
    }
}

public enum CubeLUTError: Error, LocalizedError, Equatable {
    case notText
    case missingSize
    case bothKinds(line: Int)
    case unsupportedSize(line: Int, size: Int, allowed: ClosedRange<Int>)
    case repeatedKeyword(line: Int, keyword: String)
    case keywordAfterData(line: Int, keyword: String)
    /// A line that should hold numbers holds the wrong count of them, or something that isn't a number.
    case malformedLine(line: Int)
    case wrongEntryCount(expected: Int, found: Int)
    case invalidDomain(min: SIMD3<Float>, max: SIMD3<Float>)

    public var errorDescription: String? {
        switch self {
        case .notText:
            "The file isn’t a text file, so it can’t be a .cube LUT."
        case .missingSize:
            "The file doesn’t say its size. A .cube LUT needs a LUT_3D_SIZE or LUT_1D_SIZE line before its values."
        case .bothKinds(let line):
            "Line \(line) gives a second size. Proof reads a .cube LUT that is either 1D or 3D, not both."
        case .unsupportedSize(let line, let size, let allowed):
            "Line \(line) gives a size of \(size). Proof reads sizes from \(allowed.lowerBound) to \(allowed.upperBound)."
        case .repeatedKeyword(let line, let keyword):
            "Line \(line) repeats \(keyword)."
        case .keywordAfterData(let line, let keyword):
            "Line \(line) has \(keyword) after the values have started. Settings must come first."
        case .malformedLine(let line):
            "Line \(line) can’t be read. It has the wrong number of values, or something that isn’t a number."
        case .wrongEntryCount(let expected, let found):
            "The file has \(found) values, but its size calls for \(expected)."
        case .invalidDomain:
            "The file’s DOMAIN_MIN isn’t below its DOMAIN_MAX for every channel."
        }
    }
}
