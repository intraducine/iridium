import CryptoKit
import Foundation
import IridiumCore

public struct ExecutableFingerprint: Codable, Hashable, Sendable {
    public var algorithm: String
    public var value: String
    public var sizeBytes: Int64
    public var modifiedAt: Date?

    public init(algorithm: String, value: String, sizeBytes: Int64, modifiedAt: Date? = nil) {
        self.algorithm = algorithm
        self.value = value
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public protocol GameArtifactInventory: Sendable {
    func scanImport(installPath: String, title: String) -> ImportScanResult
    func fingerprintExecutable(at executablePath: String) throws -> ExecutableFingerprint
    func makeManagedArtifact(
        title: String,
        executablePath: String,
        installPath: String
    ) throws -> RuntimeArtifact
}

public struct FileSystemGameArtifactInventory: GameArtifactInventory {
    public init() {}

    public func scanImport(installPath: String, title: String) -> ImportScanResult {
        ImportScanner().scan(installPath: installPath, title: title)
    }

    public func fingerprintExecutable(at executablePath: String) throws -> ExecutableFingerprint {
        let executableURL = URL(fileURLWithPath: executablePath)
        let data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        let checksum = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let values = try executableURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ExecutableFingerprint(
            algorithm: "SHA256",
            value: checksum,
            sizeBytes: Int64(values.fileSize ?? data.count),
            modifiedAt: values.contentModificationDate
        )
    }

    public func makeManagedArtifact(
        title: String,
        executablePath: String,
        installPath: String
    ) throws -> RuntimeArtifact {
        let fingerprint = try fingerprintExecutable(at: executablePath)
        let installRoot = URL(fileURLWithPath: installPath, isDirectory: true).standardizedFileURL
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let relativePath = relativePath(from: installRoot, to: executableURL) ?? executableURL.lastPathComponent

        return RuntimeArtifact(
            identifier: normalizedIdentifier(from: title),
            relativePath: relativePath,
            sizeBytes: fingerprint.sizeBytes,
            checksum: fingerprint.value,
            kind: .executable
        )
    }

    private func normalizedIdentifier(from value: String) -> String {
        let filtered = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(filtered).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
    }

    private func relativePath(from root: URL, to target: URL) -> String? {
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents

        guard targetComponents.starts(with: rootComponents) else {
            return nil
        }

        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

