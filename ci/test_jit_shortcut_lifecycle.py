"""Execute the generated shipping JIT/Shortcut methods with controlled endpoints."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import madeira_jit_lifecycle as lifecycle

ROOT = Path(__file__).resolve().parents[1]


def upstream():
    return Path(os.environ.get('IRIDIUM_MADEIRA_SOURCE', ROOT / 'vendor/Madeira')) / 'app/Madeira'


class ShortcutLifecycleTests(unittest.TestCase):
    @unittest.skipUnless((upstream() / 'JITNetwork.swift').is_file(), 'Pinned Madeira source required')
    def test_single_flight_failure_cleanup_and_stale_callbacks(self):
        network = lifecycle.apply('JITNetwork.swift', (upstream() / 'JITNetwork.swift').read_text())
        setup = lifecycle.apply('JITSetup.swift', (upstream() / 'JITSetup.swift').read_text())
        # Exact production methods. Replace only the platform/network endpoints.
        methods = network[network.index('    func start(completion:'):network.index('    /// At launch:')]
        methods += network[network.index('    private func run('):].rsplit('\n}', 1)[0]
        enable = setup[setup.index('    func enable(completion:'):setup.index('    /// JIT setup\'s connect action')]
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
@MainActor enum StikJITHelper { static var ready = false }
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
    var error: String?
    var status: String?
    var connectionProblem: String?
    var loopbackAnswered: Bool?
    var enables = 0
    var resolved: ((Result<Void, Error>) -> Void)?
    func enableResolved(_ callback: @escaping (Result<Void, Error>) -> Void) { enables += 1; resolved = callback }
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
print("PASS generated JIT single-flight, failed/cancelled start cleanup, late callbacks, explicit retry, restore recovery, open failure, timeout, already-ready")
}
MainActor.assumeIsolated { runChecks() }
'''.replace('NETWORK_METHODS', methods).replace('COORDINATOR_METHODS', enable)
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'main.swift'
            source.write_text(swift)
            binary = Path(folder) / 'check'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)
