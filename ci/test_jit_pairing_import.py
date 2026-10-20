"""Execute the shipping pairing-import actions with inert model endpoints."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PairingImportTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_entry_and_late_completion_preserve_active_pairing_and_jit(self):
        source = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        start = source.index('    private func beginImport() {')
        end = source.index('\n}\n\n/// Installation', start)
        # Run the actual action/completion/guard bodies. Expose only the two UI
        # entry points; replace model endpoints, never the admission decision.
        actions = source[start:end].replace(
            'private func beginImport()', 'func beginImport()', 1).replace(
            'private func completeImport(', 'func completeImport(', 1)
        fixture = r'''
import Foundation
final class CoordinatorFixture {
    var busy = false
    var imported: [URL] = []
    func importPairingFile(_ url: URL) { imported.append(url) }
}
final class PairingFixture { var active = false }
final class LogStore {
    static let shared = LogStore()
    enum Level { case error }
    var messages: [String] = []
    func log(_ message: String, level: Level) { messages.append(message) }
}
final class ImportFixture {
    let coordinator = CoordinatorFixture()
    let pairing = PairingFixture()
    var importing = false
    var modalPresented = false
    var importError: String?
ACTIONS
}

let url = URL(string: "fixture://pairing.plist")!
for busy in [false, true] {
    for active in [false, true] {
        let view = ImportFixture()
        view.coordinator.busy = busy
        view.pairing.active = active
        view.importError = "old error"
        view.beginImport()
        let blocked = busy || active
        precondition(view.importing == !blocked && view.modalPresented == !blocked)
        precondition((view.importError != nil) == blocked)
        precondition(view.coordinator.imported.isEmpty)
        precondition(view.coordinator.busy == busy && view.pairing.active == active)
    }
}

// A request admitted before pairing/JIT starts must be checked again when the
// picker returns. The late selection cannot replace state or cancel pairing.
for lateBusy in [false, true] {
    for lateActive in [false, true] where lateBusy || lateActive {
        let view = ImportFixture()
        view.beginImport()
        precondition(view.importing && view.modalPresented)
        view.coordinator.busy = lateBusy
        view.pairing.active = lateActive
        view.completeImport(.success(url))
        precondition(!view.importing && !view.modalPresented)
        precondition(view.coordinator.imported.isEmpty && view.importError != nil)
        precondition(view.coordinator.busy == lateBusy && view.pairing.active == lateActive)
        let message = view.importError!.lowercased()
        precondition(message.contains("import") && (message.contains("cancel") || message.contains("wait")))

        // Once the competing operation ends, an explicit retry imports normally.
        view.coordinator.busy = false
        view.pairing.active = false
        view.beginImport()
        precondition(view.importError == nil && view.importing && view.modalPresented)
        view.completeImport(.success(url))
        precondition(view.coordinator.imported == [url] && view.importError == nil)
        precondition(!view.importing && !view.modalPresented)
    }
}

let normal = ImportFixture()
normal.beginImport()
normal.completeImport(.success(url))
precondition(normal.coordinator.imported == [url] && normal.importError == nil)
precondition(!normal.importing && !normal.modalPresented)

let cancelled = ImportFixture()
cancelled.beginImport()
cancelled.pairing.active = true
cancelled.completeImport(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
precondition(cancelled.coordinator.imported.isEmpty && cancelled.importError == nil)
precondition(!cancelled.importing && !cancelled.modalPresented && cancelled.pairing.active)
precondition(LogStore.shared.messages.isEmpty)

let failed = ImportFixture()
failed.beginImport()
failed.completeImport(.failure(NSError(domain: "fixture", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Picker failed"])))
precondition(failed.coordinator.imported.isEmpty && failed.importError == "Picker failed")
precondition(!failed.importing && !failed.modalPresented && LogStore.shared.messages.count == 1)
print("PASS production import actions: entry guards, late busy/pairing rejection, normal import, retry, cancellation and visible picker failures")
'''.replace('ACTIONS', actions)
        with tempfile.TemporaryDirectory(prefix='iridium-pairing-import-') as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            binary = folder / 'check'
            main.write_text(fixture)
            result = subprocess.run(
                ['swiftc', '-swift-version', '5', '-module-cache-path', str(folder / 'cache'),
                 str(main), '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if result.stdout:
                print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
