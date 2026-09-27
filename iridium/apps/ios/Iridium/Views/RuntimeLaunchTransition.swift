import SwiftUI
import UIKit

/// Measure the existing title/backdrop, never a cover to stretch into a modal.
@MainActor struct RuntimeLaunchSource: UIViewRepresentable {
    enum Role: String { case title, backdrop }
    let gameID: UUID
    let role: Role
    private static let sources = NSMapTable<NSString, UIView>(keyOptions: .strongMemory, valueOptions: .weakMemory)

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        Self.sources.setObject(view, forKey: "\(gameID).\(role.rawValue)" as NSString)
    }
    static func frame(gameID: UUID, role: Role, in window: UIWindow?) -> CGRect? {
        guard let window, let source = sources.object(forKey: "\(gameID).\(role.rawValue)" as NSString),
              source.window === window else { return nil }
        return RuntimeLaunchGeometry.sourceFrame(source.convert(source.bounds, to: window), in: window.bounds)
    }
}

/// Frozen for this launch: no network wait, second image decode, or late crop swap.
@MainActor struct RuntimeLaunchArtworkSnapshot {
    let gameID: UUID
    let title: String
    let background: UIImage?
    let cover: UIImage?
    let backgroundY: Double
    let coverY: Double
    let viewport: CGRect?
    let titleFrame: CGRect?
    let backdropFrame: CGRect?

    static func capture(session: RuntimePlayerSession, in window: UIWindow? = nil) -> Self {
        let artwork = LibraryArtwork.shared
        let appearance = artwork.appearance(session.gameID)
        return Self(gameID: session.gameID,
                    title: appearance.title ?? appearance.matchName ?? session.gameTitle,
                    background: artwork.displayImage(appearance.background),
                    cover: artwork.displayImage(appearance.cover),
                    backgroundY: appearance.backgroundY, coverY: appearance.coverY,
                    viewport: window?.bounds,
                    titleFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .title, in: window),
                    backdropFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .backdrop, in: window))
    }

    func retainedFrame(_ frame: CGRect?, in bounds: CGRect) -> CGRect? {
        RuntimeLaunchGeometry.retainedFrame(frame, sourceBounds: viewport, targetBounds: bounds)
    }
}

/// Only the outgoing full-screen UI fades. The incoming player is already opaque
/// underneath; neither controller is scaled, cropped, rounded, or slid into place.
@MainActor final class RuntimeLaunchTransition: NSObject, UIViewControllerTransitioningDelegate {
    private var gameReady = false
    private weak var opening: Animator?

    func revealGame() {
        gameReady = true
        opening?.finishImmediately()
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animator = Animator(immediate: gameReady)
        opening = animator
        return animator
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(immediate: false)
    }

    @MainActor private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        private var immediate: Bool
        private var animation: UIViewPropertyAnimator?
        init(immediate: Bool) { self.immediate = immediate }

        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
            immediate ? 0 : (UIAccessibility.isReduceMotionEnabled ? 0.16 : RuntimeLaunchMotion.chromeFadeDuration)
        }

        func finishImmediately() {
            immediate = true
            guard let animation, animation.state == .active else { return }
            animation.stopAnimation(false)
            animation.finishAnimation(at: .end)
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let destination = context.viewController(forKey: .to),
                  let toView = context.view(forKey: .to), let fromView = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            let container = context.containerView
            // Capture before insertion, so a fast frame cannot enter the library snapshot.
            let snapshot = fromView.snapshotView(afterScreenUpdates: false)
            snapshot?.frame = container.convert(fromView.bounds, from: fromView)
            snapshot?.isUserInteractionEnabled = false
            snapshot?.accessibilityElementsHidden = true
            let oldToAlpha = toView.alpha
            toView.frame = context.finalFrame(for: destination)
            container.addSubview(toView)
            toView.layoutIfNeeded()
            if let snapshot { container.addSubview(snapshot) }
            else { toView.alpha = 0 } // Crossfade over the source, never over a blank screen.

            let animation = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .easeOut) {
                snapshot?.alpha = 0
                toView.alpha = oldToAlpha
            }
            self.animation = animation
            animation.addCompletion { [weak self] _ in
                snapshot?.removeFromSuperview()
                toView.alpha = oldToAlpha
                if context.transitionWasCancelled { toView.removeFromSuperview() }
                self?.animation = nil
                context.completeTransition(!context.transitionWasCancelled)
            }
            animation.startAnimation()
            if immediate { finishImmediately() }
        }
    }
}
