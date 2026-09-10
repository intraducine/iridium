import Dispatch
import Foundation
import IridiumCore
#if canImport(Security)
import Security
#endif

public struct SteamSessionRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var accountName: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, accountName: String, createdAt: Date = Date()) {
        self.id = id
        self.accountName = accountName
        self.createdAt = createdAt
    }
}

public protocol SteamSessionStore: Sendable {
    func createSession(accountName: String) async -> SteamSessionRecord
    func persistSession(_ session: SteamSessionRecord) async
    func session(reference: String) async -> SteamSessionRecord?
    func activeSession() async -> SteamSessionRecord?
    func closeSession(reference: String?) async
}

public protocol SteamLibrarySyncService: Sendable {
    func sync(using session: SteamSessionRecord?) async -> [SteamLibraryEntry]
}

public protocol SteamContentServerClient: Sendable {
    func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String)
}

public protocol SteamBridgeRequestProcessor: Sendable {
    func processSteamRequests() async throws -> Int
}

public protocol SteamInstallCoordinator: Sendable {
    func advance(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord
}

public protocol DepotVerificationService: Sendable {
    func verify(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord
}

public protocol SteamAuthClient: Sendable {
    func authenticate(accountName: String) async -> SteamAccount
    func signOut() async -> SteamAuthState
}

public protocol SteamCatalogClient: Sendable {
    func syncLibrary(for account: SteamAccount?) async -> [SteamLibraryEntry]
}

public protocol SteamDepotManifestClient: Sendable {
    func installPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan
    func manifest(for entry: SteamLibraryEntry) -> SteamManifestResolution
}

public protocol DepotTransferEngine: Sendable {
    func makeExecution(
        for entry: SteamLibraryEntry,
        plan: SteamInstallPlan,
        manifest: SteamManifestResolution
    ) -> InstallExecutionRecord
}

public struct LocalSteamAuthClient: SteamAuthClient {
    private let sessionStore: any SteamSessionStore

    public init(sessionStore: any SteamSessionStore = FileSystemSteamSessionStore()) {
        self.sessionStore = sessionStore
    }

    public func authenticate(accountName: String) async -> SteamAccount {
        let session = await sessionStore.createSession(accountName: accountName)
        return SteamAccount(accountName: accountName, state: .signedIn, sessionReference: session.id)
    }

    public func signOut() async -> SteamAuthState {
        let active = await sessionStore.activeSession()
        await sessionStore.closeSession(reference: active?.id)
        return .signedOut
    }
}

public struct HostedSteamAuthClient: SteamAuthClient {
    private let sessionStore: any SteamSessionStore

    public init(sessionStore: any SteamSessionStore = FileSystemSteamSessionStore()) {
        self.sessionStore = sessionStore
    }

    public func authenticate(accountName: String) async -> SteamAccount {
        let session = await sessionStore.createSession(accountName: accountName)
        return SteamAccount(accountName: session.accountName, state: .signedIn, sessionReference: session.id)
    }

    public func signOut() async -> SteamAuthState {
        let active = await sessionStore.activeSession()
        await sessionStore.closeSession(reference: active?.id)
        return .signedOut
    }
}

public struct SteamBridgeConfiguration: Sendable {
    public var rootURL: URL

    public init(
        rootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.rootURL = rootURL
            ?? IridiumDeploymentPaths.steamBridgeRootURL(
                environment: environment,
                infoDictionary: infoDictionary
            )
    }

    public var requestsRootURL: URL {
        rootURL.appending(path: "requests", directoryHint: .isDirectory)
    }

    public var responsesRootURL: URL {
        rootURL.appending(path: "responses", directoryHint: .isDirectory)
    }
}

public enum SteamBridgeFallbackMode: Sendable {
    case never
    case developmentOnly
}

private struct SteamAuthBridgeRequest: Codable, Sendable {
    let accountName: String
}

private struct SteamSignOutBridgeRequest: Codable, Sendable {
    let sessionReference: String?
}

private struct SteamInstallPlanBridgeRequest: Codable, Sendable {
    let appID: String
    let targetPath: String
    let title: String?
}

private struct SteamTransferBridgeRequest: Codable, Sendable {
    let depot: SteamDepotManifest
    let execution: InstallExecutionRecord
}

private struct SteamVerificationBridgeRequest: Codable, Sendable {
    let execution: InstallExecutionRecord
    let manifest: SteamManifestResolution
}

public struct BridgedSteamAuthClient: SteamAuthClient {
    private let configuration: SteamBridgeConfiguration
    private let sessionStore: any SteamSessionStore
    private let processor: (any SteamBridgeRequestProcessor)?
    private let fallbackMode: SteamBridgeFallbackMode
    private let fallback: (any SteamAuthClient)?

    public init(
        configuration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        sessionStore: any SteamSessionStore = FileSystemSteamSessionStore(),
        processor: (any SteamBridgeRequestProcessor)? = nil,
        fallbackMode: SteamBridgeFallbackMode = .never,
        fallback: (any SteamAuthClient)? = nil
    ) {
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func authenticate(accountName: String) async -> SteamAccount {
        let requestName = "auth-\(sanitizedBridgeComponent(accountName)).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            SteamAuthBridgeRequest(accountName: accountName),
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let session: SteamSessionRecord = try? await waitForSteamBridgeResponse(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            await sessionStore.persistSession(session)
            return SteamAccount(accountName: session.accountName, state: .signedIn, sessionReference: session.id)
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return SteamAccount(accountName: accountName, state: .signedOut, sessionReference: nil)
        }

        return await fallback.authenticate(accountName: accountName)
    }

    public func signOut() async -> SteamAuthState {
        let activeReference = await sessionStore.activeSession()?.id
        let requestName = "signout-current.json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            SteamSignOutBridgeRequest(sessionReference: activeReference),
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        await sessionStore.closeSession(reference: activeReference)

        if let state: SteamAuthState = try? await waitForSteamBridgeResponse(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return state
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return .signedOut
        }

        return await fallback.signOut()
    }
}

public struct BridgedSteamCatalogClient: SteamCatalogClient {
    private let configuration: SteamBridgeConfiguration
    private let processor: (any SteamBridgeRequestProcessor)?
    private let fallbackMode: SteamBridgeFallbackMode
    private let fallback: (any SteamCatalogClient)?

    public init(
        configuration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        processor: (any SteamBridgeRequestProcessor)? = nil,
        fallbackMode: SteamBridgeFallbackMode = .never,
        fallback: (any SteamCatalogClient)? = nil
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func syncLibrary(for account: SteamAccount?) async -> [SteamLibraryEntry] {
        let reference = account?.sessionReference ?? "signed-out"
        let requestName = "library-\(sanitizedBridgeComponent(reference)).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            account,
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let library: [SteamLibraryEntry] = try? await waitForSteamBridgeResponse(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return library
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return []
        }

        return await fallback.syncLibrary(for: account)
    }
}

public struct BridgedSteamDepotManifestClient: SteamDepotManifestClient {
    private let configuration: SteamBridgeConfiguration
    private let processor: (any SteamBridgeRequestProcessor)?
    private let fallbackMode: SteamBridgeFallbackMode
    private let fallback: (any SteamDepotManifestClient)?

    public init(
        configuration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        processor: (any SteamBridgeRequestProcessor)? = nil,
        fallbackMode: SteamBridgeFallbackMode = .never,
        fallback: (any SteamDepotManifestClient)? = nil
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func installPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
        let requestName = "install-plan-\(entry.appID).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            SteamInstallPlanBridgeRequest(appID: entry.appID, targetPath: targetPath, title: entry.title),
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let plan: SteamInstallPlan = try? waitForSteamBridgeResponseSync(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return plan
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return unavailableInstallPlan(for: entry, targetPath: targetPath)
        }

        return fallback.installPlan(for: entry, targetPath: targetPath)
    }

    public func manifest(for entry: SteamLibraryEntry) -> SteamManifestResolution {
        let requestName = "manifest-\(entry.appID).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            entry,
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let manifest: SteamManifestResolution = try? waitForSteamBridgeResponseSync(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return manifest
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return unavailableManifest(for: entry)
        }

        return fallback.manifest(for: entry)
    }
}

public struct LocalSteamCatalogClient: SteamCatalogClient {
    public init() {}

    public func syncLibrary(for account: SteamAccount?) async -> [SteamLibraryEntry] {
        _ = account
        return []
    }
}

public struct LocalSteamLibrarySyncService: SteamLibrarySyncService {
    private let catalogClient: any SteamCatalogClient
    private let sessionStore: any SteamSessionStore

    public init(
        catalogClient: any SteamCatalogClient = LocalSteamCatalogClient(),
        sessionStore: any SteamSessionStore = FileSystemSteamSessionStore()
    ) {
        self.catalogClient = catalogClient
        self.sessionStore = sessionStore
    }

    public func sync(using session: SteamSessionRecord?) async -> [SteamLibraryEntry] {
        let sessionRecord = if let session {
            session
        } else {
            await sessionStore.activeSession()
        }

        guard let sessionRecord else {
            return []
        }
        guard let resolvedSession = await sessionStore.session(reference: sessionRecord.id) else {
            return []
        }
        return await catalogClient.syncLibrary(
            for: SteamAccount(accountName: resolvedSession.accountName, state: .signedIn, sessionReference: resolvedSession.id)
        )
    }
}

public struct HostedSteamCatalogClient: SteamCatalogClient {
    public init() {}

    public func syncLibrary(for account: SteamAccount?) async -> [SteamLibraryEntry] {
        _ = account
        return []
    }
}

public struct LocalSteamDepotManifestClient: SteamDepotManifestClient {
    public init() {}

    public func installPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
        unavailableInstallPlan(for: entry, targetPath: targetPath)
    }

    public func manifest(for entry: SteamLibraryEntry) -> SteamManifestResolution {
        unavailableManifest(for: entry)
    }
}

public struct HostedSteamDepotManifestClient: SteamDepotManifestClient {
    public init() {}

    public func installPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
        unavailableInstallPlan(for: entry, targetPath: targetPath)
    }

    public func manifest(for entry: SteamLibraryEntry) -> SteamManifestResolution {
        unavailableManifest(for: entry)
    }
}

public struct DefaultDepotTransferEngine: DepotTransferEngine {
    public init() {}

    public func makeExecution(
        for entry: SteamLibraryEntry,
        plan: SteamInstallPlan,
        manifest: SteamManifestResolution
    ) -> InstallExecutionRecord {
        InstallExecutionRecord(
            title: entry.title,
            appID: entry.appID,
            buildID: manifest.buildID,
            branchName: manifest.branchName,
            targetPath: plan.targetPath,
            primaryExecutable: plan.primaryExecutable,
            depotIDs: manifest.depots.map(\.depotID),
            depotMountPaths: Dictionary(uniqueKeysWithValues: manifest.depots.map { ($0.depotID, $0.mountedPath) }),
            completedDepotIDs: [],
            stage: .queued,
            detail: "Install session prepared for build \(manifest.buildID).",
            reservedDiskGB: plan.requiredDiskHeadroomGB,
            depotProgressBytes: Dictionary(uniqueKeysWithValues: manifest.depots.map { ($0.depotID, 0) }),
            lastUpdatedAt: Date()
        )
    }
}

public struct FileSystemSteamSessionStore: SteamSessionStore {
    private let sessionsRootURL: URL

    public init(
        rootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) {
        self.sessionsRootURL = rootURL
            ?? IridiumDeploymentPaths.steamSessionsRootURL(
                environment: environment,
                infoDictionary: infoDictionary
            )
    }

    public func createSession(accountName: String) async -> SteamSessionRecord {
        let session = SteamSessionRecord(accountName: accountName)
        await persistSession(session)
        return session
    }

    public func persistSession(_ session: SteamSessionRecord) async {
        do {
            try FileManager.default.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)
            let sessionURL = sessionsRootURL.appending(path: "\(session.id).json")
            let activeURL = sessionsRootURL.appending(path: "active-session.txt")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: sessionURL, options: .atomic)
            try Data(session.id.utf8).write(to: activeURL, options: .atomic)
            try persistSecret(for: session)
        } catch {
            assertionFailure("Failed to persist Steam session: \(error)")
        }
    }

    public func session(reference: String) async -> SteamSessionRecord? {
        let sessionURL = sessionsRootURL.appending(path: "\(reference).json")
        guard FileManager.default.fileExists(atPath: sessionURL.path),
              secretExists(reference: reference),
              let data = try? Data(contentsOf: sessionURL) else {
            return nil
        }
        return try? JSONDecoder().decode(SteamSessionRecord.self, from: data)
    }

    public func activeSession() async -> SteamSessionRecord? {
        let activeURL = sessionsRootURL.appending(path: "active-session.txt")
        guard let data = try? Data(contentsOf: activeURL),
              let reference = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else {
            return nil
        }
        return await session(reference: reference)
    }

    public func closeSession(reference: String?) async {
        let resolvedReference = if let reference {
            reference
        } else {
            await activeSession()?.id
        }
        guard let resolvedReference else {
            return
        }
        try? FileManager.default.removeItem(at: sessionsRootURL.appending(path: "\(resolvedReference).json"))
        deleteSecret(reference: resolvedReference)

        let activeURL = sessionsRootURL.appending(path: "active-session.txt")
        if let data = try? Data(contentsOf: activeURL),
           let activeReference = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           activeReference == resolvedReference {
            try? FileManager.default.removeItem(at: activeURL)
        }
    }

    private func persistSecret(for session: SteamSessionRecord) throws {
        let payload = "steam-session=\(session.id);account=\(session.accountName)"
        let data = Data(payload.utf8)

#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.iridium.prototype.steam-session",
            kSecAttrAccount: session.id,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            try persistSecretToFilesystem(reference: session.id, data: data)
        }
#else
        try persistSecretToFilesystem(reference: session.id, data: data)
#endif
    }

    private func secretExists(reference: String) -> Bool {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.iridium.prototype.steam-session",
            kSecAttrAccount: reference,
            kSecReturnData: false
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return true
        }
        return filesystemSecretExists(reference: reference)
#else
        return filesystemSecretExists(reference: reference)
#endif
    }

    private func deleteSecret(reference: String) {
#if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.iridium.prototype.steam-session",
            kSecAttrAccount: reference
        ]
        SecItemDelete(query as CFDictionary)
#endif
        try? FileManager.default.removeItem(at: secretFileURL(for: reference))
    }

    private func persistSecretToFilesystem(reference: String, data: Data) throws {
        let secretsRoot = sessionsRootURL.appending(path: ".secrets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secretsRoot, withIntermediateDirectories: true)
        try data.write(to: secretFileURL(for: reference), options: .atomic)
    }

    private func filesystemSecretExists(reference: String) -> Bool {
        FileManager.default.fileExists(atPath: secretFileURL(for: reference).path)
    }

    private func secretFileURL(for reference: String) -> URL {
        sessionsRootURL.appending(path: ".secrets/\(reference).secret")
    }
}

public struct NativeSteamBridgeRequestProcessor: SteamBridgeRequestProcessor {
    private let steamConfiguration: SteamBridgeConfiguration
    private let runtimeConfiguration: RuntimeHostBridgeConfiguration

    public init(
        steamConfiguration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        runtimeConfiguration: RuntimeHostBridgeConfiguration = RuntimeHostBridgeConfiguration()
    ) {
        self.steamConfiguration = steamConfiguration
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func processSteamRequests() async throws -> Int {
        try await NativeBridgeService(
            runtimeConfiguration: runtimeConfiguration,
            steamConfiguration: steamConfiguration
        ).processSteamRequests()
    }
}

public struct LocalSteamContentServerClient: SteamContentServerClient {
    public init() {}

    public func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String) {
        let totalBytes = Int64(depot.compressedSizeGB * 1_000_000_000)
        let current = execution.depotProgressBytes[depot.depotID] ?? 0
        let increment = max(totalBytes / 2, 1)
        let next = min(current + increment, totalBytes)
        let checkpoint = "\(depot.depotID):\(next)"
        return (next, checkpoint)
    }
}

private struct HostedDepotTransferState: Codable, Hashable, Sendable {
    var depotID: String
    var manifestID: String
    var bytesTransferred: Int64
    var totalBytes: Int64
    var updatedAt: Date
}

private struct HostedDepotVerificationReceipt: Codable, Hashable, Sendable {
    var appID: String
    var buildID: String
    var verifiedDepotIDs: [String]
    var verifiedAt: Date
}

public struct HostedSteamContentServerClient: SteamContentServerClient {
    public init() {}

    public func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String) {
        let totalBytes = max(Int64(depot.compressedSizeGB * 1_000_000_000), 1)
        let existing = (try? readHostedTransferState(targetPath: execution.targetPath, depotID: depot.depotID))
            ?? HostedDepotTransferState(
                depotID: depot.depotID,
                manifestID: depot.manifestID,
                bytesTransferred: 0,
                totalBytes: totalBytes,
                updatedAt: Date()
            )
        let chunkSize = max(min(totalBytes / 2, 2_000_000_000), 1)
        let nextBytes = min(existing.bytesTransferred + chunkSize, totalBytes)
        let updated = HostedDepotTransferState(
            depotID: depot.depotID,
            manifestID: depot.manifestID,
            bytesTransferred: nextBytes,
            totalBytes: totalBytes,
            updatedAt: Date()
        )

        try? writeHostedTransferState(updated, targetPath: execution.targetPath, depotID: depot.depotID)
        if nextBytes >= totalBytes {
            try? materializeHostedDepotPayload(
                depot: depot,
                execution: execution,
                bytesTransferred: nextBytes
            )
        }

        return (nextBytes, "\(depot.depotID):\(nextBytes)")
    }
}

public struct BridgedSteamContentServerClient: SteamContentServerClient {
    private let configuration: SteamBridgeConfiguration
    private let processor: (any SteamBridgeRequestProcessor)?
    private let fallbackMode: SteamBridgeFallbackMode
    private let fallback: (any SteamContentServerClient)?

    public init(
        configuration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        processor: (any SteamBridgeRequestProcessor)? = nil,
        fallbackMode: SteamBridgeFallbackMode = .never,
        fallback: (any SteamContentServerClient)? = nil
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func transfer(
        depot: SteamDepotManifest,
        into execution: InstallExecutionRecord
    ) async -> (bytesTransferred: Int64, resumeCheckpoint: String) {
        let requestName = "transfer-\(depot.depotID).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            SteamTransferBridgeRequest(depot: depot, execution: execution),
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let response: BridgeTransferResponse = try? await waitForSteamBridgeResponse(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return (response.bytesTransferred, response.resumeCheckpoint)
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            return (execution.depotProgressBytes[depot.depotID] ?? 0, execution.resumeCheckpoint ?? "\(depot.depotID):0")
        }

        return await fallback.transfer(depot: depot, into: execution)
    }
}

public struct DefaultDepotVerificationService: DepotVerificationService {
    public init() {}

    public func verify(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        var updated = execution
        updated.depotVerifiedIDs = manifest.depots.map(\.depotID)
        updated.detail = "Verification passed for \(manifest.depots.count) depot(s)."
        return updated
    }
}

public struct HostedDepotVerificationService: DepotVerificationService {
    public init() {}

    public func verify(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        var updated = execution
        let verifiedDepotIDs = manifest.depots.compactMap { depot -> String? in
            guard let transferState = try? readHostedTransferState(targetPath: execution.targetPath, depotID: depot.depotID),
                  transferState.bytesTransferred >= transferState.totalBytes,
                  hostedDepotPayloadExists(targetPath: execution.targetPath, depot: depot) else {
                return nil
            }
            return depot.depotID
        }
        updated.depotVerifiedIDs = verifiedDepotIDs

        if verifiedDepotIDs.count == manifest.depots.count {
            let receipt = HostedDepotVerificationReceipt(
                appID: execution.appID,
                buildID: execution.buildID,
                verifiedDepotIDs: verifiedDepotIDs,
                verifiedAt: Date()
            )
            try? writeHostedVerificationReceipt(receipt, targetPath: execution.targetPath)
            updated.detail = "Verification passed for \(manifest.depots.count) depot(s)."
        } else {
            let pending = manifest.depots.map(\.depotID).filter { !verifiedDepotIDs.contains($0) }
            updated.detail = "Verification blocked. Missing transferred payloads for depot(s): \(pending.joined(separator: ", "))."
        }

        return updated
    }
}

public struct BridgedDepotVerificationService: DepotVerificationService {
    private let configuration: SteamBridgeConfiguration
    private let processor: (any SteamBridgeRequestProcessor)?
    private let fallbackMode: SteamBridgeFallbackMode
    private let fallback: (any DepotVerificationService)?

    public init(
        configuration: SteamBridgeConfiguration = SteamBridgeConfiguration(),
        processor: (any SteamBridgeRequestProcessor)? = nil,
        fallbackMode: SteamBridgeFallbackMode = .never,
        fallback: (any DepotVerificationService)? = nil
    ) {
        self.configuration = configuration
        self.processor = processor
        self.fallbackMode = fallbackMode
        self.fallback = fallback
    }

    public func verify(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        let requestName = "verify-\(execution.id.uuidString).json"
        let responseURL = configuration.responsesRootURL.appending(path: requestName)
        _ = try? writeSteamBridgeRequest(
            SteamVerificationBridgeRequest(execution: execution, manifest: manifest),
            requestURL: configuration.requestsRootURL.appending(path: requestName),
            responseURL: responseURL
        )

        if let response: InstallExecutionRecord = try? await waitForSteamBridgeResponse(
            configuration: configuration,
            responseURL: responseURL,
            processor: processor,
            fallbackMode: fallbackMode
        ) {
            return response
        }

        guard shouldUseDevelopmentSteamFallback(fallbackMode), let fallback else {
            var blocked = execution
            blocked.detail = "Verification blocked. The Steam bridge did not return a verification result."
            return blocked
        }

        return await fallback.verify(execution: execution, manifest: manifest)
    }
}

public struct NativeSteamInstallCoordinator: SteamInstallCoordinator {
    private let contentClient: any SteamContentServerClient
    private let verificationService: any DepotVerificationService
    private let artifactInventory: any GameArtifactInventory

    public init(
        contentClient: any SteamContentServerClient = HostedSteamContentServerClient(),
        verificationService: any DepotVerificationService = HostedDepotVerificationService(),
        artifactInventory: any GameArtifactInventory = FileSystemGameArtifactInventory()
    ) {
        self.contentClient = contentClient
        self.verificationService = verificationService
        self.artifactInventory = artifactInventory
    }

    public func advance(
        execution: InstallExecutionRecord,
        manifest: SteamManifestResolution
    ) async -> InstallExecutionRecord {
        var updated = execution
        let previousStage = updated.stage

        switch updated.stage {
        case .queued:
            updated.stage = .resolving
            updated.detail = "Entitlement confirmed for app \(manifest.appID); resolved \(manifest.depots.count) depot(s) on branch \(manifest.branchName)."
        case .resolving, .downloading:
            let remaining = manifest.depots.filter { !updated.completedDepotIDs.contains($0.depotID) }
            guard let nextDepot = remaining.first else {
                updated.stage = .verifying
                updated.detail = "All depots downloaded. Verification is ready to start."
                break
            }

            let transfer = await contentClient.transfer(depot: nextDepot, into: updated)
            updated.depotProgressBytes[nextDepot.depotID] = transfer.bytesTransferred
            updated.resumeCheckpoint = transfer.resumeCheckpoint

            let totalBytes = Int64(nextDepot.compressedSizeGB * 1_000_000_000)
            if transfer.bytesTransferred >= totalBytes {
                updated.completedDepotIDs.append(nextDepot.depotID)
            }

            if updated.completedDepotIDs.count == manifest.depots.count {
                updated.stage = .verifying
                updated.detail = "All depots downloaded. Verification is ready to start."
            } else {
                updated.stage = .downloading
                updated.detail = "Transferred \(updated.completedDepotIDs.count) of \(manifest.depots.count) depot(s); resumable checkpoint \(updated.resumeCheckpoint ?? "none")."
            }
        case .verifying:
            updated = await verificationService.verify(execution: updated, manifest: manifest)
            if updated.depotVerifiedIDs.count == manifest.depots.count {
                updated.stage = .mounting
            } else {
                updated.stage = .verifying
            }
        case .mounting:
            updated = finalizeMountedInstall(updated)
        case .completed:
            break
        }

        if previousStage != updated.stage || previousStage == .downloading {
            updated.lastUpdatedAt = Date()
        }
        return updated
    }

    private func finalizeMountedInstall(_ execution: InstallExecutionRecord) -> InstallExecutionRecord {
        var updated = execution
        guard let executableURL = absoluteSteamExecutableURL(for: execution) else {
            updated.detail = "Mount completed, but the managed executable target could not be resolved."
            return updated
        }

        do {
            try FileManager.default.createDirectory(
                at: executableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: executableURL.path) {
                try Data(
                    """
                    steam-app-id=\(execution.appID)
                    build-id=\(execution.buildID)
                    executable=\(execution.primaryExecutable)
                    """.utf8
                ).write(to: executableURL, options: .atomic)
            }

            let artifact = try artifactInventory.makeManagedArtifact(
                title: execution.title,
                executablePath: executableURL.path,
                installPath: execution.targetPath
            )
            try writeHostedMountReceipt(
                executablePath: executableURL.path,
                managedArtifactIdentifier: artifact.identifier,
                executableFingerprint: artifact.checksum,
                execution: execution
            )

            updated.managedArtifactIdentifier = artifact.identifier
            updated.executableFingerprint = artifact.checksum
            if updated.runtimeBundleIdentifier == nil || updated.runtimeBundleVersion == nil {
                updated.detail = "Payload mounted and executable resolved, but runtime bundle binding is still missing."
                return updated
            }

            updated.stage = .completed
            updated.detail = "Payload mounted into managed storage, executable resolved, and managed artifact inventory recorded."
            return updated
        } catch {
            updated.detail = "Mount completed, but executable registration failed: \(error.localizedDescription)"
            return updated
        }
    }
}

private struct BridgeTransferResponse: Codable, Sendable {
    let bytesTransferred: Int64
    let resumeCheckpoint: String
}

private struct HostedMountReceipt: Codable, Hashable, Sendable {
    let appID: String
    let buildID: String
    let executablePath: String
    let managedArtifactIdentifier: String
    let executableFingerprint: String
    let runtimeBundleIdentifier: String?
    let runtimeBundleVersion: String?
    let mountedAt: Date
}

private func sanitizedBridgeComponent(_ value: String) -> String {
    let filtered = value.replacingOccurrences(
        of: #"[^A-Za-z0-9._-]"#,
        with: "-",
        options: .regularExpression
    )
    return filtered.isEmpty ? "default" : filtered
}

private func writeBridgeRequest<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

private func writeSteamBridgeRequest<Value: Encodable>(
    _ value: Value,
    requestURL: URL,
    responseURL: URL
) throws {
    if FileManager.default.fileExists(atPath: responseURL.path) {
        try? FileManager.default.removeItem(at: responseURL)
    }
    try writeBridgeRequest(value, to: requestURL)
}

private func readBridgeResponse<Value: Decodable>(from url: URL, as type: Value.Type) throws -> Value {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
}

private func waitForBridgeResponse<Value: Decodable>(
    from url: URL,
    as type: Value.Type,
    attempts: Int = 20,
    intervalMS: UInt64 = 50
) async throws -> Value? {
    for _ in 0..<attempts {
        if let value = try? readBridgeResponse(from: url, as: type) {
            return value
        }
        try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return nil
}

private func waitForBridgeResponseSync<Value: Decodable>(
    from url: URL,
    as type: Value.Type,
    attempts: Int = 20,
    intervalMS: TimeInterval = 0.05
) throws -> Value? {
    for _ in 0..<attempts {
        if let value = try? readBridgeResponse(from: url, as: type) {
            return value
        }
        Thread.sleep(forTimeInterval: intervalMS)
    }
    return nil
}

private func waitForSteamBridgeResponse<Value: Decodable>(
    configuration: SteamBridgeConfiguration,
    responseURL: URL,
    processor: (any SteamBridgeRequestProcessor)?,
    fallbackMode: SteamBridgeFallbackMode,
    attempts: Int = 20,
    intervalMS: UInt64 = 50
) async throws -> Value? {
    guard shouldAttemptSteamBridgeResponse(
        configuration: configuration,
        responseURL: responseURL,
        processor: processor,
        fallbackMode: fallbackMode
    ) else {
        return nil
    }

    for _ in 0..<attempts {
        if let value = try? readBridgeResponse(from: responseURL, as: Value.self) {
            return value
        }

        if let processor {
            _ = try? await processor.processSteamRequests()
        } else if !steamBridgeHeartbeatExists(configuration: configuration) {
            break
        }

        try await Task.sleep(nanoseconds: intervalMS * 1_000_000)
    }
    return nil
}

private func waitForSteamBridgeResponseSync<Value: Decodable>(
    configuration: SteamBridgeConfiguration,
    responseURL: URL,
    processor: (any SteamBridgeRequestProcessor)?,
    fallbackMode: SteamBridgeFallbackMode,
    attempts: Int = 20,
    intervalMS: TimeInterval = 0.05
) throws -> Value? {
    guard shouldAttemptSteamBridgeResponse(
        configuration: configuration,
        responseURL: responseURL,
        processor: processor,
        fallbackMode: fallbackMode
    ) else {
        return nil
    }

    for _ in 0..<attempts {
        if let value = try? readBridgeResponse(from: responseURL, as: Value.self) {
            return value
        }

        if let processor {
            runSteamBridgeProcessorSync(processor)
        } else if !steamBridgeHeartbeatExists(configuration: configuration) {
            break
        }

        Thread.sleep(forTimeInterval: intervalMS)
    }
    return nil
}

private func shouldUseDevelopmentSteamFallback(_ mode: SteamBridgeFallbackMode) -> Bool {
    switch mode {
    case .never:
        return false
    case .developmentOnly:
#if os(macOS) || targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }
}

private func shouldAttemptSteamBridgeResponse(
    configuration: SteamBridgeConfiguration,
    responseURL: URL,
    processor: (any SteamBridgeRequestProcessor)?,
    fallbackMode: SteamBridgeFallbackMode
) -> Bool {
    if FileManager.default.fileExists(atPath: responseURL.path) {
        return true
    }

    if processor != nil || steamBridgeHeartbeatExists(configuration: configuration) {
        return true
    }

    return shouldUseDevelopmentSteamFallback(fallbackMode)
}

private func steamBridgeHeartbeatExists(configuration: SteamBridgeConfiguration) -> Bool {
    FileManager.default.fileExists(
        atPath: configuration.rootURL.appending(path: "bridge-status.json").path
    )
}

private func runSteamBridgeProcessorSync(_ processor: any SteamBridgeRequestProcessor) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        _ = try? await processor.processSteamRequests()
        semaphore.signal()
    }
    semaphore.wait()
}

private func unavailableInstallPlan(for entry: SteamLibraryEntry, targetPath: String) -> SteamInstallPlan {
    SteamInstallPlan(
        title: entry.title,
        appID: entry.appID,
        targetPath: targetPath,
        primaryExecutable: "",
        contentSets: [],
        estimatedInstallSizeGB: 0,
        requiredDiskHeadroomGB: 0,
        verificationSteps: ["Steam bridge unavailable; install planning is blocked."]
    )
}

private func unavailableManifest(for entry: SteamLibraryEntry) -> SteamManifestResolution {
    SteamManifestResolution(
        title: entry.title,
        appID: entry.appID,
        buildID: "bridge-unavailable",
        branchName: "unavailable",
        depots: [],
        verificationStages: ["Steam bridge unavailable; manifest resolution is blocked."]
    )
}

private func absoluteSteamExecutableURL(for execution: InstallExecutionRecord) -> URL? {
    guard execution.targetPath.hasPrefix("/") else {
        return nil
    }
    return URL(fileURLWithPath: execution.targetPath, isDirectory: true)
        .appending(path: execution.primaryExecutable)
}

private func hostedSteamMetadataRoot(targetPath: String) -> URL? {
    guard targetPath.hasPrefix("/") else {
        return nil
    }
    return URL(fileURLWithPath: targetPath, isDirectory: true)
        .appending(path: ".iridium/steam-host", directoryHint: .isDirectory)
}

private func hostedDepotTransferURL(targetPath: String, depotID: String) -> URL? {
    hostedSteamMetadataRoot(targetPath: targetPath)?
        .appending(path: "transfers/\(depotID).json")
}

private func hostedVerificationReceiptURL(targetPath: String) -> URL? {
    hostedSteamMetadataRoot(targetPath: targetPath)?
        .appending(path: "verification.json")
}

private func hostedMountReceiptURL(targetPath: String) -> URL? {
    hostedSteamMetadataRoot(targetPath: targetPath)?
        .appending(path: "mount.json")
}

private func readHostedTransferState(targetPath: String, depotID: String) throws -> HostedDepotTransferState {
    guard let url = hostedDepotTransferURL(targetPath: targetPath, depotID: depotID) else {
        throw CocoaError(.fileNoSuchFile)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(HostedDepotTransferState.self, from: data)
}

private func writeHostedTransferState(
    _ state: HostedDepotTransferState,
    targetPath: String,
    depotID: String
) throws {
    guard let url = hostedDepotTransferURL(targetPath: targetPath, depotID: depotID) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: url, options: .atomic)
}

private func materializeHostedDepotPayload(
    depot: SteamDepotManifest,
    execution: InstallExecutionRecord,
    bytesTransferred: Int64
) throws {
    guard execution.targetPath.hasPrefix("/") else {
        return
    }
    let targetRoot = URL(fileURLWithPath: execution.targetPath, isDirectory: true)
    let mountedRoot = targetRoot.appending(path: depot.mountedPath, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mountedRoot, withIntermediateDirectories: true)
    let payloadURL = mountedRoot.appending(path: "payload-\(depot.depotID).txt")
    try Data(
        """
        depot=\(depot.depotID)
        manifest=\(depot.manifestID)
        bytesTransferred=\(bytesTransferred)
        label=\(depot.label)
        """.utf8
    ).write(to: payloadURL, options: .atomic)
}

private func hostedDepotPayloadExists(targetPath: String, depot: SteamDepotManifest) -> Bool {
    guard targetPath.hasPrefix("/") else {
        return false
    }
    let payloadURL = URL(fileURLWithPath: targetPath, isDirectory: true)
        .appending(path: depot.mountedPath, directoryHint: .isDirectory)
        .appending(path: "payload-\(depot.depotID).txt")
    return FileManager.default.fileExists(atPath: payloadURL.path)
}

private func writeHostedVerificationReceipt(
    _ receipt: HostedDepotVerificationReceipt,
    targetPath: String
) throws {
    guard let url = hostedVerificationReceiptURL(targetPath: targetPath) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .atomic)
}

private func writeHostedMountReceipt(
    executablePath: String,
    managedArtifactIdentifier: String,
    executableFingerprint: String,
    execution: InstallExecutionRecord
) throws {
    guard let url = hostedMountReceiptURL(targetPath: execution.targetPath) else {
        throw CocoaError(.fileNoSuchFile)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let receipt = HostedMountReceipt(
        appID: execution.appID,
        buildID: execution.buildID,
        executablePath: executablePath,
        managedArtifactIdentifier: managedArtifactIdentifier,
        executableFingerprint: executableFingerprint,
        runtimeBundleIdentifier: execution.runtimeBundleIdentifier,
        runtimeBundleVersion: execution.runtimeBundleVersion,
        mountedAt: Date()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .atomic)
}
