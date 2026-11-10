import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct LUTStageTests {
    /// A 3D table that gives each lattice point `f` of its input.
    static func cube(size: Int, domainMax: Float = 1, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var values = [SIMD3<Float>]()
        let step = domainMax / Float(size - 1)
        for b in 0..<size { for g in 0..<size { for r in 0..<size { values.append(f(SIMD3(Float(r), Float(g), Float(b)) * step)) } } }
        return CubeLUT(kind: .threeDimensional, size: size, domainMax: SIMD3(repeating: domainMax), values: values)
    }

    static let invert = cube(size: 17) { 1 - $0 }
    static let identity = cube(size: 33) { $0 }

    /// Linear-light colors spread over the range, including values outside 0…1 that the
    /// extended-range decode produces.
    static let image: CIImage = {
        let colors: [[Float]] = [[0, 0, 0], [0.18, 0.18, 0.18], [1, 1, 1], [0.05, 0.4, 0.9],
                                 [0.7, 0.2, 0.03], [1.6, 1.2, 0.8], [-0.02, 0.3, 0.5], [0.5, 0.5, 0.02]]
        let floats = colors.flatMap { $0 + [1] }
        return CIImage(bitmapData: floats.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: colors.count * 16,
                       size: CGSize(width: colors.count, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }()

    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
    ])

    /// Pixels as sRGB-encoded floats, unclamped, three per pixel.
    static func encoded(_ image: CIImage) -> [Float] {
        let count = Int(image.extent.width)
        var floats = [Float](repeating: 0, count: count * 4)
        context.render(image, toBitmap: &floats, rowBytes: count * 16, bounds: image.extent, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB))
        return floats.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
    }

    /// Whether the stage handed back the very image it was given, with no filter added.
    static func isUnchanged(_ result: CIImage) -> Bool { result === image }

    static func largestDifference(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    @Test("Strength 0 returns the image unchanged, exactly as with no LUT")
    func strengthZero() {
        let lut = PreparedLUT(Self.invert)
        #expect(Self.isUnchanged(LUTStage.apply(lut, strength: 0, to: Self.image)))
        #expect(Self.isUnchanged(LUTStage.apply(nil, strength: 1, to: Self.image)))
        #expect(Self.encoded(LUTStage.apply(lut, strength: 0, to: Self.image)) == Self.encoded(Self.image))
    }

    @Test("Strength is limited to 0–100%")
    func strengthClamped() {
        let lut = PreparedLUT(Self.invert)
        #expect(Self.isUnchanged(LUTStage.apply(lut, strength: -0.5, to: Self.image)))
        let full = Self.encoded(LUTStage.apply(lut, strength: 1, to: Self.image))
        #expect(Self.encoded(LUTStage.apply(lut, strength: 1.8, to: Self.image)) == full)
    }

    @Test("The LUT applies to sRGB-encoded values")
    func displayReferred() {
        let input = Self.encoded(Self.image)
        let output = Self.encoded(LUTStage.apply(PreparedLUT(Self.invert), strength: 1, to: Self.image))
        // Input outside 0…1 takes the table's edge value.
        let expected = input.map { 1 - min(max($0, 0), 1) }
        #expect(Self.largestDifference(output, expected) < 0.002)
    }

    @Test("Strength blends with the image before the LUT in sRGB")
    func blend() {
        let input = Self.encoded(Self.image)
        let output = Self.encoded(LUTStage.apply(PreparedLUT(Self.invert), strength: 0.25, to: Self.image))
        let expected = input.map { 0.75 * $0 + 0.25 * (1 - min(max($0, 0), 1)) }
        #expect(Self.largestDifference(output, expected) < 0.002)
    }

    @Test("An identity LUT leaves colors inside 0…1 as they were")
    func identity() {
        let input = Self.encoded(Self.image)
        let output = Self.encoded(LUTStage.apply(PreparedLUT(Self.identity), strength: 1, to: Self.image))
        for (a, b) in zip(input, output) where (0...1).contains(a) {
            #expect(abs(a - b) < 0.002)
        }
    }

    @Test("A 1D table is sampled onto a 3D lattice")
    func oneDimensional() {
        let values = (0..<1024).map { SIMD3<Float>(repeating: 1 - Float($0) / 1023) }
        let lut = CubeLUT(kind: .oneDimensional, size: 1024, values: values)
        let prepared = PreparedLUT(lut)
        #expect(prepared.size == PreparedLUT.oneDimensionalSize)
        let output = Self.encoded(LUTStage.apply(prepared, strength: 1, to: Self.image))
        let expected = Self.encoded(LUTStage.apply(PreparedLUT(Self.invert), strength: 1, to: Self.image))
        #expect(Self.largestDifference(output, expected) < 0.002)
    }

    @Test("A table with a domain other than 0…1 is resampled onto 0…1")
    func domain() {
        // Over 0…2, a table that halves its input maps 0…1 to 0…0.5.
        let lut = Self.cube(size: 9, domainMax: 2) { $0 / 2 }
        #expect(abs(PreparedLUT.sample(lut, at: SIMD3(repeating: 0.6)).x - 0.3) < 1e-6)
        let input = Self.encoded(Self.image)
        let output = Self.encoded(LUTStage.apply(PreparedLUT(lut), strength: 1, to: Self.image))
        let expected = input.map { min(max($0, 0), 2) / 2 }
        #expect(Self.largestDifference(output, expected) < 0.002)
    }

    @Test("Tables larger than Core Image accepts are resampled to 128 per side")
    func largeTable() {
        let lut = Self.cube(size: 129) { 1 - $0 }
        let prepared = PreparedLUT(lut)
        #expect(prepared.size == PreparedLUT.maximumSize)
        #expect(prepared.data.count == 128 * 128 * 128 * 16)
        let output = Self.encoded(LUTStage.apply(prepared, strength: 1, to: Self.image))
        let expected = Self.encoded(LUTStage.apply(PreparedLUT(Self.invert), strength: 1, to: Self.image))
        #expect(Self.largestDifference(output, expected) < 0.002)
    }

    @Test("Trilinear sampling matches the table at lattice points and between them")
    func sampling() {
        let lut = Self.cube(size: 5) { SIMD3($0.x * $0.x, $0.y, 1 - $0.z) }
        #expect(PreparedLUT.sample(lut, at: SIMD3(0.5, 0.25, 0.75)) == SIMD3(0.25, 0.25, 0.25))
        // Halfway between 0.25 and 0.5 on red: halfway between their squares.
        #expect(abs(PreparedLUT.sample(lut, at: SIMD3(0.375, 0, 0)).x - (0.0625 + 0.25) / 2) < 1e-6)
        #expect(PreparedLUT.sample(lut, at: SIMD3(-1, 2, 0)) == SIMD3(0, 1, 1))
    }
}
