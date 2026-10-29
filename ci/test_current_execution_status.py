"""Run the production status projection and PSP event handler with host fixtures.

This exercises session UI state, not device JIT execution or SwiftUI rendering.
"""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FRONTEND = ROOT / 'iridium/apps/ios/MadeiraFrontend'


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class CurrentExecutionStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        folder = Path(cls.folder.name)
        source = (FRONTEND / 'IridiumConsoleSession.swift').read_text()
        handler = source[source.index('    private func nativePSPEvent('):source.index('    func setPSPResolution(')]
        reset = source[source.index('            pspReady = false;'):source.index('            jitDiagnostic = nil')]
        cleanup = next(line for line in source.splitlines() if 'self.pspReady = false; self.pspCPUMode' in line)
        fallback = source.split('            case .fallback(let reason):', 1)[1].split('\n            }', 1)[0]
        harness = r'''import Foundation
import Dispatch
struct Game { var platform: IridiumPlatform = .psp; var runtimeID = "ppsspp"; var pspJITEnabled = false; var id = UUID() }
enum IridiumCoreContent { static func saveFolders(_ folders: [String: String], game: UUID) {} }
struct Progress { var phase = "" }
struct FixtureQueue { func async(_ work: @escaping () -> Void) {} }
enum RuntimeDiagnosticLogFiles { static func writeConsoleLine(_ text: String) {} }
func ir_psp_native_resolution() -> Int32 { 2 }
final class IridiumConsoleSession {
    enum Phase { case idle, starting, running, paused, stopping, restartRequired }
    var game: Game? = Game(), lease: Int? = 1
    var phase = Phase.starting
    var pspReady = false, pspJITVerifiedForLaunch = false
    var coreControls = IridiumCoreControls(), coreStateStatus: String?
    var coreOperationPending=false, fastForward=false, rewindEnabled=false
    var cheats: [IridiumCheat]=[], pendingCheats: [IridiumCheat]?, restoredCheats=false
    let savedCheats: [IridiumCheat]=[]
    func restoreCheatsIfNeeded() {}
    func finishCheats(success: Bool) {}
    var phase3JITVerified = false, phase3Status = "Waiting for video"
    var phase3CommandIntent: UInt64?
    var pspResolution = 2, pspCPUMode = "Not reported", pspJITStatus = ""
    var pspJITFallbackReason: String?, pspStateStatus: String?, error: String?
    var nativePSPController: Int? = 1, terminalFailure = false, diagnostics = Progress()
    let queue = FixtureQueue()
    func complete(_ owner: Int) {}
    func stop() { phase = .stopping }
    func pause() { phase = .paused }
    func receive(_ kind: UInt32, _ text: String = "") { nativePSPEvent(kind, text: text) }
    func begin() { phase = .starting; lease = 1; game = Game(); nativePSPController = 1; RESET }
    func ended() { CLEANUP; phase = .idle; lease = nil; game = nil }
    func fallback(_ reason: String) { FALLBACK }
HANDLER
}
let session = IridiumConsoleSession()
switch CommandLine.arguments[1] {
case "jit":
    for cpu in ["JIT", "JIT using IR"] {
        session.begin()
        // Helper/preference state alone cannot claim active JIT.
        session.pspJITVerifiedForLaunch = true
        precondition(session.executionStatus.mode == "Unknown")
        session.receive(8, cpu)
        precondition(session.executionStatus.mode == "Unknown")
        session.receive(4)
        precondition(session.executionStatus.mode == "JIT active")
        session.phase = .paused
        precondition(session.executionStatus.mode == "JIT active" && session.executionStatus.detail.contains("paused"))
    }
case "interpreter":
    for cpu in ["Interpreter", "IR interpreter"] {
        session.begin()
        session.pspJITVerifiedForLaunch = true
        session.fallback("The execution probe did not pass.")
        session.receive(8, cpu); session.receive(4)
        precondition(session.executionStatus.mode == "Interpreter")
        // The native handler replaces the preflight reason when the engine
        // selects the interpreter after a verified launch.
        precondition(session.executionStatus.detail == "PPSSPP selected the interpreter after JIT verification.")
        session.begin(); session.fallback("JIT is turned off for this game.")
        session.receive(8, cpu); session.receive(4)
        precondition(session.executionStatus.detail == "JIT is turned off for this game.")
    }
case "failure":
    session.receive(8, "JIT"); session.receive(4)
    session.receive(2, "Launch failed")
    precondition(session.executionStatus.mode == "Unknown")
    session.begin(); session.receive(8, "JIT"); session.receive(4); session.receive(1)
    precondition(session.executionStatus.mode == "Not running") // Native close precedes queue cleanup.
    session.ended()
    precondition(session.executionStatus == .notRunning)
    session.begin(); session.receive(8, "JIT"); session.receive(9, "Cleanup incomplete")
    precondition(session.executionStatus.mode == "Unknown")
case "phase3":
    for (platform, runtime) in [(IridiumPlatform.gameCube, "dolphin"), (.nintendo3DS, "azahar"), (.playStation2, "play"), (.dreamcast, "flycast")] {
        session.begin(); session.game = Game(platform: platform, runtimeID: runtime)
        session.phase3JITVerified = true
        precondition(session.executionStatus.mode == "Unknown")
        session.phase = .running
        precondition(session.executionStatus.mode == "Allocator verified")
        precondition(session.executionStatus.detail.contains("does not establish"))
        precondition(!session.executionStatus.runtime.contains("SameBoy"))
        session.phase3JITVerified = false
        precondition(session.executionStatus.mode != "JIT active")
    }
case "stale":
    session.receive(8, "JIT"); session.receive(4)
    precondition(session.executionStatus.mode == "JIT active")
    session.ended()
    session.receive(8, "JIT"); session.receive(4) // Retired owner cannot revive status.
    precondition(session.executionStatus == .notRunning)
    session.begin()
    precondition(session.pspCPUMode == "Not reported" && session.pspJITFallbackReason == nil)
    precondition(session.executionStatus.mode == "Unknown")
    session.receive(8, "unexpected engine data"); session.receive(4)
    precondition(session.executionStatus.mode == "Unknown")
    session.game = Game(platform: .gameBoy); session.pspCPUMode = "JIT"
    precondition(session.executionStatus.runtime.contains("SameBoy") && session.executionStatus.mode == "Unknown")
    precondition(IridiumExecutionStatus.madeira.mode == "Unknown")
default: fatalError("Unknown fixture")
}
print("PASS current-session execution status: " + CommandLine.arguments[1])
'''.replace('HANDLER', handler).replace('RESET', reset).replace('CLEANUP', cleanup).replace('FALLBACK', fallback)
        main = folder / 'main.swift'; main.write_text(harness)
        cls.binary = folder / 'status'
        result = subprocess.run(['swiftc', '-swift-version', '5', '-D', 'IRIDIUM_PPSSPP', '-D', 'IRIDIUM_PHASE3',
                                 '-module-cache-path', module_cache('macosx'),
                                 str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumRuntime.swift'),
                                  str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumCoreControls.swift'),
                                 str(FRONTEND / 'IridiumExecutionStatus.swift'), str(main),
                                 '-o', str(cls.binary)], capture_output=True, text=True)
        if result.returncode:
            cls.folder.cleanup()
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def check_scenario(self, scenario):
        subprocess.run([str(self.binary), scenario], check=True, timeout=10)

    def test_active_jit_requires_booted_engine_report(self):
        self.check_scenario('jit')

    def test_interpreter_fallback_shows_current_reason(self):
        self.check_scenario('interpreter')

    def test_launch_failure_cannot_claim_active_jit(self):
        self.check_scenario('failure')

    def test_previous_session_and_other_runtimes_do_not_inherit_jit(self):
        self.check_scenario('stale')

    def test_phase3_allocator_capability_does_not_claim_guest_jit(self):
        self.check_scenario('phase3')


if __name__ == '__main__':
    unittest.main()
