// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// UI and secure-store endpoints are inert. All filesystem and admission code is production.
struct LibraryEntry {
    var id: UUID
    var title: String
    var relativePath: String
    var bits: Int
    var desktop: Bool? = nil
    var steamAppID: Int? = nil
}
enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
@MainActor final class LibraryModel {
    static let shared = LibraryModel()
    static let documents = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
    static var drive: URL { documents.appendingPathComponent("wine/drive_c") }
    // PRODUCTION_EXECUTABLE
    var entries: [LibraryEntry] = []
    var current: UUID?
    var launching = false
    var refuseSave = false
    func save(_ entry: LibraryEntry) { if !refuseSave { entries.append(entry) } }
}
@MainActor final class IridiumConsoleSession {
    static let shared = IridiumConsoleSession()
    var isActive = false, dolphinMaintenance = false
}
@MainActor final class IridiumConsoleLibrary: ObservableObject {
    static let shared = IridiumConsoleLibrary()
    nonisolated static var importExtensions: [String] { IridiumConsoleSystem.all.flatMap(\.extensions) }
    var working = false
    @Published var games: [IridiumConsoleGame] = []
    nonisolated static var importContentTypes: [UTType] { importExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) } }
    let store = IridiumConsoleStore(root: LibraryModel.documents.appendingPathComponent("IridiumRuntimes"),
        gamesRoot: LibraryModel.documents.appendingPathComponent("Games"))
    func reload() { }
}
@MainActor final class JITCoordinator {
    static let shared = JITCoordinator()
    var busy = false
    func refreshPairingStatus() { }
}
@MainActor final class OnDevicePairing {
    static let shared = OnDevicePairing()
    var active = false
}
@MainActor final class SteamOwnedLibrary {
    static let shared = SteamOwnedLibrary()
    struct Download { enum State { case active, paused }; let state: State }
    var downloads: [Int: Download] = [:]
    func resumeDownloadsAfterImport() { }
}
@MainActor final class SteamGamesModel {
    static let shared = SteamGamesModel()
    func refresh() { }
}
enum JITPairingSource { case imported }
@MainActor enum JITPairingFileStore {
    static var saved: [Data] = []
    static var refuse = false
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !refuse, (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else { throw CocoaError(.fileWriteUnknown) }
        saved.append(data)
    }
}

@main @MainActor struct ImportFolderChecks {
    static let fm = FileManager.default
    static func require(_ value: @autoclosure () throws -> Bool, _ text: String) { precondition(try! value(), text) }
    static func rejects(_ operation: () throws -> Void) { do { try operation(); preconditionFailure("Expected rejection") } catch { } }
    static func pe() -> Data {
        var data = Data(repeating: 0, count: 512)
        data[0] = 77; data[1] = 90; data[60] = 128
        data[128] = 80; data[129] = 69; data[132] = 100; data[133] = 134
        data[134] = 1; data[148] = 240; data[150] = 2; data[152] = 11; data[153] = 2
        return data
    }
    static func rom() -> Data {
        var data = Data(repeating: 0, count: 32768)
        let logo: [UInt8] = [0xCE,0xED,0x66,0x66,0xCC,0x0D,0x00,0x0B,0x03,0x73,0x00,0x83,0x00,0x0C,0x00,0x0D,0x00,0x08,0x11,0x1F,0x88,0x89,0x00,0x0E,0xDC,0xCC,0x6E,0xE6,0xDD,0xDD,0xD9,0x99,0xBB,0xBB,0x67,0x63,0x6E,0x0E,0xEC,0xCC,0xDD,0xDC,0x99,0x9F,0xBB,0xB9,0x33,0x3E]
        data.replaceSubrange(0x104..<0x134, with: logo)
        data.replaceSubrange(0x134..<0x13b, with: Data("FIXTURE".utf8))
        data[0x14d] = data[0x134...0x14c].reduce(UInt8(0)) { $0 &- $1 &- 1 }
        return data
    }
    @discardableResult static func put(_ path: String, _ bytes: Data = Data("asset".utf8)) throws -> URL {
        let file = LibraryModel.documents.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        return file
    }
    @MainActor static func settle(_ coordinator: IridiumImportCoordinator) async throws {
        let deadline = Date().addingTimeInterval(20)
        while coordinator.isWorking {
            guard Date() < deadline else { preconditionFailure("Import timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    @MainActor static func main() async throws {
        let docs = LibraryModel.documents
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let storage = IridiumGameStorage(documents: docs)
        let worker = IridiumImportFiles(documents: docs)
        let old = docs.appendingPathComponent("IridiumRuntimes")
        switch CommandLine.arguments[1] {
        case "migration":
            let a = UUID(), b = UUID(), console = UUID()
            let original = "Program Files (x86)/Steam/steamapps/common/Shared Game"
            let exe = try put("wine/drive_c/" + original + "/game.exe", pe())
            let save = try put("IridiumRuntimes/Saves/sameboy/" + console.uuidString + "/save.sav")
            try put("IridiumRuntimes/Games/" + console.uuidString + "/game.gb", rom())
            try await worker.prepare(windows: [(a,original,true),(b,original,true)], consoles: [console], oldConsoleRoot: old)
            let moved = [a,b].sorted { $0.uuidString < $1.uuidString }[0]
            require(fm.fileExists(atPath: exe.path), "Old Wine paths keep working")
            require(try Data(contentsOf: exe) == pe(), "Moved executable unchanged")
            require(try Data(contentsOf: save) == Data("asset".utf8), "Save identity unchanged")
            require(try fm.contentsOfDirectory(atPath: storage.games.path).count == 2, "Shared installs move once")
            require(IridiumGameStorage.windowsRelative(exe, drive: storage.drive) == original + "/game.exe", "Existing logical C path retained")
            require(IridiumGameStorage.windowsRelative(docs.appendingPathComponent("private.exe"), drive: storage.drive) == nil, "Other Documents files refused")
            let link = storage.drive.appendingPathComponent(original)
            require(IridiumGameStorage.movedWindowsFolder(link, drive: storage.drive)?.path == storage.games.appendingPathComponent(moved.uuidString).path, "Only journaled uninstall target")
            try fm.removeItem(at: link)
            try await worker.prepare(windows: [(a,original,true)], consoles: [console], oldConsoleRoot: old)
            require(fm.fileExists(atPath: exe.path), "Interrupted move repairs its alias")
            let unknown = storage.drive.appendingPathComponent("unowned")
            try fm.createSymbolicLink(at: unknown, withDestinationURL: storage.games.appendingPathComponent(moved.uuidString))
            require(IridiumGameStorage.movedWindowsFolder(unknown, drive: storage.drive) == nil, "Unowned alias cannot delete games")
            SteamInstallFiles.delete(appID: 999, folderName: "Shared Game", steamApps: storage.drive.appendingPathComponent("Program Files (x86)/Steam/steamapps"))
            require(!fm.fileExists(atPath: exe.path), "Uninstall removes the recorded installation")
            require(!fm.fileExists(atPath: storage.games.appendingPathComponent(moved.uuidString).path), "Uninstall leaves no orphan game data")
            require(fm.fileExists(atPath: save.path), "Uninstall leaves console saves intact")
        case "installed-content":
            let rawID = UUID(), owner = UUID()
            let raw = IridiumConsoleGame(id: rawID, title: "Raw Game", platform: .gameBoy,
                runtimeID: "sameboy", fileExtension: "gb", importedAt: Date())
            var installed = IridiumConsoleGame(id: UUID(), title: "Installed Game", platform: .nintendo3DS,
                runtimeID: "azahar", fileExtension: "app", importedAt: Date())
            installed.storageOwnerID = owner; installed.installedPath = "sdmc/title/content.app"
            let store = IridiumConsoleLibrary.shared.store
            try store.save([raw, installed])
            try put("IridiumRuntimes/Games/" + rawID.uuidString + "/game.gb", rom())
            var content = Data(repeating: 0, count: 512)
            content.replaceSubrange(0x100..<0x104, with: Data("NCCH".utf8)); content[0x104] = 1
            let executable = try put("IridiumRuntimes/Saves/azahar/" + owner.uuidString + "/Azahar/" + installed.installedPath!, content)
            let save = try put("IridiumRuntimes/Saves/azahar/" + owner.uuidString + "/Azahar/save.bin")
            let titles = [rawID: raw.title, installed.id: installed.title]
            for _ in 0..<2 {
                try await worker.prepare(windows: [], consoles: [rawID, installed.id], oldConsoleRoot: old, titles: titles)
                require(try store.load() == [raw, installed], "Migration retains installed records and owners")
                require(try store.rom(installed) == executable, "Installed content stays in its shared 3DS storage")
                require(try store.validateROM(installed) == executable, "Installed content remains launchable")
                require(try Data(contentsOf: save) == Data("asset".utf8), "Shared 3DS saves stay intact")
                require(try Data(contentsOf: store.validateROM(raw)) == rom(), "Raw ROM uses its named Games folder")
                require(!fm.fileExists(atPath: try storage.gameFolder(installed.id).path), "Installed content does not gain a duplicate ROM folder")
            }
        case "windows-paths":
            let id = UUID()
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            try put("Games/" + id.uuidString + "/game.exe", pe())
            try storage.prepareWindowsLink()
            let path = "iridium-games/" + id.uuidString + "/game.exe"
            require(try LibraryModel.executable(path).path == storage.games.appendingPathComponent(id.uuidString + "/game.exe").path, "Actual Windows preflight permits managed games")
            for bad in ["../../Games/" + id.uuidString + "/game.exe", "/" + path, "iridium-games/../" + path, "iridium-games\\game.exe"] {
                rejects { _ = try LibraryModel.executable(bad) }
            }
            let privateFile = try put("Private/hidden.exe", pe())
            try fm.createSymbolicLink(at: storage.drive.appendingPathComponent("escape.exe"), withDestinationURL: privateFile)
            rejects { _ = try LibraryModel.executable("escape.exe") }
            require(IridiumGameStorage.windowsRelative(storage.drive.appendingPathComponent("iridium-games"), drive: storage.drive) == "iridium-games", "Managed root is browsable")
        case "loose":
            let id = UUID()
            let source = try put("wine/drive_c/standalone.exe", pe())
            let unrelated = try put("wine/drive_c/keep.dat")
            try await worker.prepare(windows: [(id,"standalone.exe",false)], consoles: [], oldConsoleRoot: old)
            require(try Data(contentsOf: source) == pe(), "Loose executable keeps its old C path")
            require(fm.fileExists(atPath: storage.games.appendingPathComponent(id.uuidString + "/standalone.exe").path), "Loose executable has its own game folder")
            require(fm.fileExists(atPath: unrelated.path), "Unrelated C files stay in place")
            try await worker.prepare(windows: [(id,"standalone.exe",false)], consoles: [], oldConsoleRoot: old)
        case "relocation":
            let id = UUID(), original = "Imported/old/game.exe"
            try put("wine/drive_c/" + original, pe())
            try await worker.prepare(windows: [(id,original,false)], consoles: [], oldConsoleRoot: old)
            let restored = docs.deletingLastPathComponent().appendingPathComponent("Restored")
            try fm.moveItem(at: docs, to: restored)
            let movedStorage = IridiumGameStorage(documents: restored)
            try movedStorage.migrateWindows([(id,original,false)])
            require(try Data(contentsOf: movedStorage.drive.appendingPathComponent(original)) == pe(), "Relative Wine aliases survive a container move")
            require(try Data(contentsOf: movedStorage.drive.appendingPathComponent("iridium-games/" + id.uuidString + "/game.exe")) == pe(), "Managed C path survives container move")
        case "receive-safety":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            try put("Import/still.gb", rom())
            try await worker.receive([storage.inbox])
            require(try fm.contentsOfDirectory(atPath: storage.inbox.path) == ["still.gb"], "Selecting Import itself does not recursively copy it")
            do { try await worker.receive([docs]); preconditionFailure("Expected ancestor refusal") } catch { }
            let evil = storage.inbox.appendingPathComponent("link.gb")
            try fm.createSymbolicLink(at: evil, withDestinationURL: storage.inbox.appendingPathComponent("still.gb"))
            do { _ = try await worker.receipt(evil); preconditionFailure("Expected link refusal") } catch { }
            require(fm.fileExists(atPath: storage.inbox.appendingPathComponent("still.gb").path), "Unsafe inputs never delete their target")
        case "pairing-restart":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let first = try await worker.pairingNeedsChoice(count: 2)
            require(first, "Multiple pairings need a choice")
            let restarted = IridiumImportFiles(documents: docs)
            try await restarted.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let second = try await restarted.pairingNeedsChoice(count: 1)
            require(second, "Restart cannot silently replace a selected pairing with the remaining one")
            _ = try await restarted.pairingNeedsChoice(count: 0)
            let fresh = try await restarted.pairingNeedsChoice(count: 1)
            require(!fresh, "A later single-file import can run normally")
        case "conflict":
            let id = UUID()
            try put("wine/drive_c/Imported/old/game.exe", pe())
            try put("Games/" + id.uuidString + "/keep.sav")
            do { try await worker.prepare(windows: [(id,"Imported/old/game.exe",false)], consoles: [], oldConsoleRoot: old); preconditionFailure("Expected conflict") } catch { }
            require(fm.fileExists(atPath: storage.drive.appendingPathComponent("Imported/old/game.exe").path), "Conflicting source kept")
            require(fm.fileExists(atPath: storage.games.appendingPathComponent(id.uuidString + "/keep.sav").path), "Conflicting destination kept")
        case "console-stage":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let file = try put("Import/one.gb", rom())
            let ticket = try await worker.receipt(file)
            try put("Games/.console-import-" + ticket.id.uuidString + "/" + ticket.id.uuidString + "/one.gb", Data("partial".utf8))
            let store = IridiumConsoleLibrary.shared.store
            let game = try await worker.importConsole(file, receipt: ticket, platform: .gameBoy, siblings: [file], store: store)
            require(try Data(contentsOf: store.rom(game)) == rom(), "Interrupted staging is rebuilt before publication")
            require(!fm.fileExists(atPath: storage.games.appendingPathComponent(".console-import-" + ticket.id.uuidString).path), "Staging cleaned after success")
            require(fm.fileExists(atPath: file.path), "Only the caller can consume a durable import")
        case "records":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let file = try put("Import/one.gb", rom())
            let ticket = try await worker.receipt(file)
            let future = Data("{\"version\":2,\"receipts\":{},\"pairingChoice\":false}".utf8)
            let records = docs.appendingPathComponent(".iridium-import-receipts.json")
            try future.write(to: records)
            do { try await worker.choose("test", receipt: ticket); preconditionFailure("Expected changed records refusal") } catch { }
            require(try Data(contentsOf: records) == future, "External future records never overwritten")
            let restarted = IridiumImportFiles(documents: docs)
            do { try await restarted.prepare(windows: [], consoles: [], oldConsoleRoot: old); preconditionFailure("Expected future version refusal") } catch { }
            require(fm.fileExists(atPath: file.path), "Future records keep original game")
        case "receipt":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let file = try put("Import/game.gb", rom())
            let first = try await worker.receipt(file)
            let restarted = IridiumImportFiles(documents: docs)
            try await restarted.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let second = try await restarted.receipt(file)
            require(first.id == second.id, "Restart retains pending import identity")
            try Data("changed".utf8).write(to: file)
            do { try await restarted.consume(file, receipt: second); preconditionFailure("Expected changed source") } catch { }
            require(fm.fileExists(atPath: file.path), "Changed source is never removed")
            let changed = try await restarted.receipt(file)
            require(changed.id != first.id, "Changed inputs get a new identity")
        case "windows-retry":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let exe = try put("Import/PC/bin/game.exe", pe())
            let asset = try put("Import/PC/data/level.dat")
            let folder = exe.deletingLastPathComponent().deletingLastPathComponent()
            let ticket = try await worker.receipt(folder)
            let first = try await worker.importWindows(exe, folder: folder, receipt: ticket)
            let second = try await worker.importWindows(exe, folder: folder, receipt: ticket)
            require(first.importID == second.importID && first.relativePath == second.relativePath, "Copy-before-registration retry reuses ID")
            require(fm.fileExists(atPath: asset.path), "Original retained before registration")
            try await worker.consume(folder, receipt: ticket)
            require(!fm.fileExists(atPath: folder.path), "Successful source leaves Import")
            require(fm.fileExists(atPath: try storage.gameFolder(ticket.id).appendingPathComponent("data/level.dat").path), "Dependencies preserved")
        case "named-folders":
            let windows = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, console = UUID()
            let episode = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let other = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
            let original = "Program Files (x86)/Steam/steamapps/common/Shared Game"
            let exe = try put("wine/drive_c/" + original + "/game.exe", pe())
            try put("wine/drive_c/Imported/Other/game.exe", pe())
            let save = try put("IridiumRuntimes/Saves/sameboy/" + console.uuidString + "/save.sav")
            try put("IridiumRuntimes/Games/" + console.uuidString + "/game.gb", rom())
            let titles = [windows: "Shared Game", console: "Zelda", episode: "Episode", other: "Other"]
            try await worker.prepare(windows: [(episode,original,true),(other,"Imported/Other/game.exe",false),(windows,original,true)],
                consoles: [console], oldConsoleRoot: old, titles: titles)
            require(try storage.gameFolder(windows).lastPathComponent == "Shared Game - " + windows.uuidString, "Shared installs use the base game's title and stable ID")
            require(IridiumGameFolder.name("A /: Game?", id: windows) == "A Game - " + windows.uuidString, "Unsafe title characters are removed")
            require(try storage.gameFolder(console).lastPathComponent == "Zelda - " + console.uuidString, "Existing console folder has its title")
            require(try Data(contentsOf: exe) == pe(), "Steam path survives named migration")
            let stable = storage.drive.appendingPathComponent("iridium-games/" + windows.uuidString + "/game.exe")
            require(try Data(contentsOf: stable) == pe(), "Windows game ID remains a stable C path")
            let prior = try storage.gameFolder(windows)
            let renamed = storage.games.appendingPathComponent("Renamed - " + windows.uuidString)
            try fm.moveItem(at: prior, to: renamed)
            let restarted = IridiumImportFiles(documents: docs)
            try await restarted.prepare(windows: [(windows,original,true)], consoles: [console], oldConsoleRoot: old,
                titles: [windows:"Renamed",console:"Zelda"])
            require(try Data(contentsOf: stable) == pe() && Data(contentsOf: exe) == pe(), "Restart repairs aliases after an interrupted rename")
            require(try Data(contentsOf: save) == Data("asset".utf8), "Renaming leaves saves intact")
            let loose = UUID()
            let looseFile = try put("wine/drive_c/standalone.exe", pe())
            try await restarted.prepare(windows: [(windows,original,true),(loose,"standalone.exe",false)], consoles: [console], oldConsoleRoot: old)
            try await restarted.prepare(windows: [(windows,original,true),(loose,"standalone.exe",false)], consoles: [console], oldConsoleRoot: old,
                titles: [windows:"Renamed",console:"Zelda",loose:"Loose Game"])
            require(try Data(contentsOf: looseFile) == pe(), "Loose executable alias survives folder rename")
            require(try storage.gameFolder(loose).lastPathComponent == "Loose Game - " + loose.uuidString, "Legacy loose executable receives a readable folder")
            let second = UUID()
            try put("Games/" + second.uuidString + "/game.gb", rom())
            try storage.nameGames([second:"Zelda",console:"Zelda"])
            require(try storage.gameFolder(second) != storage.gameFolder(console), "Same-title games keep distinct folders")
            require(IridiumGameFolder.name(String(repeating:"あ",count:200),id:second).utf8.count <= 159, "Unicode names fit filesystem limits")
            let coordinator = IridiumImportCoordinator.shared
            LibraryModel.shared.entries = [LibraryEntry(id: windows, title: "Renamed", relativePath: original, bits: 64, steamAppID: 999)]
            coordinator.scan(); try await settle(coordinator)
            require(SteamInstallFiles.delete(appID: 999, folderName: "Shared Game", steamApps: storage.drive.appendingPathComponent("Program Files (x86)/Steam/steamapps")), "Uninstall removes the journaled named installation")
            try put("wine/drive_c/" + original + "/game.exe", pe())
            coordinator.storageDidChange(); try await settle(coordinator)
            require(try storage.gameFolder(windows).lastPathComponent == "Renamed - " + windows.uuidString && Data(contentsOf: stable) == pe(), "A reinstall with unchanged library IDs still moves into its named folder")
            let duplicate = try put("Games/Duplicate - " + windows.uuidString + "/keep.dat")
            rejects { _ = try storage.gameFolder(windows) }
            require(fm.fileExists(atPath: duplicate.path) && fm.fileExists(atPath: renamed.path), "Conflicting IDs preserve both folders")
        case "batch-resume":
            for index in 0..<60 { try put(String(format:"Import/Game %02d.gb",index), rom()) }
            let note = try put("Import/keep.txt")
            let coordinator = IridiumImportCoordinator.shared
            coordinator.scan()
            let deadline = Date().addingTimeInterval(20)
            while coordinator.imported == 0 && coordinator.isWorking {
                precondition(Date() < deadline, "Batch made no progress")
                try await Task.sleep(for: .milliseconds(2))
            }
            coordinator.suspend(); try await settle(coordinator)
            let store = IridiumConsoleLibrary.shared.store
            let partial = try store.load()
            require(!partial.isEmpty, "Backgrounding occurs after durable registration")
            let save = try store.saveDirectory(partial[0]).appendingPathComponent("progress.sav")
            try Data("progress".utf8).write(to: save)
            coordinator.resume(); try await settle(coordinator)
            let complete = try store.load()
            require(complete.count == 60 && Set(complete.map(\.id)).count == 60, "Large batch resumes without lost or duplicate records")
            for game in complete {
                require(try Data(contentsOf: store.rom(game)) == rom(), "Resumed batch preserves every game payload")
                require(try store.rom(game).deletingLastPathComponent().lastPathComponent.hasPrefix(game.title + " - "), "Every batch folder is readable")
            }
            coordinator.scan(retry: true); try await settle(coordinator)
            require(try store.load().count == 60, "Retry after batch completion does not duplicate games")
            require(try Data(contentsOf: save) == Data("progress".utf8) && fm.fileExists(atPath: note.path), "Resume and retry preserve saves and unsupported files")
        case "archive-restart":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let archive = storage.inbox.appendingPathComponent("games.zip")
            let ticket = try await worker.receipt(archive)
            let expanded = try await worker.expand(archive, receipt: ticket)
            let store = IridiumConsoleLibrary.shared.store
            for source in try await worker.files(expanded) where source.pathExtension == "gb" {
                let child = try await worker.receipt(source)
                _ = try await worker.importConsole(source, receipt: child, platform: .gameBoy, siblings: [], store: store)
                try await worker.consume(source, receipt: child)
            }
            require(try store.load().count == 2, "Both archive payloads durably registered")
            try await worker.removeEmptyStagingFolders()
            require(fm.fileExists(atPath: expanded.path), "Pending archive keeps its sealed extraction across restart")
            let coordinator = IridiumImportCoordinator.shared
            coordinator.scan(); try await settle(coordinator)
            require(try store.load().count == 2, "Restart after last payload does not duplicate games")
            require(!fm.fileExists(atPath: archive.path) && !fm.fileExists(atPath: expanded.path), "Completed archive and empty staging leave Import")
        case "empty-folders":
            try await worker.prepare(windows: [], consoles: [], oldConsoleRoot: old)
            let received = "Import/From Files-" + UUID().uuidString
            try put(received + "/.iridium-received", Data("Iridium file selection 1\n".utf8))
            try fm.createDirectory(at: docs.appendingPathComponent(received + "/empty/nested"), withIntermediateDirectories: true)
            let expanded = "Import/Archive extracted-" + UUID().uuidString
            let expandedID = String(expanded.suffix(36))
            try put(expanded + "/.iridium-extracted", Data((expandedID + "\n" + String(repeating:"a",count:64)).utf8))
            let retained = "Import/From Files-" + UUID().uuidString
            try put(retained + "/.iridium-received", Data("Iridium file selection 1\n".utf8))
            let hidden = try put(retained + "/.keep")
            let unknown = docs.appendingPathComponent("Import/User empty folder")
            try fm.createDirectory(at: unknown, withIntermediateDirectories: false)
            let outside = try put("Private/keep.dat")
            try fm.createSymbolicLink(at: storage.inbox.appendingPathComponent("bad-link"), withDestinationURL: outside.deletingLastPathComponent())
            try await worker.removeEmptyStagingFolders()
            require(!fm.fileExists(atPath: docs.appendingPathComponent(received).path), "Empty Files staging folder removed")
            require(!fm.fileExists(atPath: docs.appendingPathComponent(expanded).path), "Empty extraction folder removed")
            require(fm.fileExists(atPath: hidden.path) && fm.fileExists(atPath: unknown.path), "Hidden user files and unowned folders preserved")
            try put("Import/Good.gb", rom())
            let coordinator = IridiumImportCoordinator.shared
            coordinator.scan(); try await settle(coordinator)
            require(try IridiumConsoleLibrary.shared.store.load().count == 1, "A rejected symbolic link does not block valid games")
            require(fm.fileExists(atPath: outside.path), "Cleanup does not follow a link to user files")
        case "cloud":
            let c = IridiumImportCoordinator.shared, id = UUID()
            c.scan(); try await settle(c)
            try await c.beginCloudTransfer()
            let original = "Program Files (x86)/Steam/steamapps/common/Cloud Game"
            try put("wine/drive_c/" + original + "/game.exe", pe())
            let save = try put("wine/drive_c/" + original + "/save.dat")
            LibraryModel.shared.entries = [LibraryEntry(id: id, title: "Cloud Game", relativePath: original, bits: 64, steamAppID: 42)]
            c.storageDidChange()
            require(!c.isWorking && c.syncingCloud, "Migration waits for Cloud ownership")
            rejects { try c.beginLibraryTransfer() }
            require((try? fm.destinationOfSymbolicLink(atPath: save.deletingLastPathComponent().path)) == nil, "Migration cannot move the folder during Cloud restore")
            try Data("cloud save".utf8).write(to: save, options: .atomic)
            c.endCloudTransfer()
            require(!c.blocksLaunch, "Cloud release does not start a scan ahead of the waiting game launch")
            try c.beginLibraryTransfer()
            var waiting = false, acquired = false
            let cloud = Task {
                waiting = true
                try await c.beginCloudTransfer()
                acquired = true
                require(!c.isWorking, "Cloud waits until migration releases files")
                require(try Data(contentsOf: save) == Data("cloud save".utf8), "Cloud sees the same save through the repaired alias")
            }
            while !waiting { await Task.yield() }
            require(!acquired, "Cloud cannot pass an existing file transfer")
            c.endLibraryTransfer()
            require(c.isWorking, "Migration reserves files before yielding")
            try await settle(c)
            try await cloud.value
            require(c.syncingCloud, "Cloud owns files after migration")
            require(try Data(contentsOf: storage.gameFolder(id).appendingPathComponent("save.dat")) == Data("cloud save".utf8), "The moved save has the Cloud contents")
            require(try fm.contentsOfDirectory(atPath: storage.games.path).count == 1, "Restore and migration leave one game folder")
            waiting = false
            let cancelled = Task { waiting = true; try await c.beginCloudTransfer() }
            while !waiting { await Task.yield() }
            cancelled.cancel()
            do { try await cancelled.value; preconditionFailure("Cancelled Cloud wait acquired storage") } catch is CancellationError { }
            require(c.syncingCloud, "A cancelled waiter cannot release the active owner's files")
            c.endCloudTransfer()
            try await c.beginCloudTransfer(); c.endCloudTransfer()
            SteamOwnedLibrary.shared.downloads[42] = .init(state: .active)
            waiting = false
            let downloading = Task { waiting = true; try await c.beginCloudTransfer() }
            while !waiting { await Task.yield() }
            require(!c.syncingCloud, "Cloud waits for an active installer")
            downloading.cancel()
            do { try await downloading.value; preconditionFailure("Cancelled installer wait acquired storage") } catch is CancellationError { }
            SteamOwnedLibrary.shared.downloads.removeAll()
            IridiumConsoleSession.shared.isActive = true
            try await c.beginCloudTransfer()
            require(c.syncingCloud, "Quit upload can own storage while the game is active")
            c.scan(); require(!c.isWorking, "Quit upload never permits migration")
            c.endCloudTransfer()
            IridiumConsoleSession.shared.isActive = false
            try fm.removeItem(at: save.deletingLastPathComponent())
            try put("wine/drive_c/" + original + "/keep.dat")
            c.storageDidChange(); try await settle(c)
            require(c.migrationError != nil, "A conflicting source blocks migration")
            do { try await c.beginCloudTransfer(); preconditionFailure("Cloud ignored a failed migration") } catch { }
            require(!c.syncingCloud, "A failed migration cannot grant Cloud file access")
        case "bulk", "archive", "pairing", "registration", "idle", "arcade", "picker":
            let model = LibraryModel.shared, c = IridiumImportCoordinator.shared
            if CommandLine.arguments[1] == "picker" {
                let external = docs.deletingLastPathComponent().appendingPathComponent("Selected")
                try fm.createDirectory(at: external, withIntermediateDirectories: true)
                try rom().write(to: external.appendingPathComponent("One.gb"))
                try rom().write(to: external.appendingPathComponent("Two.gb"))
                try Data("keep".utf8).write(to: external.appendingPathComponent("readme.txt"))
                c.scan()
                c.receive(try fm.contentsOfDirectory(at: external, includingPropertiesForKeys: nil))
            } else if CommandLine.arguments[1] == "bulk" {
                try put("Import/Batch/One.gb", rom()); try put("Import/Batch/Two.gb", rom())
                try put("Import/Batch/PC/game.exe", pe()); try put("Import/Batch/PC/data.dat")
                try put("Import/Batch/readme.txt")
            } else if CommandLine.arguments[1] == "pairing" {
                let bytes = try PropertyListSerialization.data(fromPropertyList: ["test":1], format: .xml, options: 0)
                try put("Import/a.plist", bytes); try put("Import/b.plist", bytes)
            } else if CommandLine.arguments[1] == "registration" {
                try put("Import/game.exe", pe()); model.refuseSave = true
            } else if CommandLine.arguments[1] == "idle" {
                try put("Import/One.gb", rom()); IridiumConsoleSession.shared.isActive = true
                c.scan(); require(!c.isWorking && !c.ready, "No migration or import during gameplay")
                IridiumConsoleSession.shared.isActive = false
            }
            c.scan(); require(c.blocksLaunch, "Launch blocked before import reservation yields")
            try await settle(c)
            require(c.ready, "Storage prepared")
            if CommandLine.arguments[1] == "pairing" {
                require(JITPairingFileStore.saved.isEmpty && c.choices.count == 2, "Multiple credentials require choice")
                c.choose(c.choices.values.first!, value: ":pairing"); try await settle(c)
                require(JITPairingFileStore.saved.count == 1, "Only selected pairing imported")
                require(c.choices.count == 1, "Remaining credential still requires choice")
                require(try fm.contentsOfDirectory(atPath: storage.inbox.path).filter { $0.hasSuffix("plist") }.count == 1, "Stored pairing leaves Import")
            } else if CommandLine.arguments[1] == "registration" {
                require(fm.fileExists(atPath: storage.inbox.appendingPathComponent("game.exe").path), "Failed library save keeps source")
                model.refuseSave = false; c.scan(retry: true); try await settle(c)
                require(model.entries.count == 1 && !fm.fileExists(atPath: storage.inbox.appendingPathComponent("game.exe").path), "Registration retry consumes once")
            } else if CommandLine.arguments[1] == "arcade" {
                require(c.choices.count == 1, "Arcade ZIP asks instead of losing its archive")
                c.choose(c.choices.values.first!, value: IridiumPlatform.arcade.rawValue); try await settle(c)
                require(try IridiumConsoleLibrary.shared.store.load().count == 1, "Arcade set registered")
                require(try fm.contentsOfDirectory(atPath: storage.inbox.path).filter { !$0.hasPrefix(".") }.isEmpty, "Unchanged arcade expansion removed after registration")
            } else {
                let games = try IridiumConsoleLibrary.shared.store.load()
                let expected = CommandLine.arguments[1] == "idle" ? 1 : 2
                require(games.count == expected, "All console games registered: \(c.failures)")
                if CommandLine.arguments[1] == "bulk" { require(model.entries.count == 1, "Mixed folder includes Windows game") }
                for game in games { require(fm.fileExists(atPath: try IridiumConsoleLibrary.shared.store.rom(game).path), "Each game launch path exists") }
                require(c.failures.isEmpty && c.choices.isEmpty, "No hidden import failure")
                c.scan(); try await settle(c)
                require(try IridiumConsoleLibrary.shared.store.load().count == expected, "Rescan has no duplicates")
                if CommandLine.arguments[1] == "picker" {
                    let selected = docs.deletingLastPathComponent().appendingPathComponent("Selected")
                    require(try fm.contentsOfDirectory(atPath: selected.path).count == 3, "External originals stay intact")
                }
                if CommandLine.arguments[1] != "idle" { require(c.remaining.contains { $0.hasSuffix("readme.txt") }, "Unknown files remain visible") }
            }
        default: preconditionFailure("Unknown scenario")
        }
        print("PASS " + CommandLine.arguments[1])
    }
}
