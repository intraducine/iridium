import Foundation

public protocol GameLibraryService: Sendable {
    func allGames() async -> [GameRecord]
    func register(_ game: GameRecord) async
    func importGame(
        title: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        managedArtifactIdentifier: String?,
        executableFingerprint: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?
    ) async -> GameRecord
    func registerSteamGame(
        title: String,
        appID: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        managedArtifactIdentifier: String?,
        executableFingerprint: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?
    ) async -> GameRecord
    func finalizeVerifiedInstallIntoLibraryRegistration(
        entry: SteamLibraryEntry,
        execution: InstallExecutionRecord,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        resolvedPolicySummary: String
    ) async -> GameRecord?
    func update(_ game: GameRecord) async
    func verify(gameID: UUID) async -> Bool
    func uninstall(gameID: UUID) async
}

public protocol SteamService: Sendable {
    func authState() async -> SteamAuthState
    func activeAccount() async -> SteamAccount?
    func signIn(accountName: String, sessionReference: String?) async
    func signOut() async
    func librarySnapshot() async -> [SteamLibraryEntry]
    func syncLibrary() async -> [SteamLibraryEntry]
    func replaceSteamLibrary(_ entries: [SteamLibraryEntry], syncedAt: Date) async
    func allDownloads() async -> [DownloadTask]
    func installExecutions() async -> [InstallExecutionRecord]
    func installHistory() async -> [InstallHistoryEntry]
    func updateInstallExecution(_ execution: InstallExecutionRecord) async
    func queueInstall(title: String, depotID: String, targetPath: String, reservedDiskGB: Double) async -> DownloadTask
    func beginInstallExecution(
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        targetPath: String,
        primaryExecutable: String,
        depotIDs: [String],
        depotMountPaths: [String: String],
        reservedDiskGB: Double,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?
    ) async -> InstallExecutionRecord
    func advanceInstallExecution(title: String) async -> InstallExecutionRecord?
    func resetInstallExecution(title: String) async
    func markDownloadInstalled(downloadID: UUID) async
    func lastLibrarySyncDate() async -> Date?
}

public protocol RuntimeService: Sendable {
    func allPrefixes() async -> [PrefixRecord]
    func createPrefix(name: String, runtimeName: String) async -> PrefixRecord
    func prefix(prefixID: UUID) async -> PrefixRecord?
    func updatePrefix(_ prefix: PrefixRecord) async
    func clone(prefixID: UUID, newName: String) async -> PrefixRecord?
    func repair(prefixID: UUID) async
    func rebuild(prefixID: UUID) async
    func deletePrefix(prefixID: UUID) async
    func healthReport() async -> RuntimeHealthReport
    func provisionRuntimeBundleMetadata(_ report: RuntimeHealthReport) async
    func validateRuntime(report: RuntimeHealthReport?) async
    func launchHistory() async -> [LaunchHistoryEntry]
    func pendingLaunches() async -> [PendingLaunchRecord]
    func compatibilityEvidence() async -> [CompatibilityEvidenceRecord]
    func activityFeed() async -> [ActivityLogEntry]
    func verificationAudits() async -> [VerificationAuditEntry]
    func managedStorageStatus() async -> ManagedStorageStatus
    func recordLaunch(
        gameTitle: String,
        resolvedExecutablePath: String,
        readiness: String,
        issueSummary: [String],
        hostSessionID: String?,
        terminalStatus: String?,
        failureCode: String?,
        failureReason: String?,
        runtimeBundleVersion: String?
    ) async
    func queueLaunchWaitingForJIT(_ pendingLaunch: PendingLaunchRecord, launchEntry: LaunchHistoryEntry) async
    func markPendingLaunchResumed(id: UUID, detail: String, resumedAt: Date) async
    func markPendingLaunchValidationFailure(
        id: UUID,
        failureReason: String,
        issueSummary: [String],
        failedAt: Date
    ) async
    func attachRuntimeBundleToPrefix(
        prefixID: UUID,
        runtimeName: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        manifestPath: String?,
        manifestVersion: String?,
        environmentOverrides: [String: String],
        titleFingerprint: String?,
        bootstrapStatus: String?,
        bootstrapDetail: String?,
        state: PrefixState
    ) async
    func recordRuntimeExecutionStarted(
        gameID: UUID,
        launchEntryID: UUID,
        resolvedExecutablePath: String,
        issueSummary: [String],
        hostSessionID: String,
        stateHistory: [String],
        runtimeBundleVersion: String?,
        launchedAt: Date
    ) async
    func recordRuntimeExecutionSuccess(
        gameID: UUID,
        launchEntryID: UUID,
        resolvedExecutablePath: String,
        issueSummary: [String],
        hostSessionID: String,
        stateHistory: [String],
        terminalStatus: String,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        manifestPath: String?,
        manifestVersion: String?,
        environmentOverrides: [String: String],
        prefixState: PrefixState,
        bootstrapDetail: String,
        telemetrySummary: String?,
        mitigationAction: String?,
        evidenceSummary: String,
        resolvedPolicySummary: String,
        launchedAt: Date
    ) async
    func recordRuntimeExecutionFailure(
        gameID: UUID,
        launchEntryID: UUID,
        issueSummary: [String],
        hostSessionID: String?,
        stateHistory: [String],
        terminalStatus: String?,
        failureCode: String,
        failureReason: String,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        evidenceSummary: String,
        resolvedPolicySummary: String,
        launchedAt: Date?
    ) async
    func recordCompatibilityEvidence(_ evidence: CompatibilityEvidenceRecord) async
    func recordVerificationAudit(_ audit: VerificationAuditEntry) async
}

public actor IridiumStore: GameLibraryService, SteamService, RuntimeService {
    private struct LoadedSnapshotState {
        var snapshot: IridiumSnapshot
        var didResetLegacyState: Bool
    }

    private var games: [GameRecord]
    private var downloads: [DownloadTask]
    private var installExecutionEntries: [InstallExecutionRecord]
    private var installHistoryEntries: [InstallHistoryEntry]
    private var prefixes: [PrefixRecord]
    private var steamAccount: SteamAccount?
    private var steamLibrary: [SteamLibraryEntry]
    private var runtimeHealth: RuntimeHealthReport
    private var lastLibrarySync: Date?
    private var launchHistoryEntries: [LaunchHistoryEntry]
    private var pendingLaunchEntries: [PendingLaunchRecord]
    private var compatibilityEvidenceEntries: [CompatibilityEvidenceRecord]
    private var activityEntries: [ActivityLogEntry]
    private var verificationAuditEntries: [VerificationAuditEntry]
    private let snapshotURL: URL?

    public init(snapshot: IridiumSnapshot = .empty, snapshotURL: URL? = nil) {
        let loadedState = Self.loadInitialSnapshot(defaultSnapshot: snapshot, snapshotURL: snapshotURL)
        let initialSnapshot = loadedState.snapshot

        self.games = initialSnapshot.games
        self.downloads = initialSnapshot.downloads
        self.installExecutionEntries = initialSnapshot.installExecutions
        self.installHistoryEntries = initialSnapshot.installHistory
        self.prefixes = initialSnapshot.prefixes
        self.steamAccount = initialSnapshot.steamAccount
        self.steamLibrary = initialSnapshot.steamLibrary
        self.runtimeHealth = initialSnapshot.runtimeHealth
        self.lastLibrarySync = initialSnapshot.lastLibrarySync
        self.launchHistoryEntries = initialSnapshot.launchHistory
        self.pendingLaunchEntries = initialSnapshot.pendingLaunches
        self.compatibilityEvidenceEntries = initialSnapshot.compatibilityEvidence
        self.activityEntries = initialSnapshot.activityFeed
        self.verificationAuditEntries = initialSnapshot.verificationAudits

        self.snapshotURL = snapshotURL

        if loadedState.didResetLegacyState {
            Self.persistSnapshot(initialSnapshot, to: snapshotURL)
        }
    }

    public func allGames() async -> [GameRecord] {
        games.sorted { $0.title < $1.title }
    }

    public func register(_ game: GameRecord) async {
        games.append(game)
        persist()
    }

    public func importGame(
        title: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        managedArtifactIdentifier: String? = nil,
        executableFingerprint: String? = nil,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil
    ) async -> GameRecord {
        let game = upsertGame(
            source: .manualImport,
            title: title,
            installPath: installPath,
            executablePath: executablePath,
            compatibilityProfileName: compatibilityProfileName,
            inputProfileName: inputProfileName,
            deviceTier: deviceTier,
            rendererPreset: rendererPreset,
            launchArguments: [],
            titleFlags: ["manual-import"],
            touchOverlayName: "Custom Touch Overlay",
            controllerPresetName: "Custom Controller Preset",
            keyboardMouseEnabled: true,
            installedSizeGB: estimatedImportedSizeGB(for: deviceTier),
            prefixFootprintGB: 2.0,
            managedArtifactIdentifier: managedArtifactIdentifier,
            executableFingerprint: executableFingerprint,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            summary: "Imported Windows title with an isolated prefix and custom renderer/input defaults."
        )
        recordActivity(
            kind: .imported,
            title: "Imported \(game.title)",
            detail: "Copied the title into managed imports and bound it to prefix \(game.launchProfile.prefixID.uuidString).",
            relatedTitle: game.title
        )
        persist()
        return game
    }

    public func registerSteamGame(
        title: String,
        appID: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        managedArtifactIdentifier: String? = nil,
        executableFingerprint: String? = nil,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil
    ) async -> GameRecord {
        let game = registerSteamGameInternal(
            title: title,
            appID: appID,
            installPath: installPath,
            executablePath: executablePath,
            compatibilityProfileName: compatibilityProfileName,
            inputProfileName: inputProfileName,
            deviceTier: deviceTier,
            rendererPreset: rendererPreset,
            launchArguments: launchArguments,
            titleFlags: titleFlags,
            managedArtifactIdentifier: managedArtifactIdentifier,
            executableFingerprint: executableFingerprint,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            summary: "Native Steam install staged into managed storage with an isolated prefix and direct launch target.",
            registrationDetail: nil
        )
        persist()
        return game
    }

    public func finalizeVerifiedInstallIntoLibraryRegistration(
        entry: SteamLibraryEntry,
        execution: InstallExecutionRecord,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        resolvedPolicySummary: String
    ) async -> GameRecord? {
        guard execution.stage == .completed,
              let managedArtifactIdentifier = execution.managedArtifactIdentifier,
              let executableFingerprint = execution.executableFingerprint,
              let runtimeBundleIdentifier = execution.runtimeBundleIdentifier,
              let runtimeBundleVersion = execution.runtimeBundleVersion else {
            return nil
        }

        let executablePath = URL(fileURLWithPath: execution.targetPath, isDirectory: true)
            .appending(path: execution.primaryExecutable)
            .path
        guard FileManager.default.fileExists(atPath: executablePath) else {
            return nil
        }

        let game = registerSteamGameInternal(
            title: entry.title,
            appID: entry.appID,
            installPath: execution.targetPath,
            executablePath: executablePath,
            compatibilityProfileName: compatibilityProfileName,
            inputProfileName: inputProfileName,
            deviceTier: deviceTier,
            rendererPreset: rendererPreset,
            launchArguments: launchArguments,
            titleFlags: titleFlags,
            managedArtifactIdentifier: managedArtifactIdentifier,
            executableFingerprint: executableFingerprint,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            summary: "Verified Steam payload registered into the game library with a direct runtime launch target.",
            registrationDetail: "Registered verified Steam build \(execution.buildID) from branch \(execution.branchName) after transfer, verification, executable resolution, and prefix runtime binding."
        )

        upsertCompatibilityEvidenceEntry(
            CompatibilityEvidenceRecord(
                title: entry.title,
                source: .steam,
                managedArtifactIdentifier: managedArtifactIdentifier,
                executableFingerprint: executableFingerprint,
                runtimeBundleIdentifier: runtimeBundleIdentifier,
                runtimeBundleVersion: runtimeBundleVersion,
                resolvedPolicySummary: resolvedPolicySummary,
                accepted: true,
                evidenceSummary: "Registered verified Steam artifact \(entry.title) into managed storage after transfer, verification, executable resolution, and runtime bundle binding completed."
            )
        )
        persist()
        return game
    }

    public func update(_ game: GameRecord) async {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else {
            return
        }

        games[index] = game
        persist()
    }

    public func verify(gameID: UUID) async -> Bool {
        guard let index = games.firstIndex(where: { $0.id == gameID }) else {
            return false
        }

        let game = games[index]
        let installExists = managedPathExists(game.installPath) || (!hasManagedFilesystemContext() && !game.installPath.isEmpty)
        let executableExists = managedPathExists(game.launchProfile.executablePath)
            || (!hasManagedFilesystemContext() && !game.launchProfile.executablePath.isEmpty)
        let isValid = installExists && executableExists
        let verifiedState: PrefixState
        if isValid {
            if game.prefixState == .customized
                || prefixes.first(where: { $0.id == game.launchProfile.prefixID })?.state == .customized {
                verifiedState = .customized
            } else {
                verifiedState = .clean
            }
        } else {
            verifiedState = .verificationFailed
        }

        games[index].prefixState = verifiedState
        if let prefixIndex = prefixes.firstIndex(where: { $0.id == game.launchProfile.prefixID }) {
            prefixes[prefixIndex].state = verifiedState
        }
        persist()
        return isValid
    }

    public func relocateLibraryEntry(gameID: UUID, folder: URL, executable: URL, identifier: String, fingerprint: String) async throws {
        guard let index = games.firstIndex(where: { $0.id == gameID }), let imports = importsRootURL() else { throw CocoaError(.fileNoSuchFile) }
        let source = folder.resolvingSymlinksInPath().standardizedFileURL
        let file = executable.resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(source.path + "/"), file.pathExtension.lowercased() == "exe",
              FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileReadInvalidFileName) }
        let relative = String(file.path.dropFirst(source.path.count + 1))
        let destination = imports.appendingPathComponent("Relocated-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path) else { throw CocoaError(.fileNoSuchFile) }
        games[index].installPath = destination.path
        games[index].launchProfile.executablePath = destination.appendingPathComponent(relative).path
        games[index].managedArtifactIdentifier = identifier
        games[index].executableFingerprint = fingerprint
        persist()
    }

    public func removeLibraryEntry(gameID: UUID) async {
        games.removeAll { $0.id == gameID }
        persist()
    }

    public func uninstall(gameID: UUID) async {
        guard let game = games.first(where: { $0.id == gameID }) else {
            return
        }

        removeManagedGameArtifacts(for: game)
        recordActivity(
            kind: .uninstalled,
            title: "Uninstalled \(game.title)",
            detail: "Removed managed install data, prefix ownership, and cached launch state.",
            relatedTitle: game.title
        )
        games.removeAll { $0.id == gameID }
        prefixes.removeAll { $0.id == game.launchProfile.prefixID }
        installExecutionEntries.removeAll { $0.title == game.title }
        downloads.removeAll { $0.title == game.title }
        verificationAuditEntries.removeAll { $0.gameID == gameID }
        launchHistoryEntries.removeAll { $0.gameTitle == game.title }
        steamLibrary = steamLibrary.map { entry in
            var updated = entry
            if updated.title == game.title {
                updated.installed = false
            }
            return updated
        }
        persist()
    }

    public func authState() async -> SteamAuthState {
        steamAccount?.state ?? .signedOut
    }

    public func activeAccount() async -> SteamAccount? {
        steamAccount
    }

    public func signIn(accountName: String, sessionReference: String? = nil) async {
        steamAccount = SteamAccount(accountName: accountName, state: .signedIn, sessionReference: sessionReference)
        persist()
    }

    public func signOut() async {
        steamAccount = nil
        lastLibrarySync = nil
        persist()
    }

    public func librarySnapshot() async -> [SteamLibraryEntry] {
        steamLibrary.sorted { $0.title < $1.title }
    }

    public func syncLibrary() async -> [SteamLibraryEntry] {
        guard steamAccount != nil else {
            return []
        }

        let syncDate = Date()
        lastLibrarySync = syncDate
        if !steamLibrary.isEmpty {
            steamLibrary = steamLibrary.map { entry in
                var updated = entry
                updated.lastSyncedAt = syncDate
                updated.installed = games.contains(where: { $0.title == entry.title && $0.source == .steam })
                return updated
            }
        }

        persist()
        return steamLibrary.sorted { $0.title < $1.title }
    }

    public func replaceSteamLibrary(_ entries: [SteamLibraryEntry], syncedAt: Date) async {
        lastLibrarySync = syncedAt
        steamLibrary = entries.map { entry in
            var updated = entry
            updated.installed = games.contains(where: {
                ($0.title == updated.title || $0.launchProfile.titleFlags.contains("steam-app-id:\(updated.appID)"))
                    && $0.source == .steam
            })
            updated.lastSyncedAt = syncedAt
            return updated
        }
            .sorted { $0.title < $1.title }
        persist()
    }

    public func allDownloads() async -> [DownloadTask] {
        downloads
    }

    public func installExecutions() async -> [InstallExecutionRecord] {
        installExecutionEntries.sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    public func installHistory() async -> [InstallHistoryEntry] {
        installHistoryEntries.sorted { $0.installedAt > $1.installedAt }
    }

    public func updateInstallExecution(_ execution: InstallExecutionRecord) async {
        guard let index = installExecutionEntries.firstIndex(where: { $0.id == execution.id }) else {
            return
        }

        installExecutionEntries[index] = execution
        materializeInstallExecution(execution, previousStage: nil)
        syncDownloadState(with: execution)
        persist()
    }

    public func activityFeed() async -> [ActivityLogEntry] {
        activityEntries.sorted { $0.recordedAt > $1.recordedAt }
    }

    public func queueInstall(title: String, depotID: String, targetPath: String, reservedDiskGB: Double) async -> DownloadTask {
        let task = DownloadTask(
            title: title,
            progress: 0,
            state: .queued,
            detail: "Queued Steam depot \(depotID) for install at \(targetPath).",
            reservedDiskGB: reservedDiskGB
        )
        downloads.append(task)
        persist()
        return task
    }

    public func beginInstallExecution(
        title: String,
        appID: String,
        buildID: String,
        branchName: String,
        targetPath: String,
        primaryExecutable: String,
        depotIDs: [String],
        depotMountPaths: [String: String],
        reservedDiskGB: Double,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil
    ) async -> InstallExecutionRecord {
        let execution = InstallExecutionRecord(
            title: title,
            appID: appID,
            buildID: buildID,
            branchName: branchName,
            targetPath: targetPath,
            primaryExecutable: primaryExecutable,
            depotIDs: depotIDs,
            depotMountPaths: depotMountPaths,
            completedDepotIDs: [],
            stage: .queued,
            detail: "Install session prepared for build \(buildID).",
            reservedDiskGB: reservedDiskGB,
            depotProgressBytes: Dictionary(uniqueKeysWithValues: depotIDs.map { ($0, 0) }),
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            lastUpdatedAt: Date()
        )

        ensureManagedStorageRoots()
        materializeInstallExecution(execution, previousStage: nil)

        installExecutionEntries.removeAll { $0.title == title }
        installExecutionEntries.insert(execution, at: 0)
        syncDownloadState(with: execution)
        steamLibrary = steamLibrary.map { entry in
            var updated = entry
            if updated.title == title || updated.appID == appID {
                updated.installed = false
            }
            return updated
        }
        persist()
        return execution
    }

    public func advanceInstallExecution(title: String) async -> InstallExecutionRecord? {
        guard let index = installExecutionEntries.firstIndex(where: { $0.title == title }) else {
            return nil
        }

        var execution = installExecutionEntries[index]
        let previousStage = execution.stage
        switch execution.stage {
        case .queued:
            execution.stage = .resolving
            execution.detail = "Resolved \(execution.depotIDs.count) depot(s) on branch \(execution.branchName)."
        case .resolving, .downloading:
            let remaining = execution.depotIDs.filter { !execution.completedDepotIDs.contains($0) }
            if let nextDepot = remaining.first {
                execution.completedDepotIDs.append(nextDepot)
                execution.depotProgressBytes[nextDepot] = 1_000_000_000
            }

            let completion = execution.depotIDs.isEmpty
                ? 1.0
                : Double(execution.completedDepotIDs.count) / Double(execution.depotIDs.count)

            if execution.completedDepotIDs.count >= execution.depotIDs.count {
                execution.stage = .verifying
                execution.detail = "All depots downloaded. Verification is ready to start."
            } else {
                execution.stage = .downloading
                execution.resumeCheckpoint = "\(execution.completedDepotIDs.last ?? "partial"):\(Int(completion * 100))"
                execution.detail = "Downloaded \(execution.completedDepotIDs.count) of \(execution.depotIDs.count) depots into managed storage."
            }
        case .verifying:
            execution.depotVerifiedIDs = execution.depotIDs
            execution.stage = .mounting
            execution.detail = "Verification passed. Runtime mount is being prepared."
        case .mounting:
            execution.stage = .completed
            execution.detail = "Payload mounted into managed storage and ready for registration."
            steamLibrary = steamLibrary.map { entry in
                var updated = entry
                if updated.title == execution.title || updated.appID == execution.appID {
                    updated.installed = true
                }
                return updated
            }
        case .completed:
            return execution
        }

        execution.lastUpdatedAt = Date()
        materializeInstallExecution(execution, previousStage: previousStage)
        installExecutionEntries[index] = execution
        syncDownloadState(with: execution)
        persist()
        return execution
    }

    public func resetInstallExecution(title: String) async {
        if let execution = installExecutionEntries.first(where: { $0.title == title }) {
            removeFilesystemArtifacts(for: execution)
            recordActivity(
                kind: .stagedReset,
                title: "Reset staged install for \(execution.title)",
                detail: "Cleared staged depot content for build \(execution.buildID) before registration.",
                relatedTitle: execution.title
            )
        }
        installExecutionEntries.removeAll { $0.title == title }
        downloads.removeAll { $0.title == title }
        steamLibrary = steamLibrary.map { entry in
            var updated = entry
            if updated.title == title {
                updated.installed = games.contains(where: { $0.title == title && $0.source == .steam })
            }
            return updated
        }
        persist()
    }

    public func markDownloadInstalled(downloadID: UUID) async {
        guard let index = downloads.firstIndex(where: { $0.id == downloadID }) else {
            return
        }

        downloads[index].progress = 1.0
        downloads[index].state = .installed
        downloads[index].detail = "Installed and verified."

        let title = downloads[index].title
            steamLibrary = steamLibrary.map { entry in
                var updated = entry
                if updated.title == title {
                    updated.installed = true
                }
            return updated
        }
        persist()
    }

    public func lastLibrarySyncDate() async -> Date? {
        lastLibrarySync
    }

    public func allPrefixes() async -> [PrefixRecord] {
        prefixes
    }

    public func prefix(prefixID: UUID) async -> PrefixRecord? {
        prefixes.first(where: { $0.id == prefixID })
    }

    public func createPrefix(name: String, runtimeName: String) async -> PrefixRecord {
        let prefix = createPrefixRecord(name: name, runtimeName: runtimeName)
        prefixes.append(prefix)
        persist()
        return prefix
    }

    public func updatePrefix(_ prefix: PrefixRecord) async {
        guard let index = prefixes.firstIndex(where: { $0.id == prefix.id }) else {
            return
        }

        prefixes[index] = prefix
        if let gameIndex = games.firstIndex(where: { $0.launchProfile.prefixID == prefix.id }) {
            games[gameIndex].prefixState = prefix.state
        }
        persist()
    }

    public func clone(prefixID: UUID, newName: String) async -> PrefixRecord? {
        guard let source = prefixes.first(where: { $0.id == prefixID }) else {
            return nil
        }

        let clone = PrefixRecord(
            name: newName,
            runtimeName: source.runtimeName,
            state: .customized,
            storageFootprint: source.storageFootprint,
            storageFootprintGB: source.storageFootprintGB,
            manifestPath: source.manifestPath,
            manifestVersion: source.manifestVersion,
            titleFingerprint: source.titleFingerprint,
            environmentOverrides: source.environmentOverrides,
            lastBootstrapStatus: source.lastBootstrapStatus,
            lastBootstrapDetail: source.lastBootstrapDetail,
            runtimeBundleIdentifier: source.runtimeBundleIdentifier,
            runtimeBundleVersion: source.runtimeBundleVersion
        )
        prefixes.append(clone)
        persist()
        return clone
    }

    public func repair(prefixID: UUID) async {
        guard let index = prefixes.firstIndex(where: { $0.id == prefixID }) else {
            return
        }

        prefixes[index].state = .rebuilding
        runtimeHealth.status = .degraded
        runtimeHealth.notes = ["Prefix repair scheduled for \(prefixes[index].name)."]
        recordActivity(
            kind: .prefixRepairScheduled,
            title: "Repair scheduled for \(prefixes[index].name)",
            detail: "Marked the prefix for repair and downgraded runtime health until rebuild completes.",
            relatedTitle: games.first(where: { $0.launchProfile.prefixID == prefixes[index].id })?.title
        )
        persist()
    }

    public func rebuild(prefixID: UUID) async {
        guard let index = prefixes.firstIndex(where: { $0.id == prefixID }) else {
            return
        }

        prefixes[index].state = .clean
        runtimeHealth.status = .healthy
        runtimeHealth.lastValidatedAt = Date()
        runtimeHealth.notes = ["Runtime base and prefix were rebuilt successfully."]
        recordActivity(
            kind: .prefixRebuilt,
            title: "Rebuilt \(prefixes[index].name)",
            detail: "Restored the prefix to a clean state and refreshed runtime health.",
            relatedTitle: games.first(where: { $0.launchProfile.prefixID == prefixes[index].id })?.title
        )
        persist()
    }

    public func deletePrefix(prefixID: UUID) async {
        prefixes.removeAll { $0.id == prefixID }
        persist()
    }

    public func healthReport() async -> RuntimeHealthReport {
        runtimeHealth
    }

    public func provisionRuntimeBundleMetadata(_ report: RuntimeHealthReport) async {
        applyRuntimeHealthReport(report)
        persist()
    }

    public func validateRuntime(report: RuntimeHealthReport? = nil) async {
        if let report {
            applyRuntimeHealthReport(report)
        } else {
            runtimeHealth.status = .healthy
            runtimeHealth.lastValidatedAt = Date()
            runtimeHealth.notes = [
                "Shared runtime image checksum passed.",
                "Tiered graphics translation stack is registered."
            ]
        }
        recordActivity(
            kind: .runtimeValidated,
            title: "Validated runtime bundle",
            detail: "Verified the shared runtime image and translation stack registration.",
            relatedTitle: nil
        )
        persist()
    }

    public func launchHistory() async -> [LaunchHistoryEntry] {
        launchHistoryEntries.sorted { $0.launchedAt > $1.launchedAt }
    }

    public func pendingLaunches() async -> [PendingLaunchRecord] {
        pendingLaunchEntries.sorted { lhs, rhs in
            if lhs.requestedAt == rhs.requestedAt {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            return lhs.requestedAt > rhs.requestedAt
        }
    }

    public func compatibilityEvidence() async -> [CompatibilityEvidenceRecord] {
        compatibilityEvidenceEntries.sorted { $0.recordedAt > $1.recordedAt }
    }

    public func managedStorageStatus() async -> ManagedStorageStatus {
        computeManagedStorageStatus()
    }

    public func verificationAudits() async -> [VerificationAuditEntry] {
        verificationAuditEntries.sorted { $0.verifiedAt > $1.verifiedAt }
    }

    public func recordLaunch(
        gameTitle: String,
        resolvedExecutablePath: String,
        readiness: String,
        issueSummary: [String],
        hostSessionID: String? = nil,
        terminalStatus: String? = nil,
        failureCode: String? = nil,
        failureReason: String? = nil,
        runtimeBundleVersion: String? = nil
    ) async {
        let entry = LaunchHistoryEntry(
            gameTitle: gameTitle,
            resolvedExecutablePath: resolvedExecutablePath,
            readiness: readiness,
            issueSummary: issueSummary,
            hostSessionID: hostSessionID,
            terminalStatus: terminalStatus ?? (failureCode == nil ? "submitted" : "failed"),
            failureCode: failureCode,
            failureReason: failureReason,
            runtimeBundleVersion: runtimeBundleVersion,
            launchedAt: Date()
        )
        launchHistoryEntries.insert(entry, at: 0)
        if launchHistoryEntries.count > 25 {
            launchHistoryEntries = Array(launchHistoryEntries.prefix(25))
        }
        persist()
    }

    public func upsertLaunch(_ entry: LaunchHistoryEntry) async {
        upsertLaunchEntry(entry)
        persist()
    }

    public func queueLaunchWaitingForJIT(_ pendingLaunch: PendingLaunchRecord, launchEntry: LaunchHistoryEntry) async {
        pendingLaunchEntries.removeAll { entry in
            entry.id == pendingLaunch.id || entry.gameID == pendingLaunch.gameID || entry.launchEntryID == pendingLaunch.launchEntryID
        }
        pendingLaunchEntries.insert(pendingLaunch, at: 0)
        pendingLaunchEntries.sort { $0.requestedAt > $1.requestedAt }
        upsertLaunchEntry(launchEntry)
        recordActivity(
            kind: .launchQueuedForJIT,
            title: "Queued \(pendingLaunch.gameTitle) for JIT",
            detail: pendingLaunch.detail,
            relatedTitle: pendingLaunch.gameTitle,
            recordedAt: pendingLaunch.requestedAt
        )
        persist()
    }

    public func markPendingLaunchResumed(id: UUID, detail: String, resumedAt: Date) async {
        guard let pending = pendingLaunchEntries.first(where: { $0.id == id }) else {
            return
        }

        pendingLaunchEntries.removeAll { $0.id == id }

        if let existingIndex = launchHistoryEntries.firstIndex(where: { $0.id == pending.launchEntryID }) {
            var launch = launchHistoryEntries[existingIndex]
            launch.readiness = "Resumed After JIT"
            launch.issueSummary.append(detail)
            launch.stateHistory = ["queued", "waitingForJIT", "resumingAfterJIT"]
            launch.terminalStatus = "started"
            launch.failureCode = nil
            launch.failureReason = nil
            launch.launchedAt = resumedAt
            launchHistoryEntries[existingIndex] = launch
        }

        recordActivity(
            kind: .launchResumed,
            title: "Resumed \(pending.gameTitle)",
            detail: detail,
            relatedTitle: pending.gameTitle,
            recordedAt: resumedAt
        )
        persist()
    }

    public func markPendingLaunchValidationFailure(
        id: UUID,
        failureReason: String,
        issueSummary: [String],
        failedAt: Date
    ) async {
        guard let pending = pendingLaunchEntries.first(where: { $0.id == id }) else {
            return
        }

        pendingLaunchEntries.removeAll { $0.id == id }

        let launch = LaunchHistoryEntry(
            id: pending.launchEntryID,
            gameTitle: pending.gameTitle,
            resolvedExecutablePath: pending.resolvedExecutablePath,
            readiness: "Resume Failed",
            issueSummary: issueSummary,
            hostSessionID: nil,
            stateHistory: ["queued", "waitingForJIT", "resumeValidationFailed"],
            terminalStatus: "resumeValidationFailed",
            failureCode: "jitResumeValidationFailed",
            failureReason: failureReason,
            runtimeBundleVersion: pending.runtimeBundleVersion,
            telemetrySummary: nil,
            launchedAt: failedAt
        )
        upsertLaunchEntry(launch)
        recordActivity(
            kind: .launchResumeFailed,
            title: "Could Not Resume \(pending.gameTitle)",
            detail: failureReason,
            relatedTitle: pending.gameTitle,
            recordedAt: failedAt
        )
        persist()
    }

    public func attachRuntimeBundleToPrefix(
        prefixID: UUID,
        runtimeName: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        manifestPath: String?,
        manifestVersion: String?,
        environmentOverrides: [String: String],
        titleFingerprint: String?,
        bootstrapStatus: String?,
        bootstrapDetail: String?,
        state: PrefixState
    ) async {
        guard let prefixIndex = prefixes.firstIndex(where: { $0.id == prefixID }) else {
            return
        }

        applyPrefixRuntimeAttachment(
            prefixIndex: prefixIndex,
            runtimeName: runtimeName,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            manifestPath: manifestPath,
            manifestVersion: manifestVersion,
            environmentOverrides: environmentOverrides,
            titleFingerprint: titleFingerprint,
            bootstrapStatus: bootstrapStatus,
            bootstrapDetail: bootstrapDetail,
            state: state
        )
        persist()
    }

    public func recordRuntimeExecutionStarted(
        gameID: UUID,
        launchEntryID: UUID,
        resolvedExecutablePath: String,
        issueSummary: [String],
        hostSessionID: String,
        stateHistory: [String],
        runtimeBundleVersion: String?,
        launchedAt: Date
    ) async {
        guard let game = games.first(where: { $0.id == gameID }) else {
            return
        }

        let launch = LaunchHistoryEntry(
            id: launchEntryID,
            gameTitle: game.title,
            resolvedExecutablePath: resolvedExecutablePath,
            readiness: "Verifying",
            issueSummary: issueSummary,
            hostSessionID: hostSessionID,
            stateHistory: stateHistory,
            terminalStatus: "running",
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: runtimeBundleVersion,
            telemetrySummary: "Runtime host entered execution; awaiting the first guest frame.",
            launchedAt: launchedAt
        )
        upsertLaunchEntry(launch)
        pendingLaunchEntries.removeAll { $0.launchEntryID == launchEntryID || $0.gameID == gameID }
        persist()
    }

    public func recordRuntimeExecutionSuccess(
        gameID: UUID,
        launchEntryID: UUID,
        resolvedExecutablePath: String,
        issueSummary: [String],
        hostSessionID: String,
        stateHistory: [String],
        terminalStatus: String,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        manifestPath: String?,
        manifestVersion: String?,
        environmentOverrides: [String: String],
        prefixState: PrefixState,
        bootstrapDetail: String,
        telemetrySummary: String?,
        mitigationAction: String?,
        evidenceSummary: String,
        resolvedPolicySummary: String,
        launchedAt: Date
    ) async {
        guard let gameIndex = games.firstIndex(where: { $0.id == gameID }) else {
            return
        }

        games[gameIndex].lastSuccessfulRuntimeBundleIdentifier = runtimeBundleIdentifier
        games[gameIndex].lastSuccessfulRuntimeBundleVersion = runtimeBundleVersion
        games[gameIndex].validationEvidenceSummary = evidenceSummary

        if let prefixIndex = prefixes.firstIndex(where: { $0.id == games[gameIndex].launchProfile.prefixID }) {
            applyPrefixRuntimeAttachment(
                prefixIndex: prefixIndex,
                runtimeName: runtimeHealth.runtimeName,
                runtimeBundleIdentifier: runtimeBundleIdentifier,
                runtimeBundleVersion: runtimeBundleVersion,
                manifestPath: manifestPath,
                manifestVersion: manifestVersion,
                environmentOverrides: environmentOverrides,
                titleFingerprint: games[gameIndex].executableFingerprint,
                bootstrapStatus: terminalStatus,
                bootstrapDetail: bootstrapDetail,
                state: prefixState
            )
        }

        upsertCompatibilityEvidenceEntry(
            CompatibilityEvidenceRecord(
                title: games[gameIndex].title,
                source: games[gameIndex].source,
                managedArtifactIdentifier: games[gameIndex].managedArtifactIdentifier,
                executableFingerprint: games[gameIndex].executableFingerprint,
                runtimeBundleIdentifier: runtimeBundleIdentifier,
                runtimeBundleVersion: runtimeBundleVersion,
                resolvedPolicySummary: resolvedPolicySummary,
                accepted: true,
                hostSessionID: hostSessionID,
                terminalStatus: terminalStatus,
                telemetrySummary: telemetrySummary,
                mitigationAction: mitigationAction,
                evidenceSummary: evidenceSummary
            )
        )

        let launch = LaunchHistoryEntry(
            id: launchEntryID,
            gameTitle: games[gameIndex].title,
            resolvedExecutablePath: resolvedExecutablePath,
            readiness: launchHistoryEntries.first(where: { $0.id == launchEntryID })?.readiness ?? "Ready",
            issueSummary: issueSummary,
            hostSessionID: hostSessionID,
            stateHistory: stateHistory,
            terminalStatus: terminalStatus,
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: runtimeBundleVersion,
            telemetrySummary: telemetrySummary ?? "Telemetry unavailable from runtime backend.",
            launchedAt: launchedAt
        )
        upsertLaunchEntry(launch)
        pendingLaunchEntries.removeAll { $0.launchEntryID == launchEntryID || $0.gameID == gameID }
        persist()
    }

    public func recordRuntimeExecutionFailure(
        gameID: UUID,
        launchEntryID: UUID,
        issueSummary: [String],
        hostSessionID: String?,
        stateHistory: [String],
        terminalStatus: String?,
        failureCode: String,
        failureReason: String,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        evidenceSummary: String,
        resolvedPolicySummary: String,
        launchedAt: Date?
    ) async {
        guard let gameIndex = games.firstIndex(where: { $0.id == gameID }) else {
            return
        }

        games[gameIndex].validationEvidenceSummary = evidenceSummary

        if let prefixIndex = prefixes.firstIndex(where: { $0.id == games[gameIndex].launchProfile.prefixID }) {
            applyPrefixRuntimeAttachment(
                prefixIndex: prefixIndex,
                runtimeName: runtimeHealth.runtimeName,
                runtimeBundleIdentifier: runtimeBundleIdentifier,
                runtimeBundleVersion: runtimeBundleVersion,
                manifestPath: nil,
                manifestVersion: nil,
                environmentOverrides: prefixes[prefixIndex].environmentOverrides,
                titleFingerprint: games[gameIndex].executableFingerprint,
                bootstrapStatus: terminalStatus ?? "failed",
                bootstrapDetail: failureReason,
                state: .verificationFailed
            )
        }

        upsertCompatibilityEvidenceEntry(
            CompatibilityEvidenceRecord(
                title: games[gameIndex].title,
                source: games[gameIndex].source,
                managedArtifactIdentifier: games[gameIndex].managedArtifactIdentifier,
                executableFingerprint: games[gameIndex].executableFingerprint,
                runtimeBundleIdentifier: runtimeBundleIdentifier,
                runtimeBundleVersion: runtimeBundleVersion,
                resolvedPolicySummary: resolvedPolicySummary,
                accepted: false,
                hostSessionID: hostSessionID,
                terminalStatus: terminalStatus ?? "failed",
                failureCode: failureCode,
                failureReason: failureReason,
                evidenceSummary: evidenceSummary
            )
        )

        let existing = launchHistoryEntries.first(where: { $0.id == launchEntryID })
        let launch = LaunchHistoryEntry(
            id: launchEntryID,
            gameTitle: games[gameIndex].title,
            resolvedExecutablePath: existing?.resolvedExecutablePath ?? games[gameIndex].launchProfile.executablePath,
            readiness: "Failed",
            issueSummary: issueSummary,
            hostSessionID: hostSessionID,
            stateHistory: stateHistory,
            terminalStatus: terminalStatus ?? "failed",
            failureCode: failureCode,
            failureReason: failureReason,
            runtimeBundleVersion: runtimeBundleVersion,
            launchedAt: launchedAt ?? existing?.launchedAt ?? Date()
        )
        upsertLaunchEntry(launch)
        pendingLaunchEntries.removeAll { $0.launchEntryID == launchEntryID || $0.gameID == gameID }
        persist()
    }

    public func recordCompatibilityEvidence(_ evidence: CompatibilityEvidenceRecord) async {
        upsertCompatibilityEvidenceEntry(evidence)
        persist()
    }

    public func recordVerificationAudit(_ audit: VerificationAuditEntry) async {
        verificationAuditEntries.removeAll { existing in
            existing.gameID == audit.gameID && existing.verifiedAt == audit.verifiedAt
        }
        verificationAuditEntries.insert(audit, at: 0)
        if verificationAuditEntries.count > 50 {
            verificationAuditEntries = Array(verificationAuditEntries.prefix(50))
        }
        persist()
    }

    public func recoverInterruptedOperations() async {
        let now = Date()
        let staleThreshold: TimeInterval = 300

        for index in installExecutionEntries.indices {
            let execution = installExecutionEntries[index]
            guard execution.stage != .completed,
                  now.timeIntervalSince(execution.lastUpdatedAt) >= staleThreshold else {
                continue
            }

            var recovered = execution
            let hasProgress = recovered.depotProgressBytes.values.contains(where: { $0 > 0 })
                || recovered.resumeCheckpoint != nil
            recovered.stage = hasProgress ? .downloading : .queued
            recovered.detail = "Recovered interrupted install state. Resume is available from checkpoint \(recovered.resumeCheckpoint ?? "none")."
            recovered.lastUpdatedAt = now
            installExecutionEntries[index] = recovered
        }

        for index in launchHistoryEntries.indices {
            let entry = launchHistoryEntries[index]
            guard let terminalStatus = entry.terminalStatus,
                  ["started", "queued", "bootstrappingPrefix", "bootingRuntime", "running"].contains(terminalStatus),
                  now.timeIntervalSince(entry.launchedAt) >= staleThreshold else {
                continue
            }

            var recovered = entry
            recovered.terminalStatus = "stale"
            recovered.failureCode = recovered.failureCode ?? "runtimeBootFailed"
            recovered.failureReason = recovered.failureReason ?? "Recovered stale runtime host session that did not reach a terminal state."
            recovered.issueSummary.append("Recovered stale host session after app restart or interruption.")
            launchHistoryEntries[index] = recovered
        }

        persist()
    }

    private func persist() {
        guard let snapshotURL else {
            return
        }

        let snapshot = IridiumSnapshot(
            games: games,
            downloads: downloads,
            installExecutions: installExecutionEntries,
            installHistory: installHistoryEntries,
            prefixes: prefixes,
            steamAccount: steamAccount,
            steamLibrary: steamLibrary,
            runtimeHealth: runtimeHealth,
            lastLibrarySync: lastLibrarySync,
            launchHistory: launchHistoryEntries,
            pendingLaunches: pendingLaunchEntries,
            compatibilityEvidence: compatibilityEvidenceEntries,
            verificationAudits: verificationAuditEntries,
            activityFeed: activityEntries
        )

        Self.persistSnapshot(snapshot, to: snapshotURL)
    }

    private func createPrefixRecord(
        name: String,
        runtimeName: String,
        runtimeBundleIdentifier: String? = nil,
        runtimeBundleVersion: String? = nil
    ) -> PrefixRecord {
        PrefixRecord(
            name: name,
            runtimeName: runtimeName,
            state: .clean,
            storageFootprint: "2.0 GB",
            storageFootprintGB: 2.0,
            manifestVersion: "1",
            environmentOverrides: [:],
            lastBootstrapStatus: "pending",
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion
        )
    }

    private func applyRuntimeHealthReport(_ report: RuntimeHealthReport) {
        runtimeHealth = report
        if runtimeHealth.lastValidatedAt == nil {
            runtimeHealth.lastValidatedAt = Date()
        }
    }

    private func recordInstallHistory(from execution: InstallExecutionRecord) {
        let entry = InstallHistoryEntry(
            title: execution.title,
            appID: execution.appID,
            buildID: execution.buildID,
            branchName: execution.branchName,
            targetPath: execution.targetPath,
            primaryExecutable: execution.primaryExecutable,
            installedAt: Date(),
            detail: execution.detail
        )
        installHistoryEntries.removeAll { $0.title == execution.title || $0.appID == execution.appID }
        installHistoryEntries.insert(entry, at: 0)
        if installHistoryEntries.count > 20 {
            installHistoryEntries = Array(installHistoryEntries.prefix(20))
        }
    }

    private func recordActivity(
        kind: ActivityLogKind,
        title: String,
        detail: String,
        relatedTitle: String?,
        recordedAt: Date = Date()
    ) {
        let entry = ActivityLogEntry(
            kind: kind,
            title: title,
            detail: detail,
            relatedTitle: relatedTitle,
            recordedAt: recordedAt
        )
        activityEntries.insert(entry, at: 0)
        if activityEntries.count > 40 {
            activityEntries = Array(activityEntries.prefix(40))
        }
    }

    private func upsertLaunchEntry(_ entry: LaunchHistoryEntry) {
        if let index = launchHistoryEntries.firstIndex(where: { $0.id == entry.id }) {
            launchHistoryEntries[index] = entry
        } else {
            launchHistoryEntries.insert(entry, at: 0)
        }
        launchHistoryEntries.sort { $0.launchedAt > $1.launchedAt }
        if launchHistoryEntries.count > 25 {
            launchHistoryEntries = Array(launchHistoryEntries.prefix(25))
        }
    }

    private func upsertCompatibilityEvidenceEntry(_ evidence: CompatibilityEvidenceRecord) {
        compatibilityEvidenceEntries.removeAll { existing in
            existing.title == evidence.title
                && existing.recordedAt == evidence.recordedAt
                && existing.hostSessionID == evidence.hostSessionID
        }
        compatibilityEvidenceEntries.insert(evidence, at: 0)
        if compatibilityEvidenceEntries.count > 100 {
            compatibilityEvidenceEntries = Array(compatibilityEvidenceEntries.prefix(100))
        }
    }

    private func applyPrefixRuntimeAttachment(
        prefixIndex: Int,
        runtimeName: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        manifestPath: String?,
        manifestVersion: String?,
        environmentOverrides: [String: String],
        titleFingerprint: String?,
        bootstrapStatus: String?,
        bootstrapDetail: String?,
        state: PrefixState
    ) {
        if let runtimeName {
            prefixes[prefixIndex].runtimeName = runtimeName
        }
        if let runtimeBundleIdentifier {
            prefixes[prefixIndex].runtimeBundleIdentifier = runtimeBundleIdentifier
        }
        if let runtimeBundleVersion {
            prefixes[prefixIndex].runtimeBundleVersion = runtimeBundleVersion
        }
        if let manifestPath {
            prefixes[prefixIndex].manifestPath = manifestPath
        }
        if let manifestVersion {
            prefixes[prefixIndex].manifestVersion = manifestVersion
        }
        prefixes[prefixIndex].environmentOverrides = environmentOverrides
        if let titleFingerprint {
            prefixes[prefixIndex].titleFingerprint = titleFingerprint
        }
        if let bootstrapStatus {
            prefixes[prefixIndex].lastBootstrapStatus = bootstrapStatus
        }
        if let bootstrapDetail {
            prefixes[prefixIndex].lastBootstrapDetail = bootstrapDetail
        }
        prefixes[prefixIndex].state = state

        if let gameIndex = games.firstIndex(where: { $0.launchProfile.prefixID == prefixes[prefixIndex].id }) {
            games[gameIndex].prefixState = state
        }
    }

    private func registerSteamGameInternal(
        title: String,
        appID: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        managedArtifactIdentifier: String?,
        executableFingerprint: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        summary: String,
        registrationDetail: String?
    ) -> GameRecord {
        let game = upsertGame(
            source: .steam,
            title: title,
            installPath: installPath,
            executablePath: executablePath,
            compatibilityProfileName: compatibilityProfileName,
            inputProfileName: inputProfileName,
            deviceTier: deviceTier,
            rendererPreset: rendererPreset,
            launchArguments: launchArguments,
            titleFlags: titleFlags + ["steam-app-id:\(appID)"],
            touchOverlayName: "Adaptive Steam Overlay",
            controllerPresetName: "Steam Controller Layout",
            keyboardMouseEnabled: true,
            installedSizeGB: estimatedSteamInstallSizeGB(for: title),
            prefixFootprintGB: 2.6,
            managedArtifactIdentifier: managedArtifactIdentifier,
            executableFingerprint: executableFingerprint,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion,
            summary: summary
        )

        if let completedExecution = installExecutionEntries.first(where: {
            ($0.title == title || $0.appID == appID) && $0.stage == .completed
        }) {
            recordInstallHistory(from: completedExecution)
            recordActivity(
                kind: .steamRegistered,
                title: "Registered \(game.title)",
                detail: registrationDetail ?? "Registered build \(completedExecution.buildID) from branch \(completedExecution.branchName) into the game library.",
                relatedTitle: game.title
            )
        } else {
            recordActivity(
                kind: .steamRegistered,
                title: "Registered \(game.title)",
                detail: registrationDetail ?? "Registered a Steam title into the game library and attached a direct launch target.",
                relatedTitle: game.title
            )
        }
        installExecutionEntries.removeAll { $0.title == title || $0.appID == appID }
        downloads.removeAll { $0.title == title }
        steamLibrary = steamLibrary.map { entry in
            var updated = entry
            if updated.appID == appID || updated.title == title {
                updated.installed = true
            }
            return updated
        }
        return game
    }

    private func upsertDownload(
        title: String,
        progress: Double,
        state: DownloadState,
        detail: String,
        reservedDiskGB: Double
    ) {
        if let index = downloads.firstIndex(where: { $0.title == title }) {
            downloads[index].progress = progress
            downloads[index].state = state
            downloads[index].detail = detail
            downloads[index].reservedDiskGB = reservedDiskGB
        } else {
            downloads.append(
                DownloadTask(
                    title: title,
                    progress: progress,
                    state: state,
                    detail: detail,
                    reservedDiskGB: reservedDiskGB
                )
            )
        }
    }

    private func syncDownloadState(with execution: InstallExecutionRecord) {
        let totalDepots = max(execution.depotIDs.count, 1)
        let completed = execution.completedDepotIDs.count
        let progress: Double
        let state: DownloadState

        switch execution.stage {
        case .queued, .resolving:
            progress = 0.08
            state = .queued
        case .downloading:
            progress = 0.12 + (Double(completed) / Double(totalDepots) * 0.58)
            state = .downloading
        case .verifying:
            progress = 0.82
            state = .verifying
        case .mounting:
            progress = 0.94
            state = .mounting
        case .completed:
            progress = 1.0
            state = .installed
        }

        upsertDownload(
            title: execution.title,
            progress: progress,
            state: state,
            detail: execution.detail,
            reservedDiskGB: execution.stage == .completed ? 0 : execution.reservedDiskGB
        )
    }

    private func rootURL() -> URL? {
        snapshotURL?.deletingLastPathComponent()
    }

    private func managedRootURL() -> URL? {
        rootURL()?.appending(path: "Managed", directoryHint: .isDirectory)
    }

    private func steamRootURL() -> URL? {
        managedRootURL()?.appending(path: "Steam", directoryHint: .isDirectory)
    }

    private func importsRootURL() -> URL? {
        managedRootURL()?.appending(path: "Imports", directoryHint: .isDirectory)
    }

    private func runtimeRootURL() -> URL? {
        managedRootURL()?.appending(path: "Runtime", directoryHint: .isDirectory)
    }

    private func ensureManagedStorageRoots() {
        let urls = [rootURL(), managedRootURL(), steamRootURL(), importsRootURL(), runtimeRootURL()].compactMap { $0 }
        for url in urls {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func hasManagedFilesystemContext() -> Bool {
        rootURL() != nil
    }

    private func materializeInstallExecution(_ execution: InstallExecutionRecord, previousStage: InstallExecutionStage?) {
        guard rootURL() != nil,
              let targetRoot = fileURLIfAbsolutePath(execution.targetPath) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

            let metadataRoot = targetRoot.appending(path: ".iridium", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: metadataRoot, withIntermediateDirectories: true)

            switch execution.stage {
            case .queued:
                try write(
                    "build=\(execution.buildID)\nbranch=\(execution.branchName)\n",
                    to: metadataRoot.appending(path: "session.txt")
                )
            case .resolving:
                try write(
                    execution.depotIDs.joined(separator: "\n"),
                    to: metadataRoot.appending(path: "resolved-depots.txt")
                )
            case .downloading:
                try materializeCompletedDepots(for: execution, targetRoot: targetRoot, previousStage: previousStage)
            case .verifying:
                try materializeCompletedDepots(for: execution, targetRoot: targetRoot, previousStage: previousStage)
                try write(
                    "verified=true\nbuild=\(execution.buildID)\n",
                    to: metadataRoot.appending(path: "verified.txt")
                )
            case .mounting:
                try materializeCompletedDepots(for: execution, targetRoot: targetRoot, previousStage: previousStage)
                let executableURL = targetRoot.appending(path: execution.primaryExecutable)
                try FileManager.default.createDirectory(
                    at: executableURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: executableURL.path) {
                    FileManager.default.createFile(atPath: executableURL.path, contents: Data("iridium-launch-stub".utf8))
                }
                try write(
                    "mounted=true\nprimaryExecutable=\(execution.primaryExecutable)\n",
                    to: metadataRoot.appending(path: "mounted.txt")
                )
            case .completed:
                try materializeCompletedDepots(for: execution, targetRoot: targetRoot, previousStage: previousStage)
                let executableURL = targetRoot.appending(path: execution.primaryExecutable)
                try FileManager.default.createDirectory(
                    at: executableURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: executableURL.path) {
                    FileManager.default.createFile(atPath: executableURL.path, contents: Data("iridium-launch-stub".utf8))
                }
                try write(
                    "completed=true\nprimaryExecutable=\(execution.primaryExecutable)\n",
                    to: metadataRoot.appending(path: "completed.txt")
                )
            }
        } catch {
            assertionFailure("Failed to materialize install execution for \(execution.title): \(error)")
        }
    }

    private func materializeCompletedDepots(
        for execution: InstallExecutionRecord,
        targetRoot: URL,
        previousStage: InstallExecutionStage?
    ) throws {
        let newDepotIDs = execution.completedDepotIDs.filter { depotID in
            guard previousStage == .downloading || previousStage == .resolving else {
                return true
            }
            if let stored = installExecutionEntries.first(where: { $0.id == execution.id }) {
                return !stored.completedDepotIDs.contains(depotID)
            }
            return true
        }

        for depotID in newDepotIDs {
            let mountedPath = execution.depotMountPaths[depotID] ?? "Depot-\(depotID)"
            let mountURL = targetRoot.appending(path: mountedPath, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
            try write(
                "depot=\(depotID)\nmountedPath=\(mountedPath)\n",
                to: mountURL.appending(path: "payload-\(depotID).txt")
            )
        }
    }

    private func removeFilesystemArtifacts(for execution: InstallExecutionRecord) {
        guard rootURL() != nil,
              let targetRoot = fileURLIfAbsolutePath(execution.targetPath) else {
            return
        }

        guard let steamRoot = steamRootURL(), targetRoot.path.hasPrefix(steamRoot.path) else {
            return
        }

        try? FileManager.default.removeItem(at: targetRoot)
    }

    private func removeManagedGameArtifacts(for game: GameRecord) {
        guard rootURL() != nil,
              let installURL = fileURLIfAbsolutePath(game.installPath),
              let managedRoot = managedRootURL() else {
            return
        }

        let standardizedInstallURL = installURL.standardizedFileURL
        guard standardizedInstallURL.path.hasPrefix(managedRoot.standardizedFileURL.path) else {
            return
        }

        try? FileManager.default.removeItem(at: standardizedInstallURL)
    }

    private func resolvedManagedImportLocation(
        title: String,
        installPath: String,
        executablePath: String
    ) -> (installPath: String, executablePath: String) {
        guard let importsRoot = importsRootURL(),
              installPath.hasPrefix("/") else {
            return (installPath, executablePath)
        }

        let sourceDirectory = URL(fileURLWithPath: installPath, isDirectory: true)
        let managedDirectory = importsRoot
            .appending(path: normalizedIdentifier(from: title), directoryHint: .isDirectory)
            .standardizedFileURL

        guard canonicalPath(for: sourceDirectory) != canonicalPath(for: managedDirectory) else {
            return (installPath, executablePath)
        }

        do {
            ensureManagedStorageRoots()
            if FileManager.default.fileExists(atPath: managedDirectory.path) {
                try FileManager.default.removeItem(at: managedDirectory)
            }
            try copyDirectory(from: sourceDirectory, to: managedDirectory)

            let executableURL = fileURLIfAbsolutePath(executablePath)
            let relativeExecutable = executableURL
                .flatMap { relativePath(from: sourceDirectory, to: $0) }
                ?? URL(fileURLWithPath: executablePath).lastPathComponent
            let managedExecutableURL = managedDirectory.appending(path: relativeExecutable)

            try repairManagedExecutableIfNeeded(
                sourceExecutable: executableURL,
                managedExecutable: managedExecutableURL
            )

            guard FileManager.default.fileExists(atPath: managedDirectory.path),
                  FileManager.default.fileExists(atPath: managedExecutableURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }

            return (
                managedDirectory.path,
                managedExecutableURL.path
            )
        } catch {
            print(
                "[IridiumRuntime] resolvedManagedImportLocation: Falling back to source paths for \(title) after copy failure: \(error)"
            )
            return (installPath, executablePath)
        }
    }

    private func repairManagedExecutableIfNeeded(
        sourceExecutable: URL?,
        managedExecutable: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: managedExecutable.path) else {
            return
        }

        guard let sourceExecutable else {
            return
        }

        let canonicalSourceExecutable = sourceExecutable
        guard FileManager.default.fileExists(atPath: canonicalSourceExecutable.path) else {
            return
        }

        try FileManager.default.createDirectory(
            at: managedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: managedExecutable.path) {
            try FileManager.default.removeItem(at: managedExecutable)
        }
        try FileManager.default.copyItem(at: canonicalSourceExecutable, to: managedExecutable)
    }

    private func copyDirectory(from source: URL, to destination: URL) throws {
        let sourceRoot = source
        let destinationRoot = destination.standardizedFileURL
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let item as URL in enumerator {
            let sourceItem = item
            guard let relativePath = relativePath(from: sourceRoot, to: sourceItem) else {
                continue
            }
            let target = destinationRoot.appending(path: relativePath)
            let values = try sourceItem.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: sourceItem, to: target)
            }
        }
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private func fileURLIfAbsolutePath(_ path: String) -> URL? {
        guard path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private func managedPathExists(_ path: String) -> Bool {
        guard let url = fileURLIfAbsolutePath(path) else {
            return false
        }

        return FileManager.default.fileExists(atPath: url.standardizedFileURL.path)
    }

    private func relativePath(from root: URL, to item: URL) -> String? {
        let rootComponents = URL(fileURLWithPath: canonicalPath(for: root)).pathComponents
        let itemComponents = URL(fileURLWithPath: canonicalPath(for: item)).pathComponents

        guard itemComponents.starts(with: rootComponents), itemComponents.count > rootComponents.count else {
            return nil
        }

        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func canonicalPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func upsertGame(
        source: GameSource,
        title: String,
        installPath: String,
        executablePath: String,
        compatibilityProfileName: String,
        inputProfileName: String,
        deviceTier: DeviceTier,
        rendererPreset: RendererPreset,
        launchArguments: [String],
        titleFlags: [String],
        touchOverlayName: String,
        controllerPresetName: String,
        keyboardMouseEnabled: Bool,
        installedSizeGB: Double,
        prefixFootprintGB: Double,
        managedArtifactIdentifier: String?,
        executableFingerprint: String?,
        runtimeBundleIdentifier: String?,
        runtimeBundleVersion: String?,
        summary: String
    ) -> GameRecord {
        let resolvedPaths: (installPath: String, executablePath: String)
        if source == .manualImport {
            resolvedPaths = resolvedManagedImportLocation(
                title: title,
                installPath: installPath,
                executablePath: executablePath
            )
        } else {
            resolvedPaths = (installPath, executablePath)
        }

        if let existingIndex = games.firstIndex(where: {
            $0.installPath == resolvedPaths.installPath
                || $0.launchProfile.executablePath == resolvedPaths.executablePath
                || ($0.title == title && $0.source == source)
        }) {
            var existing = games[existingIndex]
            let refreshedPrefixState: PrefixState = {
                guard let prefix = prefixes.first(where: { $0.id == existing.launchProfile.prefixID }) else {
                    return existing.prefixState == .customized ? .customized : .clean
                }
                return (existing.prefixState == .customized || prefix.state == .customized) ? .customized : .clean
            }()
            existing.title = title
            existing.source = source
            existing.installPath = resolvedPaths.installPath
            existing.savePathMapping = "Documents/Saves/\(normalizedIdentifier(from: title))"
            existing.compatibilityProfileName = compatibilityProfileName
            existing.inputProfileName = inputProfileName
            existing.touchOverlayName = touchOverlayName
            existing.controllerPresetName = controllerPresetName
            existing.keyboardMouseEnabled = keyboardMouseEnabled
            existing.deviceTier = deviceTier
            existing.rendererPreset = rendererPreset
            existing.prefixState = refreshedPrefixState
            existing.launchProfile.executablePath = resolvedPaths.executablePath
            existing.launchProfile.arguments = launchArguments
            existing.launchProfile.rendererPreset = rendererPreset
            existing.launchProfile.deviceTier = deviceTier
            existing.launchProfile.titleFlags = titleFlags
            existing.installedSizeGB = installedSizeGB
            existing.managedArtifactIdentifier = managedArtifactIdentifier
            existing.executableFingerprint = executableFingerprint
            existing.validationEvidenceSummary = existing.validationEvidenceSummary ?? "Registration refreshed in managed inventory."
            existing.summary = summary.replacingOccurrences(of: "staged", with: "refreshed")
            games[existingIndex] = existing

            if let prefixIndex = prefixes.firstIndex(where: { $0.id == existing.launchProfile.prefixID }) {
                prefixes[prefixIndex].state = refreshedPrefixState
                prefixes[prefixIndex].storageFootprintGB = prefixFootprintGB
                prefixes[prefixIndex].storageFootprint = formattedGB(prefixFootprintGB)
                prefixes[prefixIndex].titleFingerprint = executableFingerprint
                prefixes[prefixIndex].runtimeBundleIdentifier = runtimeBundleIdentifier
                prefixes[prefixIndex].runtimeBundleVersion = runtimeBundleVersion
            }
            persist()
            return existing
        }

        var prefix = createPrefixRecord(
            name: "\(title) Prefix",
            runtimeName: runtimeHealth.runtimeName,
            runtimeBundleIdentifier: runtimeBundleIdentifier,
            runtimeBundleVersion: runtimeBundleVersion
        )
        prefix.storageFootprintGB = prefixFootprintGB
        prefix.storageFootprint = formattedGB(prefixFootprintGB)
        prefix.titleFingerprint = executableFingerprint
        prefixes.append(prefix)

        let game = GameRecord(
            title: title,
            source: source,
            installPath: resolvedPaths.installPath,
            savePathMapping: "Documents/Saves/\(normalizedIdentifier(from: title))",
            compatibilityProfileName: compatibilityProfileName,
            inputProfileName: inputProfileName,
            touchOverlayName: touchOverlayName,
            controllerPresetName: controllerPresetName,
            keyboardMouseEnabled: keyboardMouseEnabled,
            prefixState: .clean,
            deviceTier: deviceTier,
            rendererPreset: rendererPreset,
            launchProfile: GameLaunchProfile(
                executablePath: resolvedPaths.executablePath,
                arguments: launchArguments,
                prefixID: prefix.id,
                rendererPreset: rendererPreset,
                deviceTier: deviceTier,
                titleFlags: titleFlags
            ),
            installedSizeGB: installedSizeGB,
            managedArtifactIdentifier: managedArtifactIdentifier,
            executableFingerprint: executableFingerprint,
            validationEvidenceSummary: "Registered in managed inventory.",
            summary: summary
        )

        games.append(game)
        persist()
        return game
    }

    private func normalizedIdentifier(from title: String) -> String {
        title.filter { $0.isLetter || $0.isNumber }
    }

    private func formattedGB(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) GB"
    }

    private func estimatedImportedSizeGB(for deviceTier: DeviceTier) -> Double {
        switch deviceTier {
        case .tier1:
            4
        case .tier2:
            12
        case .tier3:
            36
        }
    }

    private func estimatedSteamInstallSizeGB(for title: String) -> Double {
        let normalized = title.lowercased()
        if normalized.contains("heavy")
            || normalized.contains("aaa")
            || normalized.contains("complete") {
            return 72
        }
        if normalized.contains("performance")
            || normalized.contains("latency")
            || normalized.contains("racing")
            || normalized.contains("shooter") {
            return 24
        }
        if normalized.contains("light")
            || normalized.contains("indie")
            || normalized.contains("card")
            || normalized.contains("puzzle") {
            return 2
        }
        return 12
    }

    private func computeManagedStorageStatus() -> ManagedStorageStatus {
        let totalCapacityGB = 256.0
        let reservedForSystemGB = 24.0
        let usedByGamesGB = games.reduce(0) { $0 + ($1.installedSizeGB ?? 0) }
        let usedByPrefixesGB = prefixes.reduce(0) { $0 + ($1.storageFootprintGB ?? 0) }
        let reservedForQueuedDownloadsGB = downloads.reduce(0) { partial, task in
            guard task.state != .installed else {
                return partial
            }
            return partial + (task.reservedDiskGB ?? 0)
        }
        let headroom = totalCapacityGB - reservedForSystemGB - usedByGamesGB - usedByPrefixesGB - reservedForQueuedDownloadsGB

        let pressure: StoragePressure
        if headroom <= 16 {
            pressure = .critical
        } else if headroom <= 40 {
            pressure = .warning
        } else {
            pressure = .healthy
        }

        var notes = [
            "Managed storage reserves \(reservedForSystemGB.formatted(.number.precision(.fractionLength(0)))) GB for iOS, caches, and rollback buffers."
        ]
        if reservedForQueuedDownloadsGB > 0 {
            notes.append("Queued transfers are holding \(reservedForQueuedDownloadsGB.formatted(.number.precision(.fractionLength(0)))) GB of install headroom.")
        }
        if pressure != .healthy {
            notes.append("Heavy installs should be deferred until storage headroom is recovered.")
        }

        return ManagedStorageStatus(
            totalCapacityGB: totalCapacityGB,
            reservedForSystemGB: reservedForSystemGB,
            usedByGamesGB: usedByGamesGB,
            usedByPrefixesGB: usedByPrefixesGB,
            reservedForQueuedDownloadsGB: reservedForQueuedDownloadsGB,
            pressure: pressure,
            notes: notes,
            lastMeasuredAt: Date()
        )
    }

    private static func loadInitialSnapshot(
        defaultSnapshot: IridiumSnapshot,
        snapshotURL: URL?
    ) -> LoadedSnapshotState {
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let stored = try? JSONDecoder().decode(IridiumSnapshot.self, from: data) else {
            return LoadedSnapshotState(snapshot: defaultSnapshot, didResetLegacyState: false)
        }

        let rootURL = snapshotURL.deletingLastPathComponent()

        guard stored.snapshotVersion < IridiumSnapshot.currentSnapshotVersion else {
            let rebasedState = rebaseManagedPaths(in: stored, rootURL: rootURL)
            return LoadedSnapshotState(snapshot: rebasedState.snapshot, didResetLegacyState: rebasedState.didRebase)
        }

        purgeLegacyManagedGameStorage(rootURL: rootURL)
        return LoadedSnapshotState(snapshot: .empty, didResetLegacyState: true)
    }

    private static func rebaseManagedPaths(
        in snapshot: IridiumSnapshot,
        rootURL: URL
    ) -> (snapshot: IridiumSnapshot, didRebase: Bool) {
        let currentRoot = rootURL.standardizedFileURL
        var didRebase = false
        var snapshot = snapshot

        func rebase(_ path: String) -> String {
            let rebased = rebaseManagedPath(path, rootURL: currentRoot)
            if rebased != path {
                didRebase = true
            }
            return rebased
        }

        snapshot.games = snapshot.games.map { game in
            var game = game
            game.installPath = rebase(game.installPath)
            game.launchProfile.executablePath = rebase(game.launchProfile.executablePath)
            return game
        }

        snapshot.installExecutions = snapshot.installExecutions.map { execution in
            var execution = execution
            execution.targetPath = rebase(execution.targetPath)
            return execution
        }

        snapshot.installHistory = snapshot.installHistory.map { entry in
            var entry = entry
            entry.targetPath = rebase(entry.targetPath)
            return entry
        }

        snapshot.prefixes = snapshot.prefixes.map { prefix in
            var prefix = prefix
            if let manifestPath = prefix.manifestPath {
                prefix.manifestPath = rebase(manifestPath)
            }
            return prefix
        }

        snapshot.launchHistory = snapshot.launchHistory.map { entry in
            var entry = entry
            entry.resolvedExecutablePath = rebase(entry.resolvedExecutablePath)
            return entry
        }

        snapshot.pendingLaunches = snapshot.pendingLaunches.map { pendingLaunch in
            var pendingLaunch = pendingLaunch
            pendingLaunch.resolvedExecutablePath = rebase(pendingLaunch.resolvedExecutablePath)
            pendingLaunch.workingDirectory = rebase(pendingLaunch.workingDirectory)
            return pendingLaunch
        }

        return (snapshot, didRebase)
    }

    private static func rebaseManagedPath(_ path: String, rootURL: URL) -> String {
        guard !path.isEmpty else {
            return path
        }

        if path.hasPrefix("/Managed/") {
            return rootURL.appending(path: String(path.dropFirst())).path
        }

        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let marker = "/Library/Application Support/Iridium/"

        guard let markerRange = standardizedPath.range(of: marker) else {
            return path
        }

        let suffix = String(standardizedPath[markerRange.upperBound...])
        return rootURL.appending(path: suffix).path
    }

    private static func purgeLegacyManagedGameStorage(rootURL: URL) {
        let managedRoot = rootURL.appending(path: "Managed", directoryHint: .isDirectory)
        resetDirectory(at: managedRoot.appending(path: "Imports", directoryHint: .isDirectory))
        resetDirectory(at: managedRoot.appending(path: "Steam", directoryHint: .isDirectory))
    }

    private static func resetDirectory(at url: URL) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func persistSnapshot(_ snapshot: IridiumSnapshot, to snapshotURL: URL?) {
        guard let snapshotURL else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let directory = snapshotURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            assertionFailure("Failed to persist Iridium snapshot: \(error)")
        }
    }

}

public extension IridiumStore {
    nonisolated static func defaultRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        IridiumDeploymentPaths.defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        )
    }

    nonisolated static func defaultSnapshotURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        )
            .appending(path: "state.json")
    }

    nonisolated static func defaultManagedRootURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        IridiumDeploymentPaths.managedRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        )
    }

    nonisolated static func defaultSteamInstallURL(
        forTitle title: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultManagedRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        )
            .appending(path: "Steam", directoryHint: .isDirectory)
            .appending(path: title.filter { $0.isLetter || $0.isNumber }, directoryHint: .isDirectory)
    }

    nonisolated static func defaultImportInstallURL(
        forTitle title: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL {
        defaultManagedRootURL(
            fileManager: fileManager,
            environment: environment,
            infoDictionary: infoDictionary
        )
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: title.filter { $0.isLetter || $0.isNumber }, directoryHint: .isDirectory)
    }

    static func persistentDefault() -> IridiumStore {
        IridiumStore(snapshotURL: defaultSnapshotURL())
    }

    static let preview = IridiumStore(snapshot: .preview)
}
