"""Execute production buffering/clock policy and legacy RTC restore behavior."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / 'iridium/apps/ios'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class SameBoyAudioTests(unittest.TestCase):
    def run_swift(self, fixture, sources=()):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); source = folder / 'main.swift'; source.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-module-cache-path',
                            module_cache('macosx'), *map(str, sources), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)

    def test_jitter_prefill_recovery_bounds_and_pause_reset(self):
        self.run_swift(r'''
import Foundation
func simulate(recover: Bool) -> (steps: Int, gaps: Int) {
    var pacer = IridiumFramePacer(), audio = IridiumAudioBuffering()
    var chunks: [Int] = [], remaining = 0, nextEvent = 0.0
    var playing = false, steps = 0, gaps = 0
    let fps = 59.72750056960583, rate = 96000.0
    for ms in 0..<2000 {
        let now = Double(ms) / 1000
        if now >= nextEvent && !(200..<225).contains(ms) && !(1200..<1225).contains(ms) {
            nextEvent = (floor(now * fps) + 1) / fps
            let count = recover ? pacer.steps(at: now, fps: fps) : 1
            for _ in 0..<count {
                steps += 1
                let frames = Int(rate / fps)
                if audio.enqueue(frames, rate: rate) { chunks.append(frames) }
            }
            if recover { if audio.beginPlayback(rate: rate) { playing = true } }
            else { playing = true }
        }
        if playing {
            var needed = 96
            while needed > 0 {
                if remaining == 0 {
                    guard !chunks.isEmpty else { gaps += 1; break }
                    remaining = chunks.removeFirst()
                }
                let used = min(remaining, needed); remaining -= used; needed -= used
                if remaining == 0 {
                    let drained = audio.consumed(Int(rate / fps))
                    if recover && drained { playing = false }
                }
            }
        }
    }
    return (steps, gaps)
}
let old = simulate(recover: false), current = simulate(recover: true)
precondition(old.gaps > 0 && current.gaps == 0 && current.steps > old.steps)
var audio = IridiumAudioBuffering()
precondition(audio.enqueue(1607, rate: 96000) && !audio.beginPlayback(rate: 96000))
precondition(audio.enqueue(3214, rate: 96000) && audio.beginPlayback(rate: 96000))
precondition(!audio.enqueue(96000, rate: 96000) && audio.droppedFrames == 96000)
precondition(audio.consumed(4821) && audio.underruns == 1 && !audio.started)
audio.resetQueue()
precondition(audio.queuedFrames == 0 && audio.enqueue(1607, rate: 96000) && !audio.beginPlayback(rate: 96000))
var clock = IridiumFramePacer()
precondition(clock.steps(at: 0, fps: 60) == 1)
precondition(clock.steps(at: 0.001, fps: 60) == 0)
precondition(clock.steps(at: 60, fps: 60) == 3 && clock.discardedSteps > 3000)
clock = IridiumFramePacer() // resume starts a new clock, never pause debt
precondition(clock.steps(at: 120, fps: 60) == 1)
print("PASS 25 ms timer-delay windows: old gaps=\(old.gaps), recovered gaps=\(current.gaps); frame catch-up, prefill, bounded overflow, re-prime and pause reset")
''', [IOS / 'RuntimeSupport/IridiumAudioBuffering.swift'])

    def test_no_rtc_upgrade_preserves_legacy_file_and_battery(self):
        session = (IOS / 'MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        restore = session[session.index('    private func restoreSaves()'):session.index('    private func persistSaves()')]
        restore = restore.replace('private func restoreSaves()', 'func restoreSaves()')
        self.run_swift(r'''
import Foundation
enum IridiumRuntimeError: Error { case invalidGame }
nonisolated(unsafe) var rtcSize = 0
nonisolated(unsafe) var writes: [Bool] = []
func ir_core_save_size(_ clock: Bool) -> Int { clock ? rtcSize : 4 }
func ir_core_write_save(_ clock: Bool, _ bytes: UnsafeRawPointer?, _ count: Int) -> Bool { writes.append(clock); return true }
struct Disk {
    let folder: URL
    func saveURL(clock: Bool) throws -> URL { folder.appendingPathComponent(clock ? "clock.bin" : "battery.sav") }
RESTORE
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let disk = Disk(folder: folder)
let battery = Data([1, 2, 3, 4]), oldClock = Data(repeating: 42, count: 48)
try battery.write(to: disk.saveURL(clock: false))
try oldClock.write(to: disk.saveURL(clock: true))
try disk.restoreSaves()
precondition(writes == [false])
let retainedClock = try Data(contentsOf: disk.saveURL(clock: true))
let retainedBattery = try Data(contentsOf: disk.saveURL(clock: false))
precondition(retainedClock == oldClock && retainedBattery == battery)
rtcSize = 47
do { try disk.restoreSaves(); fatalError("bad real RTC size accepted") } catch IridiumRuntimeError.invalidGame {}
try Data([0]).write(to: disk.saveURL(clock: false))
rtcSize = 0
do { try disk.restoreSaves(); fatalError("bad battery size accepted") } catch IridiumRuntimeError.invalidGame {}
print("PASS no-RTC release upgrade ignores and preserves obsolete clock bytes; battery and real RTC validation retained")
'''.replace('RESTORE', restore))


if __name__ == '__main__':
    unittest.main()
