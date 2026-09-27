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
        precondition(RuntimeLaunchGeometry.wholeFrame(cover, in: portrait) == cover)
        precondition(RuntimeLaunchGeometry.wholeFrame(CGRect(x: -30, y: 100, width: 200, height: 300), in: portrait) == nil)
        precondition((0.40...0.55).contains(RuntimeLaunchMotion.heroDuration))
        precondition((0.45...0.65).contains(RuntimeLaunchMotion.revealDuration))
        precondition(RuntimeLaunchMotion.chromeFadeDuration < RuntimeLaunchMotion.heroDuration)
        let chrome = RuntimeLaunchChrome(gameID: UUID(), label: "Play", detail: nil, controllerHints: true)
        precondition(chrome.label == "Play" && chrome.detail == nil && chrome.controllerHints)
        for bounds in [portrait, landscape, CGRect(x: 0, y: 0, width: 320, height: 568),
                       CGRect(x: 0, y: 0, width: 1024, height: 768)] {
            for hasCover in [false, true] {
                for accessibility in [false, true] {
                    let layout = RuntimeLaunchHeroLayout.resolve(in: bounds, safeTop: 24, safeLeading: 24,
                        safeBottom: 24, safeTrailing: 24, hasCover: hasCover, accessibility: accessibility)
                    precondition(layout.text.minX >= 24 && layout.text.maxX <= bounds.width - 24)
                    precondition(layout.text.minY >= 24 + 72)
                    precondition((layout.cover != nil) == hasCover)
                    if let poster = layout.cover {
                        precondition(abs(poster.width / poster.height - 2.0 / 3.0) < 0.0001)
                        precondition(poster.minX >= 24 && poster.maxX <= bounds.width - 24)
                        precondition(poster.maxY <= bounds.height - 24)
                        if layout.sideBySide {
                            precondition(layout.text.minX > poster.maxX && layout.text.minY == poster.minY)
                        } else {
                            precondition(layout.text.minX == poster.minX && layout.text.maxY < poster.minY)
                        }
                    }
                    if accessibility { precondition(!layout.sideBySide) }
                }
            }
        }
        let tallText = RuntimeLaunchHeroLayout.resolve(in: portrait, safeTop: 59, safeLeading: 0,
            safeBottom: 34, safeTrailing: 0, hasCover: true, accessibility: true, textHeight: 400)
        precondition(tallText.cover!.minY > tallText.text.maxY)
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
            self.assertIn(f"RuntimeLaunchSource(gameID: selected.id, role: .{role}, active: visible)", shelf)
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
        self.assertIn("guard hidden, !settled, !artwork.handoff.hasPresentedFrame else { return }", art)
        self.assertIn(".easeInOut(duration: RuntimeLaunchMotion.heroDuration)", art)
        self.assertIn("LibraryBackdropScrim()", art)
        self.assertNotIn("LibraryBackdropScrim(strength:", art)
        self.assertNotIn(".scaleEffect", art)
        self.assertNotIn("var strength", shelf)
        self.assertIn("@State private var artwork: RuntimeLaunchArtworkSnapshot", art)
        self.assertNotIn("@ObservedObject", art)
        self.assertNotIn("repeatForever", art)
        self.assertNotIn("gamecontroller.fill", art)
        self.assertNotIn(".multilineTextAlignment(.center)", art)
        self.assertIn(".libraryGlass()", art)

    def test_early_frame_preserves_the_fade_without_a_timer_gate(self):
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
        player = (VIEWS / "RuntimePlayerView.swift").read_text()
        presenter = (APP.parent / "MadeiraSupport/MadeiraPlayerPresentation.swift").read_text()
        self.assertIn("if phase == .playing { onLaunchReady() }", player)
        self.assertIn("player?.launchTransition?.revealGame()", presenter)
        self.assertNotIn("finishImmediately", transition)
        self.assertNotIn("finishAnimation(at:", transition)
        self.assertIn("artwork.handoff.hasPresentedFrame = true", transition)
        self.assertIn(".transition(.opacity)", player)
        self.assertIn("value: launchPresentation.showsArtwork", player)
        self.assertIn("RuntimeLaunchMotion.revealDuration", player)
        for timer in ("Task.sleep", "asyncAfter", "Timer("):
            self.assertNotIn(timer, transition)

    def test_launch_chrome_is_frozen_before_all_play_entry_points(self):
        shelf = (VIEWS / "LibraryShelf.swift").read_text()
        request = shelf.split("private func requestPlay(_ game:", 1)[1].split("private func controllerFocus", 1)[0]
        self.assertLess(request.index("guard !disabled(game)"), request.index("launchChrome ="))
        self.assertLess(request.index("launchChrome ="), request.index("play(game)"))
        self.assertIn("detail: launchDetail(game)", request)
        self.assertEqual(shelf.count("requestPlay(selected)"), 2)
        self.assertEqual(shelf.count("requestPlay(game)"), 1)
        self.assertIn(".disabled(disabled(game))", shelf)
        self.assertIn("return launchChrome.detail", shelf) # Including nil, not a nil-coalescing fallback.
        self.assertIn("if !isDisabled { launchChrome = nil }", shelf)
        self.assertIn(".onAppear { launchChrome = nil;", shelf)

    def test_hero_elements_move_once_instead_of_crossfading(self):
        shelf = (VIEWS / "LibraryShelf.swift").read_text()
        art = (VIEWS / "RuntimeLaunchArtworkView.swift").read_text()
        transition = (VIEWS / "RuntimeLaunchTransition.swift").read_text()
        self.assertIn("RuntimeLaunchSource(gameID: game.id, role: .cover, active: visible)", shelf)
        self.assertIn("artwork.retainedFrame(artwork.coverFrame, in: bounds)", art)
        self.assertIn("artwork.retainedFrame(artwork.titleFrame, in: bounds)", art)
        self.assertIn(".offset(x: frame.minX, y: frame.minY)", art)
        self.assertIn(".offset(x: textFrame.minX, y: textFrame.minY)", art)
        self.assertIn(".onReceive(artwork.handoff.$chromeHidden)", art)
        self.assertNotIn(".transition(", art)
        self.assertIn("mask.fillRule = .evenOdd", transition)
        self.assertIn("artwork.windowID == ObjectIdentifier(window)", transition)
        self.assertIn("artwork.cover == nil ? nil : artwork.coverFrame", transition)
        self.assertLess(transition.index("snapshot?.removeFromSuperview()"),
                        transition.index("self.artwork?.handoff.finishChromeFade()"))

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
