import Darwin
import Foundation
import Testing
@testable import ProofKit

/// Peak memory and times for the renders an iPhone makes of a large photo, for #236. Runs with
/// `PROOF_SAMPLE_DNG` and `PROOF_MEMORY`, on the Mac or, through `TEST_RUNNER_` variables, on an
/// iPhone simulator (CONTRIBUTING.md has both commands). Each test measures the process's
/// footprint, which on Apple silicon includes GPU memory, from before its renderer exists.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PROOF_MEMORY"] != nil && sampleDNG != nil))
struct MemoryTests {
    /// The canvas above the sheet on an iPhone 18 Pro, in pixels: the screen's width at 3×, and
    /// about half its height.
    static let phoneCanvas = CGSize(width: 1206, height: 1300)

    @Test("Opening and editing at the phone canvas's size")
    func openAndEdit() async throws {
        let url = try #require(sampleDNG)
        let recipe = Self.savedEdit(for: url)
        let lut = await LUTLibrary().lut(for: recipe.look)
        let (times, peak) = try await FootprintSampler.measure {
            let renderer = try RAWRenderer()
            var times: [Double] = []
            let start = ContinuousClock.now
            try await renderer.open(url)
            _ = try await renderer.render(fitting: Self.phoneCanvas, recipe: recipe, lut: lut)
            times.append((ContinuousClock.now - start) / .milliseconds(1))
            for exposure in [0.5, -0.5, 1, -1, 1.5, -1.5, 2] {
                var changed = recipe
                changed.basic.exposure = exposure
                let start = ContinuousClock.now
                _ = try await renderer.render(fitting: Self.phoneCanvas, recipe: changed, lut: lut)
                times.append((ContinuousClock.now - start) / .milliseconds(1))
            }
            return times
        }
        Self.report("Open and first render", [times[0]])
        Self.report("Exposure change", Array(times.dropFirst()))
        print("Open and edit peak footprint: \(Self.mb(peak))")
    }

    @Test("Zoomed in on the phone canvas", arguments: [0.5, 0.7, 1.0])
    func zoomed(scale: Double) async throws {
        let url = try #require(sampleDNG)
        let recipe = Self.savedEdit(for: url)
        let lut = await LUTLibrary().lut(for: recipe.look)
        let (times, peak) = try await FootprintSampler.measure {
            let renderer = try RAWRenderer()
            try await renderer.open(url)
            let fitted = try await renderer.render(fitting: Self.phoneCanvas, recipe: recipe, lut: lut)
            let size = fitted.photoSize
            // The view at this zoom, with an eighth of it past each edge, as the canvas asks for.
            let width = Self.phoneCanvas.width * 1.25 / (size.width * scale)
            let height = Self.phoneCanvas.height * 1.25 / (size.height * scale)
            var times: [Double] = []
            for (x, exposure) in zip([0.3, 0.32, 0.5, 0.52], [0.0, 0.0, 0.5, 0.5]) {
                var changed = recipe
                changed.basic.exposure = exposure
                let start = ContinuousClock.now
                _ = try await renderer.render(region: CGRect(x: x, y: 0.4, width: width, height: height), scale: scale,
                                              recipe: changed, lut: lut)
                times.append((ContinuousClock.now - start) / .milliseconds(1))
            }
            return times
        }
        Self.report("Region at \(Int(scale * 100))%, pans then an exposure change", times)
        print("Zoomed to \(Int(scale * 100))% peak footprint: \(Self.mb(peak))")
    }

    @Test("Full-size JPEG export")
    func export() async throws {
        let url = try #require(sampleDNG)
        let recipe = Self.savedEdit(for: url)
        let lut = await LUTLibrary().lut(for: recipe.look)
        let (time, peak) = try await FootprintSampler.measure {
            let renderer = try RAWRenderer()
            let start = ContinuousClock.now
            let image = try await renderer.export(url, recipe: recipe, lut: lut, settings: ExportSettings(format: .jpeg))
            print("Exported \(image.width)×\(image.height)")
            return (ContinuousClock.now - start) / .milliseconds(1)
        }
        Self.report("Full-size JPEG export render", [time])
        print("Export peak footprint: \(Self.mb(peak)), kept after: \(Self.mb(FootprintSampler.retained))")
    }

    static func savedEdit(for url: URL) -> EditRecipe {
        (try? Sidecar.read(for: url))??.recipe ?? EditRecipe()
    }

    static func report(_ label: String, _ times: [Double]) {
        let sorted = times.sorted()
        print("\(label): median \(String(format: "%.1f", sorted[sorted.count / 2])) ms over \(times.count) "
            + "(range \(String(format: "%.1f", sorted[0]))–\(String(format: "%.1f", sorted[sorted.count - 1])) ms)")
    }

    static func mb(_ bytes: UInt64) -> String { "\(bytes / 1_000_000) MB" }
}

/// Samples the process's physical footprint every few milliseconds while `work` runs and returns
/// the highest value above the footprint before it.
enum FootprintSampler {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// The footprint above `baseline` once `work` has returned, for what a renderer keeps.
    nonisolated(unsafe) static var retained: UInt64 = 0

    static func measure<T>(_ work: () async throws -> T) async rethrows -> (T, UInt64) {
        let baseline = footprint()
        let peak = Peak()
        let sampler = Thread {
            while !peak.isDone {
                peak.record(footprint())
                usleep(2_000)
            }
        }
        sampler.start()
        let value = try await work()
        peak.record(footprint())
        peak.finish()
        let after = footprint()
        retained = after > baseline ? after - baseline : 0
        return (value, peak.highest > baseline ? peak.highest - baseline : 0)
    }

    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        private var done = false
        var isDone: Bool { lock.withLock { done } }
        var highest: UInt64 { lock.withLock { value } }
        func record(_ bytes: UInt64) { lock.withLock { value = max(value, bytes) } }
        func finish() { lock.withLock { done = true } }
    }
}
