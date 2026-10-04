import Foundation
import IridiumCore

// Host declarations isolate runtime/Steam network dependencies. This executes
// the actual production coordinator; transfer safety is tested in CloudTests.cs.
enum FixtureRuntimeState { case running, completed }
struct FixtureSession { let gameID: UUID; let state: FixtureRuntimeState }
@MainActor final class AppViewModel {
    var activeRuntimePlayerSession: FixtureSession?
    var closingMadeiraSession = false
    var madeiraShutdownUnconfirmed = false
    var preparingInstaller = false
    var refreshingGameCopy = false
    var usesMadeiraRuntime = true
}
struct FixtureSnapshot { var steamId: String? = "76561198000000001"; var signedIn = true }
@MainActor final class SteamLibraryModel {
    static let shared = SteamLibraryModel()
    var state = FixtureSnapshot()
    var cloudOperation: UUID?
    var cloudShutdownUnconfirmed = false
    var busy: Bool { cloudOperation != nil }
    var gameFilesBusy = false
    var loseShutdown = false
    var cloudProblems: [UUID: String] = [:]
    var calls: [String] = []
    var block = false
    var waiting: CheckedContinuation<SteamCloudStatus?, Never>?
    func setCloudProblem(_ id: UUID, _ message: String) { cloudProblems[id] = message }
    func resumeQueueAfterFileOperation() { precondition(!SteamCloudFileAccess.shared.busy) }
    func perform(_ command: [String: Any]) {
        calls.append(command["action"] as? String ?? "unknown")
        waiting?.resume(returning: nil); waiting = nil
    }
    func cloud(_ target: SteamCloudTarget, mode: String, choice: SteamCloudChoice? = nil, backupID: String? = nil,
               access: SteamCloudFileAccess.Lease) async -> SteamCloudStatus? {
        precondition(SteamCloudFileAccess.shared.owns(access, operation: .cloud))
        calls.append(mode); cloudOperation = target.gameID
        defer { cloudOperation = nil }
        if block { return await withCheckedContinuation { waiting = $0 } }
        if loseShutdown { cloudShutdownUnconfirmed = true; return nil }
        return SteamCloudStatus(gameId: target.gameID.uuidString, appId: target.appID, enabled: true,
            phase: "ready", message: "Synthetic", entries: [], backups: [])
    }
}

@main @MainActor
struct CoordinatorChecks {
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Coordinator fixture did not settle")
    }
    static func main() async {
        let preferenceKey = "IridiumSteamCloudOptedGames"
        let previous = UserDefaults.standard.stringArray(forKey: preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: preferenceKey) }
        let game = GameRecord(id: UUID(), title: "Synthetic", installPath: "/synthetic",
                              launchProfile: FixtureLaunchProfile(executablePath: "/synthetic/game.exe", titleFlags: ["steam-app-id:42"]))
        let cloud = SteamCloudCoordinator.shared
        let steam = SteamLibraryModel.shared
        let model = AppViewModel()
        var launched = 0
        precondition(!cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        _ = await cloud.synchronize(game, model: model, mode: "enable")
        precondition(cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        await until { !cloud.busy }
        precondition(launched == 1 && steam.calls == ["enable", "preflight"])
        steam.block = true
        precondition(cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        await until { steam.waiting != nil }
        cloud.clearLaunch()
        await until { !cloud.busy }
        precondition(launched == 1 && steam.calls.suffix(2) == ["preflight", "cancel"])
        precondition(!steam.calls.contains("sync"))
        steam.block = false
        model.activeRuntimePlayerSession = FixtureSession(gameID: game.id, state: .running)
        let count = steam.calls.count
        _ = await cloud.synchronize(game, model: model, mode: "sync")
        precondition(steam.calls.count == count)
        model.activeRuntimePlayerSession = FixtureSession(gameID: game.id, state: .completed)
        model.madeiraShutdownUnconfirmed = true
        cloud.confirmedExit(game, model: model)
        for _ in 0..<100 { await Task.yield() }
        precondition(steam.calls.count == count)
        model.madeiraShutdownUnconfirmed = false
        cloud.cancelSession(game.id)
        cloud.confirmedExit(game, model: model)
        for _ in 0..<100 { await Task.yield() }
        precondition(steam.calls.count == count && steam.cloudProblems[game.id] != nil)
        model.activeRuntimePlayerSession = nil
        steam.state.steamId = "76561198000000002"
        precondition(!cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        steam.state.steamId = "76561198000000001"
        precondition(cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        await until { !cloud.busy }
        model.activeRuntimePlayerSession = FixtureSession(gameID: game.id, state: .completed)
        cloud.confirmedExit(game, model: model)
        await until { steam.calls.last == "sync" && !cloud.busy }
        // A stale completion cannot release a new owner's files.
        let gate = SteamCloudFileAccess.shared
        let old = gate.begin(.refresh)!
        precondition(gate.begin(.cloud) == nil)
        gate.finish(old)
        let current = gate.begin(.installer)!
        gate.finish(old)
        precondition(gate.owns(current, operation: .installer) && gate.begin(.cloud) == nil)
        gate.finish(current)
        // Lost proof of native shutdown retains the Cloud lease until restart.
        model.activeRuntimePlayerSession = nil
        steam.loseShutdown = true
        let beforeUncertainLaunch = launched
        precondition(cloud.beforeLaunch(game, model: model, proceed: { launched += 1 }))
        await until { cloud.launchProblem != nil }
        precondition(gate.cloudOwned && gate.begin(.deleteImportedFiles) == nil)
        precondition(!cloud.canLaunchWithoutSync)
        cloud.launchWithoutSync()
        precondition(launched == beforeUncertainLaunch)
        cloud.clearLaunch()
        precondition(gate.cloudOwned)
        print("PASS: production Cloud launch gate, cancellation without uploads, account selection and confirmed-exit gates (host mocks).")
    }
}
