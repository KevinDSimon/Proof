import CoreImage
import Foundation
import simd

/// A `CubeLUT` laid out for Core Image's color cube filter: a 3D lattice over 0…1 on each axis,
/// as RGBA 32-bit floats, red changing fastest. Building one reads the whole table, so it is
/// made once when a LUT is loaded and reused for every render.
public struct PreparedLUT: Sendable {
    /// Core Image's color cube filters take 2 to 128 entries per side.
    static let maximumSize = 128
    /// The lattice a 1D table is sampled onto. 65 is the largest common 3D size; between its
    /// entries the filter interpolates in straight lines.
    static let oneDimensionalSize = 65

    /// Entries per side.
    public let size: Int
    let data: Data

    public init(_ lut: CubeLUT) {
        let size = switch lut.kind {
        case .oneDimensional: Self.oneDimensionalSize
        case .threeDimensional: min(lut.size, Self.maximumSize)
        }
        var floats = [Float]()
        floats.reserveCapacity(size * size * size * 4)
        if lut.kind == .threeDimensional, size == lut.size, lut.domainMin == .zero, lut.domainMax == .one {
            // Already Core Image's layout; values outside 0…1 are kept, as the file has them.
            for value in lut.values { floats += [value.x, value.y, value.z, 1] }
        } else {
            let step = 1 / Float(size - 1)
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let value = Self.sample(lut, at: SIMD3(Float(r), Float(g), Float(b)) * step)
                        floats += [value.x, value.y, value.z, 1]
                    }
                }
            }
        }
        self.size = size
        data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The table's output for `input`, interpolating in straight lines between entries: per
    /// channel for a 1D table, across the eight surrounding entries for a 3D one. Input outside
    /// the table's domain takes the value at its edge, as Core Image's filter does.
    static func sample(_ lut: CubeLUT, at input: SIMD3<Float>) -> SIMD3<Float> {
        let last = Float(lut.size - 1)
        let position = simd_clamp((input - lut.domainMin) / (lut.domainMax - lut.domainMin), .zero, .one) * last
        let low = SIMD3<Int>(simd_min(position.rounded(.down), SIMD3(repeating: last - 1)))
        let t = position - SIMD3<Float>(low)
        switch lut.kind {
        case .oneDimensional:
            var output = SIMD3<Float>()
            for c in 0..<3 {
                let a = lut.values[low[c]][c], b = lut.values[low[c] + 1][c]
                output[c] = a + (b - a) * t[c]
            }
            return output
        case .threeDimensional:
            func at(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Float> {
                lut[red: low.x + dr, green: low.y + dg, blue: low.z + db]
            }
            func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
            let g0 = mix(mix(at(0, 0, 0), at(1, 0, 0), t.x), mix(at(0, 1, 0), at(1, 1, 0), t.x), t.y)
            let g1 = mix(mix(at(0, 0, 1), at(1, 0, 1), t.x), mix(at(0, 1, 1), at(1, 1, 1), t.x), t.y)
            return mix(g0, g1, t.z)
        }
    }
}

/// The LUT stage, step 4 in docs/architecture.md. A `.cube` LUT expects display-referred values,
/// so the image goes from the linear working space to sRGB, through the cube, and back. The
/// blend with the image before the LUT happens in sRGB too, so the strength slider moves
/// evenly between the two as they look, not as linear light would weight them.
enum LUTStage {
    /// Above 1 the blend would extrapolate past the LUT, which clips colors.
    static let strengthRange: ClosedRange<Double> = 0...1
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Applies `lut` at `strength`, from 0 to 1; values outside are clamped. At 0, or without a
    /// LUT, the image is returned as it came, so it renders exactly as with no LUT.
    static func apply(_ lut: PreparedLUT?, strength: Double, to image: CIImage) -> CIImage {
        let amount = clamped(strength)
        guard let lut, amount > 0, let encoded = image.matchedFromWorkingSpace(to: colorSpace) else { return image }
        // Values outside 0…1, which the linear decode can reach, stay outside in `encoded`; the
        // cube takes its edge values for them.
        var looked = encoded.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": lut.size,
            "inputCubeData": lut.data,
        ])
        if amount < 1 {
            looked = looked.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: encoded,
                kCIInputAmountKey: amount,
            ])
        }
        return looked.matchedToWorkingSpace(from: colorSpace) ?? image
    }

    static func clamped(_ strength: Double) -> Double {
        min(max(strength, strengthRange.lowerBound), strengthRange.upperBound)
    }
}
