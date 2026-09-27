import SwiftUI
import UIKit

/// Measure the visible title, cover, and backdrop in the library window.
@MainActor struct RuntimeLaunchSource: UIViewRepresentable {
    enum Role: String { case title, cover, backdrop }
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
    let coverFits: Bool
    let backgroundY: Double
    let coverY: Double
    let viewport: CGRect?
    let titleFrame: CGRect?
    let coverFrame: CGRect?
    let backdropFrame: CGRect?

    static func capture(session: RuntimePlayerSession, in window: UIWindow? = nil) -> Self {
        let artwork = LibraryArtwork.shared
        let appearance = artwork.appearance(session.gameID)
        return Self(gameID: session.gameID,
                    title: appearance.title ?? appearance.matchName ?? session.gameTitle,
                    background: artwork.displayImage(appearance.background),
                    cover: artwork.displayImage(appearance.cover), coverFits: !appearance.customCover,
                    backgroundY: appearance.backgroundY, coverY: appearance.coverY,
                    viewport: window?.bounds,
                    titleFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .title, in: window),
                    coverFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .cover, in: window),
                    backdropFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .backdrop, in: window))
    }

    func retainedFrame(_ frame: CGRect?, in bounds: CGRect) -> CGRect? {
        RuntimeLaunchGeometry.retainedFrame(frame, sourceBounds: viewport, targetBounds: bounds)
    }
}

/// The presenter starts this motion while UIKit still owns the screen change.
@MainActor final class RuntimeLaunchMotionState: ObservableObject {
    let shouldAnimate: Bool
    @Published private(set) var settled: Bool
    @Published private(set) var detailsVisible: Bool

    init(animate: Bool) {
        shouldAnimate = animate
        settled = !animate
        detailsVisible = !animate
    }

    func settle(animated: Bool) {
        guard !settled else { return }
        if animated {
            withAnimation(.snappy(duration: RuntimeLaunchMotion.artworkMoveDuration, extraBounce: 0)) {
                settled = true
            }
        } else {
            settled = true
        }
    }

    func finish() { detailsVisible = true }
}

@MainActor final class RuntimeLaunchTransition: NSObject, UIViewControllerTransitioningDelegate {
    private let motionState: RuntimeLaunchMotionState

    init(motionState: RuntimeLaunchMotionState) { self.motionState = motionState }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(opening: true, motionState: motionState)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(opening: false, motionState: motionState)
    }

    @MainActor private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        private let opening: Bool
        private let motionState: RuntimeLaunchMotionState
        init(opening: Bool, motionState: RuntimeLaunchMotionState) {
            self.opening = opening
            self.motionState = motionState
        }

        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
            if opening {
                return motionState.shouldAnimate && !UIAccessibility.isReduceMotionEnabled
                    ? RuntimeLaunchMotion.chromeFadeDuration + RuntimeLaunchMotion.artworkMoveDuration : 0
            }
            return UIAccessibility.isReduceMotionEnabled ? 0.16 : RuntimeLaunchMotion.chromeFadeDuration
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let destination = context.viewController(forKey: .to),
                  let toView = context.view(forKey: .to), let fromView = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            let container = context.containerView
            toView.frame = context.finalFrame(for: destination)
            if opening {
                let duration = transitionDuration(using: context)
                let chrome = duration > 0 ? fromView.snapshotView(afterScreenUpdates: false) : nil
                chrome?.frame = container.convert(fromView.bounds, from: fromView)
                chrome?.isUserInteractionEnabled = false
                chrome?.accessibilityElementsHidden = true
                container.addSubview(toView)
                toView.layoutIfNeeded()
                if let chrome { container.addSubview(chrome) }
                guard duration > 0 else {
                    motionState.settle(animated: false)
                    self.motionState.finish()
                    context.completeTransition(!context.transitionWasCancelled)
                    return
                }
                UIView.animate(withDuration: RuntimeLaunchMotion.chromeFadeDuration, delay: 0,
                               options: .curveEaseOut) { chrome?.alpha = 0 } completion: { _ in
                    chrome?.removeFromSuperview()
                    self.motionState.settle(animated: !context.transitionWasCancelled)
                }
                let oldFromAlpha = fromView.alpha
                let animation = UIViewPropertyAnimator(duration: duration, curve: .linear) {
                    fromView.alpha = 0
                }
                animation.addCompletion { _ in
                    chrome?.removeFromSuperview()
                    fromView.alpha = oldFromAlpha
                    self.motionState.finish()
                    if context.transitionWasCancelled { toView.removeFromSuperview() }
                    context.completeTransition(!context.transitionWasCancelled)
                }
                animation.startAnimation()
                return
            }
            let snapshot = fromView.snapshotView(afterScreenUpdates: false)
            snapshot?.frame = container.convert(fromView.bounds, from: fromView)
            snapshot?.isUserInteractionEnabled = false
            snapshot?.accessibilityElementsHidden = true
            let oldToAlpha = toView.alpha
            container.addSubview(toView)
            toView.layoutIfNeeded()
            if let snapshot { container.addSubview(snapshot) }
            else { toView.alpha = 0 } // Crossfade over the source, never over a blank screen.

            let animation = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .easeOut) {
                snapshot?.alpha = 0
                toView.alpha = oldToAlpha
            }
            animation.addCompletion { _ in
                snapshot?.removeFromSuperview()
                toView.alpha = oldToAlpha
                if context.transitionWasCancelled { toView.removeFromSuperview() }
                context.completeTransition(!context.transitionWasCancelled)
            }
            animation.startAnimation()
        }
    }
}
