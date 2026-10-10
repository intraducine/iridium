"""Exercise production PSP observations without claiming game progress."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iridium/apps/ios"


class RuntimeDiagnosticsTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cc"), "C compiler required")
    def test_psp_callback_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            executable = Path(folder) / "diagnostics"
            subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", str(IOS / "RuntimeBridge"),
                            "-I", str(ROOT / "ci/input"), str(ROOT / "ci/input/check_psp_diagnostics.c"),
                            "-o", str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=15)

    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler required")
    def test_progress_never_infers_loading_completion(self):
        with tempfile.TemporaryDirectory() as folder:
            main = Path(folder) / "main.swift"
            main.write_text('''import Foundation
var progress = IridiumRuntimeProgress()
precondition(progress.observation.contains("No image"))
progress.runtimeSteps = 500
precondition(progress.observation.contains("progress is unknown"))
progress.freshImages = 10; progress.changedImages = 1
progress.secondsSinceFreshImage = 0; progress.secondsSinceChangedImage = 20
precondition(progress.observation.contains("static screen or a stall"))
progress.secondsSinceFreshImage = 30
precondition(progress.observation.contains("No fresh image for 30"))
progress.secondsSinceFreshImage = 0; progress.secondsSinceChangedImage = 0
precondition(progress.observation.contains("progress is not measured"))
precondition(progress.logLine.contains("game_progress=unknown"))
progress.phase = "paused"; progress.sampledUptime -= 100
precondition(progress.observation.contains("Resume"))
precondition(!progress.observation.contains("stalled"))
progress.phase = "pause requested"
precondition(progress.observation.contains("Pause requested; no completed"))
progress.phase = "failed"
precondition(progress.observation.contains("Runtime state: failed"))
progress.phase = "running"
precondition(progress.observation.contains("No completed runtime step"))
print("PASS: progress separates runtime liveness, images, static/stale screens and unknown game progress")
''')
            executable = Path(folder) / "progress"
            subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", str(IOS / "RuntimeSupport/IridiumRuntimeProgress.swift"),
                            str(main), "-o", str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
