// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Serial producer clock: Dispatch timers may coalesce while disk I/O runs.
/// Recover short delays, bounding work and discarding debt after long stalls.
struct IridiumFramePacer {
    private var next: Double?
    private(set) var lateEvents = 0
    private(set) var discardedSteps = 0

    mutating func steps(at now: Double, fps: Double) -> Int {
        guard fps.isFinite, fps > 0, now.isFinite else { return 0 }
        let deadline = next ?? now
        guard now + 0.000001 >= deadline else { return 0 }
        let owed = min(1_000_000, max(1, Int(min(999_999, (now - deadline) * fps)) + 1))
        let count = min(3, owed)
        if owed > 1 { lateEvents += 1 }
        if owed > count { discardedSteps += owed - count; next = now + 1 / fps }
        else { next = deadline + Double(count) / fps }
        return count
    }
}

/// Scheduling policy only; AVAudioPlayerNode owns the actual PCM storage.
/// Keep 50 ms before playback and at most 150 ms queued, in sample frames.
struct IridiumAudioBuffering {
    private(set) var queuedFrames = 0
    private(set) var started = false
    private(set) var underruns = 0
    private(set) var droppedFrames = 0

    mutating func resetQueue() { queuedFrames = 0; started = false }

    mutating func enqueue(_ frames: Int, rate: Double) -> Bool {
        guard frames > 0, rate.isFinite, rate >= 8000 else { return false }
        guard frames <= Int(rate * 0.15) - queuedFrames else { droppedFrames += frames; return false }
        queuedFrames += frames
        return true
    }
    mutating func beginPlayback(rate: Double) -> Bool {
        guard !started, queuedFrames >= Int(rate * 0.05) else { return false }
        started = true
        return true
    }
    mutating func consumed(_ frames: Int) -> Bool {
        queuedFrames = max(0, queuedFrames - frames)
        guard started, queuedFrames == 0 else { return false }
        started = false; underruns += 1
        return true
    }
}
