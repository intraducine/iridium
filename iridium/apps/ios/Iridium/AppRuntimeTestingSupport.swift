import Foundation
import IridiumCore
import IridiumRuntime

struct NoopRuntimePlayerServiceRegistry: RuntimePlayerServiceRegistry {
    func reserve(_ reservation: RuntimePlayerReservation) -> Result<Void, RuntimeFailure> {
        _ = reservation
        return .success(())
    }

    func setServiceLiveness(
        sessionIdentifier: String,
        serviceKind: RuntimePlayerServiceKind,
        isLive: Bool
    ) -> Result<Void, RuntimeFailure> {
        _ = sessionIdentifier
        _ = serviceKind
        _ = isLive
        return .success(())
    }

    func release(sessionIdentifier: String) {
        _ = sessionIdentifier
    }
}

struct StaticRuntimeRunningSessionObserver: RuntimeRunningSessionObserver {
    let terminalState: RuntimeHostSessionState

    func resolveTerminalState(
        from execution: RuntimeSessionResult,
        gameID: UUID,
        gameTitle: String
    ) async -> RuntimeHostSession {
        RuntimeHostSession(
            id: execution.sessionIdentifier,
            gameID: gameID,
            gameTitle: gameTitle,
            launchTicketPath: execution.launchTicketPath,
            sessionLogPath: execution.sessionLogPath,
            telemetryPath: execution.telemetryPath,
            runtimeBundleID: execution.runtimeBundleID,
            runtimeBundleVersion: execution.runtimeBundleVersion,
            state: terminalState,
            stateHistory: execution.stateHistory.compactMap(RuntimeHostSessionState.init(rawValue:))
                + [terminalState],
            statusSummary: "Observed terminal state \(terminalState.rawValue).",
            startedAt: execution.launchedAt,
            updatedAt: Date()
        )
    }
}
