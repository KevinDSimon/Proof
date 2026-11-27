import CoreGraphics
import Testing
@testable import ProofKit

struct AccessibilityMetricsTests {
    @Test("A VoiceOver swipe moves a linear slider a twentieth of its range, rounded to its step")
    func swipeOnLinearSlider() {
        // Exposure: −5 to +5 stops in steps of a tenth.
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: true, from: 0, in: -5...5, step: 0.1) == 0.5)
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: false, from: 0, in: -5...5, step: 0.1) == -0.5)
        // Contrast: −100 to +100 in whole points.
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: true, from: 12, in: -100...100, step: 1) == 22)
    }

    @Test("A VoiceOver swipe stops at the ends of the slider")
    func swipeStopsAtEnds() {
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: true, from: 98, in: 0...100, step: 1) == 100)
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: true, from: 100, in: 0...100, step: 1) == 100)
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: false, from: 0, in: 0...100, step: 1) == 0)
    }

    @Test("A VoiceOver swipe always moves at least one step")
    func swipeMovesAtLeastOneStep() {
        // A step larger than a twentieth of the range.
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: true, from: 0, in: 0...10, step: 1) == 1)
        #expect(AccessibilityMetrics.sliderValue(afterSwipe: false, from: 5, in: 0...10, step: 1) == 4)
    }

    @Test("A VoiceOver swipe on temperature moves evenly along the slider, in mireds")
    func swipeOnTemperature() {
        let range = WhiteBalance.temperatureRange
        let start = 5500.0
        let warmer = AccessibilityMetrics.sliderValue(
            afterSwipe: true, from: start, in: range, step: 10,
            position: { WhiteBalance.sliderPosition(forTemperature: $0) },
            valueAtPosition: { WhiteBalance.temperature(atSliderPosition: $0) })
        let moved = WhiteBalance.sliderPosition(forTemperature: warmer) - WhiteBalance.sliderPosition(forTemperature: start)
        #expect(abs(moved - AccessibilityMetrics.sliderSwipeFraction) < 0.005)
        #expect(warmer.truncatingRemainder(dividingBy: 10) == 0)
    }

    @Test("A small control grows to a 44-point touch target on each side, a large one not at all")
    func touchTargetOutset() {
        #expect(AccessibilityMetrics.touchTargetOutset(for: CGSize(width: 24, height: 30)) == CGSize(width: 10, height: 7))
        #expect(AccessibilityMetrics.touchTargetOutset(for: CGSize(width: 60, height: 44)) == .zero)
    }

    @Test("The inspector's labels and titles meet WCAG contrast on the interface's grays")
    func interfaceContrast() {
        let canvas = CanvasColor.darkGray.components.red
        // The inspector cards' gray on iPhone and iPad, a step lighter than the canvas.
        let card = 0.18
        for background in [canvas, card] {
            // `InspectorCard.labelColor`: white at 75%.
            #expect(AccessibilityMetrics.contrastRatio(AccessibilityMetrics.white(0.75, over: background), background) >= 4.5)
            // Titles and values: white.
            #expect(AccessibilityMetrics.contrastRatio(1, background) >= 7)
        }
        #expect(AccessibilityMetrics.contrastRatio(0, 1) == 21)
    }
}
