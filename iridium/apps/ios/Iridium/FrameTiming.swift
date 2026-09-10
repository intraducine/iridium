import Foundation

struct FrameTiming {
    private var last: Double?
    private var intervals: [Double] = []
    private(set) var updatedAt: Double = 0
    private(set) var fps: Double = 0
    private(set) var milliseconds: Double = 0
    private(set) var low: Double?
    private(set) var high: Double?

    mutating func record(_ time: Double) {
        guard time.isFinite, time > 0 else { return }
        defer { last = time }
        guard let previous = last, time > previous else { return }
        intervals.append(time - previous)
        // ponytail: bounded 600-frame window; sort once per second for tail averages.
        if intervals.count > 600 { intervals.removeFirst() }
        guard time - updatedAt >= 1 else { return }
        updatedAt = time
        let recent = intervals.suffix(60)
        milliseconds = recent.reduce(0, +) / Double(recent.count) * 1000
        fps = 1000 / milliseconds
        guard intervals.count >= 100 else { low = nil; high = nil; return }
        let sorted = intervals.sorted()
        let count = max(1, Int(ceil(Double(sorted.count) * 0.01)))
        low = Double(count) / sorted.suffix(count).reduce(0, +)
        high = Double(count) / sorted.prefix(count).reduce(0, +)
    }
}
