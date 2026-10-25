"""Exercise the shipping Settings JIT entry and pairing-recovery actions."""
from host_tests import module_cache
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class JITSettingsActionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_local_prerequisite_setup_ready_enable_and_visible_pairing_recovery(self):
        capabilities = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumCapabilitiesView.swift').read_text()
        start = capabilities.index('    private func enableJIT() {')
        enable = capabilities[start:capabilities.rindex('\n}')].replace(
            'private func enableJIT()', 'func enableJIT()', 1)
        setup = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        helper = setup.index('@MainActor func jitConnectionActions(')
        start = setup.index('                dismiss()', helper)
        end = setup.index('\n            }\n        }', start)
        recovery = setup[start:end]
        # Only the model endpoints and UI host are fixtures. These are the exact
        # production button action and recovery closure, with real branch bodies.
        fixture = r'''
import Foundation
enum JITMethod: CaseIterable { case automatic, stikDebug, builtIn }
enum StikJITHelper {
    static var ready = false
    static var isAvailable = false
}
enum JITPairingFileStore { static var isImported = false }
final class JITCoordinator {
    static let shared = JITCoordinator()
    var method = JITMethod.automatic
    var busy = false
    var showSetup = false
    var enables = 0
    // Deliberately stale cache: admission must read the real pairing endpoint.
    var pairingImported = false
    var resolvedMethod: JITMethod {
        method == .automatic ? (StikJITHelper.isAvailable ? .stikDebug : .builtIn) : method
    }
    func prepareConsoleMemory(completion: (Result<Void, Error>) -> Void) { enables += 1; completion(.success(())) }
}
final class OnDevicePairing {
    static let shared = OnDevicePairing()
    static var isSupported = false
    var starts = 0
    var methodAtStart: JITMethod?
    func start() { starts += 1; methodAtStart = JITCoordinator.shared.method }
}
final class SettingsFixture {
    let coordinator = JITCoordinator()
    var showingJITSetup = false
ENABLE
}
func recover(openSetup: (() -> Void)? = nil, then dismiss: () -> Void = {}) {
RECOVERY
}

var cases = 0
for method in JITMethod.allCases {
    for available in [false, true] {
        for imported in [false, true] {
            for ready in [false, true] {
                for busy in [false, true] {
                    let settings = SettingsFixture()
                    settings.coordinator.method = method
                    settings.coordinator.busy = busy
                    settings.coordinator.pairingImported = !imported
                    StikJITHelper.isAvailable = available
                    StikJITHelper.ready = ready
                    JITPairingFileStore.isImported = imported
                    settings.enableJIT()
                    let effective = method == .automatic ? (available ? JITMethod.stikDebug : .builtIn) : method
                    let needsSetup = !ready && ((effective == .builtIn && !imported) || (effective == .stikDebug && !available))
                    precondition(settings.showingJITSetup == (!busy && needsSetup))
                    precondition(settings.coordinator.enables == (!busy && !needsSetup ? 1 : 0))
                    precondition(!settings.coordinator.showSetup)
                    precondition(settings.coordinator.method == method && settings.coordinator.busy == busy)
                    cases += 1
                }
            }
        }
    }
}

// Supported Pair Again must reveal the built-in panel before pairing starts;
// local Settings recovery must not trigger the root's global setup presentation.
for supported in [false, true] {
    for local in [false, true] {
        let coordinator = JITCoordinator.shared
        let pairing = OnDevicePairing.shared
        coordinator.method = .stikDebug
        coordinator.showSetup = false
        pairing.starts = 0
        pairing.methodAtStart = nil
        OnDevicePairing.isSupported = supported
        var dismissals = 0
        var localOpens = 0
        let localPresenter: (() -> Void)? = local ? { localOpens += 1 } : nil
        recover(openSetup: localPresenter, then: { dismissals += 1 })
        precondition(dismissals == 1 && localOpens == (local ? 1 : 0))
        precondition(coordinator.showSetup == !local)
        precondition(pairing.starts == (supported ? 1 : 0))
        precondition(coordinator.method == (supported ? .builtIn : .stikDebug))
        precondition(pairing.methodAtStart == (supported ? .builtIn : nil))
    }
}
print("PASS production Settings actions: \(cases) enable preflights, live pairing/detection, ready bypass, busy admission, local/default setup and visible Pair Again panel")
'''.replace('ENABLE', enable).replace('RECOVERY', recovery)
        with tempfile.TemporaryDirectory(prefix='iridium-jit-settings-') as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            binary = folder / 'check'
            main.write_text(fixture)
            result = subprocess.run(
                ['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                 str(main), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if result.stdout:
                print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
