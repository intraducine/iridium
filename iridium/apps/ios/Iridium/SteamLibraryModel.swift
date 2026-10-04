import Foundation
import Combine
import Security
import Darwin

struct SteamDownloadSnapshot: Decodable {
    var phase = "signedOut"
    var message = "Sign in to Steam."
    var busy = false
    var signedIn = false
    var accountName: String?
    var error: String?
    var failureCode: String?
    var storage: SteamStorageDiagnostic?
    var challengeUrl: String?
    var games: [SteamOwnedGame] = []
    var appId: UInt32?
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var installed: SteamDownloadedGame?
    var operationId: String?
    var networkBytes: Int64 = 0
    var details: SteamGameDetails?
    var steamId: String?
    var cloud: SteamCloudStatus?
}

private enum SteamModuleError: LocalizedError {
    case unavailable, storage, rejected, response
    var errorDescription: String? {
        switch self {
        case .unavailable: "This build is missing its native Steam module. Install a build that includes Steam support."
        case .storage: "The secure Steam session could not be saved. Please sign in again next time."
        case .rejected: "Steam is busy or the session has expired. Wait for the current action or sign in again."
        case .response: "The Steam module returned an unreadable response."
        }
    }
}

// Serializes C ABI access away from the main actor. The framework owns the network tasks.
private actor SteamNativeWorker {
    typealias Capacity = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int64
    typealias SetCapacity = @convention(c) (Capacity?) -> Int32
    typealias Input = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias Output = @convention(c) () -> UnsafeMutablePointer<CChar>?
    typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private var library: UnsafeMutableRawPointer?
    private var submit: Input?
    private var snapshot: Output?
    private var takeSession: Output?
    private var release: Release?

    func initialize() throws {
        if library != nil { return }
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let handle = dlopen(frameworks.appendingPathComponent("IridiumSteam.framework/IridiumSteam").path, RTLD_NOW | RTLD_LOCAL),
              let initSymbol = dlsym(handle, "iridium_steam_initialize"),
              let capacitySymbol = dlsym(handle, "iridium_steam_set_capacity_provider"),
              let submitSymbol = dlsym(handle, "iridium_steam_submit"),
              let snapshotSymbol = dlsym(handle, "iridium_steam_snapshot"),
              let sessionSymbol = dlsym(handle, "iridium_steam_take_session"),
              let freeSymbol = dlsym(handle, "iridium_steam_free")
        else { throw SteamModuleError.unavailable }
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("SteamGames", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var storageValues = URLResourceValues()
        storageValues.isExcludedFromBackup = true
        try root.setResourceValues(storageValues)
        let setCapacity = unsafeBitCast(capacitySymbol, to: SetCapacity.self)
        guard setCapacity({ path, source in
            autoreleasepool {
                source?.pointee = 0
                guard let path else { return -1 }
                // Runs on the native download worker at preflight, not at enqueue time.
                let result = SteamStorageCapacity.measure(at: URL(fileURLWithPath: String(cString: path)))
                source?.pointee = result.source
                return result.bytes
            }
        }) == 1 else { throw SteamModuleError.unavailable }
        let start = unsafeBitCast(initSymbol, to: Input.self)
        guard root.resolvingSymlinksInPath().path.withCString({ start($0) }) == 1 else { throw SteamModuleError.storage }
        // NativeAOT libraries cannot be unloaded while their runtime is alive.
        library = handle
        submit = unsafeBitCast(submitSymbol, to: Input.self)
        snapshot = unsafeBitCast(snapshotSymbol, to: Output.self)
        takeSession = unsafeBitCast(sessionSymbol, to: Output.self)
        release = unsafeBitCast(freeSymbol, to: Release.self)
    }

    func send(_ data: Data) throws {
        try initialize()
        guard let text = String(data: data, encoding: .utf8), text.withCString({ submit?($0) }) == 1
        else { throw SteamModuleError.rejected }
    }
    func read() throws -> Data {
        try initialize()
        guard let pointer = snapshot?() else { throw SteamModuleError.response }
        defer { release?(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }
    func session() -> Data? {
        guard let pointer = takeSession?() else { return nil }
        defer { release?(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }
}

private enum SteamKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "software.iridium.steam",
         kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }
    static func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
            else { throw SteamModuleError.storage }
        } else if status != errSecSuccess { throw SteamModuleError.storage }
    }
    static func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SteamModuleError.storage }
        return item as? Data
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamModuleError.storage }
    }
}

@MainActor
final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()
    @Published private(set) var state = SteamDownloadSnapshot()
    @Published private(set) var queue = SteamDownloadQueue()
    @Published private(set) var activeJobID: UUID?
    @Published private(set) var detailsByApp: [UInt32: SteamGameDetails] = [:]
    @Published private(set) var bytesPerSecond: Double = 0
    @Published var error: String?
    @Published private(set) var starting = false
    @Published private(set) var cloudByGame: [UUID: SteamCloudStatus] = [:]
    @Published private(set) var cloudProblems: [UUID: String] = [:]
    @Published private(set) var cloudOperation: UUID?
    @Published private(set) var cloudShutdownUnconfirmed = false

    private let worker = SteamNativeWorker()
    private var persistence: SteamQueuePersistence?
    private var operationTask: Task<Void, Never>?
    private var didRestore = false
    private var restoring = false
    private var queueWritable = false
    private var foreground = true
    private var nativeStateUncertain = false
    private var revision: UInt64 = 0
    private var stopRequested: SteamDownloadJob.Status?
    private var rate = SteamTransferRate()
    private var lastCheckpoint = Date.distantPast
    private var logAttempt: UInt64 = 0

    var busy: Bool { restoring || starting || state.busy || operationTask != nil || nativeStateUncertain }
    var gameFilesBusy: Bool { activeJobID != nil || nativeStateUncertain }
    var pendingCount: Int { queue.jobs.filter(\.isPending).count }
    var account: String? { state.signedIn ? state.accountName : nil }

    func restore() async {
        guard !didRestore, !restoring else { return }
        restoring = true
        didRestore = true
        do {
            var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("SteamDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let storage = SteamQueuePersistence(url: folder.appendingPathComponent("queue.json"))
            persistence = storage
            queue = try await storage.load()
            queue.rebaseInstalledDirectories(steamGamesRoot: folder.deletingLastPathComponent()
                .appendingPathComponent("SteamGames", isDirectory: true))
            queue.recoverAfterRelaunch()
            queueWritable = true
            try await saveQueue()
        } catch {
            // A damaged queue is not silently overwritten by an empty one.
            queueWritable = false
            self.error = error.localizedDescription
        }
        restoring = false
        do {
            try await worker.initialize()
            if let saved = try SteamKeychain.load(),
               var command = try JSONSerialization.jsonObject(with: saved) as? [String: String] {
                command["action"] = "restore"
                perform(command)
            }
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ command: [String: Any]) {
        let action = command["action"] as? String
        if action == "guard" || action == "cancel" {
            Task {
                do { try await send(command) }
                catch { self.error = error.localizedDescription }
            }
            return
        }
        // Installation goes through the durable queue, never through a view task.
        guard action != "install", !busy else { return }
        starting = true
        error = nil
        operationTask = Task {
            do {
                if action == "signOut" {
                    queue.isPaused = true
                    if queueWritable {
                        do { try await saveQueue() }
                        catch { queueWritable = false; self.error = error.localizedDescription }
                    }
                    try SteamKeychain.clear()
                }
                try await send(command)
                starting = false
                try await poll(expectedJob: nil)
            } catch { self.error = error.localizedDescription }
            starting = false
            operationTask = nil
            startNext()
        }
    }

    func loadDetails(for game: SteamOwnedGame) {
        guard !busy else { return }
        perform(["action": "details", "appId": game.appId])
    }

    @discardableResult
    func enqueue(_ game: SteamOwnedGame, options: SteamInstallOptions = SteamInstallOptions(),
                 reuseDirectory: String? = nil) -> Bool {
        guard queueWritable, let account else {
            error = queueWritable ? "Sign in to Steam before adding a download." : "The download queue is unavailable. Existing files have been kept."
            return false
        }
        let job = SteamDownloadJob(game: game, account: account, options: options, reuseDirectory: reuseDirectory)
        guard queue.enqueue(job) else {
            error = "This game is already in the queue, or the queue is full. Resume or remove its existing entry first."
            return false
        }
        queue.isPaused = false
        checkpoint()
        startNext()
        return true
    }

    func resume(_ id: UUID) {
        guard let account, queue.resume(id, account: account) else {
            error = "Sign in to the account used for this download, or finish its other queued operation first."
            return
        }
        checkpoint()
        startNext()
    }

    func downloadAnyway(_ id: UUID) {
        guard foreground, !busy, !SteamCloudFileAccess.shared.busy, queueWritable, let account,
              let job = queue.jobs.first(where: { $0.id == id }),
              let authorization = SteamStorageRetryAuthorization(job: job, account: account),
              queue.resume(id, account: account) else {
            error = "Wait for the current download to finish or pause, then retry from this download's storage warning."
            return
        }
        // Consent cannot wait behind another job or be transferred to the next one.
        queue.prioritize(id)
        startNext(storageAuthorization: authorization)
    }

    func resumeQueue() {
        guard let account else { error = "Sign in to Steam to resume downloads."; return }
        queue.isPaused = false
        for job in queue.jobs where job.status == .paused && job.account == SteamDownloadJob.accountKey(account) {
            _ = queue.resume(job.id, account: account)
        }
        checkpoint()
        startNext()
    }

    func pauseQueue() {
        queue.isPaused = true
        if let id = activeJobID { pause(id) }
        checkpoint()
    }

    func pause(_ id: UUID) {
        if activeJobID == id {
            stopRequested = .paused
            if !starting { perform(["action": "cancel"]) }
        } else {
            queue.update(id) { if $0.status == .queued { $0.status = .paused; $0.phase = "paused" } }
        }
        checkpoint()
    }

    func cancel(_ id: UUID) {
        if activeJobID == id {
            stopRequested = .cancelled
            if !starting { perform(["action": "cancel"]) }
        } else {
            queue.update(id) {
                guard $0.status != .completed else { return }
                $0.status = .cancelled
                $0.phase = "cancelled"
                $0.message = "Cancelled. Partial files are kept for a later download."
            }
        }
        checkpoint()
    }

    func remove(_ id: UUID) { if queue.remove(id) { checkpoint() } }
    func deleteFiles(_ job: SteamDownloadJob) async throws {
        guard SteamCloudFileAccess.shared.isHeld(by: .deleteSteamFiles), !busy, job.status == .completed, let installed = job.installed,
              queue.jobs.contains(where: { $0.id == job.id && $0.installed?.directory == installed.directory }),
              !queue.jobs.contains(where: { $0.id != job.id &&
                  ($0.installed.map { SteamManagedFiles.overlaps($0.directory, installed.directory) } == true ||
                   ($0.isPending && $0.reuseDirectory.map { SteamManagedFiles.overlaps($0, installed.directory) } == true)) })
        else { throw CocoaError(.fileWriteNoPermission) }
        starting = true
        defer { starting = false; startNext() }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).appendingPathComponent("SteamGames", isDirectory: true)
        try await Task.detached(priority: .utility) { try SteamManagedFiles.delete(job, from: root) }.value
        _ = queue.remove(job.id)
        checkpoint()
    }
    func prioritize(_ id: UUID) { queue.prioritize(id); checkpoint() }
    func markAdded(_ id: UUID) { queue.update(id) { $0.addedToLibrary = true }; checkpoint() }

    func repairOrUpdate(_ job: SteamDownloadJob) {
        guard let installed = job.installed else { return }
        _ = enqueue(SteamOwnedGame(appId: job.appId, name: job.name), options: installed.options ?? job.options,
            reuseDirectory: installed.directory)
    }

    func pauseForBackground() {
        foreground = false
        pauseQueue()
        if cloudOperation != nil { perform(["action": "cancel"]) }
    }

    func resumeForeground() {
        foreground = true
        // A background pause is explicit in the UI. Do not undo a user's pause
        // or start a large cellular transfer merely because the app reopened.
    }

    func setCloudProblem(_ gameID: UUID, _ message: String) { cloudProblems[gameID] = message }

    // The application launch gate keeps every runtime idle while this runs.
    // This shares the queue's native worker and busy state, without changing jobs.
    @discardableResult
    func cloud(_ target: SteamCloudTarget, mode: String, choice: SteamCloudChoice? = nil,
               backupID: String? = nil, access: SteamCloudFileAccess.Lease) async -> SteamCloudStatus? {
        guard SteamCloudFileAccess.shared.owns(access, operation: .cloud), !cloudShutdownUnconfirmed else { return nil }
        guard foreground, !busy, state.signedIn, let accountID = state.steamId else {
            cloudProblems[target.gameID] = "Steam is busy or offline. Wait, or sign in, then recheck saves."
            return nil
        }
        let operationID = UUID()
        cloudOperation = target.gameID
        starting = true
        cloudProblems[target.gameID] = nil
        defer { cloudOperation = nil; starting = false; startNext() }
        var submitted = false
        do {
            var request: [String: Any] = ["gameId": target.gameID.uuidString, "mode": mode]
            if let choice { request["choice"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) }
            if let backupID { request["backupId"] = backupID }
            try await send(["action": "cloud", "appId": target.appID, "operationId": operationID.uuidString, "cloud": request])
            submitted = true
            cloudShutdownUnconfirmed = true
            if !foreground { try await send(["action": "cancel"]) }
            try await poll(expectedJob: nil)
            cloudShutdownUnconfirmed = false
            guard state.steamId == accountID, state.operationId == operationID.uuidString,
                  let result = state.cloud, result.gameId == target.gameID.uuidString,
                  result.appId == target.appID else {
                cloudProblems[target.gameID] = state.error ?? state.message
                return nil
            }
            cloudByGame[target.gameID] = result
            return result
        } catch {
            if submitted {
                cloudProblems[target.gameID] = "Cloud shutdown could not be confirmed. Restart Iridium before playing or changing game files, then recheck saves. Saves and backups are kept."
            } else {
                cloudProblems[target.gameID] = "Cloud state could not be confirmed. Saves and backups are kept; recheck before playing."
            }
            return nil
        }
    }

    private func send(_ command: [String: Any]) async throws {
        try await worker.send(JSONSerialization.data(withJSONObject: command))
    }

    private func saveQueue() async throws {
        guard queueWritable, let persistence else { throw SteamQueueError.invalidDocument }
        revision &+= 1
        let snapshot = queue
        let checkpointRevision = revision
        try await persistence.save(snapshot, revision: checkpointRevision)
        lastCheckpoint = Date()
    }

    private func checkpoint() {
        guard queueWritable else { return }
        revision &+= 1
        let snapshot = queue
        let checkpointRevision = revision
        Task {
            do { try await persistence?.save(snapshot, revision: checkpointRevision) }
            catch {
                queue.isPaused = true
                self.error = "The download queue could not be saved. Downloads are paused; existing files are kept."
                queueWritable = false
                stopRequested = .paused
                if activeJobID != nil && !starting { perform(["action": "cancel"]) }
            }
        }
    }

    func resumeQueueAfterFileOperation() { startNext() }

    private func startNext(storageAuthorization: SteamStorageRetryAuthorization? = nil) {
        guard foreground, !busy, !SteamCloudFileAccess.shared.busy, queueWritable, let account,
              let job = queue.next(account: account), queue.begin(job.id) else { return }
        var authorization = storageAuthorization
        let overrideStoragePreflight = authorization?.consume(jobID: job.id, account: account) ?? false
        logAttempt &+= 1
        let attempt = logAttempt
        activeJobID = job.id
        stopRequested = nil
        starting = true
        rate.reset()
        bytesPerSecond = 0
        error = nil
        operationTask = Task {
            do {
                // Persist the operation identity before the first network write.
                try await saveQueue()
                if !foreground || queue.isPaused || stopRequested != nil {
                    settle(job.id, as: stopRequested ?? .paused, message: "Paused before downloading.")
                } else {
                    let options = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job.options))
                    var command: [String: Any] = ["action": "install", "appId": job.appId,
                        "operationId": job.id.uuidString, "options": options,
                        "overrideStoragePreflight": overrideStoragePreflight]
                    if let reuse = job.reuseDirectory { command["reuseDirectory"] = reuse }
                    try await send(command)
                    starting = false
                    if !foreground || queue.isPaused || stopRequested != nil { try await send(["action": "cancel"]) }
                    try await poll(expectedJob: job.id, attempt: attempt)
                }
            } catch {
                RuntimeLogCapture.writeLine("[Steam] attempt=\(attempt) download-failed code=submission-or-state")
                settle(job.id, as: .failed, message: error.localizedDescription)
                self.error = error.localizedDescription
            }
            do { try await saveQueue() }
            catch { queue.isPaused = true; self.error = "The download result could not be saved. Game files are kept." }
            activeJobID = nil
            stopRequested = nil
            starting = false
            bytesPerSecond = 0
            operationTask = nil
            startNext()
        }
    }

    private func settle(_ id: UUID, as status: SteamDownloadJob.Status, message: String?) {
        queue.update(id) { $0.status = status; $0.phase = status.rawValue; $0.message = message }
    }

    private func poll(expectedJob: UUID?, attempt: UInt64 = 0) async throws {
        var loggedStorage = false
        repeat {
            let next: SteamDownloadSnapshot
            do { next = try JSONDecoder().decode(SteamDownloadSnapshot.self, from: await worker.read()) }
            catch {
                // An unreadable response is not evidence the native worker has
                // stopped. Block another install until the app is restarted.
                nativeStateUncertain = true
                throw SteamModuleError.response
            }
            if let expectedJob, next.operationId != expectedJob.uuidString {
                nativeStateUncertain = true
                throw SteamModuleError.response
            }
            if !loggedStorage, let storage = next.storage {
                RuntimeLogCapture.writeLine("[Steam] attempt=\(attempt) " + storage.safeLogLine)
                loggedStorage = true
            }
            if expectedJob != nil, !next.busy {
                if next.phase == "failed" {
                    RuntimeLogCapture.writeLine("[Steam] attempt=\(attempt) " + SteamStorageDiagnostic.safeFailureLog(code: next.failureCode))
                } else {
                    let outcome = ["installed", "paused"].contains(next.phase) ? next.phase : "unexpected"
                    RuntimeLogCapture.writeLine("[Steam] attempt=\(attempt) download-ended outcome=\(outcome)")
                }
            }
            if next.steamId != state.steamId || !next.signedIn { cloudByGame = [:]; cloudProblems = [:] }
            state = next
            if let details = next.details { detailsByApp[details.appId] = details }
            if let saved = await worker.session() {
                do { try SteamKeychain.save(saved) }
                catch { self.error = error.localizedDescription }
            }
            if let id = expectedJob {
                rate.update(networkBytes: next.networkBytes, at: Date.timeIntervalSinceReferenceDate,
                    downloading: next.phase == "downloading" && next.busy)
                bytesPerSecond = rate.bytesPerSecond
                queue.update(id) {
                    $0.phase = next.phase
                    $0.completedBytes = max(0, next.completedBytes)
                    $0.totalBytes = max(0, next.totalBytes)
                    $0.message = next.message
                    $0.failureCode = next.failureCode
                    $0.storage = next.storage
                }
                if !next.busy {
                    if next.phase == "installed", let installed = next.installed {
                        queue.update(id) { $0.status = .completed; $0.installed = installed; $0.message = "Verified and ready to add." }
                    } else if next.phase == "paused" {
                        settle(id, as: stopRequested ?? .paused, message: next.message)
                    } else {
                        settle(id, as: .failed, message: next.error ?? next.message)
                    }
                } else if queueWritable && Date().timeIntervalSince(lastCheckpoint) >= 5 {
                    do { try await saveQueue() }
                    catch {
                        queue.isPaused = true
                        stopRequested = .paused
                        queueWritable = false
                        self.error = "The queue could not be saved. Pausing this download; existing files are kept."
                        try await send(["action": "cancel"])
                    }
                }
            }
            if !next.busy { return }
            try await Task.sleep(for: .milliseconds(500))
        } while true
    }
}
