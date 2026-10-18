// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Current in-memory session only. Saved preferences and helper readiness do
/// not establish which CPU core the running engine selected.
struct IridiumExecutionStatus: Equatable {
    let runtime: String
    let mode: String
    let detail: String

    static let notRunning = Self(runtime: "None", mode: "Not running",
        detail: "No game session is running. Previous log entries may describe older sessions.")
    static let madeira = Self(runtime: "Madeira (Windows)", mode: "Unknown",
        detail: "Madeira does not report a verified execution mode for this session.")
}

extension IridiumConsoleSession {
    var executionStatus: IridiumExecutionStatus {
        guard let game, phase != .idle else { return .notRunning }
        let runtime = game.platform == .psp ? "PPSSPP (PSP)" : "SameBoy (Game Boy)"
        guard phase == .running || phase == .paused else {
            let detail = phase == .starting ? "Waiting for the running engine to report its CPU mode."
                : phase == .stopping ? "The runtime is stopping." : "The runtime requires an app restart."
            return .init(runtime: runtime, mode: "Unknown", detail: detail)
        }
        guard game.platform == .psp else {
            return .init(runtime: runtime, mode: "Unknown", detail: "This runtime does not report its execution mode here.")
        }
        guard pspReady else {
            return .init(runtime: runtime, mode: "Unknown", detail: "Waiting for PPSSPP to finish booting and report its CPU mode.")
        }
        guard nativePSPController != nil else {
            return .init(runtime: runtime, mode: "Not running", detail: "PPSSPP has closed.")
        }
        switch pspCPUMode {
        case "JIT", "JIT using IR":
            return .init(runtime: runtime, mode: "JIT active",
                detail: phase == .paused ? "PPSSPP selected its JIT CPU core. The game is paused." : "PPSSPP selected its JIT CPU core for this session.")
        case "Interpreter", "IR interpreter":
            return .init(runtime: runtime, mode: "Interpreter",
                detail: pspJITFallbackReason ?? "PPSSPP selected its interpreter CPU core for this session.")
        default:
            return .init(runtime: runtime, mode: "Unknown", detail: "PPSSPP has not reported a recognized CPU mode for this session.")
        }
    }
}
