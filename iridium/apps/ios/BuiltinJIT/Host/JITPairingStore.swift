import Foundation

struct JITPairingStore {
    let filesURL: URL
    let storedURL: URL

    static var live: Self {
        let files = FileManager.default
        return Self(
            filesURL: files.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StikJIT/pairingFile.plist"),
            storedURL: files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StikJIT/pairingFile.plist")
        )
    }

    func prepareFilesFolder() throws {
        try FileManager.default.createDirectory(at: filesURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    func importFrom(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        try JITPairing.validate(data)

        try FileManager.default.createDirectory(at: storedURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: storedURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var stored = storedURL
        try stored.setResourceValues(values)
        if url.standardizedFileURL == filesURL.standardizedFileURL {
            try FileManager.default.removeItem(at: filesURL)
        }
    }

    func read() throws -> Data {
        if !FileManager.default.fileExists(atPath: storedURL.path) {
            try importFrom(filesURL)
        }
        let data = try Data(contentsOf: storedURL)
        try JITPairing.validate(data)
        return data
    }
}
