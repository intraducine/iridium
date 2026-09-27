import Combine
import SwiftUI
import UIKit

/// Measure visible library elements without intercepting touch or controller input.
@MainActor struct RuntimeLaunchSource: UIViewRepresentable {
    enum Role: String { case title, cover, backdrop }
    let gameID: UUID
    let role: Role
    var active = true
    private static let sources = NSMapTable<NSString, UIView>(keyOptions: .strongMemory, valueOptions: .weakMemory)

    final class Marker: UIView { var sourceKey: NSString? }

    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: Marker, context: Context) {
        Self.unregister(view)
        let key = "\(gameID).\(role.rawValue)" as NSString
        view.sourceKey = key
        if active { Self.sources.setObject(view, forKey: key) }
    }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { unregister(view) }
    private static func unregister(_ view: Marker) {
        if let key = view.sourceKey, sources.object(forKey: key) === view { sources.removeObject(forKey: key) }
    }
    static func frame(gameID: UUID, role: Role, in window: UIWindow?) -> CGRect? {
        guard let window, let source = sources.object(forKey: "\(gameID).\(role.rawValue)" as NSString),
              source.window === window else { return nil }
        var ancestor: UIView? = source
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return nil }
            ancestor = view.superview
        }
        let frame = source.convert(source.bounds, to: window)
        return role == .backdrop
            ? RuntimeLaunchGeometry.sourceFrame(frame, in: window.bounds)
            : RuntimeLaunchGeometry.wholeFrame(frame, in: window.bounds)
    }
}

/// An animation handoff only. It never changes runtime or first-frame readiness.
@MainActor final class RuntimeLaunchHandoff: ObservableObject {
    @Published private(set) var chromeHidden: Bool
    var hasPresentedFrame = false
    init(waitsForPresentation: Bool = false) { chromeHidden = !waitsForPresentation }
    func finishChromeFade() { chromeHidden = true }
}

/// Freeze artwork and measurements for the launch; late cache updates cannot swap
/// the image, alter its crop, or replay motion after opening Logs.
@MainActor struct RuntimeLaunchArtworkSnapshot {
    let gameID: UUID
    let title: String
    let background: UIImage?
    let cover: UIImage?
    let backgroundY: Double
    let coverY: Double
    let customCover: Bool
    let viewport: CGRect?
    let windowID: ObjectIdentifier?
    let titleFrame: CGRect?
    let coverFrame: CGRect?
    let backdropFrame: CGRect?
    let handoff: RuntimeLaunchHandoff

    static func capture(session: RuntimePlayerSession, in window: UIWindow? = nil,
                        waitsForPresentation: Bool = false) -> Self {
        let artwork = LibraryArtwork.shared
        let appearance = artwork.appearance(session.gameID)
        return Self(gameID: session.gameID,
                    title: appearance.title ?? appearance.matchName ?? session.gameTitle,
                    background: artwork.displayImage(appearance.background),
                    cover: artwork.displayImage(appearance.cover),
                    backgroundY: appearance.backgroundY, coverY: appearance.coverY,
                    customCover: appearance.customCover,
                    viewport: window?.bounds, windowID: window.map(ObjectIdentifier.init),
                    titleFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .title, in: window),
                    coverFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .cover, in: window),
                    backdropFrame: RuntimeLaunchSource.frame(gameID: session.gameID, role: .backdrop, in: window),
                    handoff: RuntimeLaunchHandoff(waitsForPresentation: waitsForPresentation))
    }

    func retainedFrame(_ frame: CGRect?, in bounds: CGRect) -> CGRect? {
        RuntimeLaunchGeometry.retainedFrame(frame, sourceBounds: viewport, targetBounds: bounds)
    }
}

/// Fade chrome first, then move the live hero. The source title/poster are cut out
/// of the outgoing snapshot, so they are never two crossfading copies.
@MainActor final class RuntimeLaunchTransition: NSObject, UIViewControllerTransitioningDelegate {
    let artwork: RuntimeLaunchArtworkSnapshot
    init(artwork: RuntimeLaunchArtworkSnapshot) { self.artwork = artwork }

    func revealGame() {
        // Do not finish the animator or remove the splash on this callback. The
        // player's opacity transition gets its full first-frame fade duration.
        artwork.handoff.hasPresentedFrame = true
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(artwork: artwork)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(artwork: nil)
    }

    @MainActor private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        let artwork: RuntimeLaunchArtworkSnapshot?
        private var animation: UIViewPropertyAnimator?
        init(artwork: RuntimeLaunchArtworkSnapshot?) { self.artwork = artwork }

        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
            UIAccessibility.isReduceMotionEnabled ? 0.16 : RuntimeLaunchMotion.chromeFadeDuration
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let destination = context.viewController(forKey: .to),
                  let toView = context.view(forKey: .to), let fromView = context.view(forKey: .from) else {
                artwork?.handoff.finishChromeFade()
                context.completeTransition(false)
                return
            }
            let container = context.containerView
            let snapshot = fromView.snapshotView(afterScreenUpdates: false)
            snapshot?.frame = container.convert(fromView.bounds, from: fromView)
            snapshot?.isUserInteractionEnabled = false
            snapshot?.accessibilityElementsHidden = true
            if let snapshot { maskSharedElements(in: snapshot, from: fromView) }
            let oldToAlpha = toView.alpha
            toView.frame = context.finalFrame(for: destination)
            container.addSubview(toView)
            toView.layoutIfNeeded()
            if let snapshot { container.addSubview(snapshot) }
            else { toView.alpha = 0 }

            let animation = UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .easeInOut) {
                snapshot?.alpha = 0
                toView.alpha = oldToAlpha
            }
            self.animation = animation
            animation.addCompletion { _ in
                self.animation = nil
                snapshot?.removeFromSuperview()
                toView.alpha = oldToAlpha
                if context.transitionWasCancelled { toView.removeFromSuperview() }
                context.completeTransition(!context.transitionWasCancelled)
                self.artwork?.handoff.finishChromeFade()
            }
            animation.startAnimation()
        }

        private func maskSharedElements(in snapshot: UIView, from source: UIView) {
            guard !UIAccessibility.isReduceMotionEnabled, let artwork,
                  !artwork.handoff.hasPresentedFrame, let window = source.window,
                  artwork.windowID == ObjectIdentifier(window),
                  artwork.retainedFrame(artwork.viewport, in: window.bounds) != nil else { return }
            let path = UIBezierPath(rect: snapshot.bounds)
            let frames = [artwork.titleFrame, artwork.cover == nil ? nil : artwork.coverFrame]
            for frame in frames.compactMap({ $0 }) {
                // Include the cover's padding/selection stroke in the chrome cutout.
                let local = source.convert(frame, from: window)
                    .offsetBy(dx: -source.bounds.minX, dy: -source.bounds.minY)
                    .insetBy(dx: -6, dy: -6)
                path.append(UIBezierPath(rect: local))
            }
            let mask = CAShapeLayer()
            mask.frame = snapshot.bounds
            mask.path = path.cgPath
            mask.fillRule = .evenOdd
            snapshot.layer.mask = mask
        }
    }
}
