// SPDX-License-Identifier: GPL-3.0-or-later
// Derived from Madeira e3a88fd; see App/Origin.
import SwiftUI
import UIKit

// MARK: - Starting screen motion

/// Moves already-visible launch content into place. Reduce Motion skips the movement.
struct LaunchEntrance: ViewModifier {
    var visible: Bool
    var step: Int
    var rise = CGSize(width: 0, height: 12)
    var scale: CGFloat = 1
    /// Under the launch flood: in place at once, never moving (the flood measures the
    /// cover's frame and lands on it).
    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let settled = visible || reduceMotion || still
        content
            .scaleEffect(settled ? 1 : scale)
            .offset(settled ? .zero : rise)
            .animation(still ? nil : reduceMotion ? .easeOut(duration: 0.2)
                                    : .spring(response: 0.62, dampingFraction: 0.84).delay(0.08 + Double(step) * 0.07),
                       value: visible)
    }
}

/// Play → starting screen, after DroidDeck's launch flood, in a window of its own above
/// every other one, driven by Core Animation so that the app's main thread (busy
/// starting the session) cannot make it stutter.
///
/// The press puts the starting screen up at once (LibraryModel.prepare), fully drawn
/// and without its own entrance, underneath this window. Here the button's colour grows
/// out of the button and fills the screen, darkening at once; then it gathers into the
/// cover's frame with the cover art and the cover's shadow coming in, while the
/// backdrop (the same hero image the starting screen shows) fades in and settles from a
/// slight zoom around it. Once both have landed the window dissolves onto the starting
/// screen, which shows the same pixels, so only its text and buttons fade in. When no
/// start follows the press it shrinks back into the button. MADEIRA_LAUNCH_FLOOD=0
/// turns it off; Reduce Motion skips it.
@MainActor final class LaunchCurtain: ObservableObject {
    static let shared = LaunchCurtain()
    private static let ink = UIColor(white: 0.06, alpha: 1)
    private var window: UIWindow?
    private var holder: UIView?      // the flood's frame and the cover's shadow
    private var flood: UIView?       // its colour, corners and the cover art
    private var spinner: UIActivityIndicatorView?
    private var heroView: UIImageView?
    private var origin: CGRect = .zero
    private var started = Date()
    private var gatherStarted = Date()
    /// The artwork the flood carries, for the starting screen too (the same pixels, so
    /// the hand-over changes nothing and waits for no download).
    @Published private(set) var coverImage: UIImage?
    @Published private(set) var heroImage: UIImage?
    private var imageAppID: Int?
    private var watch: Task<Void, Never>?
    private let enabled = MadeiraConfig.flag("MADEIRA_LAUNCH_FLOOD")   // 0: the starting screen fades in without growing out of the Play button

    /// The flood is up and has not been handed a cover yet.
    private(set) var covering = false
    private var gather: UIViewPropertyAnimator?
    /// Where the starting screen's cover is now: its layout can still move while the
    /// flood gathers (status lines arriving), and the flood lands where it ends up.
    private var latestTarget: CGRect = .zero
    func track(_ frame: CGRect) {
        guard window != nil else { return }
        latestTarget = frame
        // Mid-gather, a move blends into the running animation (UIKit animations of the
        // same property are additive), so the flood bends to the new frame instead of
        // landing and then correcting.
        if let gather, gather.isRunning, let h = holder {
            let left = max(0.15, Double(1 - gather.fractionComplete) * gather.duration)
            UIViewPropertyAnimator(duration: left, dampingRatio: 1) { h.frame = frame }.startAnimation()
        }
    }

    func cover(for appID: Int?) -> UIImage? { appID != nil && appID == imageAppID ? coverImage : nil }
    func hero(for appID: Int?) -> UIImage? { appID != nil && appID == imageAppID ? heroImage : nil }

    private func fetch(_ url: URL?, into keyPath: ReferenceWritableKeyPath<LaunchCurtain, UIImage?>, appID: Int) {
        guard let url else { return }
        Task { [weak self] in
            guard let fetched = try? await URLSession.shared.data(from: url), let img = UIImage(data: fetched.0),
                  let self, self.imageAppID == appID else { return }
            self[keyPath: keyPath] = img
            if keyPath == \LaunchCurtain.heroImage, let hv = self.heroView, hv.image == nil { hv.image = img }
        }
    }

    func begin(from frame: CGRect, appID: Int?, artwork: URL?) {
        guard enabled, !UIAccessibility.isReduceMotionEnabled, window == nil, !frame.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = UIWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        w.windowLevel = .normal + 150; w.backgroundColor = .clear
        let root = UIViewController(); root.view.backgroundColor = .clear
        w.rootViewController = root; w.isHidden = false   // never made key
        let h = UIView(frame: frame)
        h.layer.shadowColor = UIColor.black.cgColor; h.layer.shadowOpacity = 0
        let v = UIView(frame: h.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = .tintColor
        v.layer.cornerCurve = .continuous; v.clipsToBounds = true
        h.addSubview(v); root.view.addSubview(h)
        window = w; holder = h; flood = v; origin = frame; started = Date(); covering = true; latestTarget = .zero
        if let appID, appID != imageAppID {
            imageAppID = appID; coverImage = nil; heroImage = nil
            fetch(artwork, into: \.coverImage, appID: appID)
            fetch(SteamLaunchBackdrop.hero(appID), into: \.heroImage, appID: appID)
        } else if appID == nil {
            imageAppID = nil; coverImage = nil; heroImage = nil
        }
        let full = w.bounds.insetBy(dx: -2, dy: -2)
        let blob = CAKeyframeAnimation(keyPath: "cornerRadius")
        blob.values = [14, 56, 0]; blob.keyTimes = [0, 0.4, 1]; blob.duration = 0.5
        blob.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        v.layer.cornerRadius = 0
        v.layer.add(blob, forKey: "blob")
        UIViewPropertyAnimator(duration: 0.55, dampingRatio: 0.8) { h.frame = full }.startAnimation()
        UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { v.backgroundColor = Self.ink }.startAnimation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.covering, let root = self.window?.rootViewController?.view else { return }
            let s = UIActivityIndicatorView(style: .medium); s.color = .white
            s.center = CGPoint(x: root.bounds.midX, y: root.bounds.midY); s.alpha = 0
            root.addSubview(s); s.startAnimating(); self.spinner = s
            UIView.animate(withDuration: 0.3) { s.alpha = 1 }
        }
        watch = Task { [weak self] in await self?.watchStart() }
        fputs("[launch-curtain] flood from \(Int(frame.midX)),\(Int(frame.midY))\n", stderr)
    }

    /// How the starting screen draws its cover, for the flood to land looking the same.
    struct CoverStyle {
        var corner: CGFloat
        var shadowOpacity: Float
        var shadowRadius: CGFloat
        var shadowOffset: CGSize
    }

    /// The starting screen is laid out: once the flood has filled the screen, gather into
    /// its cover. `landed` runs when the flood sits on the cover, before the dissolve.
    func handOff(to cover: CGRect, style: CoverStyle, landed: @escaping () -> Void) {
        guard covering, let v = flood, let h = holder, let root = window?.rootViewController?.view else { landed(); return }
        covering = false
        let wait = max(0, 0.55 - Date().timeIntervalSince(started))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.gatherStarted = Date()
            if let s = self.spinner { UIView.animate(withDuration: 0.15) { s.alpha = 0 } }
            // The backdrop, under the flood: black, the hero image settling from a slight
            // zoom, and the starting screen's dimming over it.
            let back = UIView(frame: root.bounds); back.backgroundColor = .black
            let hv = UIImageView(image: self.heroImage)
            hv.frame = back.bounds; hv.contentMode = .scaleAspectFill; hv.clipsToBounds = true
            hv.alpha = 0; hv.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            let dim = UIView(frame: back.bounds); dim.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            back.addSubview(hv); back.addSubview(dim)
            root.insertSubview(back, belowSubview: h)
            self.heroView = hv
            UIView.animate(withDuration: 0.6, delay: 0.05, options: [.curveEaseOut]) { hv.alpha = 1 }
            UIView.animate(withDuration: 1.0, delay: 0, options: [.curveEaseOut]) { hv.transform = .identity }

            let screen = root.bounds
            let target = cover.isEmpty ? CGRect(x: screen.midX - 60, y: screen.midY - 90, width: 120, height: 180) : cover
            var art: UIImageView?
            if let image = self.coverImage {
                let iv = UIImageView(image: image)
                iv.contentMode = .scaleAspectFill; iv.frame = v.bounds; iv.alpha = 0
                iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.addSubview(iv); art = iv
            }
            // The cover's shadow comes in as the flood nears the cover.
            h.layer.shadowRadius = style.shadowRadius; h.layer.shadowOffset = style.shadowOffset
            h.layer.shadowOpacity = style.shadowOpacity
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = 0; shadow.toValue = style.shadowOpacity
            shadow.beginTime = CACurrentMediaTime() + 0.3; shadow.duration = 0.32
            shadow.fillMode = .backwards
            h.layer.add(shadow, forKey: "shadow")
            let gather = UIViewPropertyAnimator(duration: 0.62, controlPoint1: CGPoint(x: 0.6, y: 0), controlPoint2: CGPoint(x: 0.15, y: 1)) {
                h.frame = target; v.layer.cornerRadius = style.corner
            }
            gather.addCompletion { [weak self] _ in guard let self else { return }; self.gather = nil; self.settle(on: self.latestTarget.isEmpty ? target : self.latestTarget, landed: landed) }
            self.gather = gather
            gather.startAnimation()
            // The art comes in over the second half, once the flood is near the cover's size.
            if let art { UIView.animate(withDuration: 0.22, delay: 0.3, options: [.curveEaseOut]) { art.alpha = 1 } }
        }
    }

    /// The gather reached `target`. If the cover moved meanwhile, follow it; then let the
    /// backdrop finish settling and dissolve onto the starting screen.
    private func settle(on target: CGRect, landed: @escaping () -> Void) {
        guard let h = holder else { landed(); close(); return }
        let now = latestTarget
        let at = h.layer.presentation()?.frame ?? h.frame
        let moved = !now.isEmpty && (abs(now.midX - at.midX) > 1 || abs(now.midY - at.midY) > 1
                                     || abs(now.width - at.width) > 1 || abs(now.height - at.height) > 1)
        if moved {
            let follow = UIViewPropertyAnimator(duration: 0.3, curve: .easeOut) { h.frame = now }
            follow.addCompletion { [weak self] _ in self?.settle(on: now, landed: landed) }
            follow.startAnimation()
            return
        }
        landed()
        let rest = max(0.05, 1.0 - Date().timeIntervalSince(gatherStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) { [weak self] in
            UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut]) { self?.window?.alpha = 0 }
                completion: { _ in self?.close() }
        }
    }

    private func retract() {
        guard covering, let v = flood, let h = holder else { return }
        covering = false
        if let s = spinner { UIView.animate(withDuration: 0.15) { s.alpha = 0 } }
        let back = UIViewPropertyAnimator(duration: 0.45, dampingRatio: 1) { [origin] in
            h.frame = origin; v.layer.cornerRadius = 14; v.backgroundColor = .tintColor
        }
        back.addCompletion { [weak self] _ in
            UIView.animate(withDuration: 0.15) { self?.window?.alpha = 0 } completion: { _ in self?.close() }
        }
        back.startAnimation()
    }

    private func close() {
        watch?.cancel(); watch = nil
        window?.isHidden = true; window = nil; holder = nil; flood = nil; spinner = nil; heroView = nil; covering = false
        gather = nil
    }

    /// No start after the press: retract. A start whose starting screen never hands over:
    /// gather to the middle and fade.
    private func watchStart() async {
        let model = LibraryModel.shared
        while !Task.isCancelled, covering {
            try? await Task.sleep(for: .milliseconds(200))
            guard covering else { return }
            let t = Date().timeIntervalSince(started)
            if model.cloudNotice != nil || model.error != nil { retract(); return }
            if !model.startingScreen && model.current == nil && model.startingJIT == nil && t > 2.5 { retract(); return }
            if t > 4 { handOff(to: .zero, style: CoverStyle(corner: 14, shadowOpacity: 0, shadowRadius: 0, shadowOffset: .zero), landed: {}); return }
        }
    }
}
