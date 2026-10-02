import Foundation

// These values cross the native ABI and are also persisted. No passwords, Guard
// codes, refresh tokens, or CDN authorization belong in this document.
struct SteamOwnedGame: Codable, Identifiable, Equatable, Sendable {
    let appId: UInt32
    let name: String
    var id: UInt32 { appId }
}

struct SteamInstallOptions: Codable, Equatable, Sendable {
    var branch = "public"
    var language = "english"
    var architecture = "64"
    var includeDlc = true
    var dlcAppIds: [UInt32] = []
    var maxDownloads = 4
}

struct SteamDownloadedGame: Codable, Equatable, Sendable {
    let appId: UInt32
    let name: String
    var directory: String
    let executables: [String]
    var buildId: String?
    var options: SteamInstallOptions?
}

struct SteamBranch: Decodable, Identifiable, Sendable {
    let name: String
    let buildId: String?
    let passwordRequired: Bool
    var id: String { name }
}

struct SteamGameDetails: Decodable, Sendable {
    let appId: UInt32
    let branches: [SteamBranch]
    let languages: [String]
    let dlcAppIds: [UInt32]
}

// Matches the native capacity callback's fixed source values. This deliberately
// prefers user-initiated-download capacity over immediately unused blocks.
enum SteamStorageCapacity {
    static func select(important: () -> Int64?, available: () -> Int64?) -> (bytes: Int64, source: Int32) {
        if let bytes = important(), bytes >= 0 { return (bytes, 1) }
        if let bytes = available(), bytes >= 0 { return (bytes, 2) }
        return (-1, 0)
    }

    static func measure(at destination: URL) -> (bytes: Int64, source: Int32) {
        select(important: {
            #if canImport(Darwin)
            return try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            #else
            return nil
            #endif
        }, available: {
            guard let bytes = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else { return nil }
            return Int64(bytes)
        })
    }
}

struct SteamStorageDiagnostic: Codable, Equatable, Sendable {
    let requiredBytes: Int64
    let availableBytes: Int64?
    let safetyMarginBytes: Int64
    let capacitySource: String
    let overridden: Bool

    var safeLogLine: String {
        let source = ["important-usage", "volume-available", "drive-available"].contains(capacitySource) ? capacitySource : "unknown"
        let available = availableBytes.flatMap { $0 >= 0 ? String($0) : nil } ?? "unknown"
        return "storage-preflight required=\(max(0, requiredBytes)) available=\(available) margin=\(max(0, safetyMarginBytes)) source=\(source) override=\(overridden)"
    }

    static func safeFailureLog(code: String?) -> String {
        let known = ["storage-insufficient", "storage-unavailable", "disk-full", "io"]
        return "download-failed code=\(code.flatMap { known.contains($0) ? $0 : nil } ?? "request-failed")"
    }
}

// Ephemeral consent for one immediate submission. Never Codable, an install option,
// or stored on the model/queue. A failed save/send, pause, or relaunch discards it.
struct SteamStorageRetryAuthorization {
    private var jobID: UUID?
    private let account: String

    init?(job: SteamDownloadJob, account: String) {
        guard job.canDownloadAnyway, job.account == SteamDownloadJob.accountKey(account) else { return nil }
        jobID = job.id
        self.account = job.account
    }

    mutating func consume(jobID: UUID, account: String) -> Bool {
        defer { self.jobID = nil }
        return self.jobID == jobID && self.account == SteamDownloadJob.accountKey(account)
    }
}

struct SteamDownloadJob: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, running, paused, failed, completed, cancelled
    }
    let id: UUID
    let appId: UInt32
    let name: String
    let account: String
    let createdAt: Date
    var options: SteamInstallOptions
    var status: Status
    var phase: String
    var completedBytes: Int64
    var totalBytes: Int64
    var message: String?
    var installed: SteamDownloadedGame?
    var addedToLibrary: Bool
    var reuseDirectory: String?
    var failureCode: String?
    var storage: SteamStorageDiagnostic?

    init(game: SteamOwnedGame, account: String, options: SteamInstallOptions,
         reuseDirectory: String? = nil, id: UUID = UUID()) {
        self.id = id
        appId = game.appId
        name = game.name
        self.account = Self.accountKey(account)
        createdAt = Date()
        self.options = options
        status = .queued
        phase = "queued"
        completedBytes = 0
        totalBytes = 0
        message = nil
        installed = nil
        addedToLibrary = false
        self.reuseDirectory = reuseDirectory
    }

    static func accountKey(_ account: String) -> String {
        account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var canDownloadAnyway: Bool {
        status == .failed && ["storage-insufficient", "storage-unavailable"].contains(failureCode ?? "")
    }
    var canResume: Bool { [.paused, .failed, .cancelled].contains(status) }
    var isPending: Bool { [.queued, .running, .paused, .failed].contains(status) }
    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct SteamDownloadQueue: Codable, Equatable, Sendable {
    var version = 1
    private(set) var jobs: [SteamDownloadJob] = []
    var isPaused = false

    mutating func rebaseInstalledDirectories(steamGamesRoot: URL, fileManager: FileManager = .default) {
        let marker = "/Library/Application Support/SteamGames/"
        func rebase(_ path: String) -> String {
            let source = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let container = source.range(of: "/Containers/Data/Application/"),
                  let range = source.range(of: marker), container.upperBound < range.lowerBound,
                  !source[container.upperBound..<range.lowerBound].contains("/") else { return path }
            let candidate = steamGamesRoot.appending(path: String(source[range.upperBound...])).standardizedFileURL.path
            guard candidate.hasPrefix(steamGamesRoot.standardizedFileURL.path + "/") else { return path }
            return fileManager.fileExists(atPath: candidate) ? candidate : path
        }
        for index in jobs.indices {
            if var installed = jobs[index].installed {
                installed.directory = rebase(installed.directory)
                jobs[index].installed = installed
            }
            if let reuse = jobs[index].reuseDirectory { jobs[index].reuseDirectory = rebase(reuse) }
        }
    }

    mutating func recoverAfterRelaunch() {
        // A process death is not a clean pause. The native downloader re-hashes
        // partial chunks rather than trusting this possibly stale UI checkpoint.
        for index in jobs.indices where jobs[index].status == .running {
            jobs[index].status = .paused
            jobs[index].phase = "paused"
            jobs[index].message = "Interrupted. Resume to check saved chunks and continue."
        }
        if jobs.contains(where: \.isPending) { isPaused = true }
    }

    @discardableResult
    mutating func enqueue(_ job: SteamDownloadJob) -> Bool {
        guard job.appId != 0, !job.account.isEmpty, jobs.count < 500,
              !jobs.contains(where: { $0.id == job.id || ($0.account == job.account && $0.appId == job.appId && $0.isPending) })
        else { return false }
        jobs.append(job)
        return true
    }

    func next(account: String) -> SteamDownloadJob? {
        guard !isPaused, !jobs.contains(where: { $0.status == .running }) else { return nil }
        return jobs.first { $0.status == .queued && $0.account == SteamDownloadJob.accountKey(account) }
    }

    @discardableResult
    mutating func begin(_ id: UUID) -> Bool {
        guard !isPaused, !jobs.contains(where: { $0.status == .running }),
              let index = jobs.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return false }
        jobs[index].status = .running
        jobs[index].phase = "resolving"
        jobs[index].failureCode = nil
        jobs[index].storage = nil
        jobs[index].message = nil
        return true
    }

    mutating func update(_ id: UUID, _ change: (inout SteamDownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    @discardableResult
    mutating func resume(_ id: UUID, account: String) -> Bool {
        guard let index = jobs.firstIndex(where: {
            $0.id == id && $0.account == SteamDownloadJob.accountKey(account) && $0.canResume
        }), !jobs.contains(where: {
            $0.id != id && $0.appId == jobs[index].appId && $0.account == jobs[index].account && $0.isPending
        }) else { return false }
        jobs[index].status = .queued
        jobs[index].phase = "queued"
        jobs[index].failureCode = nil
        jobs[index].message = nil
        isPaused = false
        return true
    }

    mutating func prioritize(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return }
        jobs.insert(jobs.remove(at: index), at: 0)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard !jobs.contains(where: { $0.id == id && $0.status == .running }) else { return false }
        let count = jobs.count
        jobs.removeAll { $0.id == id }
        return count != jobs.count
    }

    func validated() throws -> Self {
        guard version == 1, jobs.count <= 500, Set(jobs.map(\.id)).count == jobs.count,
              jobs.allSatisfy({ $0.appId > 0 && !$0.account.isEmpty && $0.name.count <= 4096
                  && $0.completedBytes >= 0 && $0.totalBytes >= 0 }) else {
            throw SteamQueueError.invalidDocument
        }
        return self
    }
}

enum SteamQueueError: LocalizedError {
    case invalidDocument
    var errorDescription: String? {
        "The saved download queue could not be read. It has been kept unchanged; no game files were removed."
    }
}

enum SteamManagedFiles {
    static func overlaps(_ first: String, _ second: String) -> Bool {
        let a = URL(fileURLWithPath: first).resolvingSymlinksInPath().standardizedFileURL.path
        let b = URL(fileURLWithPath: second).resolvingSymlinksInPath().standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func delete(_ job: SteamDownloadJob, from root: URL) throws {
        guard job.status == .completed, let installed = job.installed,
              installed.appId == job.appId else { throw CocoaError(.fileReadInvalidFileName) }
        let managedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let content = URL(fileURLWithPath: installed.directory).resolvingSymlinksInPath().standardizedFileURL
        let appRoot = managedRoot.appendingPathComponent(String(job.appId), isDirectory: true)
        let folder = content.deletingLastPathComponent()
        guard content.lastPathComponent == "content",
              content.path.hasPrefix(appRoot.path + "/"),
              folder.path.hasPrefix(appRoot.path + "/"),
              let receipt = try? Data(contentsOf: folder.appendingPathComponent("installed.json")),
              let recorded = try? JSONDecoder().decode(SteamDownloadedGame.self, from: receipt),
              recorded.appId == job.appId else { throw CocoaError(.fileReadInvalidFileName) }
        // The legacy build folder may also own variants and completed repairs.
        // Only this receipt's payload and staging files belong to this install.
        let manager = FileManager.default
        for name in ["content", "partial", "installed.json"] {
            let item = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: item.path) { try manager.removeItem(at: item) }
        }
        if try manager.contentsOfDirectory(atPath: folder.path).isEmpty {
            try manager.removeItem(at: folder)
        }
    }
}

actor SteamQueuePersistence {
    private let url: URL
    private var revision: UInt64 = 0

    init(url: URL) { self.url = url }

    func load() throws -> SteamDownloadQueue {
        guard FileManager.default.fileExists(atPath: url.path) else { return SteamDownloadQueue() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw SteamQueueError.invalidDocument }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024 else { throw SteamQueueError.invalidDocument }
        return try JSONDecoder().decode(SteamDownloadQueue.self, from: data).validated()
    }

    func save(_ queue: SteamDownloadQueue, revision next: UInt64) throws {
        guard next >= revision else { return } // Older async checkpoints must not win.
        _ = try queue.validated()
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(queue)
        guard data.count <= 4 * 1024 * 1024 else { throw SteamQueueError.invalidDocument }
        try data.write(to: url, options: .atomic)
        revision = next
    }
}

struct SteamTransferRate {
    private var sample: (bytes: Int64, time: TimeInterval)?
    private(set) var bytesPerSecond: Double = 0

    mutating func update(networkBytes: Int64, at time: TimeInterval, downloading: Bool) {
        defer { sample = (networkBytes, time) }
        guard downloading, let previous = sample, time > previous.time,
              networkBytes >= previous.bytes else { bytesPerSecond = 0; return }
        let rate = Double(networkBytes - previous.bytes) / (time - previous.time)
        bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.6 + rate * 0.4
    }

    mutating func reset() { sample = nil; bytesPerSecond = 0 }
}
