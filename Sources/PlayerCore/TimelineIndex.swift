import Foundation

/// Sorted interval index; reused for cue and word clocks, including overlaps.
public struct TimelineIndex: Sendable {
    private let starts: [Double]
    private let ends: [Double]
    private let prefixEnd: [Double]
    public init(starts: [Double] = [], ends: [Double] = []) {
        precondition(starts.count == ends.count)
        self.starts = starts; self.ends = ends
        var end = -Double.infinity
        prefixEnd = ends.map { end = max(end, $0); return end }
    }
    public func lowerBound(_ value: Double, inclusive: Bool = false) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < value || inclusive && starts[mid] == value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
    public func active(at time: Double) -> [Int] {
        var i = lowerBound(time, inclusive: true) - 1, result: [Int] = []
        while i >= 0 && prefixEnd[i] > time { if ends[i] > time { result.append(i) }; i -= 1 }
        return result.reversed()
    }
    public func adjacent(at time: Double, direction: Int) -> Int? {
        if direction > 0 { let next = lowerBound(time + 0.05, inclusive: true); return next < starts.count ? next : nil }
        var i = lowerBound(time + 0.05, inclusive: true) - 1
        while i >= 0 && prefixEnd[i] > time {
            if ends[i] > time { let previous = lowerBound(starts[i] - 0.001) - 1; return previous >= 0 ? previous : nil }; i -= 1
        }
        let previous = lowerBound(time - 0.05) - 1
        return previous >= 0 ? previous : nil
    }
}
