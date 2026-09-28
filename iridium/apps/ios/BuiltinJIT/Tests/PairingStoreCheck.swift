import CryptoKit
import Foundation

@main enum PairingStoreCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("Documents/StikJIT/pairingFile.plist")
        let stored = root.appendingPathComponent("Application Support/StikJIT/pairingFile.plist")
        let store = JITPairingStore(filesURL: inbox, storedURL: stored)
        try store.prepareFilesFolder()

        let key = Curve25519.Signing.PrivateKey()
        let pairing = try PropertyListSerialization.data(fromPropertyList: [
            "identifier": UUID().uuidString,
            "public_key": key.publicKey.rawRepresentation,
            "private_key": key.rawRepresentation
        ], format: .xml, options: 0)

        try pairing.write(to: inbox)
        try store.importFrom(inbox)
        assert(!FileManager.default.fileExists(atPath: inbox.path))
        let imported = try store.read()
        assert(imported == pairing)

        let external = root.appendingPathComponent("external.plist")
        try pairing.write(to: external)
        try store.importFrom(external)
        assert(FileManager.default.fileExists(atPath: external.path))

        let migrated = JITPairingStore(filesURL: inbox,
            storedURL: root.appendingPathComponent("new-store/pairingFile.plist"))
        try pairing.write(to: inbox)
        let migratedData = try migrated.read()
        assert(migratedData == pairing)
        assert(!FileManager.default.fileExists(atPath: inbox.path))

        try Data("invalid".utf8).write(to: inbox)
        do {
            try store.importFrom(inbox)
            fatalError("Accepted an invalid pairing file")
        } catch {
            assert(FileManager.default.fileExists(atPath: inbox.path))
            let previous = try store.read()
            assert(previous == pairing)
        }
        print("PASS: pairing inbox is removed after import, external source stays, old files migrate, invalid input is retained")
    }
}
