import Foundation

@main
struct CloudChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("iridium-cloud-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source.appendingPathComponent("saves"), withIntermediateDirectories: true)
        let exe = source.appendingPathComponent("game.exe")
        try Data("synthetic executable".utf8).write(to: exe)
        try Data("old imported save".utf8).write(to: source.appendingPathComponent("saves/one.sav"))
        func fingerprint(_ url: URL) throws -> String { try Data(contentsOf: url).base64EncodedString() }
        let id = UUID()
        var seedCalls = 0
        func seed(_ prefix: URL) throws {
            seedCalls += 1
            try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users/madeira/AppData/Local"), withIntermediateDirectories: true)
            try Data("fixture seed".utf8).write(to: prefix.appendingPathComponent(".update-timestamp"))
        }
        try SteamCloudPreparation.prepare(gameID: id, documents: documents, executable: exe, source: source, fingerprint: fingerprint, seed: seed)
        let prefix = documents.appendingPathComponent("MadeiraTestPrefixes/" + id.uuidString)
        let save = prefix.appendingPathComponent("drive_c/IridiumGame/saves/one.sav")
        let imported = try Data(contentsOf: save)
        precondition(seedCalls == 1 && imported == Data("old imported save".utf8))
        // Simulate a verified Cloud placement after the first source copy.
        try Data("verified remote save".utf8).write(to: save, options: .atomic)
        try SteamCloudPreparation.prepare(gameID: id, documents: documents, executable: exe, source: source, fingerprint: fingerprint, seed: seed)
        let preserved = try Data(contentsOf: save)
        precondition(seedCalls == 1 && preserved == Data("verified remote save".utf8))
        // The later adapter calls this exact helper too. Its no-source-change
        // path must preserve Cloud changes rather than recopy imported saves.
        _ = try MadeiraGamePreparation.prepare(executable: exe, gameRoot: source, prefix: prefix, fingerprint: fingerprint)
        let afterAdapter = try Data(contentsOf: save)
        precondition(afterAdapter == Data("verified remote save".utf8))
        let linkedID = UUID()
        let link = documents.appendingPathComponent("MadeiraTestPrefixes/" + linkedID.uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("source"))
        do {
            try SteamCloudPreparation.prepare(gameID: linkedID, documents: documents, executable: exe, source: source, fingerprint: fingerprint, seed: seed)
            fatalError("Accepted linked prefix")
        } catch { precondition(seedCalls == 1) }
        let json = Data("""
        {"gameId":"\(id.uuidString)","appId":42,"enabled":true,"phase":"ready","message":"Fixture","entries":[{"path":"%GameInstall%saves/one.sav","action":"same","local":{"path":"fixture","sha":"AB","size":7,"time":1},"remote":{"path":"fixture","sha":"AB","size":7,"time":1}}],"backups":[]}
        """.utf8)
        let status = try JSONDecoder().decode(SteamCloudStatus.self, from: json)
        precondition(status.readyToPlay)
        let choice = SteamCloudChoice(status.entries[0], side: "local")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) as! [String: String]
        precondition(encoded["localSha"] == "AB" && encoded["remoteSha"] == "AB")
        print("PASS: Cloud first preparation, later save preservation, symlink rejection and Swift JSON contracts.")
    }
}
