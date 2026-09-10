import Foundation

enum MadeiraGamePreparation {
    static func prepare(executable: URL, gameRoot: URL, prefix: URL) throws -> String {
        let fm = FileManager.default
        let root = gameRoot.resolvingSymlinksInPath().standardizedFileURL
        let exe = executable.resolvingSymlinksInPath().standardizedFileURL
        guard exe.path.hasPrefix(root.path + "/"), fm.fileExists(atPath: exe.path) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relative = String(exe.path.dropFirst(root.path.count + 1))
        let target = prefix.appendingPathComponent("drive_c/IridiumGame")
        let stamp = target.appendingPathComponent(".iridium-test-copy-complete")
        // ponytail: snapshot once per test prefix; explicit refresh is needed for game updates.
        if !fm.fileExists(atPath: stamp.path) {
            let staging = prefix.appendingPathComponent("game-copy-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where item.lastPathComponent != ".iridium" {
                // A writable link could point back at original saves. Fail closed.
                let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.isSymbolicLinkKey])
                let descendants = (enumerator?.allObjects as? [URL]) ?? []
                for candidate in [item] + descendants {
                    if try candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                }
                try fm.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
            }
            try Data().write(to: staging.appendingPathComponent(stamp.lastPathComponent))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: target)
        }
        guard fm.fileExists(atPath: target.appendingPathComponent(relative).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return "C:\\IridiumGame\\" + relative.replacingOccurrences(of: "/", with: "\\")
    }
}
