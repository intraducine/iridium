"""Pure progress behavior plus explicitly limited production source boundaries.

The Swift harness executes IridiumRuntimeProgress when swiftc is available.
Source checks do not establish SwiftUI compilation, native lifecycle execution,
thread-race freedom, or device compatibility.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "iridium/apps/ios"


class ConsoleProgressLifecycleTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "pure Swift progress harness requires swiftc")
    def test_production_progress_observations(self):
        harness = r'''import Foundation
var p = IridiumRuntimeProgress()
p.sampledUptime = ProcessInfo.processInfo.systemUptime - 120
p.phase = "running"
precondition(p.observation.contains("No completed runtime step"))
for pending in ["pause requested", "booting (pause requested)"] {
    p.phase = pending
    precondition(p.observation.contains("busy or stalled"))
}
p.phase = "paused"
precondition(p.observation.contains("paused"))
precondition(!p.observation.contains("stalled"))
for terminal in ["closed", "failed", "restart required", "stop timed out"] {
    p.phase = terminal
    precondition(p.observation.contains(terminal))
    precondition(!p.observation.contains("Images are arriving"))
}
p.phase = "running"
p.sampledUptime = ProcessInfo.processInfo.systemUptime
p.runtimeSteps = 300
precondition(p.observation.contains("No image"))
p.freshImages = 300; p.changedImages = 1
p.secondsSinceFreshImage = 0; p.secondsSinceChangedImage = 60
precondition(p.observation.contains("static screen or a stall"))
p.secondsSinceFreshImage = 60
precondition(p.observation.contains("No fresh image"))
precondition(p.logLine.contains("game_progress=unknown"))
print("PASS: production progress distinguishes paused, terminal, stale, static and no-image observations")
'''
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            main = folder / "main.swift"
            main.write_text(harness)
            binary = folder / "progress"
            subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors",
                            str(IOS / "RuntimeSupport/IridiumRuntimeProgress.swift"),
                            str(main), "-o", str(binary)], check=True, timeout=90)
            subprocess.run([str(binary)], check=True, timeout=15)

    def test_source_sameboy_records_valid_frames_before_delivery(self):
        text = (IOS / "MadeiraFrontend/IridiumConsoleSession.swift").read_text()
        first = text.index("recordSameBoyProgress(first, owner: owner)")
        self.assertLess(first, text.index("deliver(first, owner: owner)"))
        tick = text.split("private func tick(", 1)[1].split("case .psp:", 1)[0]
        self.assertLess(tick.index("guard valid else"), tick.index("recordSameBoyProgress(frame, owner: owner)"))
        self.assertLess(tick.index("recordSameBoyProgress(frame, owner: owner)"), tick.index("deliver(frame, owner: owner)"))
        # The common Game Boy implementation must not depend on a PSP build flag.
        before = text.split("private func recordSameBoyProgress(", 1)[0]
        self.assertGreater(before.rfind("#endif"), before.rfind("#if IRIDIUM_PPSSPP"))
        recorder = text.split("private func recordSameBoyProgress(", 1)[1].split("private func publishProgress(", 1)[0]
        self.assertIn("frame.input_polled", recorder)
        self.assertIn("data != lastSameBoyPixels", recorder)

    def test_source_retained_psp_image_does_not_fake_fresh_counter(self):
        text = (IOS / "MadeiraFrontend/IridiumConsoleSession.swift").read_text()
        self.assertIn("displayedImageCount == 0", text)
        self.assertIn("frame.video_refreshed || needsFirstImage", text)
        self.assertIn("output.width = presentImage ? frame.width : 0", text)
        self.assertIn("progress.freshImages = max(progress.freshImages, frame.video_frames)", text)
        self.assertIn("progress.changedImages = max(progress.changedImages, frame.changed_frames)", text)

    def test_extracted_terminal_counter_rules_are_monotonic(self):
        text = (IOS / "MadeiraFrontend/IridiumConsoleSession.swift").read_text()
        recorder = text.split("private func recordProgress(", 1)[1].split("private func recordSameBoyProgress(", 1)[0]
        rules = re.findall(r"progress\.(\w+) = max\(progress\.\1, frame\.(\w+)\)", recorder)
        self.assertEqual({target for target, _ in rules},
                         {"runtimeSteps", "videoCallbacks", "freshImages", "changedImages", "inputPolls"})
        # Execute the extracted max rules for a zeroed terminal frame, then a
        # subsequent increment. This checks the equations, not the C bridge.
        state = {target: 50 for target, _ in rules}
        for observed in [0, 75]:
            state = {target: max(state[target], observed) for target, _ in rules}
            self.assertTrue(all(value == (50 if observed == 0 else 75) for value in state.values()))

    def test_source_terminal_logging_is_not_throttled_away(self):
        text = (IOS / "MadeiraFrontend/IridiumConsoleSession.swift").read_text()
        self.assertIn("force || changedPhase || now - lastProgressLogged", text)
        self.assertIn("force || changedPhase || now - lastProgressPublished", text)
        for start, end in [("private func complete(", "private func requireRestart("),
                           ("private func requireRestart(", "private func activate("),
                           ("private func fail(", "private func complete(")]:
            body = text.split(start, 1)[1].split(end, 1)[0]
            self.assertIn("publishProgress(owner, force: true)", body)

    def test_extracted_snapshot_guard_rejects_aba_and_prior_owner(self):
        text = (IOS / "MadeiraFrontend/IridiumConsoleSession.swift").read_text()
        publish = text.split("private func publishProgress(", 1)[1].split("private func reportSaveError(", 1)[0]
        condition = re.search(r"guard (self\.lease == owner[^\n]+) else \{ return \}", publish).group(1)
        pairs = []
        for clause in condition.split(","):
            match = re.fullmatch(r"\s*(?:self\.)?(\w+) == (\w+)\s*", clause)
            self.assertIsNotNone(match, "Update this deliberately restricted source guard interpreter")
            pairs.append(match.groups())
        self.assertIn(("currentIntentGeneration", "sampledGeneration"), pairs)

        def accepts(owner="run-A", lease="run-A", current=10, sampled=10):
            values = dict(owner=owner, lease=lease, currentIntentGeneration=current, sampledGeneration=sampled)
            return all(values[left] == values[right] for left, right in pairs)

        self.assertTrue(accepts())
        self.assertFalse(accepts(current=11))  # pause after snapshot
        self.assertFalse(accepts(current=12))  # pause then resume: request returns to play
        self.assertFalse(accepts(lease="run-B"))
        # This executes the extracted acceptance condition, not DispatchQueue races.
        mutations = [line for line in text.splitlines()
                     if "lock.lock(); intent" in line and ("intent." in line or "intent =" in line)]
        self.assertGreaterEqual(len(mutations), 8)
        self.assertTrue(all("intentGeneration &+= 1" in line for line in mutations))
        self.assertLess(publish.index("let sampledGeneration = intentGeneration"), publish.index("let snapshot = progress"))
        self.assertIn('sampledRequest == .stop', publish)
        self.assertIn('progress.phase = "stop requested"', publish)
        self.assertIn('self.phase == .restartRequired', publish)
        self.assertIn('timedOut.phase = "stop timed out"', publish)

    def test_source_embedded_logs_have_no_sheet_dismissal(self):
        text = (IOS / "RuntimeSupport/IridiumDiagnosticsView.swift").read_text()
        embedded = text.split("struct RuntimeDiagnosticsLogContent: View", 1)[1]
        self.assertNotIn("NavigationStack", embedded)
        self.assertNotIn("dismiss()", embedded)
        self.assertIn("TimelineView(.periodic", embedded)
        self.assertIn("Task.detached(priority: .utility)", embedded)
        shipping = (ROOT / "ci/madeira_player_presentation.py").read_text()
        self.assertIn("RuntimeDiagnosticsLogContent().frame(minHeight: 250)", shipping)


if __name__ == "__main__":
    unittest.main()
