import Foundation
import IridiumCore
import XCTest

final class ImportSafetyTests: XCTestCase {
    func testFilesFolderImportKeepsGameInPlaceAndRejectsOtherFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gamesRoot = root.appendingPathComponent("Documents/Games")
        let gameFolder = gamesRoot.appendingPathComponent("Test Game")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        let executable = gameFolder.appendingPathComponent("Game.exe")
        try Data("game".utf8).write(to: executable)

        XCTAssertEqual(try ManagedGameFiles.gameFolders(in: gamesRoot).map { $0.resolvingSymlinksInPath() },
                       [gameFolder.resolvingSymlinksInPath()])
        let store = IridiumStore(snapshotURL: root.appendingPathComponent("state.json"))
        let game = try await store.importGame(
            title: "Test Game", installPath: gameFolder.path, executablePath: executable.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "",
            deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
            storage: .filesFolder(gamesRoot)
        )
        XCTAssertEqual(game.installPath, gameFolder.resolvingSymlinksInPath().path)
        XCTAssertEqual(game.launchProfile.executablePath, executable.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Managed/Imports").path))
        do {
            _ = try await store.importGame(
                title: "Test Game", installPath: gameFolder.path, executablePath: executable.path,
                compatibilityProfileName: "generic-broad-catalog", inputProfileName: "",
                deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
                storage: .filesFolder(gamesRoot)
            )
            XCTFail("An existing game was added twice")
        } catch GameImportError.alreadyInLibrary {}

        let outside = root.appendingPathComponent("Other Game")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideExecutable = outside.appendingPathComponent("Other.exe")
        try Data("other".utf8).write(to: outsideExecutable)
        do {
            _ = try await store.importGame(
                title: "Other Game", installPath: outside.path, executablePath: outsideExecutable.path,
                compatibilityProfileName: "generic-broad-catalog", inputProfileName: "",
                deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
                storage: .filesFolder(gamesRoot)
            )
            XCTFail("A folder outside Documents/Games was registered")
        } catch GameImportError.invalidFilesFolder {}
        let registeredGames = await store.allGames()
        XCTAssertEqual(registeredGames.count, 1)
        let otherFolder = gamesRoot.appendingPathComponent("Other Game")
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let otherExecutable = otherFolder.appendingPathComponent("Other.exe")
        try Data("other".utf8).write(to: otherExecutable)
        _ = try await store.importGame(
            title: "Other Game", installPath: otherFolder.path, executablePath: otherExecutable.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "",
            deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
            storage: .filesFolder(gamesRoot)
        )
        do {
            try await store.relocateLibraryEntry(
                gameID: game.id, folder: otherFolder, executable: otherExecutable,
                identifier: "test-game", fingerprint: "other", storage: .filesFolder(gamesRoot)
            )
            XCTFail("Two games now use the same folder")
        } catch GameImportError.alreadyInLibrary {}
        let movedFolder = gamesRoot.appendingPathComponent("Moved Game")
        try FileManager.default.moveItem(at: gameFolder, to: movedFolder)
        let movedExecutable = movedFolder.appendingPathComponent("Game.exe")
        try await store.relocateLibraryEntry(
            gameID: game.id, folder: movedFolder, executable: movedExecutable,
            identifier: "test-game", fingerprint: "game", storage: .filesFolder(gamesRoot)
        )
        let relocatedGames = await store.allGames()
        let relocated = try XCTUnwrap(relocatedGames.first { $0.id == game.id })
        XCTAssertEqual(relocated.id, game.id)
        XCTAssertEqual(relocated.launchProfile.prefixID, game.launchProfile.prefixID)
        XCTAssertEqual(relocated.installPath, movedFolder.resolvingSymlinksInPath().path)
        await store.removeLibraryEntry(gameID: game.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedExecutable.path))
    }

    func testFilesFolderPathRebasesAfterContainerMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gamesRoot = root.appendingPathComponent("Documents/Games")
        let folder = gamesRoot.appendingPathComponent("Test Game")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("Game.exe")
        try Data("game".utf8).write(to: executable)
        let snapshotURL = root.appendingPathComponent("state.json")
        let store = IridiumStore(snapshotURL: snapshotURL)
        _ = try await store.importGame(
            title: "Test Game", installPath: folder.path, executablePath: executable.path,
            compatibilityProfileName: "generic-broad-catalog", inputProfileName: "",
            deviceTier: .tier1, rendererPreset: .metalOpenGLFallback,
            storage: .filesFolder(gamesRoot)
        )
        var snapshot = try JSONDecoder().decode(IridiumSnapshot.self, from: Data(contentsOf: snapshotURL))
        let oldFolder = "/var/mobile/Containers/Data/Application/OLD-CONTAINER/Documents/Games/Test Game"
        snapshot.games[0].installPath = oldFolder
        snapshot.games[0].launchProfile.executablePath = oldFolder + "/Game.exe"
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)

        let restored = IridiumStore(snapshotURL: snapshotURL)
        let restoredGames = await restored.allGames()
        let game = try XCTUnwrap(restoredGames.first)
        let currentDocuments = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        XCTAssertEqual(game.installPath, currentDocuments.appendingPathComponent("Games/Test Game").path)
        XCTAssertEqual(game.launchProfile.executablePath, currentDocuments.appendingPathComponent("Games/Test Game/Game.exe").path)
    }

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
