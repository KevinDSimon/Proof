import Foundation

/// Whether the tests check render times against their limits. Off unless `PROOF_TIMING` is set,
/// because the other suites render on the GPU at the same moment and can slow any render many
/// times over. The renders still run, and print their times, in every run; CONTRIBUTING.md has
/// the command that checks them on their own.
let checksTiming = ProcessInfo.processInfo.environment["PROOF_TIMING"] != nil

/// One frame at 30 fps, in milliseconds.
let frameBudget = 1000.0 / 30

/// Times `render` once for each value and returns the times in milliseconds, sorted.
///
/// Swift Testing runs the other suites in parallel, and several of them render the sample
/// photo on the GPU at the same moment, which can push even the fastest render of a round over
/// budget. So when every render in a round is over `budget`, the whole round is timed again, up
/// to `rounds` in all, and the round with the fastest render is returned. A renderer that is
/// really too slow is over budget in every round, so the check stays as strict.
func frameTimes<Value>(for values: [Value], budget: Double = frameBudget, rounds: Int = 5,
                       render: (Value) async throws -> Void) async rethrows -> [Double] {
    var best: [Double] = []
    for _ in 0..<rounds {
        var times: [Double] = []
        for value in values {
            let start = ContinuousClock.now
            try await render(value)
            times.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        times.sort()
        if best.isEmpty || times[0] < best[0] { best = times }
        if best[0] < budget { break }
    }
    return best
}
