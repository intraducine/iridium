import Foundation

struct RuntimeViewportGeometry {
    static func aspectFitFrame(
        in bounds: CGRect,
        bottomOcclusion: CGFloat,
        surfaceSize: CGSize
    ) -> CGRect {
        guard bottomOcclusion > 0 else { return bounds }

        let occlusion = min(max(bottomOcclusion, 0), max(bounds.height - 1, 0))
        let available = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(bounds.height - occlusion, 1)
        )
        guard available.width > 0, surfaceSize.width > 0, surfaceSize.height > 0 else {
            return available
        }

        let scale = min(available.width / surfaceSize.width, available.height / surfaceSize.height)
        let width = max(surfaceSize.width * scale, 1)
        let height = max(surfaceSize.height * scale, 1)
        return CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func normalizedPoint(_ point: CGPoint, in viewport: CGRect) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        return CGPoint(
            x: min(max((point.x - viewport.minX) / viewport.width, 0), 1),
            y: min(max((point.y - viewport.minY) / viewport.height, 0), 1)
        )
    }
}
