import Foundation

/// How far an export has got, as the export sheet shows it (#201). An export counts the photos
/// done. Core Image renders a photo in one step that can't report how far it has got, and the
/// render is nearly all of an export's time, so neither a one-photo export nor the photo being
/// exported has a share of its own: a percentage for them would be a guess.
public struct ExportProgress: Equatable, Sendable {
    /// Photos queued, and how many of them are done or failed.
    public var total: Int
    public var finished: Int

    public init(total: Int, finished: Int) {
        self.total = total
        self.finished = finished
    }

    /// The share of photos done, from 0 to 1, or `nil` when there's no share to show: for one
    /// photo, or before any are queued.
    public var fraction: Double? {
        guard total > 1 else { return nil }
        return Double(min(max(finished, 0), total)) / Double(total)
    }

    /// The whole percent done, rounded down so 100 appears only when every photo is done.
    public var percent: Int? {
        guard total > 1 else { return nil }
        return min(max(finished, 0), total) * 100 / total
    }
}
