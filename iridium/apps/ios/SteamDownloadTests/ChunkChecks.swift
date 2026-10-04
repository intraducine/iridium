import Foundation

enum SteamChunkChecks {
    @MainActor
    static func run() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "ChunkChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        func reject(_ operation: () throws -> Void) throws {
            do { try operation() } catch { checks += 1; return }
            try check(false, "Unsafe transfer fixture was accepted")
        }
        let operation = UUID().uuidString
        let batchId = UUID().uuidString
        let id = "10-" + String(repeating: "a", count: 40)
        let url = "https://fixture.invalid/depot/10/chunk/" + String(repeating: "a", count: 40)
        let request = SteamChunkBatch.Request(id: id, url: url + "?auth=synthetic-secret", expectedBytes: 8)
        let batch = SteamChunkBatch(operationId: operation, batchId: batchId, connections: 4, requests: [request])
        _ = try batch.validated()
        checks += 1
        for candidate in [url.replacingOccurrences(of: "https:", with: "http:"),
                          url.replacingOccurrences(of: "fixture.invalid", with: "name:secret@fixture.invalid"), url + "#fragment",
                          url.replacingOccurrences(of: "/depot/10", with: "/depot/11")] {
            try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 4,
                requests: [.init(id: id, url: candidate, expectedBytes: 8)]).validated() }
        }
        for size: Int64 in [0, -1, 16 * 1024 * 1024 + 1] {
            try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 4,
                requests: [.init(id: id, url: url, expectedBytes: size)]).validated() }
        }
        try reject { _ = try SteamChunkBatch(operationId: "../other", batchId: batchId, connections: 4, requests: [request]).validated() }
        try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 9, requests: [request]).validated() }
        try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 4, requests: [request, request]).validated() }
        var bounded: [SteamChunkBatch.Request] = []
        for n in 1...129 {
            let identity = "\(n)-" + String(repeating: "a", count: 40)
            bounded.append(.init(id: identity, url: "https://fixture.invalid/depot/\(n)/chunk/" + String(repeating: "a", count: 40), expectedBytes: 1))
        }
        _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 8, requests: Array(bounded.prefix(128))).validated()
        checks += 1
        try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 8, requests: bounded).validated() }
        let large = Array(bounded.prefix(9)).map { SteamChunkBatch.Request(id: $0.id, url: $0.url, expectedBytes: 16 * 1024 * 1024) }
        _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 8, requests: Array(large.prefix(8))).validated()
        checks += 1
        try reject { _ = try SteamChunkBatch(operationId: operation, batchId: batchId, connections: 8, requests: large).validated() }

        var journal = SteamChunkJournal(operationId: operation, batchId: batchId, records: [
            .init(id: id, expectedBytes: 8, taskIdentifier: 17, state: .scheduled, code: "ok")])
        try check(journal.callbackIndex(batch: batchId, id: id, task: 17) == 0, "Correlated callback")
        try check(journal.callbackIndex(batch: UUID().uuidString, id: id, task: 17) == nil, "Old batch cannot write new operation")
        try check(journal.callbackIndex(batch: batchId, id: id, task: 18) == nil, "Stale task cannot overwrite raw file")
        journal.recoverAfterRelaunch()
        try check(journal.callbackIndex(batch: batchId, id: id, task: 17) == nil && journal.resultCode == "cancelled", "Late completion after cancel is ignored")
        let encoded = try JSONEncoder().encode(journal)
        let text = String(decoding: encoded, as: UTF8.self)
        try check(!text.contains("auth") && !text.contains("synthetic-secret") && !text.contains("fixture.invalid"), "No credentials or URL in durable journal")

        let original = URL(string: url)!
        func response(_ final: String, _ status: Int = 200, _ length: String? = "8") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: final)!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: length.map { ["Content-Length": $0] } ?? [:])!
        }
        try check(SteamChunkResponsePolicy.accepts(original: original, response: response(url), expectedBytes: 8), "Exact HTTP response accepted")
        try check(SteamChunkResponsePolicy.accepts(original: original, response: response(url, 200, nil), expectedBytes: 8), "Absent header still requires exact raw file length")
        for invalid in [response(url, 403), response(url, 206), response(url, 200, "9"),
                        response(url.replacingOccurrences(of: "fixture.invalid", with: "other.invalid")),
                        response(url.replacingOccurrences(of: "https:", with: "http:")), response(url + "/other"),
                        response(url + "#fragment"), response(url.replacingOccurrences(of: "fixture.invalid", with: "user@fixture.invalid")),
                        response(url.replacingOccurrences(of: "fixture.invalid", with: "fixture.invalid:444")),
                        response(url + "?x=" + String(repeating: "x", count: 8192))] {
            try check(!SteamChunkResponsePolicy.accepts(original: original, response: invalid, expectedBytes: 8), "Redirect/status/length cannot promote raw content")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("steam-chunk-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SteamRawChunkStore(root: root.appendingPathComponent("raw"))
        try store.save(journal)
        try check(try store.load() == journal, "Journal round trip")
        let record = journal.records[0]
        let temporary = root.appendingPathComponent("http-response")
        try Data("12345678".utf8).write(to: temporary)
        try store.accept(temporary, operation: operation, record: record)
        try check(!FileManager.default.fileExists(atPath: temporary.path) && (try store.hasRaw(operation: operation, record: record)), "Delegate file is preserved before returning")
        for bytes in [Data("short".utf8), Data("oversized".utf8)] {
            try bytes.write(to: temporary)
            try reject { try store.accept(temporary, operation: operation, record: record) }
            try check(try Data(contentsOf: store.path(operation: operation, id: id)) == Data("12345678".utf8), "Invalid raw length preserves previous payload")
        }
        let alias = store.root.appendingPathComponent(UUID(uuidString: operation)!.uuidString.lowercased())
        let orphanID = "11-" + String(repeating: "b", count: 40)
        let orphan = try store.path(operation: operation, id: orphanID)
        try Data("orphan".utf8).write(to: orphan)
        try store.prune(operation: operation, keeping: [id])
        try check(!FileManager.default.fileExists(atPath: orphan.path)
            && (try store.hasRaw(operation: operation, record: record)), "Replan removes orphan raw files while retaining the current batch")
        let unexpected = orphan.deletingLastPathComponent().appendingPathComponent("unowned.txt")
        try Data("unowned".utf8).write(to: unexpected)
        try reject { try store.prune(operation: operation, keeping: []) }
        try check(FileManager.default.fileExists(atPath: unexpected.path)
            && (try store.hasRaw(operation: operation, record: record)), "Unexpected spool entries block cleanup without deleting files")
        try FileManager.default.removeItem(at: unexpected)
        try FileManager.default.createSymbolicLink(at: orphan, withDestinationURL: temporary)
        try reject { try store.prune(operation: operation, keeping: []) }
        try FileManager.default.removeItem(at: orphan)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try reject { _ = try store.path(operation: operation, id: id) }
        try FileManager.default.removeItem(at: alias)
        try Data("corrupt".utf8).write(to: store.safePath(["journal.json"]))
        try reject { _ = try store.load() }
        try check(try Data(contentsOf: store.safePath(["journal.json"])) == Data("corrupt".utf8), "Corrupt journal is retained")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)
        try store.remove(journal)
        try check(!FileManager.default.fileExists(atPath: alias.path), "Discard removes the complete generated operation spool")

        #if IRIDIUM_STEAM_TESTS
        let session = SteamBackgroundSession(fixtureStore: store, protocolClass: SteamHTTPFixture.self)
        try await session.enqueue(batch)
        var result: String?
        for _ in 0..<200 {
            result = await session.result(operation: operation, batch: batchId)
            if result != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(result == "ok", "URLSession delegate pipeline preserved fixture HTTP payload")
        await session.cancel(operation: UUID().uuidString)
        try check(await session.result(operation: operation, batch: batchId) == "ok", "Stale operation cancellation cannot stop the current batch")
        try check(await session.networkBytes(operation: operation) == 8, "OS observed bytes count once")
        let second = SteamChunkBatch(operationId: operation, batchId: UUID().uuidString, connections: 4, requests: [request])
        try await session.enqueue(second)
        try check(await session.result(operation: operation, batch: second.batchId) == "ok", "Untrusted raw cache is reusable after replan")
        try check(await session.networkBytes(operation: operation) == 8, "Raw cache reuse never invents network bytes")
        try check(try store.load()?.records.allSatisfy { $0.state == .ready && $0.taskIdentifier == nil } == true,
            "All-cached wake batch creates no daemon tasks")
        var acknowledgements: [String] = []
        var releasedWake = false
        try await SteamChunkWakeHandoff.settle(session: session, operation: operation, batch: second.batchId,
            acknowledge: { acknowledgements.append($0) }, pending: { releasedWake = true })
        try check(acknowledgements == ["ok"] && !releasedWake,
            "Production wake handoff acknowledges cached batch without relinquishing its runtime budget")
        let third = SteamChunkBatch(operationId: operation, batchId: UUID().uuidString, connections: 4, requests: [request])
        try await session.enqueue(third)
        try await SteamChunkWakeHandoff.settle(session: session, operation: operation, batch: third.batchId,
            acknowledge: { acknowledgements.append($0) }, pending: { releasedWake = true })
        try check(acknowledgements == ["ok", "ok"] && !releasedWake,
            "A resident wake can continue across multiple cached batches within the unchanged budget")
        await session.cancel(operation: operation, discardRaw: true)
        let heldStore = SteamRawChunkStore(root: root.appendingPathComponent("pending-raw"))
        let heldSession = SteamBackgroundSession(fixtureStore: heldStore, protocolClass: SteamHTTPHeldFixture.self)
        try await heldSession.enqueue(batch)
        try await SteamChunkWakeHandoff.settle(session: heldSession, operation: operation, batch: batchId,
            acknowledge: { acknowledgements.append($0) }, pending: { releasedWake = true })
        try check(releasedWake && acknowledgements == ["ok", "ok"],
            "Production wake handoff relinquishes only when daemon work is pending")
        await heldSession.cancel(operation: operation, discardRaw: true)
        #endif
        return checks
    }
}

#if IRIDIUM_STEAM_TESTS
final class SteamHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("12345678".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class SteamHTTPHeldFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { } // Deterministic pending task; no external network.
    override func stopLoading() { }
}
#endif
