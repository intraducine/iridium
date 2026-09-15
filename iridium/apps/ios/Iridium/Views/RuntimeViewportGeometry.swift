import Foundation

struct RuntimeViewportGeometry {
    static func aspectFitFrame(in bounds: CGRect, bottomOcclusion: CGFloat, surfaceSize: CGSize) -> CGRect {
        guard bottomOcclusion.isFinite, bottomOcclusion > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let height = max(1, bounds.height - min(bottomOcclusion, bounds.height - 1))
        let available = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        guard surfaceSize.width.isFinite, surfaceSize.height.isFinite,
              surfaceSize.width > 0, surfaceSize.height > 0 else { return available }
        let scale = min(available.width / surfaceSize.width, available.height / surfaceSize.height)
        let size = CGSize(width: surfaceSize.width * scale, height: surfaceSize.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func bottomOcclusion(keyboard: CGRect, bounds: CGRect) -> CGFloat {
        let overlap = bounds.intersection(keyboard)
        guard !overlap.isNull, !overlap.isEmpty, overlap.maxY >= bounds.maxY - 1,
              overlap.width >= bounds.width * 0.8 else { return 0 }
        return overlap.height
    }

    static func normalizedPoint(_ point: CGPoint, in viewport: CGRect) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0, point.x.isFinite, point.y.isFinite else { return .zero }
        return CGPoint(x: min(1, max(0, (point.x - viewport.minX) / viewport.width)),
                       y: min(1, max(0, (point.y - viewport.minY) / viewport.height)))
    }
}

/// Focus is requested on ownership transitions, not on periodic frame-counter updates.
struct RuntimeInputFocusPolicy {
    enum Owner: Equatable { case none, game, keyboard }
    private(set) var owner: Owner = .none
    mutating func update(inputEnabled: Bool, keyboard: Bool) -> Bool {
        let next: Owner = inputEnabled ? (keyboard ? .keyboard : .game) : .none
        guard next != owner else { return false }
        owner = next
        return true
    }
}
