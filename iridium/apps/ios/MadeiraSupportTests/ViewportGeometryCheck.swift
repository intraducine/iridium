import Foundation

@main
struct ViewportGeometryCheck {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 844, height: 390)
        let surface = CGSize(width: 1920, height: 1080)
        precondition(RuntimeViewportGeometry.aspectFitFrame(in: bounds, bottomOcclusion: 0, surfaceSize: surface) == bounds)

        let viewport = RuntimeViewportGeometry.aspectFitFrame(
            in: bounds,
            bottomOcclusion: 190,
            surfaceSize: surface
        )
        precondition(viewport.maxY <= 200.0001)
        precondition(abs(viewport.width / viewport.height - 16.0 / 9.0) < 0.0001)
        precondition(abs(viewport.midX - bounds.midX) < 0.0001)

        let center = RuntimeViewportGeometry.normalizedPoint(
            CGPoint(x: viewport.midX, y: viewport.midY),
            in: viewport
        )
        precondition(abs(center.x - 0.5) < 0.0001 && abs(center.y - 0.5) < 0.0001)

        let clamped = RuntimeViewportGeometry.normalizedPoint(
            CGPoint(x: viewport.minX - 50, y: viewport.maxY + 50),
            in: viewport
        )
        precondition(clamped.x == 0 && clamped.y == 1)

        print("PASS device keyboard viewport aspect fit and input remapping")
    }
}
