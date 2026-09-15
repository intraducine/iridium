import Foundation

@main struct GamePreparationRegression {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let game = root.appendingPathComponent("source")
        let prefix = root.appendingPathComponent("prefix")
        let exe = game.appendingPathComponent("game.exe")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        func write(_ url: URL, _ value: String) throws { try Data(value.utf8).write(to: url, options: .atomic) }
        func read(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
        // Collision-free encoding for these tiny fixtures, not the production SHA-256 implementation.
        func fingerprint(_ url: URL) throws -> String { try Data(contentsOf: url).base64EncodedString() }
        func prepare(_ force: Bool = false) throws {
            _ = try MadeiraGamePreparation.prepare(executable: exe, gameRoot: game, prefix: prefix,
                replaceConflictsWithBackup: force, fingerprint: fingerprint)
        }
        try write(exe, "v1")
        try write(game.appendingPathComponent("save.dat"), "source-save")
        try write(game.appendingPathComponent("old.asset"), "old")
        try prepare()
        let target = prefix.appendingPathComponent("drive_c/IridiumGame")
        try write(target.appendingPathComponent("save.dat"), "my-progress")
        try write(target.appendingPathComponent("new-save.dat"), "new-progress")
        try write(exe, "v2")
        try fm.removeItem(at: game.appendingPathComponent("old.asset"))
        try prepare()
        precondition(read(target.appendingPathComponent("game.exe")) == "v2")
        precondition(read(target.appendingPathComponent("save.dat")) == "my-progress")
        precondition(read(target.appendingPathComponent("new-save.dat")) == "new-progress")
        precondition(!fm.fileExists(atPath: target.appendingPathComponent("old.asset").path))
        let backups = try fm.contentsOfDirectory(at: prefix, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("game-backup-") }
        precondition(backups.count == 1)
        precondition(read(backups[0].appendingPathComponent("game.exe")) == "v1")
        try write(exe, "v3-source")
        try write(target.appendingPathComponent("game.exe"), "v3-local")
        do { try prepare(); fatalError("silently replaced conflicting local data") }
        catch MadeiraGamePreparation.PreparationError.conflictingChanges {}
        precondition(read(target.appendingPathComponent("game.exe")) == "v3-local")
        let failedCopies = try fm.contentsOfDirectory(atPath: prefix.path).filter { $0.hasPrefix("game-copy-") }
        precondition(failedCopies.isEmpty)
        try prepare(true)
        precondition(read(target.appendingPathComponent("game.exe")) == "v3-source")
        try fm.createSymbolicLink(at: game.appendingPathComponent("escape"), withDestinationURL: root)
        do { try prepare(); fatalError("accepted link") } catch is CocoaError {}
        try fm.removeItem(at: game.appendingPathComponent("escape"))
        // Crash between old->backup and staging->target must restore the old copy.
        let id = UUID().uuidString
        let backupName = "game-backup-" + id
        let stagingName = "game-copy-" + id
        try fm.moveItem(at: target, to: prefix.appendingPathComponent(backupName))
        try fm.createDirectory(at: prefix.appendingPathComponent(stagingName), withIntermediateDirectories: true)
        let record = ["staging": stagingName, "backup": backupName]
        try JSONEncoder().encode(record).write(to: prefix.appendingPathComponent(".iridium-game-update.json"))
        try prepare()
        precondition(read(target.appendingPathComponent("save.dat")) == "my-progress")
        precondition(!fm.fileExists(atPath: prefix.appendingPathComponent(stagingName).path))
        precondition(!MadeiraGamePreparation.validRelativePath("../save"))
        precondition(!MadeiraGamePreparation.validRelativePath("dir/../../save"))
        print("PASS source updates, save preservation, deletions, conflict rejection, backup refresh, failed staging cleanup, interrupted-swap recovery and path validation")
    }
}
