import Foundation

// Cloud must use the same prepared game copy as the adapter. The seed callback
// is injected so host tests exercise first preparation without starting Wine.
enum SteamCloudPreparation {
    static func prepare(gameID: UUID, documents: URL, executable: URL, source: URL,
                        fingerprint: (URL) throws -> String = MadeiraGamePreparation.fingerprintFile,
                        seed: (URL) throws -> Void) throws {
        let fm = FileManager.default
        // Resolve the OS-provided Documents anchor once (/var is an OS alias on
        // iOS). Below that trusted anchor, reject links rather than following them.
        let anchor = documents.resolvingSymlinksInPath().standardizedFileURL
        let prefixes = anchor.appendingPathComponent("MadeiraTestPrefixes", isDirectory: true)
        let prefix = prefixes.appendingPathComponent(gameID.uuidString, isDirectory: true)
        for url in [prefixes, prefix, prefix.appendingPathComponent("drive_c"), prefix.appendingPathComponent("drive_c/IridiumGame")] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        var existed = ObjCBool(false)
        let hasPrefix = fm.fileExists(atPath: prefix.path, isDirectory: &existed)
        if hasPrefix && !existed.boolValue { throw CocoaError(.fileReadInvalidFileName) }
        if !hasPrefix {
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            try seed(prefix)
        } else if try fm.contentsOfDirectory(atPath: prefix.path).isEmpty {
            try seed(prefix)
        }
        // Never unpack a seed over an existing nonempty prefix. Existing legacy
        // prefixes use their current profile or report unsupported mapping.
        _ = try MadeiraGamePreparation.prepare(executable: executable, gameRoot: source, prefix: prefix, fingerprint: fingerprint)
    }
}
