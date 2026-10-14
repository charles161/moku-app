import Foundation

/// Counts events over a rolling window (60 s by default) in one-second buckets, so memory stays
/// constant however fast events arrive. Times are seconds on any monotonic clock.
struct RollingCounter: Sendable {
    let windowSeconds: Int
    private var buckets: [Int]
    private var bucketSeconds: [Int]

    init(windowSeconds: Int = 60) {
        precondition(windowSeconds > 0, "window must be at least one second")
        self.windowSeconds = windowSeconds
        buckets = Array(repeating: 0, count: windowSeconds)
        bucketSeconds = Array(repeating: Int.min, count: windowSeconds)
    }

    mutating func record(_ count: Int = 1, at time: TimeInterval) {
        guard count > 0 else { return }
        let second = Int(time.rounded(.down))
        let slot = Self.slot(for: second, windowSeconds: windowSeconds)
        if bucketSeconds[slot] != second {
            bucketSeconds[slot] = second
            buckets[slot] = 0
        }
        buckets[slot] += count
    }

    /// Events recorded in the window that ends at `time` (the current second included).
    func count(at time: TimeInterval) -> Int {
        let now = Int(time.rounded(.down))
        let oldest = now - windowSeconds
        var total = 0
        for slot in 0..<windowSeconds where bucketSeconds[slot] > oldest && bucketSeconds[slot] <= now {
            total += buckets[slot]
        }
        return total
    }

    private static func slot(for second: Int, windowSeconds: Int) -> Int {
        ((second % windowSeconds) + windowSeconds) % windowSeconds
    }
}
