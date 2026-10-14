// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct IridiumLibraryBackdrop: View {
    let game: IridiumGame?
    @ObservedObject private var artwork = IridiumArtworkModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @State private var image: UIImage?
    @State private var position = 0.5
    @State private var loading = false
    var body: some View {
        IridiumBackdropCanvas(image: opaque ? nil : image, isLoading: loading && !opaque,
                              position: position, reduceMotion: reduceMotion)
            .task(id: game.map { artwork.key($0) } ?? "empty") {
                guard let game else { image = nil; loading = false; return }
                loading = true
                let next = await artwork.image(for: game, backdrop: true)
                guard !Task.isCancelled else { return }
                position = artwork.appearance(game.id).backgroundY
                image = next; loading = false
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
    let reduceMotion: Bool
    func makeUIView(context: Context) -> Canvas { Canvas() }
    func updateUIView(_ view: Canvas, context: Context) {
        guard image != nil || !isLoading else { return }
        view.show(image, position: position, animated: !reduceMotion)
    }
    final class Canvas: UIView {
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
            for case let layer as ArtworkLayer in subviews { layer.frame = bounds }
        }
        private final class ArtworkLayer: UIView {
            let image: UIImage
            let position: Double
            private let artwork: UIImageView
            private let ambient: UIImageView
            private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))

            init(image: UIImage, position: Double) {
                self.image = image; self.position = position
                artwork = UIImageView(image: image); ambient = UIImageView(image: image)
                super.init(frame: .zero)
                clipsToBounds = true
                addSubview(ambient); addSubview(blur); addSubview(artwork)
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
            override func layoutSubviews() {
                super.layoutSubviews()
                let layout = IridiumBackdropLayout(imageSize: image.size, viewport: bounds.size, position: position)
                artwork.frame = layout.artworkFrame
                ambient.frame = layout.fillFrame; blur.frame = bounds
                ambient.isHidden = !layout.showsAmbient; blur.isHidden = !layout.showsAmbient
            }
        }
    }
}

/// Portrait retains the entire chosen background, without guessing its subject's
/// horizontal position. The same image fills the spare space behind a material.
/// The existing vertical position also places a fitted image within that space.
struct IridiumBackdropLayout {
    let artworkFrame: CGRect
    let fillFrame: CGRect
    let showsAmbient: Bool

    init(imageSize: CGSize, viewport: CGSize, position: Double) {
        showsAmbient = viewport.height > viewport.width
        func frame(scale: CGFloat) -> CGRect {
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            return CGRect(x: (viewport.width - size.width) / 2,
                          y: (viewport.height - size.height) * position,
                          width: size.width, height: size.height)
        }
        let horizontal = viewport.width / max(1, imageSize.width)
        let vertical = viewport.height / max(1, imageSize.height)
        fillFrame = frame(scale: max(horizontal, vertical))
        artworkFrame = showsAmbient ? frame(scale: min(horizontal, vertical)) : fillFrame
    }
}
