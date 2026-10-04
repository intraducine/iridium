import Foundation
import IridiumCore

// The checker appends actual AppViewModel entry-point bodies to this host.
// Only their filesystem/store effects and the native transport are mocked.
final class FixtureFileWork: @unchecked Sendable {
    static let shared = FixtureFileWork()
    private let condition = NSCondition()
    private var held = false
    private var started = false
    private var count = 0
    var failing = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    var calls: Int { condition.lock(); defer { condition.unlock() }; return count }
    func reset(hold: Bool) {
        condition.lock(); defer { condition.unlock() }
        held = hold; started = false; count = 0; failing = false
    }
    func run() throws {
        condition.lock(); defer { condition.unlock() }
        started = true; count += 1
        let deadline = Date().addingTimeInterval(10)
        while held {
            precondition(condition.wait(until: deadline), "Synthetic file worker timed out")
        }
        if failing { throw CocoaError(.fileWriteUnknown) }
    }
    func release() { condition.lock(); held = false; condition.broadcast(); condition.unlock() }
}
enum FixtureRuntimeState { case running, completed }
struct FixtureSession { let gameID: UUID; let state: FixtureRuntimeState }
struct FixtureExecutable { let path: String }
struct FixtureScan { let installPath: String; let recommendedExecutable: FixtureExecutable? }
struct FixtureInstalled { let directory: String }
struct SteamDownloadJob { let installed: FixtureInstalled? }
struct PrefixRecord { let id: UUID; let name: String }
struct FixtureSnapshot { var steamId: String? = "76561198000000001"; var signedIn = true }
@MainActor final class FixtureStore {
    var calls = 0
    var hold = false
    var waiting: CheckedContinuation<Void, Never>?
    private func perform() async {
        calls += 1
        if hold { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { waiting?.resume(); waiting = nil; hold = false }
    func removeLibraryEntry(gameID: UUID) async { await perform() }
    func relocateLibraryEntry(gameID: UUID, folder: URL, executable: URL, identifier: String,
                              fingerprint: String, storage: Int) async throws { await perform() }
    func repair(prefixID: UUID) async { await perform() }
    func rebuild(prefixID: UUID) async { await perform() }
    func clone(prefixID: UUID, newName: String) async -> Int { await perform(); return 1 }
}
@MainActor final class AppViewModel {
    var activeRuntimePlayerSession: FixtureSession?
    var runtimePlayerReservation: FixtureSession?
    var closingMadeiraSession = false
    var madeiraShutdownUnconfirmed = false
    var preparingInstaller = false
    var refreshingGameCopy = false
    var usesMadeiraRuntime = true
    var activityStatusMessage: String?
    var importStatusMessage: String?
    var isImportingGame = false
    var importScanResult: FixtureScan?
    var importSourceURL: URL?
    var importStorage = 0
    var games: [GameRecord] = []
    let store = FixtureStore()
    func refresh() async {}
    func dismissImportScan() { importScanResult = nil }
    func validatedImportMetadata(title: String, executablePath: String, installPath: String) -> (identifier: String, fingerprint: String)? { ("synthetic", "synthetic") }
    func madeiraLaunchIssue(for game: GameRecord) -> String? { nil }
}
@MainActor final class SteamLibraryModel {
    static let shared = SteamLibraryModel()
    var state = FixtureSnapshot()
    var cloudOperation: UUID?
    var cloudShutdownUnconfirmed = false
    var gameFilesBusy = false
    var busy: Bool { gameFilesBusy || cloudOperation != nil }
    var cloudProblems: [UUID: String] = [:]
    var calls = 0
    var block = true
    var waiting: CheckedContinuation<SteamCloudStatus?, Never>?
    func setCloudProblem(_ id: UUID, _ message: String) { cloudProblems[id] = message }
    func resumeQueueAfterFileOperation() { precondition(!SteamCloudFileAccess.shared.busy) }
    func perform(_ command: [String: Any]) { waiting?.resume(returning: nil); waiting = nil }
    func cloud(_ target: SteamCloudTarget, mode: String, choice: SteamCloudChoice? = nil,
               backupID: String? = nil, access: SteamCloudFileAccess.Lease) async -> SteamCloudStatus? {
        precondition(SteamCloudFileAccess.shared.owns(access, operation: .cloud))
        calls += 1; cloudOperation = target.gameID
        defer { cloudOperation = nil }
        if block { return await withCheckedContinuation { waiting = $0 } }
        return nil
    }
    func deleteFiles(_ job: SteamDownloadJob) async throws {
        precondition(SteamCloudFileAccess.shared.isHeld(by: .deleteSteamFiles))
        try await Task.detached { try FixtureFileWork.shared.run() }.value
    }
}
enum MadeiraRuntimeAdapter {
    static let enabled = true
    static let started = false
}
enum MadeiraGamePreparation {
    static func prefix(for id: UUID) -> URL { URL(fileURLWithPath: "/synthetic/prefix") }
    static func prepare(executable: URL, gameRoot: URL, prefix: URL, replaceConflictsWithBackup: Bool) throws -> Int {
        try FixtureFileWork.shared.run(); return 1
    }
}
enum IridiumGamePrerequisites {
    static func queueInstaller(_ source: URL, prefix: URL) throws { try FixtureFileWork.shared.run() }
}
enum ManagedGameFiles {
    static func deleteGameFolder(at folder: URL, in root: URL) throws { try FixtureFileWork.shared.run() }
}
enum SteamCloudPreparation {
    static func prepare(gameID: UUID, documents: URL, executable: URL, source: URL,
                        seed: (URL) -> Void) throws { try FixtureFileWork.shared.run() }
}
func madeira_seed_prefix_if_needed(_ path: String) {}
#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif

@main @MainActor
struct MutationChecks {
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<100000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Mutation fixture did not settle")
    }
    static func rejected(_ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("Concurrent mutation was accepted") }
        catch { precondition((error as NSError).domain == "IridiumSteamCloud") }
    }
    static func main() async throws {
        let game = GameRecord(id: UUID(), title: "Synthetic", installPath: "/synthetic",
            launchProfile: FixtureLaunchProfile(executablePath: "/synthetic/game.exe", titleFlags: ["steam-app-id:42"]))
        let cloud = SteamCloudCoordinator.shared
        let gate = SteamCloudFileAccess.shared
        let steam = SteamLibraryModel.shared
        let work = FixtureFileWork.shared
        let model = AppViewModel()
        model.games = [game]
        let installer = URL(fileURLWithPath: "/synthetic/setup.exe")
        let job = SteamDownloadJob(installed: FixtureInstalled(directory: game.installPath))
        let prefix = PrefixRecord(id: UUID(), name: "Synthetic")
        func scan() { model.importScanResult = FixtureScan(installPath: "/relocated", recommendedExecutable: FixtureExecutable(path: "/relocated/game.exe")) }
        func attemptMutations() async {
            let storeCalls = model.store.calls
            let fileCalls = work.calls
            model.refreshMadeiraGameCopy(game)
            await rejected { try await model.prepareInstaller(installer, for: game) }
            await rejected { try await model.deleteImportedGameFiles(game) }
            await rejected { try await model.deleteSteamDownload(job, from: steam) }
            scan(); model.relocateScannedImport(game)
            model.removeLibraryEntry(game)
            model.repairPrefix(prefix); model.rebuildPrefix(prefix); model.clonePrefix(prefix)
            for _ in 0..<20 { await Task.yield() }
            precondition(model.store.calls == storeCalls && work.calls == fileCalls)
            precondition(!model.refreshingGameCopy && !model.preparingInstaller && !model.isImportingGame)
        }
        // Cloud-first: deny all real mutation entry points during detached
        // preparation, and again while native transfer is suspended.
        work.reset(hold: true)
        let syncing = Task { await cloud.synchronize(game, model: model, mode: "check") }
        await until { work.entered && gate.cloudOwned }
        await attemptMutations()
        cloud.clearLaunch()
        precondition(gate.cloudOwned)
        work.release()
        await until { steam.waiting != nil }
        await attemptMutations()
        steam.perform(["action": "cancel"])
        _ = await syncing.value
        precondition(!gate.busy)

        // Mutation-first: Cloud must refuse without even beginning preparation.
        func denyCloud() async {
            let before = work.calls
            let nativeCalls = steam.calls
            precondition(gate.mutating)
            let result = await cloud.synchronize(game, model: model, mode: "check")
            precondition(result == nil)
            precondition(work.calls == before && steam.calls == nativeCalls)
        }
        work.reset(hold: true)
        model.refreshMadeiraGameCopy(game)
        precondition(gate.mutating) // Acquired before its Task is scheduled.
        await until { work.entered }
        await denyCloud()
        work.release(); await until { !gate.busy }

        for operation in ["installer", "source deletion", "Steam deletion"] {
            work.reset(hold: true)
            let mutation = Task {
                switch operation {
                case "installer": try await model.prepareInstaller(installer, for: game)
                case "source deletion": try await model.deleteImportedGameFiles(game)
                default: try await model.deleteSteamDownload(job, from: steam)
                }
            }
            await until { work.entered }
            mutation.cancel()
            await denyCloud() // Cancellation does not free an active detached worker.
            work.release(); try await mutation.value
            precondition(!gate.busy)
        }
        for operation in ["relocate", "remove", "repair", "rebuild", "clone"] {
            model.store.hold = true
            switch operation {
            case "relocate": scan(); model.relocateScannedImport(game)
            case "remove": model.removeLibraryEntry(game)
            case "repair": model.repairPrefix(prefix)
            case "rebuild": model.rebuildPrefix(prefix)
            default: model.clonePrefix(prefix)
            }
            precondition(gate.mutating)
            await until { model.store.waiting != nil }
            await denyCloud()
            model.store.release(); await until { !gate.busy }
        }
        // Failure releases only after the worker finished, so later work recovers.
        work.reset(hold: false); work.failing = true
        do { try await model.prepareInstaller(installer, for: game); preconditionFailure("Fixture failed to throw") }
        catch { precondition(!gate.busy && !model.preparingInstaller) }
        work.reset(hold: false); steam.block = false
        let calls = steam.calls
        _ = await cloud.synchronize(game, model: model, mode: "check")
        precondition(steam.calls == calls + 1 && !gate.busy)
        work.reset(hold: false)
        steam.gameFilesBusy = true
        await attemptMutations()
        _ = await cloud.synchronize(game, model: model, mode: "check")
        precondition(work.calls == 0 && steam.calls == calls + 1)
        steam.gameFilesBusy = false
        work.reset(hold: true)
        let accountChange = Task { await cloud.synchronize(game, model: model, mode: "check") }
        await until { work.entered }
        steam.state.steamId = "76561198000000002"
        work.release(); _ = await accountChange.value
        precondition(steam.calls == calls + 1 && !gate.busy && steam.cloudProblems[game.id] != nil)
        print("PASS: actual AppViewModel Cloud/mutation exclusion in both orders, detached-worker cancellation, failure recovery and queue release (host effects).")
    }
}
