import Foundation
import Testing
@testable import ProofKit

struct CubeLUTTests {
    /// A look that is easy to check at every lattice point: red and blue swap, green is halved.
    static func look(_ c: SIMD3<Float>) -> SIMD3<Float> { SIMD3(c.z, c.y * 0.5, c.x) }

    /// A 3D file written the way Resolve and most LUT tools write them.
    static func file3D(size: Int, lineBreak: String = "\n") -> String {
        var lines = ["# Created by a test", "TITLE \"Swap \(size)\"", "LUT_3D_SIZE \(size)", ""]
        let step = 1 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = look(SIMD3(Float(r), Float(g), Float(b)) * step)
                    lines.append(String(format: "%.6f %.6f %.6f", out.x, out.y, out.z))
                }
            }
        }
        return lines.joined(separator: lineBreak) + lineBreak
    }

    @Test("3D files of sizes 17, 33 and 65 read with red changing fastest", arguments: [17, 33, 65])
    func reads3D(size: Int) throws {
        let lut = try CubeLUT(text: Self.file3D(size: size))
        #expect(lut.kind == .threeDimensional)
        #expect(lut.size == size)
        #expect(lut.title == "Swap \(size)")
        #expect(lut.values.count == size * size * size)
        #expect(lut.domainMin == .zero && lut.domainMax == .one)
        let step = 1 / Float(size - 1)
        for (r, g, b) in [(0, 0, 0), (size - 1, 0, 0), (0, size - 1, 0), (0, 0, size - 1), (3, 7, 11), (size - 1, size - 1, size - 1)] {
            let expected = Self.look(SIMD3(Float(r), Float(g), Float(b)) * step)
            let difference = lut[red: r, green: g, blue: b] - expected
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 1e-6)
        }
    }

    @Test("1D files of sizes 17, 33, 65 and 4096 read in order", arguments: [17, 33, 65, 4096])
    func reads1D(size: Int) throws {
        var text = "LUT_1D_SIZE \(size)\n"
        for i in 0..<size {
            let v = Float(i) / Float(size - 1)
            text += "\(v) \(v * v) \(1 - v)\n"
        }
        let lut = try CubeLUT(text: text)
        #expect(lut.kind == .oneDimensional)
        #expect(lut.size == size)
        #expect(lut.title == nil)
        #expect(lut.values.first == SIMD3(0, 0, 1))
        #expect(lut.values.last == SIMD3(1, 1, 0))
        #expect(lut.values.count == size)
    }

    @Test("DOMAIN_MIN and DOMAIN_MAX set each channel's input range")
    func domain() throws {
        let text = """
            LUT_3D_SIZE 2
            DOMAIN_MIN -0.1 0 0.05
            DOMAIN_MAX 1.5 2 1.0e0
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """
        let lut = try CubeLUT(text: text)
        #expect(lut.domainMin == SIMD3(-0.1, 0, 0.05))
        #expect(lut.domainMax == SIMD3(1.5, 2, 1))
        #expect(lut[red: 1, green: 0, blue: 1] == SIMD3(1, 0, 1))
    }

    @Test("Resolve's input range keyword sets the same range for every channel")
    func resolveInputRange() throws {
        let lut = try CubeLUT(text: "LUT_1D_SIZE 2\nLUT_1D_INPUT_RANGE 0.0 4.0\n0 0 0\n1 1 1\n")
        #expect(lut.domainMin == .zero)
        #expect(lut.domainMax == SIMD3(repeating: 4))
    }

    @Test("Windows and old Mac line breaks, a byte order mark, tabs, comments and unknown keywords are accepted")
    func toleratedVariations() throws {
        let windows = try CubeLUT(text: Self.file3D(size: 17, lineBreak: "\r\n"))
        let classicMac = try CubeLUT(text: Self.file3D(size: 17, lineBreak: "\r"))
        let unix = try CubeLUT(text: Self.file3D(size: 17))
        #expect(windows == unix && classicMac == unix)

        let text = "\u{FEFF}# comment\nTITLE \"Tabs\"\nLUT_IN_VIDEO_RANGE\nLUT_1D_SIZE 2\n\n0\t0\t0  # black\n  1 1 1\n"
        let lut = try CubeLUT(data: Data(text.utf8))
        #expect(lut.title == "Tabs")
        #expect(lut.values == [.zero, .one])
    }

    @Test("Values outside 0 to 1 are kept")
    func valuesOutsideRange() throws {
        let lut = try CubeLUT(text: "LUT_1D_SIZE 2\n-0.25 0 0\n1.75 1 1\n")
        #expect(lut.values == [SIMD3(-0.25, 0, 0), SIMD3(1.75, 1, 1)])
    }

    @Test("Malformed files fail with an error that names the problem and its line", arguments: [
        ("", CubeLUTError.missingSize),
        ("0 0 0\n", .missingSize),
        ("TITLE \"No size\"\n", .missingSize),
        ("LUT_3D_SIZE 1\n0 0 0\n", .unsupportedSize(line: 1, size: 1, allowed: CubeLUT.threeDimensionalSizes)),
        ("LUT_3D_SIZE 257\n", .unsupportedSize(line: 1, size: 257, allowed: CubeLUT.threeDimensionalSizes)),
        ("LUT_1D_SIZE 70000\n", .unsupportedSize(line: 1, size: 70000, allowed: CubeLUT.oneDimensionalSizes)),
        ("LUT_3D_SIZE many\n", .malformedLine(line: 1)),
        ("LUT_3D_SIZE 2\nLUT_1D_SIZE 2\n", .bothKinds(line: 2)),
        ("LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n", .repeatedKeyword(line: 2, keyword: "LUT_3D_SIZE")),
        ("LUT_1D_SIZE 2\n0 0 0\nDOMAIN_MAX 2 2 2\n1 1 1\n", .keywordAfterData(line: 3, keyword: "DOMAIN_MAX")),
        ("LUT_1D_SIZE 2\n0 0\n1 1 1\n", .malformedLine(line: 2)),
        ("LUT_1D_SIZE 2\n0 0 0\n1 1 1 1\n", .malformedLine(line: 3)),
        ("LUT_1D_SIZE 2\n0 0 0\n1 one 1\n", .malformedLine(line: 3)),
        ("LUT_1D_SIZE 2\n0 0 0\n1 nan 1\n", .malformedLine(line: 3)),
        ("LUT_1D_SIZE 2\nDOMAIN_MIN 0 0\n", .malformedLine(line: 2)),
        ("LUT_1D_SIZE 3\n0 0 0\n1 1 1\n", .wrongEntryCount(expected: 3, found: 2)),
        ("LUT_3D_SIZE 2\n0 0 0\n", .wrongEntryCount(expected: 8, found: 1)),
        ("LUT_1D_SIZE 2\nDOMAIN_MIN 0 1 0\n0 0 0\n1 1 1\n", .invalidDomain(min: SIMD3(0, 1, 0), max: .one)),
    ])
    func malformed(text: String, error: CubeLUTError) {
        #expect(throws: error) { try CubeLUT(text: text) }
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("A binary file, such as a photo given by mistake, fails as not text")
    func binary() {
        #expect(throws: CubeLUTError.notText) { try CubeLUT(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])) }
    }
}
