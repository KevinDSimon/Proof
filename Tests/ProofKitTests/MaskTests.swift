import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct MaskTests {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
    ])
    /// 600 × 400. Core Image's y axis points up, so a mask point (x, y) is at (600x, 400 − 400y).
    private let size = CGSize(width: 600, height: 400)

    private func brighter(_ mask: Mask) -> Layer {
        var adjustments = LocalAdjustments()
        adjustments.exposure = 1
        return Layer(name: "Mask 1", mask: mask, adjustments: adjustments)
    }

    @Test("No layers, or a layer without adjustments, pass the image through untouched")
    func passThrough() {
        let image = gray(0.18)
        #expect(MaskStage.apply([], to: image) === image)
        let layer = Layer(name: "Mask 1", mask: Mask(.radial(RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2))))
        #expect(MaskStage.apply([layer], to: image) === image)
    }

    @Test("A linear gradient applies fully before its start, half way between, and not past its end")
    func linearGradient() throws {
        // From the top quarter to the middle: the sky.
        let layer = brighter(Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.25), end: CGPoint(x: 0.5, y: 0.5)))))
        let result = MaskStage.apply([layer], to: gray(0.18))
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 390)) - 0.36) < 0.001)
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 250)) - 0.27) < 0.003)
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 50)) - 0.18) < 0.001)
    }

    @Test("Inverting a mask applies the layer where the mask doesn't")
    func inverted() throws {
        let layer = brighter(Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.25), end: CGPoint(x: 0.5, y: 0.5))),
                                  isInverted: true))
        let result = MaskStage.apply([layer], to: gray(0.18))
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 390)) - 0.18) < 0.001)
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 50)) - 0.36) < 0.001)
    }

    @Test("A radial gradient applies inside its ellipse, and its angle turns the ellipse clockwise")
    func radialGradient() throws {
        // 0.2 by 0.05 of the long edge: 120 by 30 pixels from the center, then turned upright.
        var gradient = RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.05, feather: 0)
        let wide = MaskStage.apply([brighter(Mask(.radial(gradient)))], to: gray(0.18))
        #expect(abs(try value(wide, at: CGPoint(x: 300, y: 200)) - 0.36) < 0.001)
        #expect(abs(try value(wide, at: CGPoint(x: 400, y: 200)) - 0.36) < 0.001)
        #expect(abs(try value(wide, at: CGPoint(x: 300, y: 300)) - 0.18) < 0.001)
        #expect(abs(try value(wide, at: CGPoint(x: 450, y: 200)) - 0.18) < 0.001)
        gradient.angle = 90
        let tall = MaskStage.apply([brighter(Mask(.radial(gradient)))], to: gray(0.18))
        #expect(abs(try value(tall, at: CGPoint(x: 300, y: 300)) - 0.36) < 0.001)
        #expect(abs(try value(tall, at: CGPoint(x: 400, y: 200)) - 0.18) < 0.001)
    }

    @Test("A turned ellipse leans clockwise on the photo, as on screen")
    func radialAngleDirection() throws {
        // Turned 45° clockwise with y pointing down, the long axis runs to the lower right.
        let gradient = RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.03, angle: 45, feather: 0)
        let result = MaskStage.apply([brighter(Mask(.radial(gradient)))], to: gray(0.18))
        // Lower right on screen is right and down in Core Image's coordinates.
        #expect(abs(try value(result, at: CGPoint(x: 370, y: 130)) - 0.36) < 0.001)
        #expect(abs(try value(result, at: CGPoint(x: 370, y: 270)) - 0.18) < 0.001)
    }

    @Test("Feather fades a radial gradient out toward its edge")
    func radialFeather() throws {
        let gradient = RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, feather: 100)
        let result = MaskStage.apply([brighter(Mask(.radial(gradient)))], to: gray(0.18))
        let middle = try value(result, at: CGPoint(x: 360, y: 200))
        #expect(middle > 0.2 && middle < 0.34)
    }

    @Test("A brush stroke covers its path; erasing takes it away again")
    func brush() throws {
        // A stroke across the middle, 0.03 of the long edge (18 pixels) in radius, with a hard edge.
        let stroke = BrushStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 0.03, feather: 0)
        let painted = MaskStage.apply([brighter(Mask(.brush(BrushMask(strokes: [stroke]))))], to: gray(0.18))
        #expect(abs(try value(painted, at: CGPoint(x: 300, y: 200)) - 0.36) < 0.003)
        #expect(abs(try value(painted, at: CGPoint(x: 300, y: 240)) - 0.18) < 0.001)
        #expect(abs(try value(painted, at: CGPoint(x: 60, y: 200)) - 0.18) < 0.001)
        let eraser = BrushStroke(points: [CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.7)], radius: 0.03, feather: 0, erases: true)
        let erased = MaskStage.apply([brighter(Mask(.brush(BrushMask(strokes: [stroke, eraser]))))], to: gray(0.18))
        #expect(abs(try value(erased, at: CGPoint(x: 300, y: 200)) - 0.18) < 0.003)
        #expect(abs(try value(erased, at: CGPoint(x: 200, y: 200)) - 0.36) < 0.003)
    }

    @Test("Flow sets how much one stroke adds; going back and forth within a stroke adds no more")
    func brushFlow() {
        let once = BrushStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)], radius: 0.03, feather: 0, flow: 50)
        let weights = BrushRaster.draw(BrushMask(strokes: [once]), width: 600, height: 400)
        #expect(abs(weights[200 * 600 + 300] - 0.5) < 0.01)
        let scrubbed = BrushStroke(points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5), CGPoint(x: 0.2, y: 0.5)],
                                   radius: 0.03, feather: 0, flow: 50)
        #expect(abs(BrushRaster.draw(BrushMask(strokes: [scrubbed]), width: 600, height: 400)[200 * 600 + 300] - 0.5) < 0.01)
        let twice = BrushRaster.draw(BrushMask(strokes: [once, once]), width: 600, height: 400)
        #expect(abs(twice[200 * 600 + 300] - 0.75) < 0.01)
    }

    @Test("A stroke painted a little at a time, and a stroke added after it, give the same mask as drawing them at once")
    func brushGrowsIncrementally() throws {
        let aspect = CGSize(width: 600, height: 400)
        var stroke = BrushStroke(points: [CGPoint(x: 0.2, y: 0.5)], radius: 0.02, flow: 70)
        var brush = BrushMask(strokes: [BrushStroke(points: [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8)], erases: false), stroke])
        _ = BrushRaster.image(of: brush, aspect: aspect)
        for x in stride(from: 0.25, through: 0.8, by: 0.05) {
            stroke.append(CGPoint(x: x, y: 0.5 + (x - 0.5) * 0.3))
            brush.strokes[1] = stroke
            _ = BrushRaster.image(of: brush, aspect: aspect)
        }
        brush.strokes.append(BrushStroke(points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)], radius: 0.01, erases: true))
        let grown = try #require(BrushRaster.image(of: brush, aspect: aspect))
        let drawn = try #require(BrushRaster.grayImage(BrushRaster.draw(brush, width: grown.width, height: grown.height),
                                                       width: grown.width, height: grown.height))
        #expect(grown.dataProvider?.data as Data? == drawn.dataProvider?.data as Data?)
    }

    @Test("A subject mask applies where its picture is white")
    func subject() throws {
        // The left half white.
        let weights = (0..<(60 * 40)).map { Float($0 % 60 < 30 ? 1 : 0) }
        let png = try #require(BrushRaster.grayImage(weights, width: 60, height: 40).flatMap(SubjectDetection.png(of:)))
        let result = MaskStage.apply([brighter(Mask(.subject(SubjectMask(png: png))))], to: gray(0.18))
        #expect(abs(try value(result, at: CGPoint(x: 100, y: 200)) - 0.36) < 0.002)
        #expect(abs(try value(result, at: CGPoint(x: 500, y: 200)) - 0.18) < 0.002)
    }

    @Test("A subject mask's pin goes to the middle of the subject")
    func subjectCenter() throws {
        let weights = (0..<(60 * 40)).map { Float($0 % 60 < 30 ? 1 : 0) }
        let png = try #require(BrushRaster.grayImage(weights, width: 60, height: 40).flatMap(SubjectDetection.png(of:)))
        let center = try #require(SubjectMask(png: png).center)
        #expect(abs(center.x - 0.25) < 0.02 && abs(center.y - 0.5) < 0.02)
    }

    @Test("A layer that is off changes nothing; layers apply in order, each to the one before's result")
    func enabledAndOrder() throws {
        let whole = Mask(.radial(RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 2, radiusY: 2, feather: 0)))
        var off = brighter(whole)
        off.isEnabled = false
        #expect(abs(try value(MaskStage.apply([off], to: gray(0.18)), at: CGPoint(x: 300, y: 200)) - 0.18) < 0.001)
        let twice = MaskStage.apply([brighter(whole), brighter(whole)], to: gray(0.18))
        #expect(abs(try value(twice, at: CGPoint(x: 300, y: 200)) - 0.72) < 0.002)
    }

    @Test("Temperature warms and Tint turns magenta without changing a gray's brightness")
    func temperatureAndTint() throws {
        var warm = LocalAdjustments()
        warm.temperature = 100
        let warmed = try pixel(warm.apply(to: gray(0.18)), at: CGPoint(x: 300, y: 200))
        #expect(warmed.x > warmed.y && warmed.y > warmed.z)
        var magenta = LocalAdjustments()
        magenta.tint = 50
        let tinted = try pixel(magenta.apply(to: gray(0.18)), at: CGPoint(x: 300, y: 200))
        #expect(tinted.y < tinted.x && tinted.y < tinted.z)
        for rgb in [warmed, tinted] {
            #expect(abs(0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z - 0.18) < 0.001)
        }
    }

    @Test("The overlay tints only what the mask covers, whether or not the layer is on")
    func overlay() throws {
        var layer = brighter(Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.25), end: CGPoint(x: 0.5, y: 0.5)))))
        layer.isEnabled = false
        let result = MaskStage.overlay([layer], index: 0, on: gray(0.18))
        let covered = try pixel(result, at: CGPoint(x: 300, y: 390))
        #expect(covered.x > covered.y + 0.1)
        let uncovered = try pixel(result, at: CGPoint(x: 300, y: 50))
        #expect(abs(uncovered.x - 0.18) < 0.001 && abs(uncovered.y - 0.18) < 0.001)
        #expect(MaskStage.overlay([layer], index: nil, on: gray(0.18)).extent == gray(0.18).extent)
    }

    // MARK: Format

    @Test("Layers of each kind are saved and read back unchanged")
    func roundTrip() throws {
        var adjustments = LocalAdjustments()
        adjustments.shadows = 40
        adjustments.temperature = -10
        let tiny = try #require(BrushRaster.grayImage([0, 1], width: 2, height: 1))
        let png = try #require(SubjectDetection.png(of: tiny))
        var recipe = EditRecipe()
        recipe.layers = [
            Layer(name: "Sky", mask: Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.1), end: CGPoint(x: 0.5, y: 0.4)))),
                  adjustments: adjustments),
            Layer(name: "Face", isEnabled: false,
                  mask: Mask(.radial(RadialMask(center: CGPoint(x: 0.3, y: 0.4), radiusX: 0.1, radiusY: 0.15, angle: 20)),
                             isInverted: true)),
            Layer(name: "Rock", mask: Mask(.brush(BrushMask(strokes: [
                BrushStroke(points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.25)], flow: 40, erases: true),
            ])))),
            Layer(name: "Subject", mask: Mask(.subject(SubjectMask(png: png)))),
        ]
        recipe.maskOverlay = 1
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded.layers == recipe.layers)
        // The overlay is the canvas's, not the edit's.
        #expect(decoded.maskOverlay == nil)
    }

    @Test("A layer in the form saved before masks reads as covering nothing and changing nothing")
    func layerBeforeMasks() throws {
        let json = #"{"formatVersion": 3, "layers": [{"name": "Layer 1", "isEnabled": true, "basic": {"exposure": 1}}]}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.layers.count == 1)
        #expect(recipe.layers[0].adjustments.isNeutral)
        let image = gray(0.18)
        #expect(MaskStage.apply(recipe.layers, to: image) === image)
    }

    @Test("A kind of mask this version doesn't know covers nothing, and keeps its type when saved")
    func unknownMask() throws {
        let json = #"{"name": "Sky", "isEnabled": true, "mask": {"type": "sky", "isInverted": true}, "adjustments": {"exposure": 1}}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        #expect(layer.mask.shape == .unknown("sky"))
        #expect(layer.mask.kind == nil)
        #expect(abs(try value(MaskStage.apply([layer], to: gray(0.18)), at: CGPoint(x: 300, y: 200)) - 0.18) < 0.001)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layer)) as? [String: Any]
        #expect((saved?["mask"] as? [String: Any])?["type"] as? String == "sky")
    }

    @Test("Masks start unticked in Copy Settings, and pasting them replaces the target's")
    func copySettings() {
        #expect(!SettingsItem.defaultItems.contains(.masks))
        var source = EditRecipe()
        source.layers = [brighter(Mask(.brush(BrushMask())))]
        var target = EditRecipe()
        target.layers = [brighter(Mask(.brush(BrushMask()))), brighter(Mask(.brush(BrushMask())))]
        #expect(target.pasting(CopiedSettings(from: source, items: [.masks])).layers == source.layers)
        #expect(target.pasting(CopiedSettings(from: source, items: [.exposure])).layers == target.layers)
    }

    // MARK: Helpers

    private func gray(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: linear)!)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func pixel(_ image: CIImage, at point: CGPoint) throws -> SIMD3<Double> {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: linear)
        return SIMD3(Double(values[0]), Double(values[1]), Double(values[2]))
    }

    private func value(_ image: CIImage, at point: CGPoint) throws -> Double {
        try pixel(image, at: point).y
    }
}

struct SubjectDetectionTests {
    @Test("Vision finds a subject in the sample photo, and the mask covers part of it, not all",
          .enabled(if: sampleDNG != nil))
    func findsSubject() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        guard let mask = try await renderer.subjectMask(recipe: EditRecipe()) else { return }
        let image = try #require(SubjectRaster.image(of: mask))
        #expect(max(image.width, image.height) <= SubjectMask.maxPixelSize)
    }
}
