import Foundation

@main struct ManagedGameFilesCheck {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Source")
        let imports = root.appendingPathComponent("Imports")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("Game.exe")
        try Data("version-one".utf8).write(to: exe)
        try Data("hidden-data".utf8).write(to: source.appendingPathComponent(".game-data"))
        let first = try ManagedGameFiles.importCopy(from: source, executable: exe, into: imports, title: "My-Game")
        let save = first.directory.appendingPathComponent("save.dat")
        try Data("progress".utf8).write(to: save)
        try Data("version-two".utf8).write(to: exe)
        let second = try ManagedGameFiles.importCopy(from: source, executable: exe, into: imports, title: "MyGame")
        precondition(first.directory != second.directory)
        precondition(tryValue(first.executable) == "version-one")
        precondition(tryValue(second.executable) == "version-two")
        precondition(tryValue(save) == "progress")
        precondition(tryValue(second.directory.appendingPathComponent(".game-data")) == "hidden-data")
        let before = try fm.contentsOfDirectory(atPath: imports.path).sorted()
        try fm.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        do {
            _ = try ManagedGameFiles.importCopy(from: source, executable: exe, into: imports, title: "My-Game")
            fatalError("accepted escaping link")
        } catch is CocoaError {}
        let after = try fm.contentsOfDirectory(atPath: imports.path).sorted()
        precondition(after == before)
        precondition(tryValue(save) == "progress")
        do {
            _ = try ManagedGameFiles.importCopy(from: source, executable: save, into: imports, title: "bad")
            fatalError("accepted executable outside source")
        } catch is CocoaError {}
        let size = ManagedGameFiles.sizeGB(at: second.directory)!
        precondition(abs(size - 22.0 / 1_000_000_000) < 0.00000000001)
        precondition(ManagedGameFiles.sizeGB(at: root.appendingPathComponent("missing")) == nil)
        precondition(ManagedGameFiles.volumeSpace(at: root)!.totalGB > 0)
        precondition(!ManagedGameFiles.isDescendant(root.appendingPathComponent("ImportsOther"), of: imports))
        print("PASS transactional import, name collisions, hidden files, source validation, original-save preservation and measured storage")
    }
    static func tryValue(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
}
