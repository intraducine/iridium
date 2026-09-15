import Foundation

@main
struct GamePreparationCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iridium-madeira-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let game = root.appendingPathComponent("original")
        let prefix = root.appendingPathComponent("test-prefix")
        try fm.createDirectory(at: game.appendingPathComponent(".iridium"), withIntermediateDirectories: true)
        let exe = game.appendingPathComponent("game.exe")
        try Data([1, 2]).write(to: exe)
        try Data([3]).write(to: game.appendingPathComponent("save.dat"))
        let path = try MadeiraGamePreparation.prepare(executable: exe, gameRoot: game, prefix: prefix)
        precondition(path == "C:\\IridiumGame\\game.exe")
        try Data("12345\n".utf8).write(to: game.appendingPathComponent("steam_appid.txt"))
        precondition(MadeiraGamePreparation.steamMetadata(executable: exe, gameRoot: game, windowsExecutable: path) == MadeiraGamePreparation.SteamMetadata(appID: "12345", appPath: "C:\\IridiumGame"))
        precondition(MadeiraGamePreparation.steamMetadata(appID: " 67890\n", windowsExecutable: path) == MadeiraGamePreparation.SteamMetadata(appID: "67890", appPath: "C:\\IridiumGame"))
        try fm.removeItem(at: game.appendingPathComponent("steam_appid.txt"))
        precondition(MadeiraGamePreparation.steamMetadata(executable: exe, gameRoot: game, windowsExecutable: path) == nil)
        let copy = prefix.appendingPathComponent("drive_c/IridiumGame")
        precondition(!fm.fileExists(atPath: copy.appendingPathComponent(".iridium").path))
        try Data([9]).write(to: copy.appendingPathComponent("save.dat"))
        let originalSave = try Data(contentsOf: game.appendingPathComponent("save.dat"))
        precondition(originalSave == Data([3]))
        _ = try MadeiraGamePreparation.prepare(executable: exe, gameRoot: game, prefix: prefix)
        let testSave = try Data(contentsOf: copy.appendingPathComponent("save.dat"))
        precondition(testSave == Data([9]))
        do {
            _ = try MadeiraGamePreparation.prepare(executable: exe, gameRoot: prefix, prefix: prefix)
            fatalError("accepted executable outside game root")
        } catch is CocoaError {}
        print("PASS: isolated game copy, preserved original saves, persistent test saves, steam metadata, path boundary")
    }
}