import Foundation
import IridiumRuntimeHostSDK

public enum RuntimePlayerServiceKind: String, CaseIterable, Sendable {
    case render
    case input
    case audio

    var hostValue: IridiumRuntimeHostPlayableServiceKind {
        switch self {
        case .render:
            return IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_RENDER
        case .input:
            return IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_INPUT
        case .audio:
            return IRIDIUM_RUNTIME_HOST_PLAYABLE_SERVICE_AUDIO
        }
    }

    var displayName: String {
        switch self {
        case .render:
            return "render"
        case .input:
            return "input"
        case .audio:
            return "audio"
        }
    }
}

public struct RuntimePlayerServiceDescriptor: Hashable, Sendable {
    public var kind: RuntimePlayerServiceKind
    public var handle: String
    public var metadata: String?

    public init(kind: RuntimePlayerServiceKind, handle: String, metadata: String? = nil) {
        self.kind = kind
        self.handle = handle
        self.metadata = metadata
    }
}

public struct RuntimePlayerReservation: Hashable, Sendable {
    public var sessionIdentifier: String
    public var runtimeBundleRootPath: String
    public var userlandRootPath: String?
    public var hostLogPath: String
    public var services: [RuntimePlayerServiceDescriptor]

    public init(
        sessionIdentifier: String,
        runtimeBundleRootPath: String,
        userlandRootPath: String? = nil,
        hostLogPath: String,
        services: [RuntimePlayerServiceDescriptor]
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.runtimeBundleRootPath = runtimeBundleRootPath
        self.userlandRootPath = userlandRootPath
        self.hostLogPath = hostLogPath
        self.services = services
    }
}

public protocol RuntimePlayerServiceRegistry: Sendable {
    func reserve(_ reservation: RuntimePlayerReservation) -> Result<Void, RuntimeFailure>
    func setServiceLiveness(
        sessionIdentifier: String,
        serviceKind: RuntimePlayerServiceKind,
        isLive: Bool
    ) -> Result<Void, RuntimeFailure>
    func recordFirstFramePresented(sessionIdentifier: String) -> Result<Void, RuntimeFailure>
    func release(sessionIdentifier: String)
}

public extension RuntimePlayerServiceRegistry {
    func recordFirstFramePresented(sessionIdentifier _: String) -> Result<Void, RuntimeFailure> {
        .success(())
    }
}

public struct NativeRuntimePlayerServiceRegistry: RuntimePlayerServiceRegistry {
    public init() {}

    public func reserve(_ reservation: RuntimePlayerReservation) -> Result<Void, RuntimeFailure> {
        let acquireStatus = withRuntimePlayerUserlandRoot(reservation.userlandRootPath) {
            reservation.sessionIdentifier.withCString { sessionID in
                reservation.runtimeBundleRootPath.withCString { bundleRoot in
                    reservation.hostLogPath.withCString { hostLogPath in
                        var cReservation = IridiumRuntimeHostPlayableSessionReservation(
                            session_identifier: sessionID,
                            runtime_bundle_root_path: bundleRoot,
                            host_log_path: hostLogPath
                        )
                        return iridium_runtime_host_acquire_playable_session(&cReservation)
                    }
                }
            }
        }

        guard acquireStatus == 0 else {
            return .failure(
                registrationFailure(
                    statusCode: acquireStatus,
                    action: "reserve the playable runtime session",
                    serviceKind: nil,
                    sessionIdentifier: reservation.sessionIdentifier
                )
            )
        }

        RuntimePlayerUserlandRootStore.shared.set(
            reservation.userlandRootPath,
            for: reservation.sessionIdentifier
        )

        for service in reservation.services {
            let status = withRuntimePlayerUserlandRoot(reservation.userlandRootPath) {
                reservation.sessionIdentifier.withCString { sessionID in
                    service.handle.withCString { handle in
                        let metadata = service.metadata ?? ""
                        return metadata.withCString { metadataCString in
                            var cRegistration = IridiumRuntimeHostPlayableServiceRegistration(
                                session_identifier: sessionID,
                                service_kind: service.kind.hostValue,
                                service_handle: handle,
                                service_metadata: metadataCString
                            )
                            return iridium_runtime_host_register_playable_service(&cRegistration)
                        }
                    }
                }
            }

            guard status == 0 else {
                release(sessionIdentifier: reservation.sessionIdentifier)
                return .failure(
                    registrationFailure(
                        statusCode: status,
                        action: "register playable services",
                        serviceKind: service.kind,
                        sessionIdentifier: reservation.sessionIdentifier
                    )
                )
            }
        }

        return .success(())
    }

    public func setServiceLiveness(
        sessionIdentifier: String,
        serviceKind: RuntimePlayerServiceKind,
        isLive: Bool
    ) -> Result<Void, RuntimeFailure> {
        let userlandRootPath = RuntimePlayerUserlandRootStore.shared.path(for: sessionIdentifier)
        let status = withRuntimePlayerUserlandRoot(userlandRootPath) {
            sessionIdentifier.withCString { sessionID in
                var cLiveness = IridiumRuntimeHostPlayableServiceLiveness(
                    session_identifier: sessionID,
                    service_kind: serviceKind.hostValue,
                    service_live: isLive ? 1 : 0
                )
                return iridium_runtime_host_set_playable_service_liveness(&cLiveness)
            }
        }

        guard status == 0 else {
            return .failure(
                registrationFailure(
                    statusCode: status,
                    action: isLive ? "mark playable services live" : "mark playable services offline",
                    serviceKind: serviceKind,
                    sessionIdentifier: sessionIdentifier
                )
            )
        }

        return .success(())
    }

    public func release(sessionIdentifier: String) {
        let userlandRootPath = RuntimePlayerUserlandRootStore.shared.path(for: sessionIdentifier)
        let status = withRuntimePlayerUserlandRoot(userlandRootPath) {
            sessionIdentifier.withCString { sessionID in
                iridium_runtime_host_release_playable_session(sessionID)
            }
        }
        RuntimePlayerUserlandRootStore.shared.remove(sessionIdentifier)
        print(
            "[IridiumRuntime] runtimePlayerRegistry: releaseCompleted session=\(sessionIdentifier) status=\(status)"
        )
    }

    public func recordFirstFramePresented(
        sessionIdentifier: String
    ) -> Result<Void, RuntimeFailure> {
        let status = sessionIdentifier.withCString { sessionID in
            iridium_runtime_host_record_launch_milestone(
                sessionID,
                IRIDIUM_RUNTIME_HOST_MILESTONE_FIRST_FRAME_PRESENTED
            )
        }
        guard status == 0 else {
            return .failure(
                registrationFailure(
                    statusCode: status,
                    action: "record the first guest frame milestone",
                    serviceKind: nil,
                    sessionIdentifier: sessionIdentifier
                )
            )
        }
        return .success(())
    }

    private func registrationFailure(
        statusCode: Int32,
        action: String,
        serviceKind: RuntimePlayerServiceKind?,
        sessionIdentifier: String
    ) -> RuntimeFailure {
        let subject = serviceKind.map { "\($0.displayName) service" } ?? "playable runtime session"
        let reason: String
        switch statusCode {
        case 65:
            reason = "Another fullscreen runtime session already owns the host service registry."
        case 66:
            reason = "The runtime player registry is bound to a different session than \(sessionIdentifier)."
        case 67:
            reason = "The \(subject) is already registered for a different live handle."
        default:
            reason = "Runtime host could not \(action) for session \(sessionIdentifier)."
        }

        return RuntimeFailure(
            code: .runtimeBootFailed,
            reason: reason,
            recoverySuggestion: "Dismiss the current player session or restart the runtime host before retrying."
        )
    }
}

public enum RuntimeAppStagedUserlandRoot {
    public static func rootPath(in bundle: Bundle = .main) -> String? {
        let candidate = bundle.bundleURL.appending(
            path: "IridiumWineUserland", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate.path
    }
}

private final class RuntimePlayerUserlandRootStore: @unchecked Sendable {
    static let shared = RuntimePlayerUserlandRootStore()

    private let lock = NSLock()
    private var roots: [String: String] = [:]

    func set(_ path: String?, for sessionIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        if let path, !path.isEmpty {
            roots[sessionIdentifier] = path
        } else {
            roots.removeValue(forKey: sessionIdentifier)
        }
    }

    func path(for sessionIdentifier: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return roots[sessionIdentifier]
    }

    func remove(_ sessionIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        roots.removeValue(forKey: sessionIdentifier)
    }
}

private func withRuntimePlayerUserlandRoot<Result>(
    _ userlandRootPath: String?,
    operation: () -> Result
) -> Result {
    guard let userlandRootPath, !userlandRootPath.isEmpty else {
        return operation()
    }

    let previous = getenv("IRIDIUM_USERLAND_ROOT").map { String(cString: $0) }
    setenv("IRIDIUM_USERLAND_ROOT", userlandRootPath, 1)
    defer {
        if let previous {
            setenv("IRIDIUM_USERLAND_ROOT", previous, 1)
        } else {
            unsetenv("IRIDIUM_USERLAND_ROOT")
        }
    }
    return operation()
}

public protocol RuntimeRunningSessionObserver: Sendable {
    func resolveTerminalState(
        from execution: RuntimeSessionResult,
        gameID: UUID,
        gameTitle: String
    ) async -> RuntimeHostSession
}

public struct FileSystemRuntimeRunningSessionObserver: RuntimeRunningSessionObserver {
    private let executionMonitor: any RuntimeExecutionMonitor
    private let pollInterval: Duration

    public init(
        executionMonitor: any RuntimeExecutionMonitor = FileSystemRuntimeExecutionMonitor(),
        pollInterval: Duration = .seconds(1)
    ) {
        self.executionMonitor = executionMonitor
        self.pollInterval = pollInterval
    }

    public func resolveTerminalState(
        from execution: RuntimeSessionResult,
        gameID: UUID,
        gameTitle: String
    ) async -> RuntimeHostSession {
        let state = RuntimeHostSessionState(rawValue: execution.terminalStatus) ?? .running
        let history = execution.stateHistory.compactMap(RuntimeHostSessionState.init(rawValue:))
        var observedSession = RuntimeHostSession(
            id: execution.sessionIdentifier,
            gameID: gameID,
            gameTitle: gameTitle,
            launchTicketPath: execution.launchTicketPath,
            sessionLogPath: execution.sessionLogPath,
            telemetryPath: execution.telemetryPath,
            runtimeBundleID: execution.runtimeBundleID,
            runtimeBundleVersion: execution.runtimeBundleVersion,
            state: state,
            stateHistory: history.isEmpty ? [state] : history,
            statusSummary: "Runtime host session \(execution.sessionIdentifier) reported \(execution.terminalStatus).",
            startedAt: execution.launchedAt,
            updatedAt: execution.launchedAt
        )

        while !Task.isCancelled {
            let terminalSession = await executionMonitor.resolveTerminalState(for: observedSession)
            if terminalSession.state.isTerminal {
                return terminalSession
            }

            observedSession = terminalSession
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                break
            }
        }

        return observedSession
    }
}
