import Foundation

@main enum FrameTimingCheck {
    static func main() {
        var meter = FrameTiming()
        meter.record(1)
        for i in 1...99 { meter.record(1 + Double(i) / 60) }
        assert(meter.low == nil)
        for i in 100...600 { meter.record(1 + Double(i) / 60) }
        assert(abs(meter.milliseconds - 1000 / 60) < 0.01)
        assert(abs(meter.low! - 60) < 0.01)
        assert(abs(meter.high! - 60) < 0.01)
        meter.record(12)
        assert(meter.low! < 10)
        assert(abs(meter.high! - 60) < 0.01)
        print("PASS: stable frame pacing, sample warmup, slow-frame tail")
    }
}
