import Combine
import Foundation
import IridiumCore

extension SteamCloudTarget {
    init?(game: GameRecord) {
        let ids = game.launchProfile.titleFlags.filter { $0.hasPrefix("steam-app-id:") }
        guard ids.count == 1, let appID = UInt32(ids[0].dropFirst("steam-app-id:".count)), appID > 0 else { return nil }
        self.init(gameID: game.id, appID: appID)
    }
}

// One app-level save/launch gate. No assumptions about screen dismissal or
// process exit: only the runtime's confirmed exit callback releases a session.
@MainActor
final class SteamCloudCoordinator: ObservableObject {
    static let shared = SteamCloudCoordinator()
    @Published private(set) var preparing = false
    @Published private(set) var launchGameID: UUID?
    @Published var launchProblem: String?
    private var pendingLaunch: (() -> Void)?
    private var confirmedStoppedGameID: UUID?
    private var cancelledGameID: UUID?
    private var optedGames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "IridiumSteamCloudOptedGames") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "IridiumSteamCloudOptedGames") }
    }
    var busy: Bool { preparing || launchGameID != nil || SteamLibraryModel.shared.cloudOperation != nil || SteamCloudFileAccess.shared.cloudOwned }
    var canLaunchWithoutSync: Bool {
        !preparing && !SteamCloudFileAccess.shared.busy && SteamLibraryModel.shared.cloudOperation == nil &&
            !SteamLibraryModel.shared.cloudShutdownUnconfirmed && !SteamLibraryModel.shared.gameFilesBusy
    }

    func runtimeIdle(_ model: AppViewModel) -> Bool {
        (model.activeRuntimePlayerSession == nil ||
            (model.activeRuntimePlayerSession?.gameID == confirmedStoppedGameID && model.activeRuntimePlayerSession?.state != .running)) && !model.closingMadeiraSession &&
            !model.madeiraShutdownUnconfirmed && !model.preparingInstaller && !model.refreshingGameCopy && !SteamCloudFileAccess.shared.mutating
    }

    @discardableResult
    func synchronize(_ game: GameRecord, model: AppViewModel, mode: String,
                     choice: SteamCloudChoice? = nil, backupID: String? = nil) async -> SteamCloudStatus? {
        let steam = SteamLibraryModel.shared
        guard model.usesMadeiraRuntime, let target = SteamCloudTarget(game: game) else { return nil }
        guard runtimeIdle(model), !preparing, !steam.busy else {
            steam.setCloudProblem(game.id, "Cloud sync is waiting for Steam, the game, or a game-file operation to stop. Saves stay on this device; recheck from Steam Cloud in Game Options.")
            return nil
        }
        guard let access = SteamCloudFileAccess.shared.begin(.cloud) else {
            steam.setCloudProblem(game.id, "Another save or game-file operation still owns these files. Wait for it to finish before syncing.")
            return nil
        }
        preparing = true
        let preparedAccountID = steam.state.steamId
        defer {
            preparing = false
            // An unreadable/cancelled poll is not evidence that native writes
            // stopped. Retain ownership until restart in that uncertain state.
            if !steam.cloudShutdownUnconfirmed { SteamCloudFileAccess.shared.finish(access) }
        }
        // This is a conservative launch-warning index, never upload consent.
        // The backend account record is the sole authority for transfers.
        let consentKey = game.id.uuidString + "|" + (preparedAccountID ?? "unknown")
        if mode == "enable" { var opted = optedGames; opted.insert(consentKey); optedGames = opted }
        do {
            #if MADEIRA_RUNTIME
            if mode != "disable" {
                let executable = URL(fileURLWithPath: game.launchProfile.executablePath)
                let source = URL(fileURLWithPath: game.installPath)
                let gameID = game.id
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try await Task.detached(priority: .utility) {
                    // Reuse the existing copy/baseline/rollback contract. Never
                    // receive saves before the runtime's first source copy.
                    try SteamCloudPreparation.prepare(gameID: gameID, documents: documents,
                        executable: executable, source: source) { prefix in
                        madeira_seed_prefix_if_needed(prefix.path)
                    }
                }.value
            }
            #endif
            guard runtimeIdle(model) else { return nil }
            guard steam.state.steamId == preparedAccountID else {
                steam.setCloudProblem(game.id, "The Steam account changed while preparing saves. Recheck with the current account before syncing.")
                return nil
            }
            if mode == "preflight", launchGameID != game.id { return nil }
            let result = await SteamLibraryModel.shared.cloud(target, mode: mode, choice: choice, backupID: backupID, access: access)
            if let result {
                var opted = optedGames
                if result.enabled { opted.insert(consentKey) }
                else if mode == "disable" { opted.remove(consentKey) }
                optedGames = opted
            }
            return result
        } catch {
            SteamLibraryModel.shared.setCloudProblem(game.id,
                "The isolated game copy could not be prepared. Existing files are kept. Check Files & Saves and the game-copy status before syncing.")
            return nil
        }
    }

    // Returns true when Cloud owns this Play request. A disabled/unselected game
    // continues through the existing launch path without automatic transfers.
    func beforeLaunch(_ game: GameRecord, model: AppViewModel, proceed: @escaping () -> Void) -> Bool {
        let steam = SteamLibraryModel.shared
        guard model.usesMadeiraRuntime else { return false }
        if busy { return true }
        cancelledGameID = nil
        guard SteamCloudTarget(game: game) != nil else { return false }
        let consentKey = game.id.uuidString + "|" + (steam.state.steamId ?? "unknown")
        let selected = steam.state.signedIn ? optedGames.contains(consentKey) : optedGames.contains(where: { $0.hasPrefix(game.id.uuidString + "|") })
        guard selected else { return false }
        guard runtimeIdle(model) else { return true }
        launchGameID = game.id
        pendingLaunch = proceed
        Task {
            let result = await synchronize(game, model: model, mode: "preflight")
            guard launchGameID == game.id else { return }
            if let result, !result.enabled || result.readyToPlay {
                let launch = pendingLaunch
                clearLaunch()
                confirmedStoppedGameID = nil
                launch?()
            } else {
                launchProblem = steam.cloudProblems[game.id] ?? result?.message ?? "Cloud saves could not be checked."
            }
        }
        return true
    }

    func launchWithoutSync() {
        // Never launch while the native worker might still be replacing a save.
        guard canLaunchWithoutSync else { return }
        let launch = pendingLaunch
        clearLaunch()
        confirmedStoppedGameID = nil
        launch?()
    }
    func clearLaunch() {
        if launchGameID != nil && SteamLibraryModel.shared.cloudOperation != nil { SteamLibraryModel.shared.perform(["action": "cancel"]) }
        launchGameID = nil; launchProblem = nil; pendingLaunch = nil
    }

    func cancelSession(_ gameID: UUID) {
        cancelledGameID = gameID
        SteamLibraryModel.shared.setCloudProblem(gameID,
            "This session was closed or cancelled. Saves stay on this device. After shutdown is confirmed, sync from Steam Cloud in Game Options.")
    }

    func confirmedExit(_ game: GameRecord, model: AppViewModel) {
        confirmedStoppedGameID = game.id
        guard cancelledGameID != game.id else { return }
        let consentKey = game.id.uuidString + "|" + (SteamLibraryModel.shared.state.steamId ?? "unknown")
        guard optedGames.contains(consentKey) else { return }
        Task {
            _ = await synchronize(game, model: model, mode: "sync")
        }
    }
}
