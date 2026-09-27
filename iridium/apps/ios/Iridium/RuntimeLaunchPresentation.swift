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
    static let chromeFadeDuration = 0.18
    static let heroDuration = 0.46
    static let revealDuration = 0.50
}

extension RuntimeLaunchGeometry {
    /// Retain source geometry only within the original viewport.
    static func retainedFrame(_ frame: CGRect?, sourceBounds: CGRect?, targetBounds: CGRect) -> CGRect? {
        guard let frame, let sourceBounds,
              abs(sourceBounds.width - targetBounds.width) < 1,
              abs(sourceBounds.height - targetBounds.height) < 1,
              let visible = sourceFrame(frame, in: sourceBounds),
              sourceFrame(targetBounds, in: targetBounds) != nil else { return nil }
        return visible.offsetBy(dx: targetBounds.minX - sourceBounds.minX,
                                dy: targetBounds.minY - sourceBounds.minY)
    }

    /// A partially clipped poster must not be stretched as though it were whole.
    static func wholeFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect? {
        guard let visible = sourceFrame(frame, in: bounds), visible == frame else { return nil }
        return frame
    }
}

/// Freeze outgoing chrome, not launch eligibility. A nil detail stays nil rather
/// than introducing a new status row and changing the shelf's height after Play.
struct RuntimeLaunchChrome: Equatable {
    let gameID: UUID
    let label: String
    let detail: String?
    let controllerHints: Bool
}

/// Landscape uses a poster at the left and text at its upper right. Narrow or
/// accessibility layouts keep the title above the poster, at the same left edge,
/// so the two elements do not cross through each other while moving.
struct RuntimeLaunchHeroLayout: Equatable {
    let cover: CGRect?
    let text: CGRect
    let sideBySide: Bool

    static func resolve(in bounds: CGRect, safeTop: CGFloat, safeLeading: CGFloat,
                        safeBottom: CGFloat, safeTrailing: CGFloat,
                        hasCover: Bool, accessibility: Bool, textHeight: CGFloat = 80) -> Self {
        // GeometryReader can briefly report an empty frame during rotation.
        let width = bounds.width.isFinite ? max(1, bounds.width) : 1
        let height = bounds.height.isFinite ? max(1, bounds.height) : 1
        func inset(_ value: CGFloat, limit: CGFloat) -> CGFloat {
            value.isFinite ? min(limit, max(0, value)) : 0
        }
        let leading = inset(safeLeading, limit: width / 4)
        let trailing = inset(safeTrailing, limit: width / 4)
        let top = inset(safeTop, limit: height / 4)
        let bottom = inset(safeBottom, limit: height / 4)
        let sideBySide = width > height && width - leading - trailing >= 500 && !accessibility
        let margin: CGFloat = sideBySide ? 32 : 24
        let left = min(width / 3, leading + margin)
        let right = min(width / 3, trailing + margin)
        let contentWidth = max(1, width - left - right)
        let y = top + 76 // Keep the existing player menu clear of the hero.
        let availableHeight = max(1, height - y - bottom - 24)
        let gap: CGFloat = sideBySide ? 28 : 22
        let columnHeight = textHeight.isFinite ? max(1, textHeight) : 80
        var cover: CGRect?
        if hasCover {
            let coverHeight: CGFloat
            if sideBySide {
                coverHeight = min(300, availableHeight, contentWidth * 0.30 * 1.5)
            } else {
                coverHeight = min(accessibility ? 180 : 300, max(144, availableHeight - columnHeight - gap), contentWidth * 0.56 * 1.5)
            }
            cover = CGRect(x: left, y: sideBySide ? y : y + columnHeight + gap,
                           width: coverHeight * 2 / 3, height: coverHeight)
        }
        let textX = sideBySide ? (cover.map { $0.maxX + gap } ?? left) : left
        let textY = y
        return Self(cover: cover,
                    text: CGRect(x: textX, y: textY, width: max(1, width - right - textX),
                                 height: columnHeight),
                    sideBySide: sideBySide)
    }
}
