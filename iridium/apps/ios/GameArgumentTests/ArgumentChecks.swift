import Foundation
import IridiumCore
import IridiumProfiles

// Platform state only. The methods under test come from AppViewModel.swift.
@MainActor final class SteamCloudCoordinator {
    static let shared = SteamCloudCoordinator()
    var busy = false
}
@MainActor final class SteamLibraryModel {
    static let shared = SteamLibraryModel()
    var gameFilesBusy = false
    func resumeQueueAfterFileOperation() {}
}
@MainActor final class AppViewModel {
    let store: IridiumStore
    var games: [GameRecord]
    var compatibilityProfiles: [CompatibilityProfile] = []
    var activeRuntimePlayerSession: UUID?, runtimePlayerReservation: UUID?
    var pendingLaunches: [PendingLaunchRecord] = []
    var isResumingPendingLaunch = false, savingGameArguments = false, preparingGameLaunch = false
    var refreshingGameCopy = false, preparingInstaller = false
    var closingMadeiraSession = false, madeiraShutdownUnconfirmed = false
    var activityStatusMessage: String?, importStatusMessage: String?
    init(store: IridiumStore, games: [GameRecord]) { self.store = store; self.games = games }
}

@MainActor @main struct ArgumentChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); checks += 1
    }
    static func reject(_ expected: GameArgumentEditError, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch let error as GameArgumentEditError {
            check(error.errorDescription == expected.errorDescription, "Wrong rejection: \(error)")
        } catch { preconditionFailure("Unexpected error: \(error)") }
    }
    static func bytes(_ values: [String]) -> [[UInt8]] { values.map { Array($0.utf8) } }
    static func snapshot(_ game: GameRecord) -> IridiumSnapshot {
        var value = IridiumSnapshot.empty
        value.games = [game]
        value.steamAccount = SteamAccount(accountName: "synthetic-offline", state: .signedOut)
        value.steamLibrary = [.init(title: "Synthetic", appID: "0", installed: false, cloudSavesEnabled: true)]
        value.lastLibrarySync = Date(timeIntervalSince1970: 100)
        return value
    }
    static func syntheticGame(_ root: URL) -> GameRecord {
        GameRecord(title: "Synthetic", source: .manualImport,
            installPath: root.appendingPathComponent("game").path, savePathMapping: "synthetic-saves",
            compatibilityProfileName: "synthetic", inputProfileName: "custom-input",
            touchOverlayName: "custom-touch", controllerPresetName: "custom-controller",
            keyboardMouseEnabled: true, prefixState: .customized, deviceTier: .tier2,
            rendererPreset: .dxvkBalanced,
            launchProfile: .init(executablePath: root.appendingPathComponent("game/test.exe").path,
                arguments: ["original"], prefixID: UUID(), rendererPreset: .dxvkBalanced,
                deviceTier: .tier2, titleFlags: ["steam-cloud-disabled", "synthetic-flag"]),
            managedArtifactIdentifier: "synthetic-artifact", executableFingerprint: "synthetic-fingerprint",
            lastSuccessfulRuntimeBundleIdentifier: "synthetic-runtime", lastSuccessfulRuntimeBundleVersion: "0",
            validationEvidenceSummary: "synthetic-evidence", summary: "Synthetic fixture only")
    }
    static func write(_ value: IridiumSnapshot, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func pending(_ game: GameRecord) -> PendingLaunchRecord {
        .init(launchEntryID: UUID(), gameID: game.id, gameTitle: game.title,
            prefixID: game.launchProfile.prefixID, resolvedExecutablePath: game.launchProfile.executablePath,
            workingDirectory: game.installPath, launchArguments: game.launchProfile.arguments, environment: [:],
            resolvedPolicySummary: "synthetic", status: .waitingForJIT, detail: "synthetic")
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iridium-arguments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let game = syntheticGame(root)
        try write(snapshot(game), to: file)
        let store = IridiumStore(snapshotURL: file)
        let before = try Data(contentsOf: file)
        var draft = GameArgumentDraft(game: game)
        let originalID = draft.rows[0].id
        let literals = ["", "two words", "  padded  ", "\"quotes\" 'literal'", "C:\\folder\\file",
                        "日本語 😀", "e\u{301}", "é", "$(synthetic)", "--flag=value", "tab\tline\nend"]
        draft.rows = literals.map { .init(value: $0) }
        check(try Data(contentsOf: file) == before, "Opening/editing/canceling a draft wrote state")
        check(draft.rows.count == literals.count && originalID != draft.rows[0].id, "Draft rows are distinct")
        let rowID = draft.rows[1].id
        draft.rows.swapAt(1, 2)
        check(draft.rows[2].id == rowID, "Reordering changed row identity")
        draft.rows.append(.init(value: "remove me")); draft.rows.removeLast()
        draft.rows.append(.init(value: ""))
        let wanted = draft.rows.map(\.value)

        // Concurrent edits to every other game field must survive the argument save.
        var latest = game
        latest.title = "Updated title"; latest.savePathMapping = "updated-saves"
        latest.inputProfileName = "updated-input"; latest.touchOverlayName = "updated-touch"
        latest.controllerPresetName = "updated-controller"; latest.keyboardMouseEnabled = false
        latest.launchProfile.titleFlags = ["steam-cloud-enabled", "updated-flag"]
        latest.summary = "Updated summary"
        await store.update(latest)
        let latestData = try Data(contentsOf: file)
        let saved = try await store.saveLaunchArguments(draft)
        var expected = latest; expected.launchProfile.arguments = wanted
        check(saved == expected, "Saving replaced other game fields")
        check(bytes(saved.launchProfile.arguments) == bytes(wanted), "Literal argv values changed")
        let diskData = try Data(contentsOf: file)
        let disk = try JSONDecoder().decode(IridiumSnapshot.self, from: diskData)
        check(disk.games[0] == expected && bytes(disk.games[0].launchProfile.arguments) == bytes(wanted), "Disk roundtrip changed arguments")
        var priorJSON = try JSONSerialization.jsonObject(with: latestData) as! [String: Any]
        var savedJSON = try JSONSerialization.jsonObject(with: diskData) as! [String: Any]
        priorJSON.removeValue(forKey: "games"); savedJSON.removeValue(forKey: "games")
        check(NSDictionary(dictionary: priorJSON).isEqual(to: savedJSON), "Other snapshot fields changed")
        let reopened = IridiumStore(snapshotURL: file)
        let reloaded = await reopened.allGames()
        check(bytes(reloaded[0].launchProfile.arguments) == bytes(wanted), "Reopening changed argument bytes")
        await reject(.stale) { _ = try await store.saveLaunchArguments(draft) }
        check(try Data(contentsOf: file) == diskData, "Stale draft changed disk")

        var empty = GameArgumentDraft(game: saved); empty.rows.removeAll()
        let cleared = try await store.saveLaunchArguments(empty)
        check(cleared.launchProfile.arguments.isEmpty && cleared.launchProfile.titleFlags == latest.launchProfile.titleFlags,
              "Clearing arguments changed flags")
        var invalid = GameArgumentDraft(game: cleared); invalid.rows = [.init(value: "nul\0value")]
        let clearData = try Data(contentsOf: file)
        await reject(.invalidArgument) { _ = try await store.saveLaunchArguments(invalid) }
        await reject(.busy) { _ = try await store.saveLaunchArguments(GameArgumentDraft(game: cleared), isBusy: true) }
        check(try Data(contentsOf: file) == clearData, "Rejected argument write changed disk")

        // Executable, profile and byte-distinct Unicode argument changes invalidate drafts.
        var changedExecutable = cleared; changedExecutable.launchProfile.executablePath += ".changed"
        let stale = GameArgumentDraft(game: cleared)
        let staleStore = IridiumStore(snapshot: snapshot(changedExecutable))
        await reject(.stale) { _ = try await staleStore.saveLaunchArguments(stale) }
        var changedProfile = cleared
        changedProfile.launchProfile = .init(executablePath: cleared.launchProfile.executablePath, arguments: [],
            prefixID: cleared.launchProfile.prefixID, rendererPreset: .dxvkBalanced, deviceTier: .tier2, titleFlags: [])
        let profileStore = IridiumStore(snapshot: snapshot(changedProfile))
        await reject(.stale) { _ = try await profileStore.saveLaunchArguments(stale) }
        var unicode = cleared; unicode.launchProfile.arguments = ["é"]
        let unicodeDraft = GameArgumentDraft(game: unicode)
        unicode.launchProfile.arguments = ["e\u{301}"]
        check(!unicodeDraft.isCurrent(for: unicode), "Canonical Unicode equivalence hid a byte change")
        let missing = IridiumStore(snapshot: .empty)
        await reject(.gameMissing) { _ = try await missing.saveLaunchArguments(stale) }
        var queued = snapshot(cleared); queued.pendingLaunches = [pending(cleared)]
        let queuedStore = IridiumStore(snapshot: queued)
        await reject(.busy) { _ = try await queuedStore.saveLaunchArguments(stale) }

        let model = AppViewModel(store: store, games: [cleared])
        var modelDraft = GameArgumentDraft(game: cleared); modelDraft.rows = [.init(value: "model saved"), .init(value: "")]
        func blocked(_ set: (Bool) -> Void) async {
            set(true)
            check(!model.canEditGameArguments(cleared.id), "Busy state left editing enabled")
            await reject(.busy) { try await model.saveGameArguments(modelDraft) }
            check(try! Data(contentsOf: file) == clearData, "Busy model changed disk")
            set(false)
        }
        await blocked { model.activeRuntimePlayerSession = $0 ? UUID() : nil }
        await blocked { model.runtimePlayerReservation = $0 ? UUID() : nil }
        await blocked { model.pendingLaunches = $0 ? [pending(cleared)] : [] }
        await blocked { model.isResumingPendingLaunch = $0 }
        await blocked { model.savingGameArguments = $0 }
        await blocked { model.preparingGameLaunch = $0 }
        await blocked { model.refreshingGameCopy = $0 }
        await blocked { model.preparingInstaller = $0 }
        await blocked { model.closingMadeiraSession = $0 }
        await blocked { model.madeiraShutdownUnconfirmed = $0 }
        await blocked { SteamCloudCoordinator.shared.busy = $0 }
        await blocked { SteamLibraryModel.shared.gameFilesBusy = $0 }
        for operation in SteamCloudFileAccess.Operation.allCases {
            let lease = SteamCloudFileAccess.shared.begin(operation)!
            check(!model.canEditGameArguments(cleared.id), "Existing lease left editing enabled")
            await reject(.busy) { try await model.saveGameArguments(modelDraft) }
            SteamCloudFileAccess.shared.finish(lease)
        }
        model.games = []
        await reject(.gameMissing) { try await model.saveGameArguments(modelDraft) }
        model.games = [cleared]
        try await model.saveGameArguments(modelDraft)
        check(bytes(model.games[0].launchProfile.arguments) == bytes(["model saved", ""]), "Model did not publish verified save")
        check(!model.savingGameArguments && !SteamCloudFileAccess.shared.busy, "Successful save leaked its lease")
        await reject(.stale) { try await model.saveGameArguments(modelDraft) }
        check(!model.savingGameArguments && !SteamCloudFileAccess.shared.busy, "Rejected save leaked its lease")
        let queuedModel = AppViewModel(store: queuedStore, games: [cleared])
        await reject(.busy) { try await queuedModel.saveGameArguments(stale) }
        check(!queuedModel.savingGameArguments && !SteamCloudFileAccess.shared.busy, "Store rejection leaked its lease")

        // A deterministic filesystem failure must not publish success or alter memory.
        let parentFile = root.appendingPathComponent("parent-is-file")
        try Data("fixture".utf8).write(to: parentFile)
        let unwritable = IridiumStore(snapshot: snapshot(cleared), snapshotURL: parentFile.appendingPathComponent("library.json"))
        let failedModel = AppViewModel(store: unwritable, games: [cleared])
        var failedDraft = stale; failedDraft.rows = [.init(value: "must not be published")]
        do { try await failedModel.saveGameArguments(failedDraft); preconditionFailure("Expected filesystem failure") }
        catch { check(!(error is GameArgumentEditError), "Unexpected preflight failure") }
        let unchanged = await unwritable.allGames()
        check(unchanged[0].launchProfile.arguments.isEmpty && failedModel.games[0] == cleared, "Failed save published changes")
        check(!failedModel.savingGameArguments && !SteamCloudFileAccess.shared.busy, "Failed save leaked its lease")

        // Run the real compatibility methods too: automatic defaults are never saved.
        let policy = RuntimePolicy(memoryBudgetClass: .balanced, resolutionScale: 1,
                                   shaderStrategy: .onDemand, requiresExplicitWhitelist: false)
        model.compatibilityProfiles = [.init(slug: "synthetic", title: "Synthetic", minimumDeviceTier: .tier1,
            recommendedRenderer: .dxvkBalanced, launchArguments: ["automatic"], titleFlags: [], knownIssues: [])]
        check(model.gameApplyingCompatibilityLaunchDefaults(cleared, resolvedPolicy: policy).launchProfile.arguments == ["automatic"],
              "Empty custom rows lost automatic defaults")
        check(model.gameApplyingCompatibilityLaunchDefaults(saved, resolvedPolicy: policy).launchProfile.arguments == wanted,
              "Nonempty custom rows changed compatibility behavior")
        var graphics = cleared; graphics.rendererPreset = .metalOpenGLFallback
        check(model.gameApplyingCompatibilityLaunchDefaults(graphics, resolvedPolicy: policy).launchProfile.arguments
              == BuiltInCompatibilityProfiles.unityOpenGLLaunchArguments, "Graphics defaults were lost")
        graphics.launchProfile.arguments = ["-force-vulkan", "literal space", ""]
        check(model.gameApplyingCompatibilityLaunchDefaults(graphics, resolvedPolicy: policy).launchProfile.arguments
              == graphics.launchProfile.arguments, "Explicit graphics selection was replaced")
        check(cleared.launchProfile.arguments.isEmpty, "Resolving automatic defaults mutated the stored record")
        print("\(checks) production argument checks passed")
    }
}
