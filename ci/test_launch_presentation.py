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

        let title = CGRect(x: 24, y: 172, width: 342, height: 42)
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: portrait, targetBounds: portrait) == title)
        precondition(RuntimeLaunchGeometry.retainedFrame(portrait, sourceBounds: portrait, targetBounds: portrait) == portrait)
        // Changing orientation or window size must not reuse stale coordinates.
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: portrait, targetBounds: landscape) == nil)
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: portrait, targetBounds: CGRect(x: 0, y: 0, width: 320, height: 844)) == nil)
        precondition(RuntimeLaunchGeometry.retainedFrame(nil, sourceBounds: portrait, targetBounds: portrait) == nil)
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: nil, targetBounds: portrait) == nil)
        precondition(RuntimeLaunchGeometry.retainedFrame(.infinite, sourceBounds: portrait, targetBounds: portrait) == nil)
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: portrait, targetBounds: .zero) == nil)
        let translated = portrait.offsetBy(dx: 10, dy: 20)
        precondition(RuntimeLaunchGeometry.retainedFrame(title, sourceBounds: portrait, targetBounds: translated) == title.offsetBy(dx: 10, dy: 20))
        for emphasized in [false, true] {
            precondition(RuntimeLaunchMotion.scale(emphasized: emphasized, reduceMotion: true) == 1)
        }
        precondition(RuntimeLaunchMotion.scale(emphasized: false, reduceMotion: false) == 1)
        precondition(RuntimeLaunchMotion.scale(emphasized: true, reduceMotion: false) == 1.03)
        precondition((0.35...0.45).contains(RuntimeLaunchMotion.backdropDuration))
        precondition((0.20...0.25).contains(RuntimeLaunchMotion.revealDuration))
        print("Launch state precedence, late frames, layout continuity, rotation fallback and motion limits passed")
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
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
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
        self.assertNotIn("URLSession", art + transition)
        self.assertNotIn(".image(", art + transition) # No synchronous artwork decoding on launch.
        self.assertIn("artwork.displayImage(appearance.background)", transition)
        # Cancellation moves into the existing menu, not out of the product.
        menu = player.split('accessibilityLabel("Player Menu")', 1)[1].split('.overlay(alignment: .bottomLeading)', 1)[0]
        self.assertIn('Button("Cancel Launch"', menu)
        self.assertIn('if launchPresentation == .starting', menu)
        self.assertNotIn('Button("Cancel', art)
        self.assertIn("View Logs", art)
        self.assertIn("Back to Library", art)

    def test_artwork_transition_is_noninteractive_and_motion_aware(self):
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
        shelf = (VIEWS / "LibraryShelf.swift").read_text()
        presenter = (APP.parent / "MadeiraSupport/MadeiraPlayerPresentation.swift").read_text()
        for role in ("title", "backdrop"):
            self.assertIn(f"RuntimeLaunchSource(gameID: selected.id, role: .{role})", shelf)
        self.assertNotIn("RuntimeLaunchSource(gameID: game.id)", shelf)
        self.assertIn("source.window === window", transition)
        self.assertIn("valueOptions: .weakMemory", transition)
        self.assertIn("UIAccessibility.isReduceMotionEnabled", transition)
        self.assertIn("context.completeTransition(!context.transitionWasCancelled)", transition)
        for obsolete in ("UIPinchGestureRecognizer", "CroppedArtwork", "cornerRadius", "animateKeyframes", "CGAffineTransform"):
            self.assertNotIn(obsolete, transition)
        self.assertIn("player.transitioningDelegate = player.launchTransition", presenter)
        self.assertIn("playerSceneIsForeground && !sceneIsDeactivating", presenter)
        self.assertIn("launchArtwork: player.launchArtwork", presenter)

    def test_splash_reuses_library_treatment_without_replaying_motion(self):
        art = (VIEWS / "RuntimeLaunchArtworkView.swift").read_text()
        shelf = (VIEWS / "LibraryShelf.swift").read_text()
        self.assertIn("LibraryBackdrop(image:", art)
        self.assertIn("LibraryBackdropScrim", art)
        self.assertIn("LibraryBackdropScrim()", shelf)
        self.assertIn("guard !emphasized else { return }", art)
        self.assertIn("RuntimeLaunchMotion.scale(emphasized: emphasized, reduceMotion: reduceMotion)", art)
        self.assertIn("@State private var artwork: RuntimeLaunchArtworkSnapshot", art)
        self.assertNotIn("@ObservedObject", art)
        self.assertNotIn("repeatForever", art)
        self.assertNotIn("gamecontroller.fill", art)
        self.assertNotIn(".multilineTextAlignment(.center)", art)
        self.assertIn(".libraryGlass()", art)

    def test_early_frame_can_finish_the_opening_without_a_timer_gate(self):
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
        player = (VIEWS / "RuntimePlayerView.swift").read_text()
        presenter = (APP.parent / "MadeiraSupport/MadeiraPlayerPresentation.swift").read_text()
        self.assertIn("if phase == .playing { onLaunchReady() }", player)
        self.assertIn("player?.launchTransition?.revealGame()", presenter)
        self.assertIn("opening?.finishImmediately()", transition)
        self.assertIn("animation.finishAnimation(at: .end)", transition)
        self.assertIn("RuntimeLaunchMotion.revealDuration", player)
        for timer in ("Task.sleep", "asyncAfter", "Timer("):
            self.assertNotIn(timer, transition)

    def test_simulator_scenarios_are_in_the_existing_preview_project(self):
        root = APP.parent / "InterfaceTests"
        project = (root / "project.yml.template").read_text()
        for file in ("LaunchPresentationPreview.swift", "LaunchPresentationUITests.swift"):
            self.assertIn(file, project)
        fixture = (root / "LaunchPresentationPreview.swift").read_text()
        self.assertIn("LibraryShelf(", fixture)
        self.assertIn("MadeiraPlayerPresentation(", fixture)
        self.assertIn("config.framebufferPath", fixture)
        self.assertIn("config.frameReadyPath", fixture)
        self.assertNotIn("recordRuntimePlayerFirstFramePresented(", fixture) # Real file observer, not fabricated readiness.
        self.assertIn('"--launch-presentation"', (root / "Preview.swift").read_text())


if __name__ == "__main__":
    unittest.main()
