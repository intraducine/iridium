"""Execute shipping Wine startup admission without starting Wine or an emulator."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iridium/apps/ios/App/Adapters/Madeira'


def function(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class WindowsNativeSessionTests(unittest.TestCase):
    def test_failed_pool_reports_an_error_without_scheduling_app_termination(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/StikJITHelper.swift').read_text()
        start = source.index('        guard let rxPtr = rxPtrOpt else {')
        branch = source[start:source.index('        let rxAddr =', start)]
        self.assertNotIn('exit(', branch)
        self.assertNotIn('asyncAfter', branch)
        code = '''import Foundation
final class LogStore {
    static let shared = LogStore()
    enum Level { case error }
    func log(_ text: String, level: Level) {}
}
enum Allocator {
    static var poolFailure: String?
    static let noDebuggerMessage = "No debugger"
    static func check(_ rxPtrOpt: UnsafeMutableRawPointer?, requestUnanswered: Bool, debuggerAttached: Bool) -> UnsafeMutableRawPointer? {
BRANCH
        return rxPtr
    }
}
for attached in [false, true] {
    for unanswered in [false, true] {
        precondition(Allocator.check(nil, requestUnanswered: unanswered, debuggerAttached: attached) == nil)
        precondition(Allocator.poolFailure?.isEmpty == false)
        precondition((Allocator.poolFailure == Allocator.noDebuggerMessage) == (!attached && unanswered))
    }
}
let valid = UnsafeMutableRawPointer(bitPattern: 0x1000)!
precondition(Allocator.check(valid, requestUnanswered: false, debuggerAttached: true) == valid)
'''.replace('BRANCH', branch)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'pool.swift').write_text(code)
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'),
                            str(path / 'pool.swift'), '-o', str(path / 'pool')], check=True, timeout=45)
            subprocess.run([str(path / 'pool')], check=True, timeout=10)

    def test_preparation_does_not_consume_native_session_and_server_failure_does(self):
        library = (APP / 'IridiumWindowsLibraryService.swift').read_text()
        reserve = function(library, '    @MainActor static func reserveNativeSession()')
        failure = function(library, '    @MainActor func launchFailedBeforeNative(')
        begin = function(library, '    func begin(_ entry:')
        preparation = begin[begin.index('        nativeLaunchID = UUID()'):begin.index('        launchPresent =')]
        launch = (APP / 'ContentView.swift').read_text()
        server = function(launch, '    private func startWineserver(for ')
        worker = launch[launch.index('            // Step 2: Start wineserver'):launch.index('            winios_phase("wineserver-up")')]
        self.assertIn('guard self.startWineserver(for: nativeLaunch) else {', worker)
        self.assertIn('return', worker)
        code = '''import Foundation
final class LibraryModel: @unchecked Sendable {
    static let shared = LibraryModel()
    static var sessionsThisRun = 0
    static let restartMessage = "Restart"
    private static var nativeInitializationStarted = false
    private(set) var nativeLaunchID = UUID()
    var current: UUID? = UUID()
    var failures = 0
    func launchFailed(_ reason: String? = nil, offerJIT: Bool = false) { failures += 1; current = nil }
    func prepare() { current = UUID(); PREPARATION }
RESERVE
FAILURE
}
@MainActor final class JITCoordinator {
    static let shared = JITCoordinator()
    var callback: ((Bool) -> Void)?
    func releaseAttachedDebugger(completion: @escaping (Bool) -> Void) { callback = completion }
    func finish(_ clean: Bool) { let done = callback; callback = nil; done?(clean) }
}
final class LogStore: @unchecked Sendable {
    enum Level { case success, error }
    func log(_ text: String, level: Level? = nil) {}
}
final class IridiumMadeiraRuntime: @unchecked Sendable {
    static let shared=IridiumMadeiraRuntime()
    func noteNativeInitialization() {}
}
var starts = 0
var failServer = false
func wineserver_start(_ path: String) -> Int32 {
    starts += 1
    return failServer ? -1 : 0
}
struct Host: Sendable {
    let library = LibraryModel.shared
    let logStore = LogStore()
SERVER
    func start(_ owner: UUID) -> Bool { startWineserver(for: owner) }
}
@main struct Check {
    @MainActor static func main() async {
        let library = LibraryModel.shared
        precondition(LibraryModel.sessionsThisRun == 0 && starts == 0)
        library.prepare()
        let abandoned = library.nativeLaunchID
        precondition(LibraryModel.sessionsThisRun == 1)
        library.launchFailedBeforeNative(abandoned)
        precondition(LibraryModel.sessionsThisRun == 1)
        if CommandLine.arguments.contains("cleanup-failure") {
            JITCoordinator.shared.finish(false)
            precondition(LibraryModel.sessionsThisRun == 1 && library.failures == 1)
            return
        }
        JITCoordinator.shared.finish(true)
        precondition(LibraryModel.sessionsThisRun == 0 && starts == 0 && library.failures == 1)
        library.prepare()
        library.launchFailedBeforeNative(abandoned)
        precondition(LibraryModel.sessionsThisRun == 1 && library.failures == 1)
        let cancelled = library.nativeLaunchID
        library.current = nil
        let cancelledStart = await Task.detached { Host().start(cancelled) }.value
        precondition(!cancelledStart && starts == 0 && LibraryModel.sessionsThisRun == 1)
        library.launchFailedBeforeNative(cancelled)
        precondition(LibraryModel.sessionsThisRun == 1)
        JITCoordinator.shared.finish(true)
        precondition(LibraryModel.sessionsThisRun == 0)
        library.prepare()
        let owner = library.nativeLaunchID
        failServer = CommandLine.arguments.contains("server-failure")
        let first = await Task.detached { Host().start(owner) }.value
        precondition(first != failServer && LibraryModel.sessionsThisRun == 1 && starts == 1)
        let second = await Task.detached { Host().start(owner) }.value
        precondition(!second && LibraryModel.sessionsThisRun == 1 && starts == 1)
        library.launchFailedBeforeNative(owner)
        precondition(LibraryModel.sessionsThisRun == 1)
        print("PASS preparation retry, stale failure, cancelled worker, native admission and native-state retention")
    }
}
'''.replace('RESERVE', reserve).replace('SERVER', server).replace('FAILURE', failure).replace('PREPARATION', preparation)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'test.swift').write_text(code)
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                            '-module-cache-path', module_cache('macosx'), str(path / 'test.swift'),
                            '-o', str(path / 'check')], check=True, timeout=45)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
            subprocess.run([str(path / 'check'), 'server-failure'], check=True, timeout=10)
            subprocess.run([str(path / 'check'), 'cleanup-failure'], check=True, timeout=10)
