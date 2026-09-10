import Foundation
import IridiumCore
import XCTest

final class IridiumCoreTests: XCTestCase {
    func testRemoveLibraryEntryPreservesFilesAndPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("Game.exe")
        try Data("fixture".utf8).write(to: exe)
        let snapshot = root.appendingPathComponent("state.json")
        let store = IridiumStore(snapshotURL: snapshot)
        let game = await store.importGame(title: "Custom Game", installPath: source.path, executablePath: exe.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "", deviceTier: .tier2, rendererPreset: .dxvkPerformance)
        let prefixes = await store.allPrefixes()
        let save = URL(fileURLWithPath: game.installPath).appendingPathComponent("fixture.sav")
        try Data("save data".utf8).write(to: save)
        try await store.relocateLibraryEntry(gameID: game.id, folder: source, executable: exe, identifier: "fixture", fingerprint: "fixture")
        let relocated = await store.allGames().first!
        XCTAssertNotEqual(relocated.installPath, game.installPath)
        XCTAssertEqual(relocated.launchProfile.prefixID, game.launchProfile.prefixID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.launchProfile.executablePath))
        do {
            try await store.relocateLibraryEntry(gameID: game.id, folder: source, executable: root.appendingPathComponent("Outside.exe"), identifier: "fixture", fingerprint: "fixture")
            XCTFail("Accepted a file outside the selected folder")
        } catch {}
        await store.removeLibraryEntry(gameID: game.id)
        let reloaded = IridiumStore(snapshotURL: snapshot)
        let games = await reloaded.allGames()
        let remainingPrefixes = await reloaded.allPrefixes()
        XCTAssertTrue(games.isEmpty)
        XCTAssertEqual(remainingPrefixes, prefixes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.launchProfile.executablePath))
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "save data")
    }

    func testDeploymentPathsUseConfiguredAbsoluteRootOverride() {
        let configuredRoot = URL(fileURLWithPath: "/tmp/iridium-shared-root", isDirectory: true)
        let environment = [IridiumDeploymentPaths.rootEnvironmentKey: configuredRoot.path]

        let resolvedRoot = IridiumDeploymentPaths.defaultRootURL(
            environment: environment,
            infoDictionary: nil
        )
        let managedRoot = IridiumDeploymentPaths.managedRootURL(
            environment: environment,
            infoDictionary: nil
        )

        XCTAssertEqual(resolvedRoot, configuredRoot)
        XCTAssertEqual(managedRoot, configuredRoot.appending(path: "Managed", directoryHint: .isDirectory))
    }

    func testStoreDefaultsFollowConfiguredIridiumRootOverride() {
        let configuredRoot = URL(fileURLWithPath: "/tmp/iridium-configured-root", isDirectory: true)
        let environment = [IridiumDeploymentPaths.rootEnvironmentKey: configuredRoot.path]

        let snapshotURL = IridiumStore.defaultSnapshotURL(
            environment: environment,
            infoDictionary: nil
        )
        let importURL = IridiumStore.defaultImportInstallURL(
            forTitle: "Fixture Game",
            environment: environment,
            infoDictionary: nil
        )

        XCTAssertEqual(snapshotURL, configuredRoot.appending(path: "state.json"))
        XCTAssertEqual(
            importURL,
            configuredRoot
                .appending(path: "Managed", directoryHint: .isDirectory)
                .appending(path: "Imports", directoryHint: .isDirectory)
                .appending(path: "FixtureGame", directoryHint: .isDirectory)
        )
    }

    func testPersistentDefaultStartsEmpty() async {
        let store = IridiumStore()

        let games = await store.allGames()
        let downloads = await store.allDownloads()
        let installExecutions = await store.installExecutions()
        let installHistory = await store.installHistory()
        let prefixes = await store.allPrefixes()
        let account = await store.activeAccount()
        let library = await store.librarySnapshot()
        let launchHistory = await store.launchHistory()
        let compatibilityEvidence = await store.compatibilityEvidence()
        let activity = await store.activityFeed()
        let audits = await store.verificationAudits()
        let health = await store.healthReport()
        let syncDate = await store.lastLibrarySyncDate()
        let managedStorage = await store.managedStorageStatus()

        XCTAssertTrue(games.isEmpty)
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(installExecutions.isEmpty)
        XCTAssertTrue(installHistory.isEmpty)
        XCTAssertTrue(prefixes.isEmpty)
        XCTAssertNil(account)
        XCTAssertTrue(library.isEmpty)
        XCTAssertTrue(launchHistory.isEmpty)
        XCTAssertTrue(compatibilityEvidence.isEmpty)
        XCTAssertTrue(activity.isEmpty)
        XCTAssertTrue(audits.isEmpty)
        XCTAssertNil(syncDate)
        XCTAssertEqual(health.status, .actionRequired)
        XCTAssertTrue(health.notes.contains("Runtime validation has not run yet."))
        XCTAssertEqual(managedStorage.usedByGamesGB, 0)
        XCTAssertEqual(managedStorage.usedByPrefixesGB, 0)
        XCTAssertEqual(managedStorage.reservedForQueuedDownloadsGB, 0)
    }

    func testPersistentStoreRoundTripsState() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let store = IridiumStore(snapshotURL: snapshotURL)
        await store.signIn(accountName: "tester@steam")
        _ = await store.importGame(
            title: "Imported Game",
            installPath: sourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Controller + KBM",
            deviceTier: .tier2,
            rendererPreset: .dxvkPerformance
        )
        await store.validateRuntime()

        let reloaded = IridiumStore(snapshotURL: snapshotURL)
        let games = await reloaded.allGames()
        let account = await reloaded.activeAccount()
        let health = await reloaded.healthReport()
        let launches = await reloaded.launchHistory()
        let activity = await reloaded.activityFeed()
        let audits = await reloaded.verificationAudits()
        let executions = await reloaded.installExecutions()
        let prefixes = await reloaded.allPrefixes()

        XCTAssertTrue(games.contains { $0.title == "Imported Game" })
        XCTAssertEqual(account?.accountName, "tester@steam")
        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(prefixes.count, 1)
        XCTAssertEqual(activity.count, 2)
        XCTAssertTrue(launches.isEmpty)
        XCTAssertTrue(audits.isEmpty)
        XCTAssertTrue(executions.isEmpty)
    }

    func testLegacySnapshotLoadResetsPersistedSeededState() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")

        let importedFixture = makeGameFixture(
            title: "Legacy Imported Game",
            source: .manualImport,
            appID: "1000010",
            installPath: "/Managed/Imports/LegacyImportedGame",
            executablePath: "/Managed/Imports/LegacyImportedGame/LegacyImportedGame.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            titleFlags: ["manual-import"]
        )
        let steamFixture = makeGameFixture(
            title: "Legacy Steam Game",
            source: .steam,
            appID: "1000011",
            installPath: "/Managed/Steam/LegacySteamGame",
            executablePath: "/Managed/Steam/LegacySteamGame/LegacySteamGame.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            titleFlags: ["steam"]
        )

        var legacySnapshot = IridiumSnapshot.empty
        legacySnapshot.games = [importedFixture.game, steamFixture.game]
        legacySnapshot.downloads = [
            DownloadTask(title: "Legacy Steam Game", progress: 0.4, state: .downloading, detail: "Legacy staged transfer", reservedDiskGB: 12)
        ]
        legacySnapshot.installExecutions = [
            InstallExecutionRecord(
                title: "Legacy Steam Game",
                appID: "1000011",
                buildID: "legacy-build",
                branchName: "public",
                targetPath: "/Managed/Steam/LegacySteamGame",
                primaryExecutable: "LegacySteamGame.exe",
                depotIDs: ["1000012"],
                depotMountPaths: ["1000012": "Game"],
                completedDepotIDs: [],
                stage: .downloading,
                detail: "Legacy install in progress",
                reservedDiskGB: 12
            )
        ]
        legacySnapshot.installHistory = [
            InstallHistoryEntry(
                title: "Legacy Steam Game",
                appID: "1000011",
                buildID: "legacy-build",
                branchName: "public",
                targetPath: "/Managed/Steam/LegacySteamGame",
                primaryExecutable: "LegacySteamGame.exe",
                installedAt: Date(),
                detail: "Legacy install history"
            )
        ]
        legacySnapshot.prefixes = [importedFixture.prefix, steamFixture.prefix]
        legacySnapshot.steamAccount = SteamAccount(accountName: "legacy@steam", state: .signedIn)
        legacySnapshot.steamLibrary = [
            SteamLibraryEntry(title: "Legacy Steam Game", appID: "1000011", installed: true, cloudSavesEnabled: true)
        ]
        legacySnapshot.runtimeHealth = RuntimeHealthReport(
            status: .healthy,
            runtimeName: "Legacy Runtime",
            notes: ["Legacy runtime state"]
        )
        legacySnapshot.lastLibrarySync = Date()
        legacySnapshot.launchHistory = [
            LaunchHistoryEntry(
                gameTitle: "Legacy Steam Game",
                resolvedExecutablePath: "/Managed/Steam/LegacySteamGame/LegacySteamGame.exe",
                readiness: "Ready",
                issueSummary: ["Legacy launch history"],
                launchedAt: Date()
            )
        ]
        legacySnapshot.compatibilityEvidence = [
            CompatibilityEvidenceRecord(
                title: "Legacy Steam Game",
                source: .steam,
                managedArtifactIdentifier: "legacy-steam-game",
                executableFingerprint: "fingerprint",
                runtimeBundleIdentifier: "legacy-runtime",
                runtimeBundleVersion: "2026.03.01",
                resolvedPolicySummary: "legacy",
                accepted: true,
                evidenceSummary: "Legacy evidence"
            )
        ]
        legacySnapshot.verificationAudits = [
            VerificationAuditEntry(
                gameID: steamFixture.game.id,
                gameTitle: "Legacy Steam Game",
                overallStatus: .warning,
                summary: "Legacy audit",
                gates: [
                    VerificationAuditGate(
                        title: "Legacy Gate",
                        detail: "Legacy detail",
                        status: .warning
                    )
                ],
                verifiedAt: Date()
            )
        ]
        legacySnapshot.activityFeed = [
            ActivityLogEntry(
                kind: .steamRegistered,
                title: "Registered Legacy Steam Game",
                detail: "Legacy activity entry",
                relatedTitle: "Legacy Steam Game",
                recordedAt: Date()
            )
        ]

        try writeLegacySnapshot(legacySnapshot, to: snapshotURL)

        let store = IridiumStore(snapshotURL: snapshotURL)

        let games = await store.allGames()
        let downloads = await store.allDownloads()
        let installExecutions = await store.installExecutions()
        let installHistory = await store.installHistory()
        let prefixes = await store.allPrefixes()
        let account = await store.activeAccount()
        let library = await store.librarySnapshot()
        let syncDate = await store.lastLibrarySyncDate()
        let launchHistory = await store.launchHistory()
        let compatibilityEvidence = await store.compatibilityEvidence()
        let audits = await store.verificationAudits()
        let activity = await store.activityFeed()

        XCTAssertTrue(games.isEmpty)
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(installExecutions.isEmpty)
        XCTAssertTrue(installHistory.isEmpty)
        XCTAssertTrue(prefixes.isEmpty)
        XCTAssertNil(account)
        XCTAssertTrue(library.isEmpty)
        XCTAssertNil(syncDate)
        XCTAssertTrue(launchHistory.isEmpty)
        XCTAssertTrue(compatibilityEvidence.isEmpty)
        XCTAssertTrue(audits.isEmpty)
        XCTAssertTrue(activity.isEmpty)

        let health = await store.healthReport()
        XCTAssertEqual(health.status, .actionRequired)
        XCTAssertEqual(health.runtimeName, "Iridium Runtime Base")

        let persistedData = try Data(contentsOf: snapshotURL)
        let persistedSnapshot = try JSONDecoder().decode(IridiumSnapshot.self, from: persistedData)
        XCTAssertEqual(persistedSnapshot.snapshotVersion, IridiumSnapshot.currentSnapshotVersion)
        XCTAssertTrue(persistedSnapshot.games.isEmpty)
        XCTAssertTrue(persistedSnapshot.activityFeed.isEmpty)
    }

    func testLegacySnapshotResetPurgesOnlyManagedGameStorage() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let importsRoot = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Imports", directoryHint: .isDirectory)
        let steamRoot = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Steam", directoryHint: .isDirectory)
        let runtimeRoot = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Runtime", directoryHint: .isDirectory)
        let runtimeBridgeRoot = tempDirectory
            .appending(path: "NativeBridge", directoryHint: .isDirectory)
            .appending(path: "RuntimeHost", directoryHint: .isDirectory)
        let steamBridgeRoot = tempDirectory
            .appending(path: "NativeBridge", directoryHint: .isDirectory)
            .appending(path: "Steam", directoryHint: .isDirectory)
        let runtimeProviderRoot = tempDirectory.appending(path: "RuntimeProvider", directoryHint: .isDirectory)
        let steamSessionsRoot = tempDirectory.appending(path: "SteamSessions", directoryHint: .isDirectory)

        try writeFile(at: importsRoot.appending(path: "legacy-import.txt"), contents: "legacy import")
        try writeFile(at: steamRoot.appending(path: "legacy-steam.txt"), contents: "legacy steam")
        try writeFile(at: runtimeRoot.appending(path: "keep-runtime.txt"), contents: "keep runtime")
        try writeFile(at: runtimeBridgeRoot.appending(path: "keep-bridge.txt"), contents: "keep bridge")
        try writeFile(at: steamBridgeRoot.appending(path: "keep-steam-bridge.txt"), contents: "keep steam bridge")
        try writeFile(at: runtimeProviderRoot.appending(path: "keep-provider.txt"), contents: "keep provider")
        try writeFile(at: steamSessionsRoot.appending(path: "keep-session.txt"), contents: "keep session")

        try writeLegacySnapshot(.empty, to: snapshotURL)

        _ = IridiumStore(snapshotURL: snapshotURL)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: importsRoot.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: steamRoot.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeRoot.appending(path: "keep-runtime.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeBridgeRoot.appending(path: "keep-bridge.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamBridgeRoot.appending(path: "keep-steam-bridge.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimeProviderRoot.appending(path: "keep-provider.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: steamSessionsRoot.appending(path: "keep-session.txt").path))
    }

    func testPrefixCloneAndRepairMutateRuntimeState() async throws {
        var snapshot = IridiumSnapshot.empty
        let fixturePrefix = makePrefixFixture(name: "Base Prefix")
        snapshot.prefixes = [fixturePrefix]
        let store = IridiumStore(snapshot: snapshot)
        let prefixes = await store.allPrefixes()
        let prefix = try XCTUnwrap(prefixes.first)

        let clone = await store.clone(prefixID: prefix.id, newName: "Clone Prefix")
        XCTAssertEqual(clone?.name, "Clone Prefix")

        await store.repair(prefixID: prefix.id)
        let health = await store.healthReport()

        XCTAssertEqual(health.status, .degraded)
        XCTAssertTrue(health.notes.first?.contains("Prefix repair") == true)
    }

    func testRecordingLaunchPrependsToHistory() async {
        let store = IridiumStore()
        let before = await store.launchHistory()

        await store.recordLaunch(
            gameTitle: "Launch Fixture",
            resolvedExecutablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            readiness: "Ready",
            issueSummary: ["Launch path prepared without exposing a desktop shell."],
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: "2026.03.12"
        )

        let after = await store.launchHistory()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.gameTitle, "Launch Fixture")
        XCTAssertEqual(after.first?.runtimeBundleVersion, "2026.03.12")
    }

    func testQueueLaunchWaitingForJITPersistsPendingLaunchAndActivity() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let store = IridiumStore(snapshotURL: snapshotURL)
        let requestedAt = Date()
        let launchEntryID = UUID()
        let gameID = UUID()
        let prefixID = UUID()
        let pendingLaunch = PendingLaunchRecord(
            launchEntryID: launchEntryID,
            gameID: gameID,
            gameTitle: "Queued Fixture",
            prefixID: prefixID,
            resolvedExecutablePath: "/Managed/Imports/QueuedFixture/QueuedFixture.exe",
            workingDirectory: "/Managed/Imports/QueuedFixture",
            launchArguments: ["-windowed"],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.20",
            resolvedPolicySummary: "generic-broad-catalog, balanced",
            status: .waitingForJIT,
            detail: "Launch is queued while Iridium waits for JIT.",
            requestedAt: requestedAt,
            lastUpdatedAt: requestedAt
        )
        let launchEntry = LaunchHistoryEntry(
            id: launchEntryID,
            gameTitle: "Queued Fixture",
            resolvedExecutablePath: pendingLaunch.resolvedExecutablePath,
            readiness: "Waiting For JIT",
            issueSummary: ["Launch queued until JIT becomes ready."],
            hostSessionID: nil,
            stateHistory: ["queued", "waitingForJIT"],
            terminalStatus: "waitingForJIT",
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: "2026.03.20",
            telemetrySummary: nil,
            launchedAt: requestedAt
        )

        await store.queueLaunchWaitingForJIT(pendingLaunch, launchEntry: launchEntry)

        let queuedLaunches = await store.pendingLaunches()
        let history = await store.launchHistory()
        let activity = await store.activityFeed()
        let reloaded = IridiumStore(snapshotURL: snapshotURL)
        let persistedQueuedLaunches = await reloaded.pendingLaunches()

        XCTAssertEqual(queuedLaunches.count, 1)
        XCTAssertEqual(queuedLaunches.first?.gameTitle, "Queued Fixture")
        XCTAssertEqual(history.first?.terminalStatus, "waitingForJIT")
        XCTAssertEqual(history.first?.stateHistory, ["queued", "waitingForJIT"])
        XCTAssertEqual(activity.first?.kind, .launchQueuedForJIT)
        XCTAssertEqual(persistedQueuedLaunches.first?.launchEntryID, launchEntryID)
    }

    func testPendingLaunchResumeAndValidationFailureUpdateDurableState() async throws {
        let store = IridiumStore()
        let queuedAt = Date()
        let firstPendingID = UUID()
        let firstLaunchEntryID = UUID()
        let firstPending = PendingLaunchRecord(
            id: firstPendingID,
            launchEntryID: firstLaunchEntryID,
            gameID: UUID(),
            gameTitle: "Resume Fixture",
            prefixID: UUID(),
            resolvedExecutablePath: "/Managed/Imports/ResumeFixture/ResumeFixture.exe",
            workingDirectory: "/Managed/Imports/ResumeFixture",
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.20",
            resolvedPolicySummary: "generic-broad-catalog, balanced",
            status: .waitingForJIT,
            detail: "Launch is queued while Iridium waits for JIT.",
            requestedAt: queuedAt,
            lastUpdatedAt: queuedAt
        )
        let firstLaunch = LaunchHistoryEntry(
            id: firstLaunchEntryID,
            gameTitle: "Resume Fixture",
            resolvedExecutablePath: firstPending.resolvedExecutablePath,
            readiness: "Waiting For JIT",
            issueSummary: ["Launch queued until JIT becomes ready."],
            hostSessionID: nil,
            stateHistory: ["queued", "waitingForJIT"],
            terminalStatus: "waitingForJIT",
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: "2026.03.20",
            telemetrySummary: nil,
            launchedAt: queuedAt
        )

        await store.queueLaunchWaitingForJIT(firstPending, launchEntry: firstLaunch)
        await store.markPendingLaunchResumed(
            id: firstPendingID,
            detail: "JIT became available and Iridium resumed the queued launch automatically.",
            resumedAt: queuedAt.addingTimeInterval(30)
        )

        let resumedHistory = await store.launchHistory()
        let resumedEntry = try XCTUnwrap(resumedHistory.first(where: { $0.id == firstLaunchEntryID }))
        let resumedActivity = await store.activityFeed()
        let resumedPendingLaunches = await store.pendingLaunches()

        XCTAssertEqual(resumedEntry.readiness, "Resumed After JIT")
        XCTAssertEqual(resumedEntry.terminalStatus, "started")
        XCTAssertEqual(resumedEntry.stateHistory, ["queued", "waitingForJIT", "resumingAfterJIT"])
        XCTAssertTrue(resumedActivity.contains(where: { $0.kind == .launchResumed && $0.relatedTitle == "Resume Fixture" }))
        XCTAssertTrue(resumedPendingLaunches.isEmpty)

        let secondPendingID = UUID()
        let secondLaunchEntryID = UUID()
        let secondPending = PendingLaunchRecord(
            id: secondPendingID,
            launchEntryID: secondLaunchEntryID,
            gameID: UUID(),
            gameTitle: "Failed Resume Fixture",
            prefixID: UUID(),
            resolvedExecutablePath: "/Managed/Imports/FailedResumeFixture/FailedResumeFixture.exe",
            workingDirectory: "/Managed/Imports/FailedResumeFixture",
            launchArguments: [],
            environment: ["IRIDIUM_NO_DESKTOP": "1"],
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.20",
            resolvedPolicySummary: "generic-broad-catalog, balanced",
            status: .waitingForJIT,
            detail: "Launch is queued while Iridium waits for JIT.",
            requestedAt: queuedAt,
            lastUpdatedAt: queuedAt
        )
        let secondLaunch = LaunchHistoryEntry(
            id: secondLaunchEntryID,
            gameTitle: "Failed Resume Fixture",
            resolvedExecutablePath: secondPending.resolvedExecutablePath,
            readiness: "Waiting For JIT",
            issueSummary: ["Launch queued until JIT becomes ready."],
            hostSessionID: nil,
            stateHistory: ["queued", "waitingForJIT"],
            terminalStatus: "waitingForJIT",
            failureCode: nil,
            failureReason: nil,
            runtimeBundleVersion: "2026.03.20",
            telemetrySummary: nil,
            launchedAt: queuedAt
        )

        await store.queueLaunchWaitingForJIT(secondPending, launchEntry: secondLaunch)
        await store.markPendingLaunchValidationFailure(
            id: secondPendingID,
            failureReason: "Queued launch no longer matches the current runtime, executable, or prefix state.",
            issueSummary: ["Queued launch could not resume because the launch requirements changed."],
            failedAt: queuedAt.addingTimeInterval(60)
        )

        let failedHistory = await store.launchHistory()
        let failedEntry = try XCTUnwrap(failedHistory.first(where: { $0.id == secondLaunchEntryID }))
        let failedActivity = await store.activityFeed()
        let failedPendingLaunches = await store.pendingLaunches()

        XCTAssertEqual(failedEntry.readiness, "Resume Failed")
        XCTAssertEqual(failedEntry.terminalStatus, "resumeValidationFailed")
        XCTAssertEqual(failedEntry.failureCode, "jitResumeValidationFailed")
        XCTAssertEqual(failedEntry.stateHistory, ["queued", "waitingForJIT", "resumeValidationFailed"])
        XCTAssertTrue(failedActivity.contains(where: { $0.kind == .launchResumeFailed && $0.relatedTitle == "Failed Resume Fixture" }))
        XCTAssertTrue(failedPendingLaunches.isEmpty)
    }

    func testRecordingVerificationAuditPrependsToHistory() async {
        let store = IridiumStore()
        let before = await store.verificationAudits()
        let gameID = UUID()

        await store.recordVerificationAudit(
            VerificationAuditEntry(
                gameID: gameID,
                gameTitle: "Audit Fixture",
                overallStatus: .ready,
                summary: "All launch gates passed for the current runtime and storage state.",
                gates: [
                    VerificationAuditGate(
                        title: "Install pipeline",
                        detail: "Install is complete.",
                        status: .ready
                    )
                ],
                verifiedAt: Date()
            )
        )

        let after = await store.verificationAudits()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.gameTitle, "Audit Fixture")
        XCTAssertEqual(after.first?.overallStatus, .ready)
    }

    func testRecordingCompatibilityEvidencePrependsToHistory() async {
        let store = IridiumStore()
        let before = await store.compatibilityEvidence()

        await store.recordCompatibilityEvidence(
            CompatibilityEvidenceRecord(
                title: "Evidence Fixture",
                source: .manualImport,
                managedArtifactIdentifier: "evidence-fixture",
                executableFingerprint: "fingerprint",
                runtimeBundleIdentifier: "iridium-runtime-base",
                runtimeBundleVersion: "2026.03.12",
                resolvedPolicySummary: "generic-broad-catalog, compact, metalOpenGLFallback",
                accepted: true,
                hostSessionID: "session-1",
                terminalStatus: "completed",
                telemetrySummary: "fps=60",
                mitigationAction: "none",
                evidenceSummary: "Validated Evidence Fixture direct launch."
            )
        )

        let after = await store.compatibilityEvidence()
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.first?.hostSessionID, "session-1")
        XCTAssertEqual(after.first?.accepted, true)
    }

    func testRecoverInterruptedOperationsMarksStaleRuntimeAndInstallState() async {
        var snapshot = IridiumSnapshot.empty
        snapshot.installExecutions = [
            InstallExecutionRecord(
                title: "Recovery Fixture",
                appID: "1000001",
                buildID: "recovery-build",
                branchName: "public",
                targetPath: "/Managed/Steam/RecoveryFixture",
                primaryExecutable: "RecoveryFixture.exe",
                depotIDs: ["1000002"],
                depotMountPaths: ["1000002": "Game"],
                completedDepotIDs: [],
                stage: .downloading,
                detail: "Interrupted transfer",
                reservedDiskGB: 21,
                resumeCheckpoint: "1000002:1024",
                lastUpdatedAt: Date(timeIntervalSinceNow: -600)
            )
        ]
        snapshot.launchHistory = [
            LaunchHistoryEntry(
                gameTitle: "Launch Fixture",
                resolvedExecutablePath: "/Managed/Steam/LaunchFixture/LaunchFixture.exe",
                readiness: "Ready",
                issueSummary: ["Submitted to runtime host"],
                hostSessionID: "stale-session",
                terminalStatus: "running",
                launchedAt: Date(timeIntervalSinceNow: -600)
            )
        ]

        let store = IridiumStore(snapshot: snapshot)
        await store.recoverInterruptedOperations()

        let recoveredExecution = await store.installExecutions().first
        let recoveredLaunch = await store.launchHistory().first

        XCTAssertEqual(recoveredExecution?.stage, .downloading)
        XCTAssertTrue(recoveredExecution?.detail.contains("Recovered interrupted install state") == true)
        XCTAssertEqual(recoveredLaunch?.terminalStatus, "stale")
        XCTAssertEqual(recoveredLaunch?.failureCode, "runtimeBootFailed")
    }

    func testImportGameRefreshesExistingManualImportInsteadOfDuplicatingIt() async {
        let store = IridiumStore()

        _ = await store.importGame(
            title: "Imported Game",
            installPath: "/Managed/Imports/ImportedGame",
            executablePath: "/Managed/Imports/ImportedGame/ImportedGame.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        _ = await store.importGame(
            title: "Imported Game Updated",
            installPath: "/Managed/Imports/ImportedGame",
            executablePath: "/Managed/Imports/ImportedGame/ImportedGame.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        let games = await store.allGames().filter { $0.installPath == "/Managed/Imports/ImportedGame" }
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.title, "Imported Game Updated")
    }

    func testRegisterSteamGameMarksLibraryEntryInstalled() async {
        var snapshot = IridiumSnapshot.empty
        snapshot.steamLibrary = [
            SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true)
        ]
        let store = IridiumStore(snapshot: snapshot)

        _ = await store.registerSteamGame(
            title: "Steam Fixture",
            appID: "1000000",
            installPath: "/Managed/Steam/SteamFixture",
            executablePath: "/Managed/Steam/SteamFixture/SteamFixture.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchArguments: [],
            titleFlags: ["steam"]
        )

        let games = await store.allGames()
        let library = await store.librarySnapshot()

        XCTAssertTrue(games.contains(where: { $0.title == "Steam Fixture" && $0.source == .steam }))
        XCTAssertTrue(library.contains(where: { $0.appID == "1000000" && $0.installed }))
    }

    func testRegisterSteamGameClearsCompletedInstallExecution() async {
        var snapshot = IridiumSnapshot.empty
        snapshot.steamLibrary = [
            SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true)
        ]
        let store = IridiumStore(snapshot: snapshot)

        _ = await store.beginInstallExecution(
            title: "Steam Fixture",
            appID: "1000000",
            buildID: "steam-fixture-2026.02.18",
            branchName: "public",
            targetPath: "/Managed/Steam/SteamFixture",
            primaryExecutable: "SteamFixture.exe",
            depotIDs: ["1000002"],
            depotMountPaths: ["1000002": "Game"],
            reservedDiskGB: 3
        )
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")

        _ = await store.registerSteamGame(
            title: "Steam Fixture",
            appID: "1000000",
            installPath: "/Managed/Steam/SteamFixture",
            executablePath: "/Managed/Steam/SteamFixture/SteamFixture.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchArguments: [],
            titleFlags: ["steam"]
        )

        let executions = await store.installExecutions()
        let downloads = await store.allDownloads()
        let installHistory = await store.installHistory()
        XCTAssertTrue(executions.isEmpty)
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertEqual(installHistory.first?.title, "Steam Fixture")
        XCTAssertEqual(installHistory.first?.buildID, "steam-fixture-2026.02.18")
    }

    func testFinalizeVerifiedInstallIntoLibraryRegistrationUsesVerifiedExecutionState() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let installRoot = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Steam", directoryHint: .isDirectory)
            .appending(path: "SteamFixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let executableURL = installRoot.appending(path: "SteamFixture.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("steam-fixture".utf8))

        var snapshot = IridiumSnapshot.empty
        snapshot.downloads = [
            DownloadTask(title: "Steam Fixture", progress: 1.0, state: .installed, detail: "Ready")
        ]
        snapshot.installExecutions = [
            InstallExecutionRecord(
                title: "Steam Fixture",
                appID: "1000000",
                buildID: "steam-fixture-2026.02.18",
                branchName: "public",
                targetPath: installRoot.path,
                primaryExecutable: "SteamFixture.exe",
                depotIDs: ["1000002"],
                depotMountPaths: ["1000002": "Game"],
                completedDepotIDs: ["1000002"],
                stage: .completed,
                detail: "Verified and mounted.",
                reservedDiskGB: 3,
                depotProgressBytes: ["1000002": 900_000_000],
                depotVerifiedIDs: ["1000002"],
                resumeCheckpoint: "1000002:900000000",
                managedArtifactIdentifier: "steam-fixture",
                executableFingerprint: "fingerprint-123",
                runtimeBundleIdentifier: "iridium-runtime-base",
                runtimeBundleVersion: "2026.03.12"
            )
        ]
        snapshot.steamLibrary = [
            SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true)
        ]

        let store = IridiumStore(snapshot: snapshot, snapshotURL: snapshotURL)
        let game = await store.finalizeVerifiedInstallIntoLibraryRegistration(
            entry: SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true),
            execution: snapshot.installExecutions[0],
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchArguments: [],
            titleFlags: ["steam"],
            resolvedPolicySummary: "generic-broad-catalog, compact, metalOpenGLFallback"
        )

        let library = await store.librarySnapshot()
        let executions = await store.installExecutions()
        let evidence = await store.compatibilityEvidence()

        XCTAssertEqual(game?.title, "Steam Fixture")
        XCTAssertTrue(library.contains(where: { $0.appID == "1000000" && $0.installed }))
        XCTAssertTrue(executions.isEmpty)
        XCTAssertEqual(evidence.first?.accepted, true)
        XCTAssertEqual(evidence.first?.runtimeBundleVersion, "2026.03.12")
    }

    func testFinalizeVerifiedInstallIntoLibraryRegistrationBlocksUnverifiedExecution() async throws {
        let store = IridiumStore()
        let execution = InstallExecutionRecord(
            title: "Unverified Fixture",
            appID: "1000003",
            buildID: "blocked-build",
            branchName: "public",
            targetPath: "/Managed/Steam/UnverifiedFixture",
            primaryExecutable: "UnverifiedFixture.exe",
            depotIDs: ["1000004"],
            depotMountPaths: ["1000004": "Game"],
            completedDepotIDs: ["1000004"],
            stage: .verifying,
            detail: "Verification blocked. Missing transferred payloads.",
            reservedDiskGB: 3,
            depotProgressBytes: ["1000004": 900_000_000]
        )

        let game = await store.finalizeVerifiedInstallIntoLibraryRegistration(
            entry: SteamLibraryEntry(title: "Unverified Fixture", appID: "1000003", installed: false, cloudSavesEnabled: true),
            execution: execution,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            launchArguments: [],
            titleFlags: ["steam"],
            resolvedPolicySummary: "generic-broad-catalog, compact, metalOpenGLFallback"
        )

        XCTAssertNil(game)
        let library = await store.librarySnapshot()
        XCTAssertFalse(library.contains(where: { $0.appID == "1000003" && $0.installed }))
    }

    func testRecordRuntimeExecutionSuccessUpdatesStoreOwnedLaunchState() async throws {
        var snapshot = IridiumSnapshot.empty
        let fixture = makeGameFixture(
            title: "Launch Fixture",
            source: .manualImport,
            appID: "1000005",
            installPath: "/Managed/Imports/LaunchFixture",
            executablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            titleFlags: ["manual-import"],
            summary: "Runtime fixture"
        )
        snapshot.games = [fixture.game]
        snapshot.prefixes = [fixture.prefix]
        let store = IridiumStore(snapshot: snapshot)
        let allGames = await store.allGames()
        let game = try XCTUnwrap(allGames.first(where: { $0.title == "Launch Fixture" }))
        let launchEntryID = UUID()

        await store.recordRuntimeExecutionSuccess(
            gameID: game.id,
            launchEntryID: launchEntryID,
            resolvedExecutablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            issueSummary: ["Launch completed without exposing a desktop shell."],
            hostSessionID: "host-session-1",
            stateHistory: ["queued", "bootstrappingPrefix", "running", "completed"],
            terminalStatus: "completed",
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.12",
            manifestPath: "/Managed/Prefixes/LaunchFixture/prefix.json",
            manifestVersion: "1",
            environmentOverrides: ["IRIDIUM_NO_DESKTOP": "1"],
            prefixState: .customized,
            bootstrapDetail: "Runtime host session completed successfully.",
            telemetrySummary: "fps=60",
            mitigationAction: "none",
            evidenceSummary: "Validated Launch Fixture direct launch.",
            resolvedPolicySummary: "generic-broad-catalog, compact, metalOpenGLFallback",
            launchedAt: Date()
        )

        let refreshedGames = await store.allGames()
        let refreshedGame = try XCTUnwrap(refreshedGames.first(where: { $0.id == game.id }))
        let prefixRecord = await store.prefix(prefixID: game.launchProfile.prefixID)
        let prefix = try XCTUnwrap(prefixRecord)
        let launchHistory = await store.launchHistory()
        let launch = try XCTUnwrap(launchHistory.first(where: { $0.id == launchEntryID }))
        let compatibilityEvidence = await store.compatibilityEvidence()
        let evidence = try XCTUnwrap(compatibilityEvidence.first)

        XCTAssertEqual(refreshedGame.lastSuccessfulRuntimeBundleVersion, "2026.03.12")
        XCTAssertEqual(prefix.manifestPath, "/Managed/Prefixes/LaunchFixture/prefix.json")
        XCTAssertEqual(prefix.lastBootstrapStatus, "completed")
        XCTAssertEqual(prefix.state, .customized)
        XCTAssertEqual(launch.hostSessionID, "host-session-1")
        XCTAssertEqual(launch.stateHistory, ["queued", "bootstrappingPrefix", "running", "completed"])
        XCTAssertEqual(launch.terminalStatus, "completed")
        XCTAssertEqual(launch.telemetrySummary, "fps=60")
        XCTAssertEqual(evidence.accepted, true)
    }

    func testRecordRuntimeExecutionStartedDoesNotClaimLaunchSuccess() async throws {
        var snapshot = IridiumSnapshot.empty
        let fixture = makeGameFixture(
            title: "Launch Fixture",
            source: .manualImport,
            appID: "1000005",
            installPath: "/Managed/Imports/LaunchFixture",
            executablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            titleFlags: ["manual-import"],
            summary: "Runtime fixture"
        )
        snapshot.games = [fixture.game]
        snapshot.prefixes = [fixture.prefix]
        let store = IridiumStore(snapshot: snapshot)
        let games = await store.allGames()
        let game = try XCTUnwrap(games.first)
        let launchEntryID = UUID()

        await store.recordRuntimeExecutionStarted(
            gameID: game.id,
            launchEntryID: launchEntryID,
            resolvedExecutablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            issueSummary: ["Runtime host entered execution."],
            hostSessionID: "host-session-running",
            stateHistory: ["queued", "running"],
            runtimeBundleVersion: "2026.07.16-livecontainer-56",
            launchedAt: Date()
        )

        let refreshedGames = await store.allGames()
        let refreshedGame = try XCTUnwrap(refreshedGames.first)
        let launchHistory = await store.launchHistory()
        let launch = try XCTUnwrap(launchHistory.first)
        let evidence = await store.compatibilityEvidence()

        XCTAssertNil(refreshedGame.lastSuccessfulRuntimeBundleIdentifier)
        XCTAssertNil(refreshedGame.lastSuccessfulRuntimeBundleVersion)
        XCTAssertEqual(launch.readiness, "Verifying")
        XCTAssertEqual(launch.terminalStatus, "running")
        XCTAssertEqual(
            launch.telemetrySummary?.contains("awaiting the first guest frame"),
            true
        )
        XCTAssertTrue(evidence.isEmpty)
    }

    func testRecordRuntimeExecutionFailureUpdatesStoreOwnedLaunchState() async throws {
        var snapshot = IridiumSnapshot.empty
        let fixture = makeGameFixture(
            title: "Launch Fixture",
            source: .manualImport,
            appID: "1000005",
            installPath: "/Managed/Imports/LaunchFixture",
            executablePath: "/Managed/Imports/LaunchFixture/LaunchFixture.exe",
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            titleFlags: ["manual-import"],
            summary: "Runtime fixture"
        )
        snapshot.games = [fixture.game]
        snapshot.prefixes = [fixture.prefix]
        let store = IridiumStore(snapshot: snapshot)
        let allGames = await store.allGames()
        let game = try XCTUnwrap(allGames.first(where: { $0.title == "Launch Fixture" }))
        let launchEntryID = UUID()

        await store.recordRuntimeExecutionFailure(
            gameID: game.id,
            launchEntryID: launchEntryID,
            issueSummary: ["Runtime launch failed before the host session stabilized."],
            hostSessionID: "host-session-2",
            stateHistory: ["queued", "bootingRuntime", "failed"],
            terminalStatus: "failed",
            failureCode: "runtimeBridgeUnavailable",
            failureReason: "Runtime bridge heartbeat was missing.",
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.12",
            evidenceSummary: "Launch failed during runtime bridge handoff.",
            resolvedPolicySummary: "generic-broad-catalog, compact, metalOpenGLFallback",
            launchedAt: Date()
        )

        let refreshedGames = await store.allGames()
        let refreshedGame = try XCTUnwrap(refreshedGames.first(where: { $0.id == game.id }))
        let prefixRecord = await store.prefix(prefixID: game.launchProfile.prefixID)
        let prefix = try XCTUnwrap(prefixRecord)
        let launchHistory = await store.launchHistory()
        let launch = try XCTUnwrap(launchHistory.first(where: { $0.id == launchEntryID }))
        let compatibilityEvidence = await store.compatibilityEvidence()
        let evidence = try XCTUnwrap(compatibilityEvidence.first)

        XCTAssertEqual(refreshedGame.validationEvidenceSummary, "Launch failed during runtime bridge handoff.")
        XCTAssertEqual(prefix.state, .verificationFailed)
        XCTAssertEqual(prefix.lastBootstrapStatus, "failed")
        XCTAssertEqual(launch.failureCode, "runtimeBridgeUnavailable")
        XCTAssertEqual(launch.stateHistory, ["queued", "bootingRuntime", "failed"])
        XCTAssertEqual(launch.terminalStatus, "failed")
        XCTAssertEqual(evidence.accepted, false)
    }

    func testLifecycleActivityFeedRecordsImportResetAndUninstallActions() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let snapshot = IridiumSnapshot.empty
        let stagedTargetPath = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Steam", directoryHint: .isDirectory)
            .appending(path: "ImportedGame", directoryHint: .isDirectory)
            .path

        let store = IridiumStore(snapshot: snapshot, snapshotURL: snapshotURL)
        let imported = await store.importGame(
            title: "Imported Game",
            installPath: sourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        _ = await store.beginInstallExecution(
            title: "Imported Game",
            appID: "1000006",
            buildID: "imported-game-2026.02.18",
            branchName: "public",
            targetPath: stagedTargetPath,
            primaryExecutable: "ImportedGame.exe",
            depotIDs: ["1000007"],
            depotMountPaths: ["1000007": "Game"],
            reservedDiskGB: 3
        )
        await store.resetInstallExecution(title: "Imported Game")
        await store.uninstall(gameID: imported.id)

        let activity = await store.activityFeed()
        XCTAssertEqual(activity.first?.kind, .uninstalled)
        XCTAssertTrue(activity.contains(where: { $0.kind == .imported && $0.relatedTitle == "Imported Game" }))
        XCTAssertTrue(activity.contains(where: { $0.kind == .stagedReset && $0.relatedTitle == "Imported Game" }))
    }

    func testLifecycleActivityFeedRecordsRepairRebuildAndRuntimeValidation() async throws {
        var snapshot = IridiumSnapshot.empty
        let prefix = makePrefixFixture(name: "Lifecycle Prefix")
        snapshot.prefixes = [prefix]
        let store = IridiumStore(snapshot: snapshot)

        await store.repair(prefixID: prefix.id)
        await store.rebuild(prefixID: prefix.id)
        await store.validateRuntime()

        let activity = await store.activityFeed()
        XCTAssertEqual(activity.first?.kind, .runtimeValidated)
        XCTAssertTrue(activity.contains(where: { $0.kind == .prefixRepairScheduled }))
        XCTAssertTrue(activity.contains(where: { $0.kind == .prefixRebuilt }))
    }

    func testRebuildRestoresHealthyRuntimeState() async throws {
        var snapshot = IridiumSnapshot.empty
        let prefix = makePrefixFixture(name: "Lifecycle Prefix")
        snapshot.prefixes = [prefix]
        let store = IridiumStore(snapshot: snapshot)

        await store.repair(prefixID: prefix.id)
        await store.rebuild(prefixID: prefix.id)

        let rebuiltPrefixes = await store.allPrefixes()
        let rebuilt = try XCTUnwrap(rebuiltPrefixes.first(where: { $0.id == prefix.id }))
        let health = await store.healthReport()

        XCTAssertEqual(rebuilt.state, .clean)
        XCTAssertEqual(health.status, .healthy)
    }

    func testManagedStorageTracksQueuedInstallReservations() async {
        let store = IridiumStore()
        let before = await store.managedStorageStatus()

        _ = await store.queueInstall(
            title: "Queued Fixture",
            depotID: "1000008",
            targetPath: "/Managed/Steam/QueuedFixture",
            reservedDiskGB: 3
        )

        let after = await store.managedStorageStatus()

        XCTAssertGreaterThan(after.reservedForQueuedDownloadsGB, before.reservedForQueuedDownloadsGB)
        XCTAssertLessThan(after.availableInstallHeadroomGB, before.availableInstallHeadroomGB)
    }

    func testInstallExecutionProgressesThroughStages() async {
        var snapshot = IridiumSnapshot.empty
        snapshot.steamLibrary = [
            SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true)
        ]
        let store = IridiumStore(snapshot: snapshot)

        _ = await store.beginInstallExecution(
            title: "Steam Fixture",
            appID: "1000000",
            buildID: "steam-fixture-2026.02.18",
            branchName: "public",
            targetPath: "/Managed/Steam/SteamFixture",
            primaryExecutable: "SteamFixture.exe",
            depotIDs: ["1000002"],
            depotMountPaths: ["1000002": "Game"],
            reservedDiskGB: 3
        )

        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        let completed = await store.advanceInstallExecution(title: "Steam Fixture")
        let executions = await store.installExecutions()
        let downloads = await store.allDownloads()
        let library = await store.librarySnapshot()

        XCTAssertEqual(completed?.stage, .completed)
        XCTAssertEqual(executions.first?.stage, .completed)
        XCTAssertEqual(downloads.first?.state, .installed)
        XCTAssertTrue(library.contains(where: { $0.title == "Steam Fixture" && $0.installed }))
    }

    func testInstallExecutionMaterializesManagedFilesystemArtifacts() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        var snapshot = IridiumSnapshot.empty
        snapshot.steamLibrary = [
            SteamLibraryEntry(title: "Steam Fixture", appID: "1000000", installed: false, cloudSavesEnabled: true)
        ]
        let targetPath = tempDirectory
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Steam", directoryHint: .isDirectory)
            .appending(path: "SteamFixture", directoryHint: .isDirectory)
            .path

        let store = IridiumStore(snapshot: snapshot, snapshotURL: snapshotURL)
        _ = await store.beginInstallExecution(
            title: "Steam Fixture",
            appID: "1000000",
            buildID: "steam-fixture-2026.02.18",
            branchName: "public",
            targetPath: targetPath,
            primaryExecutable: "SteamFixture.exe",
            depotIDs: ["1000002"],
            depotMountPaths: ["1000002": "Game"],
            reservedDiskGB: 3
        )
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")
        _ = await store.advanceInstallExecution(title: "Steam Fixture")

        let installRoot = URL(fileURLWithPath: targetPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installRoot.appending(path: ".iridium").appending(path: "session.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installRoot.appending(path: "Game").appending(path: "payload-1000002.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installRoot.appending(path: ".iridium").appending(path: "verified.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installRoot.appending(path: "SteamFixture.exe").path))
    }

    func testManualImportCopiesIntoManagedImportsRoot() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let store = IridiumStore(snapshotURL: snapshotURL)
        let game = await store.importGame(
            title: "Imported Game",
            installPath: sourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback,
            managedArtifactIdentifier: "imported-game",
            executableFingerprint: "fingerprint-123",
            runtimeBundleIdentifier: "iridium-runtime-base",
            runtimeBundleVersion: "2026.03.12"
        )

        XCTAssertNotEqual(game.installPath, sourceDirectory.path)
        XCTAssertTrue(game.installPath.contains("/Managed/Imports/ImportedGame"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: game.installPath).appending(path: "ImportedGame.exe").path))
        XCTAssertEqual(game.launchProfile.executablePath, URL(fileURLWithPath: game.installPath).appending(path: "ImportedGame.exe").path)
        XCTAssertEqual(game.managedArtifactIdentifier, "imported-game")
        XCTAssertEqual(game.executableFingerprint, "fingerprint-123")

        let prefixes = await store.allPrefixes()
        let prefix = try XCTUnwrap(prefixes.first(where: { $0.id == game.launchProfile.prefixID }))
        XCTAssertEqual(prefix.runtimeBundleIdentifier, "iridium-runtime-base")
        XCTAssertEqual(prefix.runtimeBundleVersion, "2026.03.12")
    }

    func testManualImportCopiesIntoManagedImportsRootWhenSourcePathUsesSymlinkAlias() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        let aliasedSourceDirectory = tempDirectory.appending(path: "AliasedSourceGame", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasedSourceDirectory, withDestinationURL: sourceDirectory)

        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let store = IridiumStore(snapshotURL: snapshotURL)
        let game = await store.importGame(
            title: "Imported Game",
            installPath: aliasedSourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        let managedExecutableURL = URL(fileURLWithPath: game.launchProfile.executablePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedExecutableURL.path))
    }

    func testVerifyUsesFilesystemPresenceForManagedGames() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let store = IridiumStore(snapshotURL: snapshotURL)
        let game = await store.importGame(
            title: "Imported Game",
            installPath: sourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        let initialVerification = await store.verify(gameID: game.id)
        XCTAssertTrue(initialVerification)

        try FileManager.default.removeItem(at: URL(fileURLWithPath: game.launchProfile.executablePath))

        let verificationAfterRemoval = await store.verify(gameID: game.id)
        XCTAssertFalse(verificationAfterRemoval)
        let allGames = await store.allGames()
        let refreshedGame = try XCTUnwrap(allGames.first(where: { $0.id == game.id }))
        XCTAssertEqual(refreshedGame.prefixState, .verificationFailed)
        let prefix = await store.prefix(prefixID: game.launchProfile.prefixID)
        XCTAssertEqual(prefix?.state, .verificationFailed)
    }

    func testPersistentStoreRebasesManagedPathsIntoCurrentRoot() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let currentRoot = snapshotURL.deletingLastPathComponent()
        let currentInstallPath = currentRoot
            .appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: "ImportedGame", directoryHint: .isDirectory)
        let currentExecutablePath = currentInstallPath.appending(path: "ImportedGame.exe")

        try FileManager.default.createDirectory(at: currentInstallPath, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: currentExecutablePath.path, contents: Data("imported".utf8))

        let oldInstallPath = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/Library/Application Support/Iridium/Managed/Imports/ImportedGame"
        let oldExecutablePath = "\(oldInstallPath)/ImportedGame.exe"
        let prefixID = UUID()
        let gameID = UUID()

        let snapshot = IridiumSnapshot(
            games: [
                GameRecord(
                    id: gameID,
                    title: "Imported Game",
                    source: .manualImport,
                    installPath: oldInstallPath,
                    savePathMapping: "Documents/Saves/ImportedGame",
                    compatibilityProfileName: "generic-broad-catalog",
                    inputProfileName: "Touch + Controller",
                    touchOverlayName: "Custom Touch Overlay",
                    controllerPresetName: "Custom Controller Preset",
                    keyboardMouseEnabled: true,
                    prefixState: .clean,
                    deviceTier: .tier1,
                    rendererPreset: .metalOpenGLFallback,
                    launchProfile: GameLaunchProfile(
                        executablePath: oldExecutablePath,
                        arguments: [],
                        prefixID: prefixID,
                        rendererPreset: .metalOpenGLFallback,
                        deviceTier: .tier1,
                        titleFlags: ["manual-import"]
                    ),
                    summary: "Imported Windows title."
                )
            ],
            downloads: [],
            installExecutions: [],
            installHistory: [],
            prefixes: [
                PrefixRecord(
                    id: prefixID,
                    name: "Imported Game Prefix",
                    runtimeName: "Iridium Runtime Base",
                    state: .clean,
                    storageFootprint: "2.0 GB"
                )
            ],
            steamAccount: nil,
            steamLibrary: [],
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

        let store = IridiumStore(snapshotURL: snapshotURL)
        let games = await store.allGames()
        let rebasedGame = try XCTUnwrap(games.first)
        let isVerified = await store.verify(gameID: gameID)

        XCTAssertEqual(rebasedGame.installPath, currentInstallPath.path)
        XCTAssertEqual(rebasedGame.launchProfile.executablePath, currentExecutablePath.path)
        XCTAssertTrue(isVerified)
    }

    func testImportGameRefreshesRebasedManualImportAndRestoresManagedExecutable() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let currentRoot = snapshotURL.deletingLastPathComponent()
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        let sourceExecutable = sourceDirectory.appending(path: "hollow_knight.exe")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sourceExecutable.path, contents: Data("imported".utf8))

        let oldInstallPath = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/Library/Application Support/Iridium/Managed/Imports/hollowknight"
        let oldExecutablePath = "\(oldInstallPath)/hollow_knight.exe"
        let prefixID = UUID()
        let gameID = UUID()

        let snapshot = IridiumSnapshot(
            games: [
                GameRecord(
                    id: gameID,
                    title: "hollow_knight",
                    source: .manualImport,
                    installPath: oldInstallPath,
                    savePathMapping: "Documents/Saves/hollowknight",
                    compatibilityProfileName: "generic-broad-catalog",
                    inputProfileName: "Touch + Controller",
                    touchOverlayName: "Custom Touch Overlay",
                    controllerPresetName: "Custom Controller Preset",
                    keyboardMouseEnabled: true,
                    prefixState: .verificationFailed,
                    deviceTier: .tier1,
                    rendererPreset: .metalOpenGLFallback,
                    launchProfile: GameLaunchProfile(
                        executablePath: oldExecutablePath,
                        arguments: [],
                        prefixID: prefixID,
                        rendererPreset: .metalOpenGLFallback,
                        deviceTier: .tier1,
                        titleFlags: ["manual-import"]
                    ),
                    summary: "Imported Windows title."
                )
            ],
            downloads: [],
            installExecutions: [],
            installHistory: [],
            prefixes: [
                PrefixRecord(
                    id: prefixID,
                    name: "Imported Game Prefix",
                    runtimeName: "Iridium Runtime Base",
                    state: .verificationFailed,
                    storageFootprint: "2.0 GB"
                )
            ],
            steamAccount: nil,
            steamLibrary: [],
            runtimeHealth: RuntimeHealthReport(
                status: .healthy,
                runtimeName: "Iridium Runtime Base",
                notes: []
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

        let store = IridiumStore(snapshotURL: snapshotURL)
        let refreshed = await store.importGame(
            title: "hollow_knight",
            installPath: sourceDirectory.path,
            executablePath: sourceExecutable.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        XCTAssertEqual(refreshed.installPath, currentRoot.appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: "hollowknight", directoryHint: .isDirectory)
            .path)
        XCTAssertEqual(refreshed.launchProfile.executablePath, currentRoot.appending(path: "Managed", directoryHint: .isDirectory)
            .appending(path: "Imports", directoryHint: .isDirectory)
            .appending(path: "hollowknight", directoryHint: .isDirectory)
            .appending(path: "hollow_knight.exe")
            .path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: refreshed.launchProfile.executablePath))
        let isVerified = await store.verify(gameID: gameID)
        XCTAssertTrue(isVerified)
    }

    func testUninstallRemovesManagedGameArtifacts() async throws {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let snapshotURL = tempDirectory.appending(path: "state.json")
        let sourceDirectory = tempDirectory.appending(path: "SourceGame", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let executableURL = sourceDirectory.appending(path: "ImportedGame.exe")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("imported".utf8))

        let store = IridiumStore(snapshotURL: snapshotURL)
        let game = await store.importGame(
            title: "Imported Game",
            installPath: sourceDirectory.path,
            executablePath: executableURL.path,
            compatibilityProfileName: "generic-broad-catalog",
            inputProfileName: "Touch + Controller",
            deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: game.installPath))

        await store.uninstall(gameID: game.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: game.installPath))
        let remainingGames = await store.allGames()
        XCTAssertFalse(remainingGames.contains(where: { $0.id == game.id }))
    }
}

private func makePrefixFixture(
    name: String,
    id: UUID = UUID(),
    runtimeName: String = "Iridium Runtime Base",
    state: PrefixState = .clean
) -> PrefixRecord {
    PrefixRecord(
        id: id,
        name: name,
        runtimeName: runtimeName,
        state: state,
        storageFootprint: "2.0 GB",
        storageFootprintGB: 2.0
    )
}

private func makeGameFixture(
    title: String,
    source: GameSource,
    appID: String,
    installPath: String,
    executablePath: String,
    compatibilityProfileName: String,
    inputProfileName: String,
    prefixState: PrefixState = .clean,
    deviceTier: DeviceTier = .tier1,
    rendererPreset: RendererPreset = .metalOpenGLFallback,
    launchArguments: [String] = [],
    titleFlags: [String],
    installedSizeGB: Double? = 1.0,
    summary: String = "Test fixture"
) -> (game: GameRecord, prefix: PrefixRecord) {
    let prefixID = UUID()
    let prefix = makePrefixFixture(name: "\(title) Prefix", id: prefixID, state: prefixState)
    let game = GameRecord(
        title: title,
        source: source,
        installPath: installPath,
        savePathMapping: "Documents/Saves/\(title.filter { $0.isLetter || $0.isNumber })",
        compatibilityProfileName: compatibilityProfileName,
        inputProfileName: inputProfileName,
        touchOverlayName: "Default Touch Overlay",
        controllerPresetName: "Default Controller Preset",
        keyboardMouseEnabled: true,
        prefixState: prefixState,
        deviceTier: deviceTier,
        rendererPreset: rendererPreset,
        launchProfile: GameLaunchProfile(
            executablePath: executablePath,
            arguments: launchArguments,
            prefixID: prefixID,
            rendererPreset: rendererPreset,
            deviceTier: deviceTier,
            titleFlags: titleFlags
        ),
        installedSizeGB: installedSizeGB,
        summary: summary
    )
    return (game, prefix)
}

private func writeLegacySnapshot(_ snapshot: IridiumSnapshot, to snapshotURL: URL) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(snapshot)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "IridiumCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to deserialize encoded snapshot"])
    }
    object.removeValue(forKey: "snapshotVersion")
    let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacyData.write(to: snapshotURL, options: .atomic)
}

private func writeFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url, options: .atomic)
}
