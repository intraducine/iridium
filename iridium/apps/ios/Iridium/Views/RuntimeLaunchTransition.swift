import SwiftUI
import UIKit

/// A noninteractive source marker: it never intercepts shelf taps or game gestures.
struct RuntimeLaunchSource: UIViewRepresentable {
    let gameID: UUID

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        RuntimeLaunchTransition.sources.setObject(view, forKey: gameID.uuidString as NSString)
    }
}

/// Retained by the player because UIViewController.transitioningDelegate is weak.
/// Unlike an interactive modal zoom, this cannot dismiss a running game by pinching.
@MainActor final class RuntimeLaunchTransition: NSObject, UIViewControllerTransitioningDelegate {
    static let sources = NSMapTable<NSString, UIView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    let gameID: UUID

    init(gameID: UUID) { self.gameID = gameID }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(gameID: gameID, presenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        Animator(gameID: gameID, presenting: false)
    }

    private final class Animator: NSObject, UIViewControllerAnimatedTransitioning {
        let gameID: UUID
        let presenting: Bool
        init(gameID: UUID, presenting: Bool) { self.gameID = gameID; self.presenting = presenting }

        func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
            UIAccessibility.isReduceMotionEnabled ? 0.16 : (presenting ? 0.48 : 0.22)
        }

        func animateTransition(using context: UIViewControllerContextTransitioning) {
            guard let destination = context.viewController(forKey: .to),
                  let toView = context.view(forKey: .to), let fromView = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            let container = context.containerView
            let finalFrame = context.finalFrame(for: destination)
            let oldBackground = container.backgroundColor
            container.backgroundColor = .black
            toView.frame = finalFrame
            if presenting { container.addSubview(toView) }
            else { container.insertSubview(toView, belowSubview: fromView) }
            toView.layoutIfNeeded()
            let oldFromAlpha = fromView.alpha
            let oldToAlpha = toView.alpha
            let duration = transitionDuration(using: context)
            var artworkView: CroppedArtwork?
            if presenting, !UIAccessibility.isReduceMotionEnabled,
               let source = RuntimeLaunchTransition.sources.object(forKey: gameID.uuidString as NSString),
               source.window != nil, source.window === container.window,
               let sourceFrame = RuntimeLaunchGeometry.sourceFrame(source.convert(source.bounds, to: container), in: container.bounds) {
                let artwork = LibraryArtwork.shared
                let appearance = artwork.appearance(gameID)
                // Cached display reads only; an unavailable image takes the crossfade path.
                if let image = artwork.displayImage(appearance.background) ?? artwork.displayImage(appearance.cover) {
                    let view = CroppedArtwork(image: image,
                        position: artwork.displayImage(appearance.background) != nil ? appearance.backgroundY : appearance.coverY)
                    view.frame = sourceFrame
                    view.layer.cornerRadius = 18
                    view.alpha = 0
                    container.addSubview(view)
                    view.layoutIfNeeded()
                    artworkView = view
                }
            }
            if presenting { toView.alpha = 0 }
            UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.calculationModeCubic]) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                    artworkView?.alpha = 1
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    if self.presenting {
                        artworkView?.frame = finalFrame
                        artworkView?.layer.cornerRadius = 0
                        artworkView?.layoutIfNeeded()
                    }
                    fromView.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: artworkView == nil ? 0 : 0.55,
                                   relativeDuration: artworkView == nil ? 1 : 0.45) {
                    toView.alpha = oldToAlpha
                    artworkView?.alpha = 0
                }
            } completion: { _ in
                fromView.alpha = oldFromAlpha
                toView.alpha = oldToAlpha
                artworkView?.removeFromSuperview()
                container.backgroundColor = oldBackground
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }

    private final class CroppedArtwork: UIView {
        let imageView: UIImageView
        let position: Double
        init(image: UIImage, position: Double) {
            imageView = UIImageView(image: image)
            self.position = position.isFinite ? min(1, max(0, position)) : 0.5
            super.init(frame: .zero)
            backgroundColor = .black
            clipsToBounds = true
            isUserInteractionEnabled = false
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let image = imageView.image else { return }
            let scale = max(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) * position, width: size.width, height: size.height)
        }
    }
}
