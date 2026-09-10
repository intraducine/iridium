import XCTest
import UIKit
@testable import LibraryPreview

final class ArtworkTests: XCTestCase {
    @MainActor func testMenuInputSampling() {
        let controller = LibraryController()
        var events: [LibraryController.Input] = []
        let subscription = controller.input.sink { events.append($0) }
        defer { subscription.cancel() }
        controller.process(pressed: [], stickX: 0.15, now: 0)
        XCTAssertTrue(events.isEmpty)
        controller.process(pressed: [], stickX: 0.8, stickY: 0.7, now: 1)
        controller.process(pressed: [], stickX: 0.8, stickY: 0.7, now: 1.2)
        XCTAssertEqual(events, [.right])
        controller.process(pressed: [], stickX: 0.8, now: 1.41)
        XCTAssertEqual(events, [.right, .right])
        controller.process(pressed: [], now: 1.5)
        controller.process(pressed: [6], now: 2)
        controller.process(pressed: [6], now: 3)
        XCTAssertEqual(events, [.right, .right, .play])
        controller.process(pressed: [], now: 4)
        controller.process(pressed: [8], now: 5)
        controller.process(pressed: [9], now: 6)
        controller.process(pressed: [10], now: 7)
        XCTAssertEqual(Array(events.suffix(3)), [.previousTab, .nextTab, .options])
        controller.process(pressed: [0], stickX: 0.9, now: 8)
        XCTAssertEqual(events.last, .left)
    }

    @MainActor func testTopmostMenuOwnsInput() {
        let controller = LibraryController()
        let parent = UUID(), child = UUID()
        var received: [String] = []
        let subscription = controller.input.sink { _ in received.append("library") }
        defer { subscription.cancel() }
        controller.pushMenu(id: parent) { _ in received.append("parent") }
        controller.pushMenu(id: child) { _ in received.append("child") }
        controller.send(.select)
        controller.send(.back)
        XCTAssertEqual(received, ["child", "child"])
        controller.popMenu(id: child)
        controller.send(.down)
        XCTAssertEqual(received.last, "parent")
        controller.popMenu(id: parent)
        controller.send(.select)
        XCTAssertEqual(received.last, "library")
        XCTAssertFalse(controller.hasMenuScope)
        let count = received.count
        controller.nativeMenuActive = true
        controller.send(.select)
        XCTAssertEqual(received.count, count)
        controller.nativeMenuActive = false
        controller.send(.select)
        XCTAssertEqual(received.count, count + 1)
    }

    @MainActor func testCustomAppearanceAndRemovalSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryArtwork(root: root)
        let id = UUID()
        try store.update(id) { $0.title = "My unreleased game"; $0.matchID = 42; $0.matchName = "Incorrect match"; $0.favorite = true }
        let data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try store.setImage(data, id: id, background: false)
        try store.setImage(data, id: id, background: true)
        let before = store.appearance(id)
        try store.removeMatch(id)
        let reopened = LibraryArtwork(root: root)
        let item = reopened.appearance(id)
        XCTAssertEqual(item.title, "My unreleased game")
        XCTAssertNil(item.matchID)
        XCTAssertFalse(item.automaticLookup)
        XCTAssertTrue(item.favorite)
        XCTAssertTrue(item.customCover && item.customBackground)
        XCTAssertEqual(item.cover, before.cover)
        XCTAssertEqual(item.background, before.background)
        XCTAssertNotNil(reopened.image(item.cover))
        XCTAssertNotNil(reopened.image(item.background))
        XCTAssertThrowsError(try reopened.setImage(Data("not an image".utf8), id: id, background: false))
        XCTAssertEqual(reopened.appearance(id), item)
        XCTAssertNil(reopened.image("../library.json"))
    }
    @MainActor func testCorruptMetadataIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("library.json")
        let original = Data("broken JSON".utf8)
        try original.write(to: file)
        let store = LibraryArtwork(root: root)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.update(UUID()) { $0.title = "do not replace" })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor func testQueriesDoNotSendParentPaths() {
        XCTAssertEqual(LibraryArtwork.query("C:\\Users\\someone\\Games\\Custom_Game.exe"), "Custom Game")
        XCTAssertEqual(LibraryArtwork.query("/private/user/game/My-Game.exe"), "My Game")
        XCTAssertEqual(LibraryArtwork.normalized("My-Game.exe"), LibraryArtwork.normalized("My Game"))
        XCTAssertLessThanOrEqual(LibraryArtwork.query(String(repeating: "x", count: 1000)).count, 120)
    }

    func testSteamAppIDFromImportedGameMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "AppId=489830\n".write(
            to: root.appendingPathComponent("steam_emu.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LibraryArtwork.steamAppID(root.path), 489830)
        // Windows INI files can have non-UTF-8 banner art and CRLF line endings.
        let windowsINI = Data([0x23, 0x20, 0xDC, 0xDB, 0x0D, 0x0A]) + Data("[Steam]\r\nAppId=489830\r\n".utf8)
        try windowsINI.write(to: root.appendingPathComponent("steam_emu.ini"))
        XCTAssertEqual(LibraryArtwork.steamAppID(root.path), 489830)
    }
}

private final class ArtworkProtocol: URLProtocol {
    static var handler: ((ArtworkProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(_ body: String, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension ArtworkTests {
    @MainActor func testLookupAndInFlightRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); ArtworkProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = LibraryArtwork(root: root, session: session, testCredential: "test-only")
        ArtworkProtocol.handler = { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only")
            XCTAssertFalse(request.request.url!.absoluteString.contains("private"))
            request.respond(#"{"success":true,"data":[{"id":123,"name":"Custom Game"}]}"#)
        }
        let matches = try await store.search("/private/user/Custom_Game.exe")
        XCTAssertEqual(matches, [ArtworkMatch(id: 123, name: "Custom Game")])
        let received = expectation(description: "Lookup has started")
        var pending: ArtworkProtocol?
        ArtworkProtocol.handler = { request in
            if request.request.url!.path.contains("grids/") { pending = request; received.fulfill() }
            else { request.respond(#"{"success":true,"data":[]}"#) }
        }
        let id = UUID()
        let task = Task { try await store.apply(matches[0], to: id) }
        await fulfillment(of: [received], timeout: 3)
        try store.removeMatch(id)
        pending?.respond(#"{"success":true,"data":[]}"#)
        try await task.value
        XCTAssertNil(store.appearance(id).matchID)
        XCTAssertFalse(store.appearance(id).automaticLookup)
        ArtworkProtocol.handler = { $0.respond("{}", status: 401) }
        do { _ = try await store.search("Custom"); XCTFail("An HTTP error must not become an empty success") } catch {}
    }
}

extension ArtworkTests {
    @MainActor func testPublicCatalogNeedsNoCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); ArtworkProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = LibraryArtwork(root: root, session: session, testCredential: "")
        ArtworkProtocol.handler = { request in
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Authorization"))
            if request.request.url?.host?.hasSuffix(".steamstatic.com") == true {
                request.respond("", status: 404)
                return
            }
            XCTAssertEqual(request.request.url?.host, "store.steampowered.com")
            if request.request.url!.path.contains("storesearch") {
                request.respond(#"{"items":[{"id":123,"name":"Custom Game","type":"app"},{"id":456,"name":"Bundle","type":"sub"}]}"#)
            } else {
                request.respond(#"{"123":{"success":true,"data":{"type":"game"}}}"#)
            }
        }
        let matches = try await store.search("Custom Game")
        XCTAssertEqual(matches, [ArtworkMatch(id: 123, name: "Custom Game", source: "steam")])
        let id = UUID()
        try store.update(id) { $0.title = "My name" }
        try await store.apply(matches[0], to: id)
        XCTAssertEqual(store.appearance(id).matchSource, "steam")
        XCTAssertEqual(store.appearance(id).title, "My name")
        try store.removeMatch(id)
        XCTAssertNil(store.appearance(id).matchSource)
    }
}
