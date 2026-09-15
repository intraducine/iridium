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
                player.rootView = RuntimePlayerView(session: session, viewModel: viewModel, onCaptureChange: { [weak player] in player?.captureRequested = $0 }, presentationConfiguration: presentationConfiguration)
                return
            }
            guard controller.view.window != nil, controller.presentedViewController == nil else { return }
            let player = Player(rootView: RuntimePlayerView(session: session, viewModel: viewModel, presentationConfiguration: presentationConfiguration))
            player.rootView = RuntimePlayerView(session: session, viewModel: viewModel, onCaptureChange: { [weak player] in player?.captureRequested = $0 }, presentationConfiguration: presentationConfiguration)
            player.modalPresentationStyle = .fullScreen
            controller.player = player
            controller.present(player, animated: true)
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
        var captureRequested = false { didSet { refreshCapture() } }
        private var observers: [NSObjectProtocol] = []

        // The presented player owns capture, not its nested SwiftUI event host.
        override var childViewControllerForPointerLock: UIViewController? { nil }
        private var captureQueries = 0
        override var prefersPointerLocked: Bool {
            captureQueries += 1
            return wantsPointerCapture
        }
        private var wantsPointerCapture: Bool {
            captureRequested && !MadeiraHardwareInput.softwareKeyboardActive && UIApplication.shared.applicationState == .active
                && !UIAccessibility.isAssistiveTouchRunning && !GCMouse.mice().isEmpty
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
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            refreshCapture()
        }

        override func viewWillDisappear(_ animated: Bool) {
            captureRequested = false
            super.viewWillDisappear(animated)
        }

        private func refreshCapture() {
            setNeedsUpdateOfPrefersPointerLocked()
            #if MADEIRA_RUNTIME
            MadeiraHardwareInput.acceptingInput = captureRequested && UIApplication.shared.applicationState == .active
            MadeiraHardwareInput.pointerCaptured = wantsPointerCapture && viewIfLoaded?.window?.windowScene?.pointerLockState?.isLocked == true
            RuntimeLogCapture.writeLine("[Launch] Pointer capture requested=\(wantsPointerCapture), systemQueries=\(captureQueries), sceneActive=\(viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive), active=\(MadeiraHardwareInput.pointerCaptured), AssistiveTouch=\(UIAccessibility.isAssistiveTouchRunning).")
            #endif
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
