import Foundation

/// File operations shared by import and relocation. Existing installs are never
/// replaced in place: only a validated, uniquely named copy is returned.
public enum ManagedGameFiles {
    public struct ImportCopy: Sendable {
        public let directory: URL
        public let executable: URL
    }

    public static func importCopy(
        from source: URL,
        executable: URL,
        into importsRoot: URL,
        title: String
    ) throws -> ImportCopy {
        let fm = FileManager.default
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let file = executable.resolvingSymlinksInPath().standardizedFileURL
        let imports = importsRoot.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(file, of: root), file.pathExtension.lowercased() == "exe",
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              !isDescendant(imports, of: root), imports != root else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relative = String(file.path.dropFirst(root.path.count + 1))
        try validateTree(root)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = imports.appendingPathComponent(".import-" + id, isDirectory: true)
        let slug = String(title.filter { $0.isLetter || $0.isNumber }.prefix(64))
        let destination = imports.appendingPathComponent((slug.isEmpty ? "Game" : slug) + "-" + id,
                                                       isDirectory: true)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        try Task.checkCancellation()
        try fm.copyItem(at: root, to: staging)
        try validateTree(staging)
        try Task.checkCancellation()
        let stagedExecutable = staging.appendingPathComponent(relative)
        guard try stagedExecutable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fm.moveItem(at: staging, to: destination)
        return ImportCopy(directory: destination, executable: destination.appendingPathComponent(relative))
    }

    public static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentParts = parent.standardizedFileURL.pathComponents
        let childParts = child.standardizedFileURL.pathComponents
        return childParts.count > parentParts.count && childParts.starts(with: parentParts)
    }

    /// Reject links and special files rather than copying a writable escape into
    /// a game's isolated environment. A symlink used to select the root is
    /// resolved by the caller; links *inside* the tree are not accepted.
    public static func validateTree(_ root: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                             options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    /// Logical file bytes, not an estimate based on game name or device tier.
    /// A failed/incomplete enumeration is unknown, never zero.
    public static func sizeGB(at directory: URL) -> Double? {
        let fm = FileManager.default
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        var failed = false
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: keys,
                                             options: [], errorHandler: { _, _ in
            failed = true
            return false
        }) else { return nil }
        var bytes: UInt64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return nil }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size >= 0 else { return nil }
            let addition = bytes.addingReportingOverflow(UInt64(size))
            guard !addition.overflow else { return nil }
            bytes = addition.partialValue
        }
        return failed ? nil : Double(bytes) / 1_000_000_000
    }

    public static func volumeSpace(at directory: URL) -> (totalGB: Double, freeGB: Double)? {
        var existing = directory.standardizedFileURL
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        guard let values = try? fm.attributesOfFileSystem(forPath: existing.path),
              let total = values[.systemSize] as? NSNumber,
              let free = values[.systemFreeSize] as? NSNumber,
              total.doubleValue > 0, free.doubleValue >= 0 else { return nil }
        return (total.doubleValue / 1_000_000_000, free.doubleValue / 1_000_000_000)
    }
}
