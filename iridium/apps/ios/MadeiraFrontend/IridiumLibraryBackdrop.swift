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
    var body: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.7), location: 0),
                               .init(color: .black.opacity(0.55), location: 0.3),
                               .init(color: .black.opacity(0.12), location: 0.65),
                               .init(color: .black.opacity(0.55), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay { LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing) }
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
        private var target: CroppedImage?
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black; clipsToBounds = true }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func show(_ image: UIImage?, position: Double, animated: Bool) {
            guard target != nil || image != nil else { return }
            guard target?.image !== image || target?.position != position else { return }
            let hadImage = target != nil
            let layers = subviews.compactMap { $0 as? CroppedImage }
            var next = layers.first { $0.image === image && $0.position == position }
            if next == nil, let image {
                let layer = CroppedImage(image: image); layer.position = position; layer.alpha = 0
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
            for case let layer as CroppedImage in subviews {
                guard let image = layer.image else { continue }
                let scale = max(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                layer.frame = CGRect(x: (bounds.width - size.width) / 2,
                    y: (bounds.height - size.height) * layer.position, width: size.width, height: size.height)
            }
        }
        private final class CroppedImage: UIImageView { var position = 0.5 }
    }
}
