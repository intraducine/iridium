import Foundation
import IridiumCore

public struct NativeBridgeProcessingReport: Codable, Hashable, Sendable {
    public var runtimeRequestsHandled: Int
    public var steamRequestsHandled: Int
    public var generatedAt: Date

    public init(runtimeRequestsHandled: Int, steamRequestsHandled: Int, generatedAt: Date = Date()) {
        self.runtimeRequestsHandled = runtimeRequestsHandled
        self.steamRequestsHandled = steamRequestsHandled
        self.generatedAt = generatedAt
    }
}

public struct NativeBridgeService: Sendable {
    private let runtimeConfiguration: RuntimeHostBridgeConfiguration
    private let steamConfiguration: SteamBridgeConfiguration
    private let runtimeBackend: NativeRuntimeHostBackend
    private let runtimeHostController: any RuntimeHostController
    private let runtimeMonitor: any RuntimeExecutionMonitor
    private let runtimeTelemetryCollector: any RuntimeTelemetryCollector
    private let steamSessionStore: any SteamSessionStore
    private let steamAuthClient: any SteamAuthClient
    private let steamCatalogClient: any SteamCatalogClient
    private let steamManifestClient: any SteamDepotManifestClient
    private let steamContentClient: any SteamContentServerClient
    private let steamVerificationService: any DepotVerificationService

    public init(
        runtimeConfiguration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration(),
        runtimeBackendClient: any RuntimeBackendClient = RuntimeBackendSelection.makeBackendClient(),
        steamConfiguration: SteamBridgeConfiguration = SteamBridgeConfiguration()
    ) {
        self.runtimeConfiguration = runtimeConfiguration
        self.steamConfiguration = steamConfiguration
        let runtimeBackend = NativeRuntimeHostBackend(backendClient: runtimeBackendClient)
        self.runtimeBackend = runtimeBackend
        self.runtimeHostController = FileSystemRuntimeHostController(backendClient: runtimeBackendClient)
        self.runtimeMonitor = FileSystemRuntimeExecutionMonitor(backendClient: runtimeBackendClient)
        self.runtimeTelemetryCollector = FileSystemRuntimeTelemetryCollector(backendClient: runtimeBackendClient)

        let bridgeSessionStore = FileSystemSteamSessionStore(
            rootURL: steamConfiguration.rootURL.appending(path: "sessions", directoryHint: .isDirectory)
        )
        self.steamSessionStore = bridgeSessionStore
        self.steamAuthClient = HostedSteamAuthClient(sessionStore: bridgeSessionStore)
        self.steamCatalogClient = HostedSteamCatalogClient()
        self.steamManifestClient = HostedSteamDepotManifestClient()
        self.steamContentClient = HostedSteamContentServerClient()
        self.steamVerificationService = HostedDepotVerificationService()
    }

    public func processAll() async throws -> NativeBridgeProcessingReport {
        let runtimeHandled = try await processRuntimeRequests()
        let steamHandled = try await processSteamRequests()
        try writeHeartbeat()
        return NativeBridgeProcessingReport(
            runtimeRequestsHandled: runtimeHandled,
            steamRequestsHandled: steamHandled
        )
    }

    @discardableResult
    public func processRuntimeRequests() async throws -> Int {
        try FileManager.default.createDirectory(
            at: runtimeConfiguration.requestsRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtimeConfiguration.responsesRootURL,
            withIntermediateDirectories: true
        )

        var handled = 0
        for requestURL in try bridgeRequestFiles(in: runtimeConfiguration.requestsRootURL, prefix: "launch-") {
            let ticket = try decode(RuntimeLaunchTicket.self, from: requestURL)
            let sessionResponseURL = runtimeConfiguration.responsesRootURL.appending(path: "session-\(ticket.id).json")
            let telemetryResponseURL = runtimeConfiguration.responsesRootURL.appending(path: "telemetry-\(ticket.id).json")
            let session: RuntimeHostSession

            if let existing = try? decode(RuntimeHostSession.self, from: sessionResponseURL) {
                if existing.state == .completed || existing.state == .failed {
                    session = existing
                } else {
                    session = try await runtimeBackend.advance(session: existing)
                }
            } else {
                let submission = await runtimeHostController.submit(ticket: ticket)
                switch submission {
                case let .success(value):
                    session = value
                case let .failure(failure):
                    session = RuntimeHostSession(
                        id: ticket.id,
                        gameID: ticket.gameID,
                        gameTitle: ticket.gameTitle,
                        launchTicketPath: requestURL.path,
                        sessionLogPath: sessionResponseURL.deletingPathExtension().appendingPathExtension("log").path,
                        telemetryPath: telemetryResponseURL.path,
                        runtimeBundleID: ticket.runtimeBundleID,
                        runtimeBundleVersion: ticket.runtimeBundleVersion,
                        state: .failed,
                        stateHistory: [.queued, .failed],
                        statusSummary: failure.reason,
                        failureCode: failure.code,
                        failureReason: failure.reason
                    )
                }
            }

            try encode(session, to: sessionResponseURL)
            if let telemetry = session.lastTelemetry {
                try encode(telemetry, to: telemetryResponseURL)
            } else if session.state == .completed || session.state == .failed {
                if let telemetry = await runtimeTelemetryCollector.collect(
                    for: session,
                    policy: RuntimePolicy(
                        memoryBudgetClass: .balanced,
                        resolutionScale: 1.0,
                        framePacingCap: 60,
                        shaderStrategy: .onDemand
                    )
                ) {
                    try encode(telemetry, to: telemetryResponseURL)
                }
            }
            handled += 1
        }

        try writeRuntimeHeartbeat()
        return handled
    }

    @discardableResult
    public func processSteamRequests() async throws -> Int {
        try FileManager.default.createDirectory(
            at: steamConfiguration.requestsRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: steamConfiguration.responsesRootURL,
            withIntermediateDirectories: true
        )

        var handled = 0
        handled += try await processSteamAuthRequests()
        handled += try await processSteamSignOutRequests()
        handled += try await processSteamLibraryRequests()
        handled += try processSteamPlanRequests()
        handled += try processSteamManifestRequests()
        handled += try await processSteamTransferRequests()
        handled += try await processSteamVerificationRequests()
        try writeSteamHeartbeat()
        return handled
    }

    private func processSteamAuthRequests() async throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "auth-") {
            let request = try decode(SteamBridgeAuthRequest.self, from: requestURL)
            let account = await steamAuthClient.authenticate(accountName: request.accountName)
            let session = await steamSessionStore.session(reference: account.sessionReference ?? "")
                ?? SteamSessionRecord(
                    id: account.sessionReference ?? UUID().uuidString,
                    accountName: account.accountName
                )
            try encode(session, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func processSteamSignOutRequests() async throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "signout-") {
            let request = try decode(SteamBridgeSignOutRequest.self, from: requestURL)
            await steamSessionStore.closeSession(reference: request.sessionReference)
            try encode(SteamAuthState.signedOut, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func processSteamLibraryRequests() async throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "library-") {
            let account = try? decode(SteamAccount?.self, from: requestURL)
            let library = await steamCatalogClient.syncLibrary(for: account ?? nil)
            try encode(library, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func processSteamPlanRequests() throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "install-plan-") {
            let request = try decode(SteamBridgeInstallPlanRequest.self, from: requestURL)
            let entry = SteamLibraryEntry(
                title: request.title ?? request.appID,
                appID: request.appID,
                installed: false,
                cloudSavesEnabled: true,
                lastSyncedAt: Date()
            )
            let plan = steamManifestClient.installPlan(for: entry, targetPath: request.targetPath)
            try encode(plan, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func processSteamManifestRequests() throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "manifest-") {
            let entry = try decode(SteamLibraryEntry.self, from: requestURL)
            let manifest = steamManifestClient.manifest(for: entry)
            try encode(manifest, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func processSteamTransferRequests() async throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "transfer-") {
            let request = try decode(SteamBridgeTransferRequest.self, from: requestURL)
            let response = await steamContentClient.transfer(depot: request.depot, into: request.execution)
            try encode(
                SteamBridgeTransferResponse(
                    bytesTransferred: response.bytesTransferred,
                    resumeCheckpoint: response.resumeCheckpoint
                ),
                to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent)
            )
            handled += 1
        }
        return handled
    }

    private func processSteamVerificationRequests() async throws -> Int {
        var handled = 0
        for requestURL in try bridgeRequestFiles(in: steamConfiguration.requestsRootURL, prefix: "verify-") {
            let request = try decode(SteamBridgeVerificationRequest.self, from: requestURL)
            let execution = await steamVerificationService.verify(
                execution: request.execution,
                manifest: request.manifest
            )
            try encode(execution, to: steamConfiguration.responsesRootURL.appending(path: requestURL.lastPathComponent))
            handled += 1
        }
        return handled
    }

    private func writeHeartbeat() throws {
        try writeRuntimeHeartbeat()
        try writeSteamHeartbeat()
    }

    private func writeRuntimeHeartbeat() throws {
        try encode(
            BridgeHeartbeatStatus(lastUpdatedAt: Date(), serviceName: "IridiumBridgeHost"),
            to: runtimeConfiguration.rootURL.appending(path: "bridge-status.json")
        )
    }

    private func writeSteamHeartbeat() throws {
        try encode(
            BridgeHeartbeatStatus(lastUpdatedAt: Date(), serviceName: "IridiumBridgeHost"),
            to: steamConfiguration.rootURL.appending(path: "bridge-status.json")
        )
    }
}

public struct BridgeHeartbeatStatus: Codable, Hashable, Sendable {
    public var lastUpdatedAt: Date
    public var serviceName: String

    public init(lastUpdatedAt: Date, serviceName: String) {
        self.lastUpdatedAt = lastUpdatedAt
        self.serviceName = serviceName
    }
}

private struct SteamBridgeAuthRequest: Codable, Sendable {
    let accountName: String
}

private struct SteamBridgeSignOutRequest: Codable, Sendable {
    let sessionReference: String?
}

private struct SteamBridgeInstallPlanRequest: Codable, Sendable {
    let appID: String
    let targetPath: String
    let title: String?
}

private struct SteamBridgeTransferRequest: Codable, Sendable {
    let depot: SteamDepotManifest
    let execution: InstallExecutionRecord
}

private struct SteamBridgeTransferResponse: Codable, Sendable {
    let bytesTransferred: Int64
    let resumeCheckpoint: String
}

private struct SteamBridgeVerificationRequest: Codable, Sendable {
    let execution: InstallExecutionRecord
    let manifest: SteamManifestResolution
}

private func bridgeRequestFiles(in root: URL, prefix: String) throws -> [URL] {
    let urls = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    )
    return urls
        .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
}
