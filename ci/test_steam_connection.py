"""Exercise the production WebSocket continuation with duplicate callbacks."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]


class SteamConnectionTests(unittest.TestCase):
    def test_ping_completion_is_once_and_retired_tasks_cannot_receive(self):
        source = (ROOT / 'iridium/apps/ios/App/Steam/Transport/Core/SteamConnection.swift').read_text()
        guard = source[source.index('final class SteamResumeGuard:'):source.index('// MARK: - WebSocket Delegate')]
        bridge = source[source.index('        let resumeOnce = SteamResumeGuard()'):source.index('        await serverList.markSuccess')]
        current = source[source.index('        guard webSocketTask === task'):source.index('        scheduleReceive(task)')]
        fixture = '''
import Foundation
enum SteamError: Error { case connectionFailed(String), disconnected }
final class PingTask: @unchecked Sendable {
    let results: [Bool]
    let parallel: Bool
    init(_ results: [Bool], parallel: Bool = false) { self.results = results; self.parallel = parallel }
    func sendPing(_ reply: @escaping @Sendable (Error?) -> Void) {
        let send: @Sendable (Int) -> Void = { i in
            reply(self.results[i] ? NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "first error"]) : nil)
        }
        if parallel { DispatchQueue.concurrentPerform(iterations: results.count, execute: send) }
        else { for i in results.indices { send(i) } }
    }
}
''' + guard + '\nfunc connect(_ task: PingTask) async throws {\n' + bridge + '''
}
func validate(_ task: PingTask, current webSocketTask: PingTask?) throws {
''' + current + '''
}
@main struct Check {
    static func main() async throws {
        for results in [[false, true], [false, false], [true, false], [true, true]] {
            do {
                try await connect(PingTask(results))
                precondition(!results[0])
            } catch SteamError.connectionFailed(let message) {
                precondition(results[0] && message == "first error")
            }
        }
        for _ in 0..<50 {
            do { try await connect(PingTask((0..<1000).map { $0 % 2 == 0 }, parallel: true)) }
            catch SteamError.connectionFailed(let message) { precondition(message == "first error") }
        }
        let task = PingTask([false])
        try validate(task, current: task)
        for current in [nil, PingTask([false])] {
            do { try validate(task, current: current); preconditionFailure("retired task admitted") }
            catch SteamError.disconnected {}
        }
        print("PASS: duplicate and racing ping results complete once; retired sockets cannot start receiving")
    }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'check.swift').write_text(fixture)
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                            '-module-cache-path', module_cache(), str(path / 'check.swift'),
                            '-o', str(path / 'check')], check=True, timeout=90)
            subprocess.run([str(path / 'check')], check=True, timeout=30)
