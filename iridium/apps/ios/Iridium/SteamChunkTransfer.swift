import Foundation

// The request exists only during a private ABI handoff. Persisted metadata below
// deliberately has no URL, headers, account name, token, depot key, or game path.
struct SteamChunkBatch: Decodable, Sendable {
    struct Request: Decodable, Sendable {
        let id: String
        let url: String
        let expectedBytes: Int64
    }
    let operationId: String
    let batchId: String
    let connections: Int
    let requests: [Request]

    func validated() throws -> Self {
        guard UUID(uuidString: operationId) != nil, UUID(uuidString: batchId) != nil,
              (1...8).contains(connections), !requests.isEmpty, requests.count <= 128,
              Set(requests.map(\.id)).count == requests.count else { throw SteamChunkError.invalid }
        var bytes: Int64 = 0
        for request in requests {
            guard SteamChunkJournal.validID(request.id), (1...16 * 1024 * 1024).contains(request.expectedBytes),
                  let url = URLComponents(string: request.url), url.scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.fragment == nil,
                  request.url.utf8.count <= 8192 else { throw SteamChunkError.invalid }
            let parts = request.id.split(separator: "-")
            guard url.path == "/depot/\(parts[0])/chunk/\(parts[1])" else { throw SteamChunkError.invalid }
            bytes += request.expectedBytes
        }
        guard bytes <= 128 * 1024 * 1024 else { throw SteamChunkError.invalid }
        return self
    }
}

enum SteamChunkError: Error { case invalid, unavailable }

// The production model uses this decision after enqueueing a batch during a
// resident wake. Cached completions need native acknowledgement while that
// wake is still alive; only pending daemon work can provide a future wake.
@MainActor
enum SteamChunkWakeHandoff {
    static func settle(session: SteamBackgroundSession, operation: String, batch: String,
                       acknowledge: (String) async throws -> Void, pending: () -> Void) async throws {
        if let code = await session.result(operation: operation, batch: batch) {
            try await acknowledge(code)
        } else {
            pending()
        }
    }
}

struct SteamChunkJournal: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case scheduled, ready, failed, cancelled }
    struct Record: Codable, Equatable, Sendable {
        let id: String
        let expectedBytes: Int64
        var taskIdentifier: Int?
        var state: State
        var code: String
    }
    var version = 1
    let operationId: String
    let batchId: String
    var records: [Record]

    static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && UInt32(parts[0]).map { $0 > 0 && String($0) == parts[0] } == true
            && parts[1].count == 40 && parts[1].allSatisfy { "0123456789abcdef".contains($0) }
    }

    func validated() throws -> Self {
        guard version == 1, UUID(uuidString: operationId) != nil, UUID(uuidString: batchId) != nil,
              !records.isEmpty, records.count <= 128, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ Self.validID($0.id) && (1...16 * 1024 * 1024).contains($0.expectedBytes)
                  && ["ok", "forbidden", "network", "invalid", "io", "disk-full", "cancelled"].contains($0.code)
                  && ($0.taskIdentifier == nil || $0.taskIdentifier! >= 0)
                  && (($0.state == .scheduled && $0.taskIdentifier != nil && $0.code == "ok")
                      || ($0.state == .ready && $0.code == "ok")
                      || ($0.state == .failed && $0.code != "ok")
                      || ($0.state == .cancelled && $0.code == "cancelled")) }),
              records.reduce(0, { $0 + $1.expectedBytes }) <= 128 * 1024 * 1024 else { throw SteamChunkError.invalid }
        return self
    }

    var resultCode: String? {
        if let failure = records.first(where: { $0.state == .failed || $0.state == .cancelled }) { return failure.code }
        return records.allSatisfy { $0.state == .ready } ? "ok" : nil
    }

    mutating func recoverAfterRelaunch() {
        for index in records.indices where records[index].state == .scheduled {
            records[index].state = .cancelled
            records[index].code = "cancelled"
        }
    }

    func callbackIndex(batch: String, id: String, task: Int) -> Int? {
        guard batch == batchId else { return nil }
        return records.firstIndex { $0.id == id && $0.taskIdentifier == task && $0.state == .scheduled }
    }
}

enum SteamChunkResponsePolicy {
    static func accepts(original: URL?, response: HTTPURLResponse, expectedBytes: Int64) -> Bool {
        guard let original, let final = response.url, response.statusCode == 200,
              let endpoint = URLComponents(url: final, resolvingAgainstBaseURL: false),
              endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              final.absoluteString.utf8.count <= 8192,
              final.scheme == "https", original.scheme == "https", final.host == original.host,
              (final.port ?? 443) == (original.port ?? 443), final.path == original.path,
              response.expectedContentLength == -1 || response.expectedContentLength == expectedBytes else { return false }
        return true
    }
}

// These files are disposable encrypted HTTP payloads. A ready record is not
// evidence of verified game content; SteamKit + VerifiedFiles must check it.
struct SteamRawChunkStore: Sendable {
    let root: URL

    func path(operation: String, id: String) throws -> URL {
        guard let operation = UUID(uuidString: operation), SteamChunkJournal.validID(id) else { throw SteamChunkError.invalid }
        return try safePath([operation.uuidString.lowercased(), id + ".raw"])
    }

    func safePath(_ components: [String]) throws -> URL {
        var current = root
        try rejectLink(current)
        for component in components {
            guard !component.isEmpty, ![".", ".."].contains(component), !component.contains("/"), !component.contains("\\")
            else { throw SteamChunkError.invalid }
            current.appendPathComponent(component)
            try rejectLink(current)
        }
        return current
    }

    private func rejectLink(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw SteamChunkError.invalid }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
    }

    func load() throws -> SteamChunkJournal? {
        let url = try safePath(["journal.json"])
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try size(url) <= 64 * 1024 else { throw SteamChunkError.invalid }
        return try JSONDecoder().decode(SteamChunkJournal.self, from: Data(contentsOf: url)).validated()
    }

    func save(_ journal: SteamChunkJournal) throws {
        _ = try journal.validated()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: safePath(["journal.json"]), options: .atomic)
    }

    func accept(_ location: URL, operation: String, record: SteamChunkJournal.Record) throws {
        guard try size(location) == record.expectedBytes else {
            throw SteamChunkError.invalid
        }
        let destination = try path(operation: operation, id: record.id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Replacement is limited to this generated raw chunk, never an install.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: location, to: destination)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #endif
    }

    func hasRaw(operation: String, record: SteamChunkJournal.Record) throws -> Bool {
        let url = try path(operation: operation, id: record.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try size(url) == record.expectedBytes
    }

    private func size(_ url: URL) throws -> Int64 {
        // URL.resourceValues can cache a previous file length. These acceptance
        // checks require a fresh filesystem read and a regular file.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber else { throw SteamChunkError.invalid }
        return bytes.int64Value
    }

    // A crash can leave raw files outside the most recent journal. Replanning
    // keeps only this batch's generated payloads, including reusable raw files.
    // Unexpected files or links block cleanup instead of widening its scope.
    func prune(operation: String, keeping ids: Set<String>) throws {
        guard let operation = UUID(uuidString: operation), ids.allSatisfy(SteamChunkJournal.validID) else {
            throw SteamChunkError.invalid
        }
        let directory = try safePath([operation.uuidString.lowercased()])
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory
        else { throw SteamChunkError.invalid }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var disposable: [URL] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".raw"), SteamChunkJournal.validID(String(name.dropLast(4))) else { throw SteamChunkError.invalid }
            let id = String(name.dropLast(4))
            let checked = try path(operation: operation.uuidString, id: id)
            _ = try size(checked)
            if !ids.contains(id) { disposable.append(checked) }
        }
        for file in disposable { try FileManager.default.removeItem(at: file) }
        if ids.isEmpty { try FileManager.default.removeItem(at: directory) }
    }

    func remove(_ journal: SteamChunkJournal) throws {
        try prune(operation: journal.operationId, keeping: [])
        let url = try safePath(["journal.json"])
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
