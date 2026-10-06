import Foundation

// All mutable state and delegate calls use the serial queue. The background
// daemon owns only HTTP; callbacks preserve raw files and finish promptly.
final class SteamBackgroundSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = SteamBackgroundSession()
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "software.iridium") + ".steam-chunks" }
    private let queue = DispatchQueue(label: "software.iridium.steam-chunks", qos: .utility)
    private var session: URLSession?
    private var store: SteamRawChunkStore?
    private var journal: SteamChunkJournal?
    private var completion: (@Sendable () -> Void)?
    private var persistenceFailure: String?
    private var observedBytes: Int64 = 0
    private var receivedByTask: [Int: Int64] = [:]
    #if IRIDIUM_STEAM_TESTS
    private var fixtureStore: SteamRawChunkStore?
    private var fixtureProtocol: URLProtocol.Type?

    init(fixtureStore: SteamRawChunkStore, protocolClass: URLProtocol.Type) {
        self.fixtureStore = fixtureStore
        self.fixtureProtocol = protocolClass
        super.init()
    }
    #endif

    private override init() { super.init() }

    private func makeStore() throws -> SteamRawChunkStore {
        #if IRIDIUM_STEAM_TESTS
        if let fixtureStore { return fixtureStore }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).resolvingSymlinksInPath()
        let games = support.appendingPathComponent("SteamGames", isDirectory: true)
        let anchor = SteamRawChunkStore(root: games)
        let root = try anchor.safePath([".background-chunks"])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = root
        try excluded.setResourceValues(values)
        return SteamRawChunkStore(root: root)
    }

    private func connect(connections: Int = 4) throws {
        if session != nil { return }
        let storage = try makeStore()
        journal = try storage.load() // Corruption is retained, never silently reset.
        store = storage
        var configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        #if IRIDIUM_STEAM_TESTS
        if let fixtureProtocol {
            configuration = .ephemeral
            configuration.protocolClasses = [fixtureProtocol]
        }
        #endif
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false // Explicit foreground user request.
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpMaximumConnectionsPerHost = connections
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegates)
    }

    func enqueue(_ batch: SteamChunkBatch) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var created: [URLSessionDownloadTask] = []
                do {
                    _ = try batch.validated()
                    try connect(connections: batch.connections)
                    guard let session, let store, persistenceFailure == nil else { throw SteamChunkError.unavailable }
                    guard journal?.resultCode != nil || journal == nil else { throw SteamChunkError.invalid }
                    if let old = journal, old.operationId != batch.operationId {
                        try store.remove(old) // Only disposable raw data; verified partials are elsewhere.
                        observedBytes = 0
                    }
                    try store.prune(operation: batch.operationId, keeping: Set(batch.requests.map(\.id)))
                    receivedByTask = [:]
                    var next = SteamChunkJournal(operationId: batch.operationId, batchId: batch.batchId, records: [])
                    for request in batch.requests {
                        var record = SteamChunkJournal.Record(id: request.id, expectedBytes: request.expectedBytes,
                            taskIdentifier: nil, state: .scheduled, code: "ok")
                        if try store.hasRaw(operation: batch.operationId, record: record) {
                            record.state = .ready // Untrusted until native decrypt/hash/assembly.
                        } else {
                            var http = URLRequest(url: URL(string: request.url)!)
                            http.httpMethod = "GET"
                            http.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                            let task = session.downloadTask(with: http)
                            task.taskDescription = batch.batchId + "/" + request.id
                            task.countOfBytesClientExpectsToReceive = request.expectedBytes
                            record.taskIdentifier = task.taskIdentifier
                            created.append(task)
                        }
                        next.records.append(record)
                    }
                    // Crash before this save: tasks are still suspended. Crash after
                    // the save: reconciliation cancels or rediscovers those tasks.
                    try store.save(next)
                    journal = next
                    for task in created { task.resume() }
                    continuation.resume()
                } catch {
                    for task in created { task.cancel() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func result(operation: String, batch: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard journal?.operationId == operation, journal?.batchId == batch else {
                    continuation.resume(returning: "invalid"); return
                }
                continuation.resume(returning: persistenceFailure ?? journal?.resultCode)
            }
        }
    }

    func networkBytes(operation: String) async -> Int64 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: journal?.operationId == operation ? observedBytes : 0) }
        }
    }

    func cancel(operation: String? = nil, discardRaw: Bool = false) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var descriptions: Set<String>?
                do {
                    try connect()
                    if let operation, journal?.operationId != operation { continuation.resume(); return }
                    if var current = journal, operation == nil || current.operationId == operation {
                        descriptions = Set(current.records.map { current.batchId + "/" + $0.id })
                        current.recoverAfterRelaunch()
                        try store?.save(current)
                        journal = current
                        if discardRaw { try store?.remove(current); journal = nil }
                    }
                } catch { persistenceFailure = Self.failureCode(error) }
                let cancelledDescriptions = descriptions ?? journal.map { current in Set(current.records.map { current.batchId + "/" + $0.id }) }
                session?.getAllTasks { tasks in
                    for task in tasks where operation == nil || cancelledDescriptions?.contains(task.taskDescription ?? "") == true { task.cancel() }
                    continuation.resume()
                }
                if session == nil { continuation.resume() }
            }
        }
    }

    // A new process resumes through its persisted queue and owning Steam account.
    // Finished raw payloads survive; unfinished daemon tasks are explicitly stopped.
    func recoverAfterRelaunch() async { await cancel() }

    func handleEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
        guard identifier == Self.identifier else { DispatchQueue.main.async(execute: completion); return }
        queue.async { [self] in
            self.completion = completion
            do { try connect() }
            catch {
                persistenceFailure = Self.failureCode(error)
                self.completion = nil
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let callback = completion
        completion = nil
        if let callback { DispatchQueue.main.async(execute: callback) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // System TLS trust validation remains intact. This transport never sends
        // an account password, client certificate, or ambient HTTP credential.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    private func index(_ task: URLSessionTask) -> Int? {
        guard let current = journal, let description = task.taskDescription,
              description.split(separator: "/").count == 2 else { return nil }
        let parts = description.split(separator: "/")
        return current.callbackIndex(batch: String(parts[0]), id: String(parts[1]), task: task.taskIdentifier)
    }

    private func update(_ index: Int, state: SteamChunkJournal.State, code: String) {
        journal?.records[index].state = state
        journal?.records[index].code = code
        do { if let journal { try store?.save(journal) } }
        catch { persistenceFailure = Self.failureCode(error) }
        if state == .failed {
            let descriptions = journal.map { current in Set(current.records.map { current.batchId + "/" + $0.id }) } ?? []
            session?.getAllTasks { tasks in
                for task in tasks where descriptions.contains(task.taskDescription ?? "") { task.cancel() }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = index(downloadTask), let current = journal, let store else { return }
        recordNetworkBytes(downloadTask.taskIdentifier, total: downloadTask.countOfBytesReceived)
        guard let response = downloadTask.response as? HTTPURLResponse,
              SteamChunkResponsePolicy.accepts(original: downloadTask.originalRequest?.url, response: response,
                  expectedBytes: current.records[index].expectedBytes) else {
            update(index, state: .failed, code: (downloadTask.response as? HTTPURLResponse)?.statusCode == 403 ? "forbidden" : "network")
            return
        }
        do {
            try store.accept(location, operation: current.operationId, record: current.records[index])
            update(index, state: .ready, code: "ok")
        } catch { update(index, state: .failed, code: Self.failureCode(error)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = index(downloadTask), let current = journal else { return }
        recordNetworkBytes(downloadTask.taskIdentifier, total: totalBytesWritten)
        if totalBytesWritten > current.records[index].expectedBytes
            || (totalBytesExpectedToWrite >= 0 && totalBytesExpectedToWrite != current.records[index].expectedBytes) {
            update(index, state: .failed, code: "invalid")
            downloadTask.cancel()
        }
    }

    private func recordNetworkBytes(_ task: Int, total: Int64) {
        let previous = receivedByTask[task] ?? 0
        if total > previous {
            observedBytes += total - previous
            receivedByTask[task] = total
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A nil error without a preserved file is not success.
        guard let index = index(task) else { return }
        update(index, state: .failed, code: error.map(Self.failureCode) ?? "invalid")
    }

    static func failureCode(_ error: Error) -> String {
        if error is SteamChunkError { return "invalid" }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSFileWriteOutOfSpaceError { return "disk-full" }
            return "io"
        }
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return "cancelled" }
        return "network"
    }
}
