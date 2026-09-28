import Combine
import GameController
import IridiumRuntime
import SwiftUI
import UIKit

// Own the presented controller so UIKit can read the game's pointer-lock preference.
// SwiftUI's ordinary fullScreenCover uses its own hosting controller.
struct MadeiraPlayerPresentation: UIViewControllerRepresentable {
    @ObservedObject var viewModel: AppViewModel
    var presentationConfiguration: RuntimePlayerBridgeConfiguration? = nil

    func makeUIViewController(context: Context) -> Presenter {
        Presenter()
    }

    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.synchronize = { [weak controller, weak viewModel] in
            guard let controller, let viewModel else { return }
            guard let session = viewModel.activeRuntimePlayerSession else {
                if let player = controller.player {
                    player.captureRequested = false
                    controller.dismissPlayer()
                }
                return
            }
            if let player = controller.player,
               player.presentingViewController == nil, !player.isBeingPresented {
                controller.player = nil
            }
            if let player = controller.player {
                player.rootView = RuntimePlayerView(session: session, viewModel: viewModel, onCaptureChange: { [weak player] in player?.captureRequested = $0 }, presentationConfiguration: presentationConfiguration, launchArtwork: player.launchArtwork, launchMotionState: player.launchMotionState, onLaunchReady: { [weak player] in player?.fadeLaunchArtwork() })
                return
            }
            guard controller.view.window != nil, controller.presentedViewController == nil else { return }
            let artwork = RuntimeLaunchArtworkSnapshot.capture(session: session, in: controller.view.window)
            let animate = !UIAccessibility.isReduceMotionEnabled
                && !UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
                && (artwork.titleFrame != nil || (artwork.cover != nil && artwork.coverFrame != nil))
            let motionState = RuntimeLaunchMotionState(animate: animate)
            let player = Player(rootView: RuntimePlayerView(session: session, viewModel: viewModel, presentationConfiguration: presentationConfiguration, launchArtwork: artwork, launchMotionState: motionState))
            player.launchArtwork = artwork
            player.launchMotionState = motionState
            player.rootView = RuntimePlayerView(session: session, viewModel: viewModel, onCaptureChange: { [weak player] in player?.captureRequested = $0 }, presentationConfiguration: presentationConfiguration, launchArtwork: artwork, launchMotionState: motionState, onLaunchReady: { [weak player] in player?.fadeLaunchArtwork() })
            player.modalPresentationStyle = .fullScreen
            player.launchTransition = RuntimeLaunchTransition(motionState: motionState)
            player.transitioningDelegate = player.launchTransition
            controller.player = player
            controller.present(player, animated: true) { [weak controller] in
                // Reconcile a failure/cancellation that arrived during the fade.
                controller?.synchronize?()
            }
        }
        if controller.sessionObservation == nil {
            // A full-screen presentation can suspend SwiftUI updates in the covered library.
            controller.sessionObservation = viewModel.$activeRuntimePlayerSession
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] _ in controller?.synchronize?() }
        }
        DispatchQueue.main.async { controller.synchronize?() }
    }

    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.sessionObservation = nil
        controller.synchronize = nil
        controller.player?.captureRequested = false
        controller.player?.dismiss(animated: false)
        controller.player = nil
    }

    final class Presenter: UIViewController {
        var player: Player?
        var sessionObservation: AnyCancellable?
        private var foregroundObservation: AnyCancellable?
        override func viewDidLoad() {
            super.viewDidLoad()
            foregroundObservation = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.synchronize?() }
        }
        private var dismissing = false
        func dismissPlayer() {
            guard !dismissing, let player, let presenter = player.presentingViewController else { return }
            dismissing = true
            // Dismiss from the presenting controller, including any alert on the player.
            presenter.dismiss(animated: true) { [weak self] in
                self?.player = nil
                self?.dismissing = false
                RuntimeLogCapture.writeLine("[Launch] Runtime player dismissed.")
                self?.synchronize?()
            }
        }
        var synchronize: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize?()
        }
    }

    final class Player: UIHostingController<RuntimePlayerView> {
        var launchTransition: RuntimeLaunchTransition?
        var launchArtwork: RuntimeLaunchArtworkSnapshot?
        var launchMotionState = RuntimeLaunchMotionState(animate: false)
        private var didFadeLaunchArtwork = false
        private var launchFadeSnapshot: UIView?
        var captureRequested = false { didSet { refreshCapture() } }

        func fadeLaunchArtwork() {
            guard !didFadeLaunchArtwork else { return }
            didFadeLaunchArtwork = true
            guard let snapshot = view.snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = view.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            view.addSubview(snapshot)
            launchFadeSnapshot = snapshot
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : RuntimeLaunchMotion.revealDuration,
                           delay: 0, options: .curveEaseOut) {
                snapshot.alpha = 0
            } completion: { [weak self] _ in
                snapshot.removeFromSuperview()
                self?.launchFadeSnapshot = nil
            }
        }
        private var observers: [NSObjectProtocol] = []

        // The presented player owns capture, not its nested SwiftUI event host.
        override var childViewControllerForPointerLock: UIViewController? { nil }
        private var captureQueries = 0
        override var prefersPointerLocked: Bool {
            captureQueries += 1
            return wantsPointerCapture
        }
        private var playerSceneIsForeground: Bool {
            if let scene = viewIfLoaded?.window?.windowScene {
                return scene.activationState == .foregroundActive
            }
            return UIApplication.shared.applicationState == .active
        }
        private var wantsPointerCapture: Bool {
            #if INTERFACE_PREVIEW
            false
            #else
            captureRequested && !MadeiraHardwareInput.softwareKeyboardActive && UIApplication.shared.applicationState == .active
                && !UIAccessibility.isAssistiveTouchRunning && !GCMouse.mice().isEmpty
            #endif
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect,
                         UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                         UIAccessibility.assistiveTouchStatusDidChangeNotification,
                         UIPointerLockState.didChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshCapture() }
                })
            }
            for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let scene = notification.object as? UIScene,
                              scene === self.viewIfLoaded?.window?.windowScene else { return }
                        self.refreshCapture(sceneIsDeactivating: notification.name == UIScene.willDeactivateNotification)
                    }
                })
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            launchMotionState.settle(animated: false)
            launchMotionState.finish()
            #if MADEIRA_RUNTIME
            rootView.viewModel.startPendingMadeiraLaunch(sessionID: rootView.session.sessionIdentifier)
            #endif
            refreshCapture()
        }

        override func viewWillDisappear(_ animated: Bool) {
            captureRequested = false
            launchFadeSnapshot?.removeFromSuperview()
            launchFadeSnapshot = nil
            super.viewWillDisappear(animated)
        }

        private func refreshCapture(sceneIsDeactivating: Bool = false) {
            setNeedsUpdateOfPrefersPointerLocked()
            #if MADEIRA_RUNTIME
            MadeiraHardwareInput.acceptingInput = captureRequested && playerSceneIsForeground && !sceneIsDeactivating
            MadeiraHardwareInput.pointerCaptured = !sceneIsDeactivating && wantsPointerCapture && viewIfLoaded?.window?.windowScene?.pointerLockState?.isLocked == true
            RuntimeLogCapture.writeLine("[Launch] Pointer capture requested=\(wantsPointerCapture), systemQueries=\(captureQueries), sceneActive=\(viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive), appActive=\(UIApplication.shared.applicationState == .active), inputActive=\(MadeiraHardwareInput.acceptingInput), active=\(MadeiraHardwareInput.pointerCaptured), AssistiveTouch=\(UIAccessibility.isAssistiveTouchRunning).")
            #endif
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
