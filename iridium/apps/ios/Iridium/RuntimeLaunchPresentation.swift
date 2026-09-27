import Foundation

/// A projection of the existing session and renderer state, not a launch gate.
enum RuntimeLaunchPresentation: Equatable {
    case starting, playing, closing, failed, stopped, shutdownUnconfirmed

    static func resolve(isRunning: Bool, isFailed: Bool, isCompleted: Bool,
                        hasPresentedFrame: Bool, isClosing: Bool,
                        shutdownUnconfirmed: Bool) -> Self {
        if isClosing { return .closing }
        if shutdownUnconfirmed { return .shutdownUnconfirmed }
        if isFailed { return .failed }
        if isCompleted { return .stopped }
        return isRunning && hasPresentedFrame ? .playing : .starting
    }

    var showsArtwork: Bool { self != .playing }
    var isBusy: Bool { self == .starting || self == .closing }
    var title: String {
        switch self {
        case .starting: "Starting game…"
        case .playing: "Playing"
        case .closing: "Closing game…"
        case .failed: "Couldn’t start the game"
        case .stopped: "Game stopped"
        case .shutdownUnconfirmed: "Restart Iridium to continue"
        }
    }
    var message: String? {
        switch self {
        case .failed: "The game could not finish starting. Open Logs for details."
        case .stopped: "The game has ended. Your launch details are available in Logs."
        case .shutdownUnconfirmed: "The runtime did not confirm that it stopped. Close and reopen Iridium before playing again."
        default: nil
        }
    }
}

/// Ignore off-screen, stale or invalid layout measurements.
enum RuntimeLaunchGeometry {
    static func sourceFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect? {
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                      bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height]
        guard !frame.isNull, !frame.isInfinite, !bounds.isNull, !bounds.isInfinite,
              values.allSatisfy({ $0.isFinite }), frame.size.width > 1, frame.size.height > 1,
              bounds.size.width > 1, bounds.size.height > 1 else { return nil }
        let visible = frame.intersection(bounds)
        guard !visible.isNull, visible.width > 1, visible.height > 1 else { return nil }
        return visible
    }
}

/// Presentation timing never gates runtime startup or first-frame readiness.
enum RuntimeLaunchMotion {
    static let chromeFadeDuration = 0.22
    static let backdropDuration = 0.42
    static let revealDuration = 0.24

    static func scale(emphasized: Bool, reduceMotion: Bool) -> CGFloat {
        emphasized && !reduceMotion ? 1.03 : 1
    }
}

extension RuntimeLaunchGeometry {
    /// Retain the same crop/title only within the original viewport. Rotation,
    /// resizing, and a different scene use the destination's safe-area layout.
    static func retainedFrame(_ frame: CGRect?, sourceBounds: CGRect?, targetBounds: CGRect) -> CGRect? {
        guard let frame, let sourceBounds,
              abs(sourceBounds.width - targetBounds.width) < 1,
              abs(sourceBounds.height - targetBounds.height) < 1,
              let visible = sourceFrame(frame, in: sourceBounds),
              sourceFrame(targetBounds, in: targetBounds) != nil else { return nil }
        return visible.offsetBy(dx: targetBounds.minX - sourceBounds.minX,
                                dy: targetBounds.minY - sourceBounds.minY)
    }
}
