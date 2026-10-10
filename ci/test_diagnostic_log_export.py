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
        try put("iridium-console.log", "[Console] steps=500 fresh_images=2 changed_images=1 game_progress=unknown\nAuthorization: Bearer synthetic-private-value\nuser@example.com\npath=/Users/Person Name/private/game.iso\nusername=private-person\npeer=192.168.1.2 session=ABC12345\npairing payload secret\n")
        let original = try Data(contentsOf: dir.appendingPathComponent("iridium-console.log"))
        let exported = try RuntimeDiagnosticLogFiles.export(in: dir, destination: dir)
        let text = try String(contentsOf: exported, encoding: .utf8)
        precondition(text.contains("iridium-console.log"))
        precondition(text.contains("steps=500 fresh_images=2 changed_images=1 game_progress=unknown"))
        for privateValue in ["synthetic-private-value", "example.com", "Person Name", "game.iso", "private-person", "192.168.1.2", "ABC12345", "pairing payload"] {
            precondition(!text.contains(privateValue))
        }
        let unchanged = try Data(contentsOf: dir.appendingPathComponent("iridium-console.log"))
        precondition(unchanged == original)
        precondition(RuntimeDiagnosticLogFiles.recentLines(in: dir).contains { $0.contains("steps=500") })
        // Bounded tail drops its partial leading line instead of exporting an
        // unlabeled fragment from a long credential value.
        try put("iridium-runtime.log", "token=" + String(repeating: "private-fragment", count: 350_000) + "\nlast complete event\n")
        let bounded = try RuntimeDiagnosticLogFiles.export(in: dir, destination: dir)
        let boundedText = try String(contentsOf: bounded, encoding: .utf8)
        precondition(boundedText.contains("truncated: true"))
        precondition(boundedText.contains("last complete event"))
        precondition(!boundedText.contains("private-fragment"))
        precondition(boundedText.utf8.count < 65_536)
        // Keep wall-clock correlation and crash addresses while removing peers.
        for diagnostic in ["04:28:10.123 PC=0x71ffd77654 LR=000000010abcdeff", "2026-10-10T04:28:10Z steps=500"] {
            precondition(RuntimeDiagnosticLogFiles.sanitizedLine(diagnostic) == diagnostic)
        }
        for peer in ["fe80::1234", "::1", "2001:db8:0000:0000:0000:0000:0000:0001", "fe80::1234%en0"] {
            precondition(!RuntimeDiagnosticLogFiles.sanitizedLine("peer=" + peer).contains(peer))
        }
        // A long old console log must not crowd out current native/host events.
        try fm.removeItem(at: current)
        try put("madeira-log.txt", "native-current-evidence\n")
        try put("iridium-runtime.log", "host-current-evidence\n")
        try put("iridium-console.log", String(repeating: "old-console-event\n", count: 400))
        let recent = RuntimeDiagnosticLogFiles.recentLines(in: dir)
        let directoryWithSlash = URL(fileURLWithPath: dir.path, isDirectory: true)
        let directoryWithoutSlash = URL(fileURLWithPath: dir.path, isDirectory: false)
        precondition(RuntimeDiagnosticLogFiles.recentLines(in: directoryWithSlash) == RuntimeDiagnosticLogFiles.recentLines(in: directoryWithoutSlash))
        precondition(recent.count <= 300)
        precondition(recent.contains { $0.contains("native-current-evidence") })
        precondition(recent.contains { $0.contains("host-current-evidence") })
        // Only the newest 40 named native sessions; no private filename in output.
        let runs = dir.appendingPathComponent("logs")
        try fm.createDirectory(at: runs, withIntermediateDirectories: true)
        for second in 0..<45 {
            let name = String(format: "private-game-2026-10-10_04-00-%02d.txt", second)
            try Data("native-session-event\n".utf8).write(to: runs.appendingPathComponent(name))
        }
        try Data("excluded-private-event\n".utf8).write(to: runs.appendingPathComponent("other.txt"))
        try fm.createSymbolicLink(at: runs.appendingPathComponent("private-link-2026-10-10_05-00-00.txt"), withDestinationURL: dir.appendingPathComponent("unrelated-private.txt"))
        let selected = RuntimeDiagnosticLogFiles.existing(in: dir).filter { $0.deletingLastPathComponent().standardizedFileURL.path == runs.standardizedFileURL.path }
        precondition(selected.count == 40)
        precondition(selected.first?.lastPathComponent.hasSuffix("44.txt") == true)
        precondition(selected.last?.lastPathComponent.hasSuffix("05.txt") == true)
        let inventory = try RuntimeDiagnosticLogFiles.export(in: dir, destination: dir)
        let inventoryText = try String(contentsOf: inventory, encoding: .utf8)
        precondition(!inventoryText.contains("private-game"))
        precondition(!inventoryText.contains("excluded-private-event"))
        // Freeze only the test queue to deterministically fill admission capacity.
        let sinkDir = dir.appendingPathComponent("sink")
        try fm.createDirectory(at: sinkDir, withIntermediateDirectories: true)
        let queue = DispatchQueue(label: "test.console.sink")
        let sink = RuntimeConsoleLogSink(directory: sinkDir, maximumBytes: 1024, pendingLimit: 4, queue: queue)
        queue.suspend()
        for _ in 0..<20 { sink.append("routine-event") }
        sink.append("phase=failed", important: true) // reserved slot survives spam
        queue.resume(); sink.flush()
        let console = sinkDir.appendingPathComponent("iridium-console.log")
        let captured = try String(contentsOf: console, encoding: .utf8)
        precondition(captured.contains("dropped_entries=17"))
        precondition(captured.contains("phase=failed"))
        sink.append("Authorization: Bearer private-sink-value", important: true)
        sink.flush()
        let sanitizedCapture = try String(contentsOf: console, encoding: .utf8)
        precondition(!sanitizedCapture.contains("private-sink-value"))
        for index in 0..<20 {
            sink.append("event=\(index) " + String(repeating: "x", count: 200), important: true)
            sink.flush()
        }
        let previous = sinkDir.appendingPathComponent("iridium-console.previous.log")
        precondition(fm.fileExists(atPath: previous.path))
        for file in [console, previous] {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            precondition(size <= 1024)
        }
        let final = try String(contentsOf: console, encoding: .utf8)
        precondition(final.contains("event=19")) // capture continues after rotation
        // A failed write is counted on the next successful capture.
        let recoveryDir = dir.appendingPathComponent("recovery")
        let recovery = RuntimeConsoleLogSink(directory: recoveryDir)
        recovery.append("before-directory-exists"); recovery.flush()
        try fm.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
        recovery.append("recovered"); recovery.flush()
        let recovered = try String(contentsOf: recoveryDir.appendingPathComponent("iridium-console.log"), encoding: .utf8)
        precondition(recovered.contains("failed_writes=1"))
        // Refuse a dangling link without creating its destination.
        let linkDir = dir.appendingPathComponent("link-sink")
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let privateTarget = dir.appendingPathComponent("must-not-create.txt")
        try fm.createSymbolicLink(at: linkDir.appendingPathComponent("iridium-console.log"), withDestinationURL: privateTarget)
        let linkSink = RuntimeConsoleLogSink(directory: linkDir)
        linkSink.append("must-not-write"); linkSink.flush()
        precondition(!fm.fileExists(atPath: privateTarget.path))
        let beforeExport = try [console, previous].map { try Data(contentsOf: $0) }
        _ = try RuntimeDiagnosticLogFiles.export(in: sinkDir, destination: dir)
        let afterExport = try [console, previous].map { try Data(contentsOf: $0) }
        precondition(beforeExport == afterExport)
        print("Diagnostic selection/export: source preservation, bounded tails, allowlist, symlinks, credential/path/identifier redaction passed")
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
        self.assertIn("RuntimeDiagnosticsExportSection()", diagnostics)
        self.assertNotIn("ShareLink", diagnostics)
        self.assertNotIn("LogStore.shared", diagnostics)
        shipping = (ROOT / "ci/madeira_presentation.py").read_text()
        self.assertIn("setting('Diagnostics', 'RuntimeDiagnosticsExportSection()')", shipping)
        view = (ROOT / "iridium/apps/ios/RuntimeSupport/IridiumDiagnosticsView.swift").read_text()
        self.assertIn("RuntimeDiagnosticLogFiles.export(in: documents)", view)
        self.assertIn("Task.detached(priority: .utility)", view)


if __name__ == "__main__":
    unittest.main()
