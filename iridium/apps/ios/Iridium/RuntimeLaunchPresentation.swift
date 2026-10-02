import Foundation
#if os(iOS)
import Darwin
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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
    static let chromeFadeDuration = 0.16
    static let artworkMoveDuration = 0.46
    static let revealDuration = 0.42
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

struct RuntimeMemorySnapshot {
    let usedBytes: UInt64
    let availableBytes: UInt64?

    static func sample() -> Self? {
        #if INTERFACE_PREVIEW
        // Include the expanding RAM meter in the existing simulator layout test.
        if ProcessInfo.processInfo.arguments.contains("--memory-budget") {
            return Self(usedBytes: 1_234_000_000, availableBytes: 5_208_000_000)
        }
        #endif
        #if os(iOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        #if targetEnvironment(simulator)
        return Self(usedBytes: info.phys_footprint, availableBytes: nil)
        #else
        return Self(usedBytes: info.phys_footprint, availableBytes: UInt64(os_proc_available_memory()))
        #endif
        #else
        return nil
        #endif
    }
}
