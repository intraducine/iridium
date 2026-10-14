// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumLibraryBackdrop: View {
    let game: IridiumGame?
    var portrait = false
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @State private var image: UIImage?
    @State private var position = 0.5
    @State private var loading = false
    var body: some View {
        IridiumBackdropCanvas(image: opaque ? nil : image, isLoading: loading && !opaque,
                              position: position, portrait: portrait, reduceMotion: reduceMotion)
            .task(id: (game.map { artwork.key($0) } ?? "empty") + (portrait ? ":portrait" : ":landscape")) {
                guard let game else { image = nil; loading = false; return }
                loading = true
                let next = portrait ? await artwork.portraitBackdrop(for: game) :
                    (await artwork.image(for: game, backdrop: true), artwork.appearance(game.id).backgroundY)
                guard !Task.isCancelled else { return }
                image = next.0; position = next.1; loading = false
            }
            .accessibilityHidden(true)
    }
}

struct IridiumBackdropScrim: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.40), location: 0),
                               .init(color: .black.opacity(0.04), location: 0.3),
                               .init(color: .black.opacity(0.12), location: 0.55),
                               .init(color: .black.opacity(0.90), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay { LinearGradient(colors: [.black.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing) }
            .overlay { Color.black.opacity(contrast == .increased ? 0.65 : dynamicTypeSize.isAccessibilitySize ? 0.55 : 0) }
            .allowsHitTesting(false)
    }
}

/// Reuses Iridium's original layered backdrop technique. The displayed image
/// survives a pending request; beginFromCurrentState handles rapid reversals.
struct IridiumBackdropCanvas: UIViewRepresentable {
    let image: UIImage?
    let isLoading: Bool
    let position: Double
    let portrait: Bool
    let reduceMotion: Bool
    func makeUIView(context: Context) -> Canvas { Canvas() }
    func updateUIView(_ view: Canvas, context: Context) {
        view.portrait = portrait; view.setNeedsLayout()
        guard image != nil || !isLoading else { return }
        view.show(image, position: position, animated: !reduceMotion)
    }
    final class Canvas: UIView {
        var portrait = false
        private var target: ArtworkLayer?
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black; clipsToBounds = true }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func show(_ image: UIImage?, position: Double, animated: Bool) {
            guard target != nil || image != nil else { return }
            guard target?.image !== image || target?.position != position else { return }
            let hadImage = target != nil
            let layers = subviews.compactMap { $0 as? ArtworkLayer }
            var next = layers.first { $0.image === image && $0.position == position }
            if next == nil, let image {
                let layer = ArtworkLayer(image: image, position: position); layer.alpha = 0
                addSubview(layer); next = layer
            }
            target = next; setNeedsLayout(); layoutIfNeeded()
            UIView.animate(withDuration: animated && hadImage ? 0.32 : 0, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
                for layer in self.subviews { layer.alpha = layer === next ? 1 : 0 }
            } completion: { [weak self] finished in
                guard finished, let self, self.target === next else { return }
                self.subviews.filter { $0 !== next }.forEach { $0.removeFromSuperview() }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            for case let layer as ArtworkLayer in subviews {
                layer.portrait = portrait; layer.frame = bounds; layer.setNeedsLayout()
            }
        }
        private final class ArtworkLayer: UIView {
            let image: UIImage
            let position: Double
            private let artwork: UIImageView
            var portrait = false
            private let hero = UIView()
            private let fade = CAGradientLayer()

            init(image: UIImage, position: Double) {
                self.image = image; self.position = position
                artwork = UIImageView(image: image)
                super.init(frame: .zero)
                backgroundColor = .black; clipsToBounds = true; hero.clipsToBounds = true
                fade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor]
                fade.locations = [0, 0.62, 1]
                addSubview(hero); hero.addSubview(artwork); hero.layer.addSublayer(fade)
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
            override func layoutSubviews() {
                super.layoutSubviews()
                let layout = IridiumBackdropLayout(imageSize: image.size, viewport: bounds.size,
                                                   position: position, portrait: portrait)
                // The image and gradient overlay crossfade as one ordinary layer;
                // no UIVisualEffectView is nested under animated alpha.
                CATransaction.begin(); CATransaction.setDisableActions(true)
                hero.frame = layout.heroFrame; artwork.frame = layout.artworkFrame
                fade.frame = hero.bounds; fade.isHidden = !portrait
                CATransaction.commit()
            }
        }
    }
}

/// A substantial portrait hero fades into the controls. Landscape retains its
/// original full-viewport crop. Both use the saved position of the chosen slot.
struct IridiumBackdropLayout {
    let artworkFrame: CGRect
    let heroFrame: CGRect

    init(imageSize: CGSize, viewport: CGSize, position: Double, portrait: Bool) {
        let height = portrait ? min(viewport.height * 0.78, viewport.width * 1.5) : viewport.height
        heroFrame = CGRect(x: 0, y: 0, width: viewport.width, height: height)
        let scale = max(viewport.width / max(1, imageSize.width), height / max(1, imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        artworkFrame = CGRect(x: (viewport.width - size.width) / 2,
                              y: (height - size.height) * position,
                              width: size.width, height: size.height)
    }
}
