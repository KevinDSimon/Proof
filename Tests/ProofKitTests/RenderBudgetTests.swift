import CoreGraphics
import Foundation
import Testing
@testable import ProofKit

struct RenderBudgetTests {
    private let m11 = CGSize(width: 9504, height: 6320)

    @Test("Without a memory limit, as on the Mac, zoom renders up to full resolution")
    func unlimited() {
        #expect(RenderBudget.unlimited.maxScale(photoSize: m11) == 1)
        #expect(RenderBudget.forAvailableMemory(nil, thermalState: .nominal) == .unlimited)
        // The simulator reports no memory left, since it has no limit.
        #expect(RenderBudget.forAvailableMemory(0, thermalState: .nominal) == .unlimited)
    }

    @Test("A zoomed render may take half the memory left to the app")
    func halfOfAvailable() {
        let budget = RenderBudget.forAvailableMemory(4_000_000_000, thermalState: .nominal)
        #expect(budget.bytes == 2_000_000_000)
        // 2 GB at 64 bytes a pixel is 31 MP, a little over half the M11's 60 MP.
        #expect(budget.maxScale(photoSize: m11) == 0.72)
    }

    @Test("Serious and critical thermal pressure halve the budget")
    func thermalPressure() {
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            #expect(RenderBudget.forAvailableMemory(4_000_000_000, thermalState: state).bytes == 1_000_000_000)
        }
        #expect(RenderBudget.forAvailableMemory(4_000_000_000, thermalState: .fair).bytes == 2_000_000_000)
    }

    @Test("A photo that fits the budget whole renders at full resolution")
    func smallPhotoIsNotLimited() {
        let budget = RenderBudget(bytes: 2_000_000_000)
        #expect(budget.maxScale(photoSize: CGSize(width: 4032, height: 3024)) == 1)
    }

    @Test("The scale is rounded down to a hundredth, so a slightly different budget asks for the same render")
    func roundedScale() {
        let a = RenderBudget(bytes: 2_000_000_000).maxScale(photoSize: m11)
        let b = RenderBudget(bytes: 2_010_000_000).maxScale(photoSize: m11)
        #expect(a == b)
        #expect(a * 100 == (a * 100).rounded())
    }
}
