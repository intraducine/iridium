"""Exercise diagnostic file selection without launching or rotating the runtime."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "iridium/apps/ios/Iridium/RuntimeDiagnosticLogFiles.swift"
VIEW = ROOT / "iridium/apps/ios/Iridium/Views/SettingsView.swift"

HARNESS = r'''
import Foundation

@main struct DiagnosticLogExportTests {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func names() -> [String] {
            RuntimeDiagnosticLogFiles.existing(in: dir).map(\.lastPathComponent)
        }
        func put(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        precondition(names().isEmpty) // No logs is valid, not an error.
        try put("iridium-runtime.log", "host: zero presents\n")
        precondition(names() == ["iridium-runtime.log"]) // Legacy-only installs.
        try put("madeira-log.txt", "native failure\n")
        try put("madeira-log.prev.txt", "previous native failure\n")
        try put("iridium-runtime.previous.log", "previous host run\n")
        let expected = ["iridium-runtime.log", "madeira-log.txt", "madeira-log.prev.txt", "iridium-runtime.previous.log"]
        precondition(names() == expected) // Native current and previous are included.
        let before = try expected.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        for _ in 0..<3 { precondition(names() == expected) }
        let after = try expected.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        precondition(before == after) // Opening diagnostics never rotates/truncates.
        try put("unrelated-private.txt", "do not export")
        precondition(names() == expected) // No directory scanning / arbitrary files.
        let current = dir.appendingPathComponent("madeira-log.txt")
        try fm.removeItem(at: current)
        precondition(names() == expected.filter { $0 != "madeira-log.txt" })
        try fm.createDirectory(at: current, withIntermediateDirectories: false)
        precondition(!names().contains("madeira-log.txt")) // Reject directories.
        try fm.removeItem(at: current)
        try fm.createSymbolicLink(at: current, withDestinationURL: dir.appendingPathComponent("unrelated-private.txt"))
        precondition(!names().contains("madeira-log.txt")) // Do not follow private links.
        print("Diagnostic selection: empty, host-only, native current/previous, no rotation, allowlist, missing, directory, symlink passed")
    }
}
'''


class DiagnosticLogExportTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "requires Swift compiler")
    def test_real_swift_file_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            main = root / "Check.swift"
            main.write_text(HARNESS)
            binary = root / "check"
            build = subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", str(SOURCE), str(main), "-o", str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_settings_shares_selected_files_not_just_host_log(self):
        source = VIEW.read_text()
        diagnostics = source.split("private struct DiagnosticsSettingsView: View {", 1)[1].split("\n#if MADEIRA_RUNTIME", 1)[0]
        self.assertIn("RuntimeDiagnosticLogFiles.existing(in: documents)", diagnostics)
        self.assertIn("ShareLink(items: logURLs)", diagnostics)
        self.assertNotIn("ShareLink(item: logURL)", diagnostics)
        self.assertNotIn("LogStore.shared", diagnostics)


if __name__ == "__main__":
    unittest.main()
