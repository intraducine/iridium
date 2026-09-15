import Foundation
import IridiumCore
import XCTest

final class ImportSafetyTests: XCTestCase {
    func testReimportPreservesTheOldCopyAndGameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("Game.exe")
        try Data("v1".utf8).write(to: exe)
        let store = IridiumStore(snapshotURL: root.appendingPathComponent("state.json"))
        let first = try await store.importGame(title: "Game", installPath: source.path, executablePath: exe.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "", deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback)
        let save = URL(fileURLWithPath: first.installPath).appendingPathComponent("save.dat")
        try Data("progress".utf8).write(to: save)
        try Data("v2".utf8).write(to: exe)
        let second = try await store.importGame(title: "Game", installPath: source.path, executablePath: exe.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "", deviceTier: .tier1,
            rendererPreset: .metalOpenGLFallback)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.launchProfile.prefixID, first.launchProfile.prefixID)
        XCTAssertNotEqual(second.installPath, first.installPath)
        XCTAssertEqual(try Data(contentsOf: save), Data("progress".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.launchProfile.executablePath)), Data("v1".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.launchProfile.executablePath)), Data("v2".utf8))
        do {
            _ = try await store.importGame(title: "Game", installPath: source.path,
                executablePath: source.appendingPathComponent("Missing.exe").path,
                compatibilityProfileName: "generic-broad-catalog", inputProfileName: "", deviceTier: .tier1,
                rendererPreset: .metalOpenGLFallback)
            XCTFail("Missing executable was registered")
        } catch {}
        let games = await store.allGames()
        XCTAssertEqual(games.map(\.id), [second.id])
        XCTAssertEqual(games.first?.installPath, second.installPath)
        XCTAssertEqual(games.first?.installedSizeGB, 2.0 / 1_000_000_000)
        let storage = await store.managedStorageStatus()
        XCTAssertNotNil(storage.measuredAvailableGB)
        XCTAssertLessThanOrEqual(storage.availableInstallHeadroomGB, storage.measuredAvailableGB ?? 0)
    }
}
