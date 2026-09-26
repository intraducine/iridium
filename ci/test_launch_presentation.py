"""Check launch presentation policy and its renderer/UI wiring without running a game."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "iridium/apps/ios/Iridium"
VIEWS = APP / "Views"

HARNESS = r'''
import Foundation

@main struct LaunchPresentationCheck {
    static func main() {
        func phase(running: Bool = true, failed: Bool = false, completed: Bool = false,
                   frame: Bool = false, closing: Bool = false, unconfirmed: Bool = false) -> RuntimeLaunchPresentation {
            .resolve(isRunning: running, isFailed: failed, isCompleted: completed,
                     hasPresentedFrame: frame, isClosing: closing, shutdownUnconfirmed: unconfirmed)
        }
        precondition(phase(running: false) == .starting)
        precondition(phase() == .starting) // Process startup is not proof of a frame.
        precondition(phase(frame: true) == .playing)
        precondition(phase(running: false, frame: true) == .starting)
        for frame in [false, true] {
            precondition(phase(failed: true, frame: frame) == .failed)
            precondition(phase(completed: true, frame: frame) == .stopped)
            precondition(phase(frame: frame, closing: true) == .closing)
            precondition(phase(frame: frame, unconfirmed: true) == .shutdownUnconfirmed)
            precondition(phase(failed: true, frame: frame, closing: true) == .closing)
            precondition(phase(failed: true, frame: frame, unconfirmed: true) == .shutdownUnconfirmed)
        }
        precondition(!phase(frame: true).showsArtwork)
        for value in [RuntimeLaunchPresentation.starting, .closing, .failed, .stopped, .shutdownUnconfirmed] {
            precondition(value.showsArtwork)
        }
        precondition(phase().isBusy && phase(closing: true).isBusy)
        precondition(!phase(failed: true).isBusy && !phase(completed: true).isBusy)
        precondition(!phase(unconfirmed: true).isBusy)
        // A new session gets starting presentation, regardless of the previous game's result.
        precondition(phase(frame: true) == .playing && phase() == .starting)

        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let cover = CGRect(x: 24, y: 240, width: 200, height: 300)
        precondition(RuntimeLaunchGeometry.sourceFrame(cover, in: portrait) == cover)
        let clipped = RuntimeLaunchGeometry.sourceFrame(CGRect(x: -30, y: 100, width: 200, height: 300), in: portrait)
        precondition(clipped == CGRect(x: 0, y: 100, width: 170, height: 300))
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)
        precondition(RuntimeLaunchGeometry.sourceFrame(cover, in: landscape) == CGRect(x: 24, y: 240, width: 200, height: 150))
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: 400, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: 0, width: -10, height: 20),
                        CGRect(x: 0, y: 0, width: 20, height: 1),
                        CGRect(x: CGFloat.nan, y: 0, width: 10, height: 20)] {
            precondition(RuntimeLaunchGeometry.sourceFrame(invalid, in: portrait) == nil)
        }
        precondition(RuntimeLaunchGeometry.sourceFrame(cover, in: .zero) == nil)
        print("Launch state precedence, late frames, busy/error states and source geometry passed")
    }
}
'''


class LaunchPresentationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "requires Swift compiler")
    def test_real_swift_presentation_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            harness = root / "Check.swift"
            harness.write_text(HARNESS)
            binary = root / "check"
            build = subprocess.run([
                "swiftc", "-swift-version", "6", "-warnings-as-errors",
                str(APP / "RuntimeLaunchPresentation.swift"), str(harness), "-o", str(binary),
            ], capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_metal_readiness_comes_from_presented_drawable(self):
        source = (VIEWS / "RuntimePlayerView.swift").read_text()
        layer = source.split("private final class PlayerMetalLayer:", 1)[1].split("#endif", 1)[0]
        self.assertIn("drawable.addPresentedHandler", layer)
        self.assertIn("presented.presentedTime", layer)
        callback = source.split("madeiraLayer.didPresent =", 1)[1].split("madeiraLayer.device", 1)[0]
        self.assertIn("recordPresentedFrame(at: time)", callback)
        self.assertIn("time.isFinite, time > 0", callback)
        self.assertIn("self.acceptsPresentedFrames", callback)
        poll = source.split("private func renderFrameIfNeeded()", 1)[1].split("#endif", 1)[0]
        self.assertIn("madeira_get_present_count()", poll) # Keep runtime stall diagnostics.
        self.assertNotIn("onFirstFramePresented()", poll)
        self.assertNotIn("onFrameCount(count)", poll)
        self.assertIn("acceptsPresentedFrames = false", source.split("    func stop() {", 1)[1])

    def test_loading_keeps_logs_and_controls_out_of_the_render_surface(self):
        player = (VIEWS / "RuntimePlayerView.swift").read_text()
        art = (VIEWS / "RuntimeLaunchArtworkView.swift").read_text()
        self.assertIn("frameSessionIdentifier == session.sessionIdentifier && frameCount > 0", player)
        self.assertIn(".id(session.sessionIdentifier)", player)
        log_task = player.split(".task(id: session.sessionIdentifier)", 1)[1].split(".task(id: bridgeConfiguration", 1)[0]
        self.assertNotIn("frameCount = 0", log_task)
        self.assertIn("RuntimeLogCapture.startupSummaries", log_task)
        self.assertIn("RuntimePlayerDiagnosticsView(", player)
        self.assertIn("launchPresentation.showsArtwork || !touchControlsEnabled || controlsVisible", player)
        self.assertIn("launchPresentation == .playing && !controlsVisible", player)
        self.assertIn(".onChange(of: launchPresentation)", player)
        self.assertIn("viewModel.dismissActiveRuntimePlayer()", player)
        self.assertNotIn("session.statusSummary", art)
        self.assertNotIn("launchEvents", art)
        self.assertNotIn("URLSession", art)
        self.assertNotIn(".image(", art) # No synchronous artwork decoding on launch.
        self.assertIn("artwork.displayImage(appearance.background)", art)
        self.assertIn("Cancel launch", art)
        self.assertIn("View Logs", art)
        self.assertIn("Back to Library", art)

    def test_artwork_transition_is_noninteractive_and_motion_aware(self):
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
        shelf = (VIEWS / "LibraryShelf.swift").read_text()
        presenter = (APP.parent / "MadeiraSupport/MadeiraPlayerPresentation.swift").read_text()
        self.assertIn("RuntimeLaunchSource(gameID: game.id)", shelf)
        self.assertIn("source.window === container.window", transition)
        self.assertIn("valueOptions: .weakMemory", transition)
        self.assertIn("UIAccessibility.isReduceMotionEnabled", transition)
        self.assertIn("context.completeTransition(!context.transitionWasCancelled)", transition)
        self.assertNotIn("UIPinchGestureRecognizer", transition)
        self.assertIn("player.transitioningDelegate = player.launchTransition", presenter)
        self.assertIn("playerSceneIsForeground && !sceneIsDeactivating", presenter)


if __name__ == "__main__":
    unittest.main()
