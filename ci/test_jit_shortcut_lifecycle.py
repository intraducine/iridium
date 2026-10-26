"""Execute the generated shipping JIT/Shortcut methods with controlled endpoints."""
from host_tests import module_cache
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import madeira_jit_lifecycle as lifecycle

ROOT = Path(__file__).resolve().parents[1]


def upstream():
    return Path(os.environ.get('IRIDIUM_MADEIRA_SOURCE', ROOT / 'vendor/Madeira')) / 'app/Madeira'


class ShortcutLifecycleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_owned_shared_helper_release_waits_for_original_completion(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        method = source[source.index('    func releaseAttachedDebugger('):source.index('    /// The helper\'s failure as shown:')]
        fixture = '''import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@MainActor var attached = false
@MainActor var detachCalls = 0
@MainActor var fallbackCalls = 0
@MainActor func isDebuggerAttached() -> Bool { attached }
func jit_arm_trap_fallback() { DispatchQueue.main.async { fallbackCalls += 1 } }
enum StikJITHelper {
    static func detachDebugger() { DispatchQueue.main.async { detachCalls += 1 } }
}
@MainActor enum RuntimeDiagnosticLogFiles { static func writeConsoleLine(_ value: String) {} }
@MainActor final class JITNetworkShortcut {
    enum Outcome { case done, failed }
    static let shared = JITNetworkShortcut()
    var pspRecoveryPending = false
    var pending: ((Outcome) -> Void)?
    func restorePSP(completion: @escaping (Outcome) -> Void) { pending = completion }
}
@MainActor final class JITCoordinator {
    var enableRequest: UUID?
    var busy = false
    var consoleMemoryBusy = false
    var builtInHelper: UUID?
    var builtInHelperReleased: Bool?
    var builtInHelperReturned: (() -> Void)?
METHOD
}
@MainActor func settle() async { try! await Task.sleep(nanoseconds: 100_000_000) }
@MainActor func runChecks() async {
    let network = JITNetworkShortcut.shared
    let foreign = JITCoordinator()
    attached = true
    var foreignResults: [Bool] = []
    foreign.releaseAttachedDebugger { foreignResults.append($0) }
    await settle()
    precondition(foreignResults == [false] && detachCalls == 0 && network.pending == nil)
    attached = false
    foreign.releaseAttachedDebugger { foreignResults.append($0) }
    precondition(foreignResults == [false, true] && detachCalls == 0)

    let owned = JITCoordinator()
    owned.builtInHelper = UUID(); attached = true
    var results: [Bool] = []
    owned.releaseAttachedDebugger { results.append($0) }
    await settle()
    precondition(detachCalls == 1 && results.isEmpty && owned.busy)
    // A returned BRK is insufficient. So is a sticky signing flag without the original result.
    attached = false
    owned.builtInHelperReturned?()
    precondition(results.isEmpty && network.pending == nil)
    let originalCompletion = owned.builtInHelperReturned!
    owned.builtInHelperReleased = true; originalCompletion()
    precondition(results.isEmpty && owned.busy && network.pending != nil)
    network.pending?(.done); network.pending = nil
    precondition(results == [true] && !owned.busy && owned.enableRequest == nil)
    originalCompletion()
    precondition(results == [true] && network.pending == nil)

    // P_TRACED can clear while the owned extension still holds its request.
    let untraced = JITCoordinator()
    untraced.builtInHelper = UUID(); attached = false
    var untracedResults: [Bool] = []
    untraced.releaseAttachedDebugger { untracedResults.append($0) }
    await settle()
    precondition(detachCalls == 2 && fallbackCalls == 1 && untracedResults.isEmpty && network.pending == nil)
    untraced.builtInHelperReleased = true; untraced.builtInHelperReturned?()
    network.pending?(.done); network.pending = nil
    precondition(untracedResults == [true] && !untraced.busy)

    let failed = JITCoordinator()
    failed.builtInHelper = UUID(); failed.builtInHelperReleased = false
    var failures: [Bool] = []
    failed.releaseAttachedDebugger { failures.append($0) }
    precondition(failures == [false] && failed.busy && network.pending == nil && detachCalls == 2)

    let replaced = JITCoordinator()
    replaced.builtInHelper = UUID(); replaced.builtInHelperReleased = true; attached = true
    replaced.releaseAttachedDebugger { failures.append($0) }
    precondition(failures == [false, false] && detachCalls == 2)

    let recovery = JITCoordinator()
    recovery.builtInHelper = UUID(); recovery.builtInHelperReleased = true; attached = false
    recovery.releaseAttachedDebugger { failures.append($0) }
    network.pspRecoveryPending = true
    network.pending?(.failed); network.pending = nil
    precondition(failures == [false, false, false] && recovery.busy)

    let interrupted = JITCoordinator()
    interrupted.builtInHelper = UUID(); attached = true
    interrupted.releaseAttachedDebugger { failures.append($0) }
    await settle()
    precondition(detachCalls == 3 && failures.count == 3)
    try! await Task.sleep(nanoseconds: 10_100_000_000)
    precondition(failures == [false, false, false, false] && interrupted.busy)
    attached = false; interrupted.builtInHelperReleased = true; interrupted.builtInHelperReturned?()
    precondition(failures.count == 4 && network.pending == nil)
}
Task { @MainActor in await runChecks(); exit(0) }
dispatchMain()
'''.replace('METHOD', method)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / 'main.swift'; unit.write_text(fixture)
            binary = folder / 'check'
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'), str(unit), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=20)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_fresh_helper_readiness_requires_live_attachment(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/StikJITHelper.swift').read_text()
        method = source[source.index('    static func waitForDebugger('):source.index('    /// Allocate a JIT memory pool')]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text('''import Foundation
enum SigningStatus { struct Status { var debugged = true }; static var current = Status() }
var attached = false
func isDebuggerAttached() -> Bool { attached }
final class LogStore {
    static let shared = LogStore()
    enum Level { case success, error }
    func log(_ text: String, level: Level) {}
}
enum Helper {
    enum RequestError: Error { case timedOut }
''' + method + '''
}
var outcomes: [Bool] = []
let timer = Helper.waitForDebugger { outcomes.append((try? $0.get()) != nil) }
timer.fire()
precondition(outcomes.isEmpty)
attached = true; SigningStatus.current.debugged = false
timer.fire()
precondition(outcomes.isEmpty)
SigningStatus.current.debugged = true
timer.fire()
precondition(outcomes == [true] && !timer.isValid)
attached = false
let expired = Helper.waitForDebugger(timeout: -1) { outcomes.append((try? $0.get()) != nil) }
expired.fire()
precondition(outcomes == [true, false] && !expired.isValid)
''')
            executable = folder / 'check'
            subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True, timeout=30)
            subprocess.run([str(executable)], check=True, timeout=5)

    @unittest.skipUnless((upstream() / 'JITNetwork.swift').is_file(), 'Pinned Madeira source required')
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required for executable JIT lifecycle checks')
    def test_single_flight_failure_cleanup_and_stale_callbacks(self):
        network = lifecycle.apply('JITNetwork.swift', (upstream() / 'JITNetwork.swift').read_text())
        setup = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        # Exact production methods. Replace only the platform/network endpoints.
        methods = network[network.index('    func start(completion:'):network.index('    /// At launch:')]
        methods += network[network.index('    private func run('):].rsplit('\n}', 1)[0]
        enable = setup[setup.index('    func enable(requiresAttachedDebugger:'):setup.index('    /// PSP owns a distinct script')]
        enable += setup[setup.index('    private func ensureLoopback('):setup.index('    /// JIT setup\'s connect action')]
        swift = r'''
import Foundation
import CoreFoundation
@MainActor final class LogStore {
    static let shared = LogStore()
    enum Level { case error }
    func log(_ text: String, level: Level? = nil) {}
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var urls: [URL] = []
    var opens = true
    func open(_ url: URL, completion: (Bool) -> Void) { urls.append(url); completion(opens) }
}
@MainActor enum LoopbackProbe {
    struct Probe { let reachable: Bool; let milliseconds = 1.0; let detail = "fixture" }
    static var vpnInterfaceUp = false
    static var pending: ((Probe) -> Void)?
    static func check(_ callback: @escaping (Probe) -> Void) { pending = callback }
    static func waitUntilReachable(within: Double, completion: (Probe) -> Void) { completion(Probe(reachable: false)) }
}
@MainActor enum SigningStatus { struct Status { let debuggable = true }; static let current = Status(); static let notDebuggableMessage = "fixture" }
@MainActor enum StikJITHelper {
    static var ready = false
    nonisolated static func detachDebugger() { fatalError("fixture has no debugger") }
}
@MainActor var debuggerAttached = true
@MainActor func isDebuggerAttached() -> Bool { debuggerAttached }
func jit_arm_trap_fallback() { fatalError("fixture has no debugger") }
@MainActor final class JITNetworkShortcut {
    enum Outcome { case done(String), failed(String) }
    static let shared = JITNetworkShortcut()
    static let name = "Madeira JIT"
    var cellularOnly = false
    var enabled = true
    var pending: String?
    private var requestID: UUID?
    private var waiting: ((Outcome) -> Void)?
    private var timeout: Timer?
    func fireTimeout() { timeout?.fire() }
NETWORK_METHODS
}
@MainActor final class JITCoordinator {
    private var enableRequest: UUID?
    var busy = false
    var consoleMemoryBusy = false
    var error: String?
    var status: String?
    var connectionProblem: String?
    var builtInHelper: UUID?
    var builtInHelperReleased: Bool?
    var loopbackAnswered: Bool?
    var enables = 0
    var resolved: ((Result<Void, Error>) -> Void)?
    func enableResolved(_ callback: @escaping (Result<Void, Error>) -> Void) { enables += 1; resolved = callback }
    // This fixture exercises activation/network ownership; arena reuse is tested separately.
    func prepareConsoleMemory(completion: @escaping (Result<Void, Error>) -> Void) {
        enable(requiresAttachedDebugger: true, completion: completion)
    }
COORDINATOR_METHODS
}
func callback(_ original: URL, _ parameter: String, result: String = "") -> URL {
    let params = URLComponents(url: original, resolvingAgainstBaseURL: false)!.queryItems!
    let address = params.first { $0.name == parameter }!.value!
    return URL(string: address + (result.isEmpty ? "" : "&result=" + result))!
}
@MainActor func runChecks() {
let app = UIApplication.shared
let shortcut = JITNetworkShortcut.shared
let coordinator = JITCoordinator()
var first: [Bool] = []
coordinator.enable { first.append((try? $0.get()) != nil) }
precondition(coordinator.busy && app.urls.isEmpty)
var rejected = false
coordinator.enable { if case .failure = $0 { rejected = true } }
precondition(rejected && app.urls.isEmpty && coordinator.enables == 0)
LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: false))
precondition(app.urls.count == 1)
let start = app.urls[0]
// Failed or cancelled start owes one completion cleanup, not a second enable.
precondition(shortcut.handle(callback(start, "x-cancel")))
precondition(app.urls.count == 2 && coordinator.busy && first.isEmpty)
let done = app.urls[1]
precondition(URLComponents(url: done, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "text" && $0.value!.hasPrefix("done") })
// A late success from start must not finish the in-flight done operation.
shortcut.handle(callback(start, "x-success"))
precondition(first.isEmpty && coordinator.busy && app.urls.count == 2)
shortcut.handle(callback(done, "x-success"))
precondition(first == [false] && !coordinator.busy && coordinator.enables == 0)
shortcut.handle(callback(done, "x-success"))
precondition(first == [false] && app.urls.count == 2)
// Retry is possible only from another explicit enable request.
coordinator.enable { first.append((try? $0.get()) != nil) }
LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: false))
precondition(app.urls.count == 3)
shortcut.handle(callback(app.urls[2], "x-success"))
precondition(coordinator.enables == 1)
let resolved = coordinator.resolved!
resolved(.failure(NSError(domain: "fixture", code: 1)))
precondition(app.urls.count == 4 && coordinator.busy)
resolved(.failure(NSError(domain: "fixture", code: 1)))
precondition(app.urls.count == 4 && coordinator.busy && first == [false])
let failedDone = app.urls[3]
shortcut.handle(callback(failedDone, "x-error"))
precondition(first == [false, false] && !coordinator.busy && shortcut.pending != nil)
// An interrupted/failed restore remains owed; one explicit restore clears it.
var restores = 0
shortcut.restoreIfNeeded { restores += 1 }
precondition(app.urls.count == 5 && restores == 0)
shortcut.handle(callback(failedDone, "x-success"))
precondition(restores == 0) // previous callback is ignored
shortcut.handle(callback(app.urls[4], "x-success"))
precondition(restores == 1)
// An OS open failure performs one owed cleanup; it does not restart enable.
let beforeOpenFailure = app.urls.count
app.opens = false
coordinator.enable { first.append((try? $0.get()) != nil) }
LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: false))
precondition(app.urls.count == beforeOpenFailure + 2 && !coordinator.busy)
precondition(first.last == false && shortcut.pending != nil)
app.opens = true
shortcut.restoreIfNeeded {}
shortcut.handle(callback(app.urls.last!, "x-success"))
// A Shortcut that never returns times out once, then waits only for cleanup.
coordinator.enable { first.append((try? $0.get()) != nil) }
LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: false))
let timedStart = app.urls.last!
let beforeTimeout = app.urls.count
shortcut.fireTimeout()
precondition(app.urls.count == beforeTimeout + 1 && coordinator.busy)
shortcut.handle(callback(timedStart, "x-success"))
precondition(coordinator.busy)
shortcut.handle(callback(app.urls.last!, "x-success"))
precondition(!coordinator.busy && first.last == false)
let beforeReady = app.urls.count
// Already enabled short-circuits without opening a Shortcut.
StikJITHelper.ready = true
coordinator.enable { first.append((try? $0.get()) != nil) }
precondition(first == [false, false, false, false, true] && app.urls.count == beforeReady && !coordinator.busy)
// A retained Madeira pool is reusable, but cannot answer a fresh Dolphin allocation.
debuggerAttached = false
for released: Bool? in [nil, false] {
    let unfinished = JITCoordinator()
    unfinished.builtInHelper = UUID(); unfinished.builtInHelperReleased = released
    unfinished.enable(requiresAttachedDebugger: true) { precondition((try? $0.get()) == nil) }
    precondition(!unfinished.busy && unfinished.enables == 0)
}
let allocatorClient = JITCoordinator()
allocatorClient.builtInHelper = UUID(); allocatorClient.builtInHelperReleased = true
var allocatorReady = false
debuggerAttached = false
allocatorClient.enable(requiresAttachedDebugger: true) { allocatorReady = (try? $0.get()) != nil }
precondition(allocatorClient.busy && !allocatorReady)
LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: true))
precondition(allocatorClient.enables == 1)
debuggerAttached = true
allocatorClient.resolved?(.success(()))
precondition(allocatorReady && !allocatorClient.busy)
allocatorClient.enable(requiresAttachedDebugger: true) { precondition((try? $0.get()) != nil) }
precondition(allocatorClient.enables == 1 && !allocatorClient.busy)
// PSP uses these exact shipping methods plus its production continuation.
// No real Shortcut, network setting or debugger endpoint is invoked.
// A preexisting debugger can satisfy ready without starting our helper.
// Both forbidden protocol endpoints above trap if cleanup invokes them.
let foreign = IridiumJITRequest()
var foreignRelease: IridiumJITCleanup = { $0() }
var foreignLaunched = false
let foreignBefore = coordinator.enables
foreign.start(requested: true, activate: { callback in
    coordinator.enableForPSP { result, release in foreignRelease = release; callback(result) }
}, validate: { $0(.success(())) }, cleanup: { foreignRelease($0) }) { foreignLaunched = $0 }
precondition(foreignLaunched && coordinator.enables == foreignBefore && !coordinator.busy)
StikJITHelper.ready = false
func awaitCleanupURL(_ count: Int) {
    let deadline = Date().addingTimeInterval(3)
    while app.urls.count < count && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    precondition(app.urls.count == count)
}
var launches: [Bool] = [], releases: [IridiumJITCleanup] = []
var probe: ((Result<Void, Error>) -> Void)?
func launch(_ request: IridiumJITRequest) {
    var release: IridiumJITCleanup = { $0() }
    request.start(requested: true, activate: { callback in
        coordinator.enableForPSP { result, cleanup in
            release = cleanup
            if case .success = result { releases.append(cleanup) }
            callback(result)
        }
    }, validate: { probe = $0 }, cleanup: { release($0) }) { launches.append($0) }
    LoopbackProbe.pending?(LoopbackProbe.Probe(reachable: false))
    shortcut.handle(callback(app.urls.last!, "x-success"))
}
let failed = IridiumJITRequest()
launch(failed)
coordinator.resolved?(.success(()))
precondition(coordinator.busy && probe != nil)
let beforeFailureCleanup = app.urls.count
probe?(.failure(NSError(domain: "probe", code: -3)))
precondition(failed.state == .restoring && launches.isEmpty)
// Duplicate release waits for the same restoration; it cannot start another.
var duplicateCompleted = false
releases.last! { duplicateCompleted = true }
awaitCleanupURL(beforeFailureCleanup + 1)
coordinator.enable { precondition((try? $0.get()) == nil) }
precondition(coordinator.busy && !duplicateCompleted && launches.isEmpty)
shortcut.handle(callback(app.urls.last!, "x-success"))
precondition(launches == [false] && duplicateCompleted && shortcut.pending == nil && !coordinator.busy)
let staleRelease = releases.last!
let cancelledActivation = IridiumJITRequest()
launch(cancelledActivation)
cancelledActivation.cancel()
let beforeCancelledActivationCleanup = app.urls.count
coordinator.resolved?(.success(()))
awaitCleanupURL(beforeCancelledActivationCleanup + 1)
shortcut.handle(callback(app.urls.last!, "x-success"))
precondition(launches == [false] && !coordinator.busy && shortcut.pending == nil)
let cancelledProbe = IridiumJITRequest()
launch(cancelledProbe)
coordinator.resolved?(.success(()))
let beforeCancelledProbeCleanup = app.urls.count
cancelledProbe.cancel()
precondition(coordinator.busy && app.urls.count == beforeCancelledProbeCleanup)
// Cleanup must wait for the worker acknowledgment, even after cancellation.
probe?(.success(()))
awaitCleanupURL(beforeCancelledProbeCleanup + 1)
shortcut.handle(callback(app.urls.last!, "x-success"))
precondition(launches == [false] && !coordinator.busy && shortcut.pending == nil)
let successful = IridiumJITRequest()
launch(successful)
coordinator.resolved?(.success(()))
let beforeSuccessCleanup = app.urls.count
var staleCompleted = false
staleRelease { staleCompleted = true }
precondition(staleCompleted && coordinator.busy && app.urls.count == beforeSuccessCleanup && shortcut.pending != nil)
probe?(.success(()))
awaitCleanupURL(beforeSuccessCleanup + 1)
precondition(launches == [false])
shortcut.handle(callback(app.urls.last!, "x-success"))
precondition(launches == [false, true] && !coordinator.busy && shortcut.pending == nil)
print("PASS PSP foreign ready debugger and coordinator-started supported activation never invoke private detach or mutate SIGTRAP")
print("PASS PSP backend failure, cancelled activation/probe, successful launch restore before continuation; duplicate/stale cleanup cannot release another owner")
print("PASS generated JIT single-flight, failed/cancelled start cleanup, late callbacks, explicit retry, restore recovery, open failure, timeout, already-ready")
}
MainActor.assumeIsolated { runChecks() }
'''.replace('NETWORK_METHODS', methods).replace('COORDINATOR_METHODS', enable)
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'main.swift'
            source.write_text(swift)
            binary = Path(folder) / 'check'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumJITRequest.swift'),
                            str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)
