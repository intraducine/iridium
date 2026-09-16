import Foundation

/// Files selected only when the user shares diagnostics. Do not initialize
/// LogStore here: doing so rotates Madeira's log and can hide the failed run.
enum RuntimeDiagnosticLogFiles {
    static func existing(in documents: URL) -> [URL] {
        let names = [
            "iridium-runtime.log",
            "madeira-log.txt",
            "madeira-log.prev.txt",
            "iridium-runtime.previous.log"
        ]
        return names.compactMap { name in
            let url = documents.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: url.path)
            else { return nil }
            return url
        }
    }
}
