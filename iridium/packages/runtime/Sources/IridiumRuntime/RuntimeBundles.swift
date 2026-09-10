import CryptoKit
import Foundation
import IridiumCore

public enum RuntimeArtifactKind: String, Codable, CaseIterable, Sendable {
    case executable
    case runtimeBinary
    case translationLayer
    case userlandPayload
    case graphicsStack
    case metadata
    case supportFile
}

public struct RuntimeArtifact: Codable, Hashable, Sendable, Identifiable {
    public var id: String { identifier }
    public var identifier: String
    public var relativePath: String
    public var sizeBytes: Int64
    public var checksum: String
    public var kind: RuntimeArtifactKind

    public init(
        identifier: String,
        relativePath: String,
        sizeBytes: Int64,
        checksum: String,
        kind: RuntimeArtifactKind
    ) {
        self.identifier = identifier
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.checksum = checksum
        self.kind = kind
    }
}

public struct RuntimeBundleManifest: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var descriptor: RuntimeDescriptor
    public var artifacts: [RuntimeArtifact]
    public var minimumDeviceTier: DeviceTier
    public var supportsDirectGameLaunch: Bool
    public var bundleRootPath: String?
    public var supportMetadata: [String: String]

    public init(
        id: String,
        name: String,
        version: String,
        descriptor: RuntimeDescriptor,
        artifacts: [RuntimeArtifact],
        minimumDeviceTier: DeviceTier,
        supportsDirectGameLaunch: Bool,
        bundleRootPath: String? = nil,
        supportMetadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.descriptor = descriptor
        self.artifacts = artifacts
        self.minimumDeviceTier = minimumDeviceTier
        self.supportsDirectGameLaunch = supportsDirectGameLaunch
        self.bundleRootPath = bundleRootPath
        self.supportMetadata = supportMetadata
    }
}

private struct RequiredRuntimeArtifact {
    let identifier: String
    let relativePath: String
    let kind: RuntimeArtifactKind
}

private let requiredRuntimeArtifacts: [RequiredRuntimeArtifact] = [
    RequiredRuntimeArtifact(
        identifier: "runtime-host-binary",
        relativePath: "Runtime/runtime-host.bin",
        kind: .runtimeBinary
    ),
    RequiredRuntimeArtifact(
        identifier: "x64-jit-translator",
        relativePath: "Translator/x64-jit.bin",
        kind: .translationLayer
    ),
    RequiredRuntimeArtifact(
        identifier: "wine-userland",
        relativePath: "Userland/wine-userland.tar.zst",
        kind: .userlandPayload
    ),
    RequiredRuntimeArtifact(
        identifier: "vkd3d-stack",
        relativePath: "Graphics/vkd3d-stack.json",
        kind: .graphicsStack
    ),
    RequiredRuntimeArtifact(
        identifier: "ios-presentation-backend",
        relativePath: "Graphics/ios-presentation-backend.json",
        kind: .graphicsStack
    ),
    RequiredRuntimeArtifact(
        identifier: "direct-launch-profile",
        relativePath: "Metadata/direct-launch.json",
        kind: .metadata
    ),
]

private let fexcoreDisabledMarker = Data(
    "Embedded FEX runtime was compiled without FEXCore support".utf8
)

let runtimeHostCodeSignatureInvariantChecksumKey =
    "runtimeHostCodeSignatureInvariantSHA256"

func codeSignatureInvariantMachOChecksum(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    let machHeader64Size = 32
    let loadCommandHeaderSize = 8
    let linkeditDataCommandSize = 16
    let segment64CommandSize = 72
    let machMagic64: UInt32 = 0xfeed_facf
    let loadCommandSegment64: UInt32 = 0x19
    let loadCommandCodeSignature: UInt32 = 0x1d

    guard bytes.count >= machHeader64Size,
          littleEndianUInt32(bytes, at: 0) == machMagic64,
          let commandCount = littleEndianUInt32(bytes, at: 16),
          let commandBytes = littleEndianUInt32(bytes, at: 20),
          commandBytes <= UInt32(bytes.count - machHeader64Size) else {
        return nil
    }

    var commandOffset = machHeader64Size
    let commandRegionEnd = machHeader64Size + Int(commandBytes)
    var signatureCommandOffset: Int?
    var signatureOffset: Int?
    var signingOwnedRanges: [Range<Int>] = []
    for _ in 0..<Int(commandCount) {
        guard commandOffset <= commandRegionEnd - loadCommandHeaderSize,
              let command = littleEndianUInt32(bytes, at: commandOffset),
              let commandSizeValue = littleEndianUInt32(bytes, at: commandOffset + 4) else {
            return nil
        }
        let commandSize = Int(commandSizeValue)
        guard commandSize >= loadCommandHeaderSize,
              commandOffset <= commandRegionEnd - commandSize else {
            return nil
        }

        if command == loadCommandSegment64, commandSize >= segment64CommandSize {
            let segmentNameBytes = bytes[(commandOffset + 8)..<(commandOffset + 24)]
            let segmentName = String(
                bytes: segmentNameBytes.prefix { $0 != 0 },
                encoding: .utf8
            )
            if segmentName == "__LINKEDIT" {
                // codesign resizes __LINKEDIT to match its replacement signature.
                signingOwnedRanges.append((commandOffset + 32)..<(commandOffset + 40))
                signingOwnedRanges.append((commandOffset + 48)..<(commandOffset + 56))
            }
        } else if command == loadCommandCodeSignature {
            guard commandSize >= linkeditDataCommandSize,
                  let signatureOffsetValue = littleEndianUInt32(bytes, at: commandOffset + 8) else {
                return nil
            }
            let resolvedSignatureOffset = Int(signatureOffsetValue)
            guard resolvedSignatureOffset >= commandRegionEnd,
                  resolvedSignatureOffset <= bytes.count,
                  commandOffset + linkeditDataCommandSize <= resolvedSignatureOffset else {
                return nil
            }
            signatureCommandOffset = commandOffset
            signatureOffset = resolvedSignatureOffset
        }

        commandOffset += commandSize
    }

    guard let signatureCommandOffset, let signatureOffset else {
        return nil
    }

    // Code signing replaces the blob at dataoff and may update both its load
    // command and __LINKEDIT's sizes. Excluding the blob and normalizing only
    // those signing-owned fields preserves every executable byte while remaining
    // stable across LiveContainer's re-signing pass.
    var canonicalBytes = Array(bytes.prefix(signatureOffset))
    signingOwnedRanges.append(
        (signatureCommandOffset + 8)..<(signatureCommandOffset + 16)
    )
    for range in signingOwnedRanges {
        for index in range {
            canonicalBytes[index] = 0
        }
    }
    return SHA256.hash(data: Data(canonicalBytes))
        .map { String(format: "%02x", $0) }
        .joined()
}

func managedUserlandRequirementSatisfied(
    managedUserlandStaged: Bool,
    appStagedUserlandAvailable: Bool,
    userlandArchiveAvailable: Bool
) -> Bool {
    managedUserlandStaged || appStagedUserlandAvailable || userlandArchiveAvailable
}

func bundledAppStagedUserlandRootURL(
    fileManager: FileManager = .default,
    bundle: Bundle = .main
) -> URL? {
    let candidate = bundle.bundleURL.appending(
        path: "IridiumWineUserland", directoryHint: .isDirectory)
    return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
}

private let embeddedGuestWineLoaderRelativePaths = [
    "lib/wine/x86_64-unix/wine-preloader",
    "lib64/wine/x86_64-unix/wine-preloader",
    "lib/wine/x86_64-unix/wine",
    "lib64/wine/x86_64-unix/wine",
    "bin/wine64",
    "bin/wine",
]

private let preloaderCompanionWineLoaderNames = [
    "wine",
    "wine64",
]

private let wineIOSDriverRelativePaths = [
    "lib/wine/x86_64-unix/wineios.so",
    "lib64/wine/x86_64-unix/wineios.so",
    "lib/wine/aarch64-unix/wineios.so",
    "lib64/wine/aarch64-unix/wineios.so",
]

private let openGLBackendRelativePaths = [
    "lib/wine/x86_64-unix/opengl32.so",
    "lib64/wine/x86_64-unix/opengl32.so",
    "lib/wine/aarch64-unix/opengl32.so",
    "lib64/wine/aarch64-unix/opengl32.so",
]

private let eglLoaderBasename = "win32u.so"
private let eglBackendMarker = Data("libEGL".utf8)

private func artifactLooksFEXCoreDisabled(_ artifactData: Data) -> Bool {
    guard !fexcoreDisabledMarker.isEmpty else {
        return false
    }
    return artifactData.range(of: fexcoreDisabledMarker) != nil
}

private struct EmbeddedGuestWineLoaderAnalysis {
    let isX8664ELF: Bool
    let hasProgramInterpreter: Bool
    let programInterpreterPath: String?
}

private func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 1 < bytes.count else {
        return nil
    }

    return UInt16(bytes[offset])
        | (UInt16(bytes[offset + 1]) << 8)
}

private func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 3 < bytes.count else {
        return nil
    }

    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func littleEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
    guard offset >= 0, offset + 7 < bytes.count else {
        return nil
    }

    var value: UInt64 = 0
    for index in 0..<8 {
        value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    }
    return value
}

private func analyzeEmbeddedGuestWineLoader(_ data: Data) -> EmbeddedGuestWineLoaderAnalysis {
    let bytes = Array(data.prefix(4096))
    let isX8664ELF =
        bytes.count >= 20
        && bytes[0] == 0x7f
        && bytes[1] == 0x45
        && bytes[2] == 0x4c
        && bytes[3] == 0x46
        && bytes[4] == 0x02
        && bytes[5] == 0x01
        && bytes[18] == 0x3e
        && bytes[19] == 0x00
    guard isX8664ELF else {
        return EmbeddedGuestWineLoaderAnalysis(
            isX8664ELF: false,
            hasProgramInterpreter: false,
            programInterpreterPath: nil
        )
    }

    var hasProgramInterpreter = false
    var programInterpreterPath: String?
    if bytes.count >= 64,
        let ePhOff = littleEndianUInt64(bytes, at: 32),
        let ePhEntSize = littleEndianUInt16(bytes, at: 54),
        let ePhNum = littleEndianUInt16(bytes, at: 56),
        ePhOff > 0,
        ePhEntSize >= 40,
        ePhNum > 0,
        ePhOff <= UInt64(bytes.count)
    {
        let phOff = Int(ePhOff)
        let entrySize = Int(ePhEntSize)
        let entryCount = Int(ePhNum)
        let tableSize = entrySize.multipliedReportingOverflow(by: entryCount)
        if !tableSize.overflow, tableSize.partialValue <= bytes.count - phOff {
            for index in 0..<entryCount {
                let offset = phOff + (index * entrySize)
                guard let pType = littleEndianUInt32(bytes, at: offset) else {
                    break
                }

                let pFilesz = littleEndianUInt64(bytes, at: offset + 32) ?? 0
                if pType == 3 && pFilesz > 0 {
                    hasProgramInterpreter = true
                    if let pOffset = littleEndianUInt64(bytes, at: offset + 8),
                        pOffset < UInt64(bytes.count)
                    {
                        let start = Int(pOffset)
                        let length = min(Int(pFilesz), bytes.count - start)
                        let rawInterpreter = bytes[start..<start + length].prefix { $0 != 0 }
                        if !rawInterpreter.isEmpty {
                            programInterpreterPath = String(
                                decoding: rawInterpreter, as: UTF8.self)
                        }
                    }
                    break
                }
            }
        }
    }

    return EmbeddedGuestWineLoaderAnalysis(
        isX8664ELF: true,
        hasProgramInterpreter: hasProgramInterpreter,
        programInterpreterPath: programInterpreterPath
    )
}

private func dataLooksEmbeddedGuestWineLoader(_ data: Data) -> Bool {
    let analysis = analyzeEmbeddedGuestWineLoader(data)
    return analysis.isX8664ELF && !analysis.hasProgramInterpreter
}

private func dataLooksUnixWineLoaderCompanion(_ data: Data) -> Bool {
    analyzeEmbeddedGuestWineLoader(data).isX8664ELF
}

private func dataLooksEGLCapableLoader(_ data: Data) -> Bool {
    data.range(of: eglBackendMarker) != nil
}

private func stagedInterpreterExists(
    _ interpreterPath: String,
    stagedUserlandRootURL: URL,
    fileManager: FileManager
) -> Bool {
    let relativePath = interpreterPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !relativePath.isEmpty else {
        return false
    }
    return fileManager.fileExists(
        atPath: stagedUserlandRootURL.appending(path: relativePath).path)
}

private func describeBinaryContainer(_ data: Data) -> String {
    let bytes = Array(data.prefix(20))
    guard !bytes.isEmpty else {
        return "unreadable"
    }

    let analysis = analyzeEmbeddedGuestWineLoader(data)
    if analysis.isX8664ELF {
        return analysis.hasProgramInterpreter ? "x86_64 ELF (PT_INTERP)" : "x86_64 ELF"
    }
    if bytes.count >= 4,
        bytes[0] == 0x7f,
        bytes[1] == 0x45,
        bytes[2] == 0x4c,
        bytes[3] == 0x46
    {
        return "non-x86_64 ELF"
    }
    if bytes.count >= 4 {
        let prefix = Array(bytes[0..<4])
        if prefix == [0xcf, 0xfa, 0xed, 0xfe]
            || prefix == [0xfe, 0xed, 0xfa, 0xcf]
            || prefix == [0xce, 0xfa, 0xed, 0xfe]
            || prefix == [0xfe, 0xed, 0xfa, 0xce]
        {
            return "Mach-O"
        }
    }
    if bytes.count >= 2, bytes[0] == 0x23, bytes[1] == 0x21 {
        return "script"
    }
    return "unknown format"
}

private func resolveEmbeddedGuestWineLoader(
    bundleID: String,
    stagedUserlandRootURL: URL,
    fileManager: FileManager = .default
) -> (relativePath: String?, failure: String?) {
    var incompatibleCandidates: [String] = []

    for relativePath in embeddedGuestWineLoaderRelativePaths {
        let candidateURL = stagedUserlandRootURL.appending(path: relativePath)
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            continue
        }

        guard let data = try? Data(contentsOf: candidateURL, options: [.mappedIfSafe]) else {
            incompatibleCandidates.append("\(relativePath) (unreadable)")
            continue
        }

        if dataLooksEmbeddedGuestWineLoader(data) {
            if relativePath.hasSuffix("wine-preloader")
                || relativePath.hasSuffix("wine64-preloader")
            {
                let companionExists = preloaderCompanionWineLoaderNames.contains { name in
                    let companionURL = candidateURL.deletingLastPathComponent().appending(path: name)
                    guard fileManager.fileExists(atPath: companionURL.path),
                        let companionData = try? Data(
                            contentsOf: companionURL, options: [.mappedIfSafe])
                    else {
                        return false
                    }
                    let companionAnalysis = analyzeEmbeddedGuestWineLoader(companionData)
                    guard companionAnalysis.isX8664ELF else {
                        return false
                    }
                    if companionAnalysis.hasProgramInterpreter {
                        guard let interpreterPath = companionAnalysis.programInterpreterPath,
                            stagedInterpreterExists(
                                interpreterPath,
                                stagedUserlandRootURL: stagedUserlandRootURL,
                                fileManager: fileManager
                            )
                        else {
                            return false
                        }
                    }
                    return true
                }
                if !companionExists {
                    return (
                        nil,
                        "Runtime bundle \(bundleID) staged Wine userland wine-preloader requires a sibling Unix Wine loader and its PT_INTERP ELF interpreter."
                    )
                }
            }
            return (relativePath, nil)
        }

        incompatibleCandidates.append("\(relativePath) (\(describeBinaryContainer(data)))")
    }

    if incompatibleCandidates.isEmpty {
        return (
            nil,
            "Runtime bundle \(bundleID) staged Wine userland is missing an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP (expected lib/wine/x86_64-unix/wine-preloader, lib64/wine/x86_64-unix/wine-preloader, lib/wine/x86_64-unix/wine, lib64/wine/x86_64-unix/wine, bin/wine64, or bin/wine)."
        )
    }

    return (
        nil,
        "Runtime bundle \(bundleID) staged Wine userland does not expose an embedded-FEX-compatible x86_64 ELF Wine loader without PT_INTERP. Found only \(incompatibleCandidates.joined(separator: ", "))."
    )
}

private func resolveWineIOSDriver(
    bundleID: String,
    stagedUserlandRootURL: URL,
    fileManager: FileManager = .default
) -> (relativePath: String?, failure: String?) {
    for relativePath in wineIOSDriverRelativePaths {
        let candidateURL = stagedUserlandRootURL.appending(path: relativePath)
        if fileManager.fileExists(atPath: candidateURL.path) {
            return (relativePath, nil)
        }
    }

    return (
        nil,
        "Runtime bundle \(bundleID) staged Wine userland is missing wineios.drv Unix driver (expected lib/wine/*-unix/wineios.so or lib64/wine/*-unix/wineios.so)."
    )
}

private func resolveOpenGLBackend(
    bundleID: String,
    stagedUserlandRootURL: URL,
    fileManager: FileManager = .default
) -> (relativePath: String?, failure: String?) {
    for relativePath in openGLBackendRelativePaths {
        let candidateURL = stagedUserlandRootURL.appending(path: relativePath)
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            continue
        }
        guard (try? Data(contentsOf: candidateURL, options: [.mappedIfSafe])) != nil else {
            return (
                nil,
                "Runtime bundle \(bundleID) staged Wine userland OpenGL backend \(relativePath) could not be read."
            )
        }
        let eglLoaderRelativePath =
            (relativePath as NSString).deletingLastPathComponent + "/" + eglLoaderBasename
        let eglLoaderURL = stagedUserlandRootURL.appending(path: eglLoaderRelativePath)
        guard fileManager.fileExists(atPath: eglLoaderURL.path) else {
            return (
                nil,
                "Runtime bundle \(bundleID) staged Wine userland OpenGL backend \(relativePath) is missing sibling \(eglLoaderRelativePath)."
            )
        }
        guard
            let eglLoaderData = try? Data(contentsOf: eglLoaderURL, options: [.mappedIfSafe]),
            dataLooksEGLCapableLoader(eglLoaderData)
        else {
            return (
                nil,
                "Runtime bundle \(bundleID) staged Wine userland OpenGL backend \(relativePath) is not EGL-capable."
            )
        }
        return (relativePath, nil)
    }

    return (
        nil,
        "Runtime bundle \(bundleID) staged Wine userland is missing an EGL-capable Wine OpenGL backend (expected lib/wine/*-unix/opengl32.so or lib64/wine/*-unix/opengl32.so with sibling win32u.so containing libEGL linkage)."
    )
}

public protocol RuntimeBundleRegistry: Sendable {
    func availableBundles() throws -> [RuntimeBundleManifest]
    func defaultBundle() throws -> RuntimeBundleManifest?
    @discardableResult
    func provisionDefaultBundle() throws -> RuntimeBundleManifest
}

public protocol RuntimeProvisioningService: Sendable {
    @discardableResult
    func provisionIfNeeded() throws -> RuntimeBundleManifest
}

public enum RuntimeBundleRegistryError: LocalizedError, Sendable {
    case missingExternalBundle(String)
    case invalidExternalBundle(String)

    public var errorDescription: String? {
        switch self {
        case .missingExternalBundle(let message), .invalidExternalBundle(let message):
            return message
        }
    }
}

public struct BundledRuntimeProvisioningService: RuntimeProvisioningService {
    private let registry: any RuntimeBundleRegistry

    public init(registry: any RuntimeBundleRegistry = FileSystemRuntimeBundleRegistry()) {
        self.registry = registry
    }

    @discardableResult
    public func provisionIfNeeded() throws -> RuntimeBundleManifest {
        try registry.provisionDefaultBundle()
    }
}

public struct FileSystemRuntimeBundleRegistry: RuntimeBundleRegistry {
    public static let bundledRuntimeRootEnvironmentKey = "IRIDIUM_BUNDLED_RUNTIME_ROOT"
    public static let bundledRuntimeRootInfoDictionaryKey = "IridiumBundledRuntimeRoot"
    private static let defaultBundleID = "iridium-runtime-base"
    private static let defaultBundleVersion = loadBundledDefaultVersion()

    public let runtimeRootURL: URL?

    public init(runtimeRootURL: URL? = nil) {
        self.runtimeRootURL = runtimeRootURL
    }

    public func availableBundles() throws -> [RuntimeBundleManifest] {
        guard let runtimeRootURL else {
            print("[IridiumRuntime] availableBundles: runtimeRootURL is nil")
            return []
        }

        print("[IridiumRuntime] availableBundles: looking in \(runtimeRootURL.path)")

        guard FileManager.default.fileExists(atPath: runtimeRootURL.path) else {
            print("[IridiumRuntime] availableBundles: runtimeRootURL does not exist")
            return []
        }

        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: runtimeRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.hasDirectoryPath }
        .map { $0.appending(path: "manifest.json") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }

        print("[IridiumRuntime] availableBundles: found \(manifestURLs.count) manifest(s)")

        let decoder = JSONDecoder()
        let manifests = try manifestURLs.compactMap { url -> RuntimeBundleManifest? in
            let data = try Data(contentsOf: url)
            var manifest = try decoder.decode(RuntimeBundleManifest.self, from: data)
            print(
                "[IridiumRuntime] availableBundles: reading manifest from \(url.path), current bundleRootPath=\(manifest.bundleRootPath ?? "nil")"
            )
            let computedBundleRootPath = Self.canonicalBundlePath(
                url.deletingLastPathComponent().path)
            let currentBundleRootPath = manifest.bundleRootPath.map(Self.canonicalBundlePath)
            if currentBundleRootPath != computedBundleRootPath {
                print(
                    "[IridiumRuntime] availableBundles: bundleRootPath mismatch, updating to computed value"
                )
                manifest.bundleRootPath = computedBundleRootPath
            }
            if manifest.supportMetadata["bundleSource"] == nil {
                manifest.supportMetadata["bundleSource"] = "managed-storage"
            }
            return manifest
        }

        print("[IridiumRuntime] availableBundles: returning \(manifests.count) bundle(s)")
        return manifests.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func defaultBundle() throws -> RuntimeBundleManifest? {
        let bundles = try availableBundles()
        return bundles.first(where: { $0.id == Self.defaultManifest.id }) ?? bundles.first
    }

    @discardableResult
    public func provisionDefaultBundle() throws -> RuntimeBundleManifest {
        guard let runtimeRootURL else {
            throw RuntimeBundleRegistryError.missingExternalBundle(
                "Managed runtime storage is not configured; the bundled runtime cannot be provisioned."
            )
        }

        let bundledManifest = try Self.bundledManifest()
        let bundledStagedUserlandRootURL = Self.bundledStagedUserlandRootURL()
        print(
            "[IridiumRuntime] Bundled manifest found: \(bundledManifest.id) v\(bundledManifest.version)"
        )
        let bundleRoot = runtimeRootURL.appending(
            path: bundledManifest.id, directoryHint: .isDirectory)
        let manifestURL = bundleRoot.appending(path: "manifest.json")
        let decoder = JSONDecoder()

        if FileManager.default.fileExists(atPath: manifestURL.path),
            let existingData = try? Data(contentsOf: manifestURL),
            var existingManifest = try? decoder.decode(
                RuntimeBundleManifest.self, from: existingData)
        {
            let decodedManifest = existingManifest
            existingManifest.bundleRootPath = Self.canonicalBundlePath(bundleRoot.path)
            if existingManifest.supportMetadata["bundleSource"] == nil {
                existingManifest.supportMetadata["bundleSource"] = "managed-storage"
            }
            let shouldPersistNormalizedManifest = existingManifest != decodedManifest

            let validation = validateRuntimeBundleInventory(existingManifest)
            let uncompressedTarget = bundleRoot.appending(
                path: "Support/wine-userland", directoryHint: .isDirectory)
            let userlandStaged = FileManager.default.fileExists(atPath: uncompressedTarget.path)
            let userlandArchiveURL = bundleRoot.appending(path: "Userland/wine-userland.tar.zst")
            let userlandArchiveAvailable = FileManager.default.fileExists(
                atPath: userlandArchiveURL.path)

            print(
                "[IridiumRuntime] Checking userlandStaged at target: \(uncompressedTarget.path) -> \(userlandStaged)"
            )

            let manifestMatchesBundled = Self.manifestPayloadIdentityMatches(
                existingManifest,
                bundledManifest
            )

            print(
                "[IridiumRuntime] Runtime bundle payload identity: installed=\(Self.payloadIdentitySummary(for: existingManifest)) bundled=\(Self.payloadIdentitySummary(for: bundledManifest)) matches=\(manifestMatchesBundled)"
            )

            if manifestMatchesBundled, validation.failures.isEmpty,
                managedUserlandRequirementSatisfied(
                    managedUserlandStaged: userlandStaged,
                    appStagedUserlandAvailable: bundledStagedUserlandRootURL != nil,
                    userlandArchiveAvailable: userlandArchiveAvailable
                )
            {
                print("[IridiumRuntime] Existing bundle is valid, using cached version")
                if shouldPersistNormalizedManifest {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(existingManifest).write(to: manifestURL, options: .atomic)
                }
                return existingManifest
            }

            if !manifestMatchesBundled {
                print(
                    "[IridiumRuntime] Existing bundle manifest differs from bundled runtime; refreshing managed copy"
                )
            }

            if shouldPersistNormalizedManifest {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(existingManifest).write(to: manifestURL, options: .atomic)
            }
        }

        print("[IridiumRuntime] Copying bundled runtime to managed storage at: \(bundleRoot.path)")

        let bundledRootURL = try Self.bundledBundleRootURL()
        try FileManager.default.createDirectory(
            at: runtimeRootURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: bundleRoot.path) {
            print("[IridiumRuntime] Removing existing bundle at: \(bundleRoot.path)")
            try FileManager.default.removeItem(at: bundleRoot)
        }
        print("[IridiumRuntime] Starting copy from: \(bundledRootURL.path)")
        try Self.copyDirectory(from: bundledRootURL, to: bundleRoot)

        let uncompressedSource = bundledStagedUserlandRootURL

        if let uncompressedSource {
            print("[IridiumRuntime] Looking for wine userland at: \(uncompressedSource.path)")
        } else {
            print("[IridiumRuntime] No app-staged wine userland root is available in Bundle.main")
        }

        if let uncompressedSource {
            print(
                "[IridiumRuntime] App-staged wine userland available at \(uncompressedSource.path); managed runtime will reference the app-staged copy without duplicating it"
            )
        } else {
            print(
                "[IridiumRuntime] WARNING: IridiumWineUserland NOT FOUND in Bundle.main; managed runtime reuse will rely on the bundled archive path instead."
            )
        }

        print("[IridiumRuntime] Copy completed, reading manifest from: \(manifestURL.path)")

        var manifest = try decoder.decode(
            RuntimeBundleManifest.self, from: Data(contentsOf: manifestURL))
        manifest.bundleRootPath = Self.canonicalBundlePath(bundleRoot.path)
        manifest.supportMetadata["bundleSource"] = "managed-storage"
        try Self.normalizeExecutablePermissions(for: manifest, under: bundleRoot)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let validation = validateRuntimeBundleInventory(manifest)
        guard validation.failures.isEmpty else {
            print(
                "[IridiumRuntime] Validation failed: \(validation.failures.joined(separator: ", "))"
            )
            throw RuntimeBundleRegistryError.invalidExternalBundle(
                validation.failures.joined(separator: " "))
        }

        print("[IridiumRuntime] Provisioning completed successfully")
        return manifest
    }

    public static let defaultManifest = RuntimeBundleManifest(
        id: defaultBundleID,
        name: "Iridium Runtime Base",
        version: defaultBundleVersion,
        descriptor: .defaultDescriptor,
        artifacts: [
            RuntimeArtifact(
                identifier: "runtime-host-binary",
                relativePath: "Runtime/runtime-host.bin",
                sizeBytes: Int64(defaultArtifactPayload(for: "runtime-host-binary").count),
                checksum: sha256(defaultArtifactPayload(for: "runtime-host-binary")),
                kind: .runtimeBinary
            ),
            RuntimeArtifact(
                identifier: "x64-jit-translator",
                relativePath: "Translator/x64-jit.bin",
                sizeBytes: Int64(defaultArtifactPayload(for: "x64-jit-translator").count),
                checksum: sha256(defaultArtifactPayload(for: "x64-jit-translator")),
                kind: .translationLayer
            ),
            RuntimeArtifact(
                identifier: "wine-userland",
                relativePath: "Userland/wine-userland.tar.zst",
                sizeBytes: Int64(defaultArtifactPayload(for: "wine-userland").count),
                checksum: sha256(defaultArtifactPayload(for: "wine-userland")),
                kind: .userlandPayload
            ),
            RuntimeArtifact(
                identifier: "vkd3d-stack",
                relativePath: "Graphics/vkd3d-stack.json",
                sizeBytes: Int64(defaultArtifactPayload(for: "vkd3d-stack").count),
                checksum: sha256(defaultArtifactPayload(for: "vkd3d-stack")),
                kind: .graphicsStack
            ),
            RuntimeArtifact(
                identifier: "ios-presentation-backend",
                relativePath: "Graphics/ios-presentation-backend.json",
                sizeBytes: Int64(defaultArtifactPayload(for: "ios-presentation-backend").count),
                checksum: sha256(defaultArtifactPayload(for: "ios-presentation-backend")),
                kind: .graphicsStack
            ),
            RuntimeArtifact(
                identifier: "direct-launch-profile",
                relativePath: "Metadata/direct-launch.json",
                sizeBytes: Int64(defaultArtifactPayload(for: "direct-launch-profile").count),
                checksum: sha256(defaultArtifactPayload(for: "direct-launch-profile")),
                kind: .metadata
            ),
        ],
        minimumDeviceTier: .tier1,
        supportsDirectGameLaunch: true,
        supportMetadata: [
            "bundleSource": "app-bundled",
            "desktopShellExposure": "blocked",
            "engineFamily": "wine-derived",
            "launchMode": "direct-executable-only",
            "runtimeHostContractVersion": "1",
            "supportedArchitectures": "x64",
            "supportedGraphicsAPIs": "opengl",
            "translatorBackend": "fex-derived",
        ]
    )

    private static func bundledBundleRootURL() throws -> URL {
        if let overrideRoot = resolveBundledRuntimeRootOverride() {
            let manifestURL = overrideRoot.appending(path: "manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw RuntimeBundleRegistryError.missingExternalBundle(
                    "Configured bundled runtime override is missing manifest.json at \(manifestURL.path)."
                )
            }
            return overrideRoot
        }

        guard let resourceRoot = Bundle.module.resourceURL else {
            throw RuntimeBundleRegistryError.missingExternalBundle(
                "Bundled runtime resources are unavailable.")
        }

        let bundleRoot =
            resourceRoot
            .appending(path: "BundledRuntime", directoryHint: .isDirectory)
            .appending(path: defaultBundleID, directoryHint: .isDirectory)

        guard FileManager.default.fileExists(atPath: bundleRoot.path) else {
            throw RuntimeBundleRegistryError.missingExternalBundle(
                "Bundled runtime resources are missing at \(bundleRoot.path)."
            )
        }

        return bundleRoot
    }

    private static func resolveBundledRuntimeRootOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> URL? {
        let rawPath =
            (environment[bundledRuntimeRootEnvironmentKey]
            ?? infoDictionary?[bundledRuntimeRootInfoDictionaryKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rawPath, !rawPath.isEmpty else {
            return nil
        }

        let bundleURL = Bundle.main.bundleURL
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        } else {
            return bundleURL.appendingPathComponent(rawPath, isDirectory: true)
        }
    }

    private static func bundledStagedUserlandRootURL() -> URL? {
        bundledAppStagedUserlandRootURL()
    }

    private static func loadBundledDefaultVersion() -> String {
        let fallbackVersion = "2026.04.01-dev-refresh"
        guard
            let resourceRoot = Bundle.module.resourceURL,
            FileManager.default.fileExists(atPath: resourceRoot.path)
        else {
            return fallbackVersion
        }

        let manifestURL =
            resourceRoot
            .appending(path: "BundledRuntime", directoryHint: .isDirectory)
            .appending(path: defaultBundleID, directoryHint: .isDirectory)
            .appending(path: "manifest.json")

        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(RuntimeBundleManifest.self, from: data)
        else {
            return fallbackVersion
        }

        return manifest.version
    }

    private static func bundledManifest() throws -> RuntimeBundleManifest {
        let bundleRoot = try bundledBundleRootURL()
        let manifestURL = bundleRoot.appending(path: "manifest.json")
        var manifest = try JSONDecoder().decode(
            RuntimeBundleManifest.self, from: Data(contentsOf: manifestURL))
        manifest.bundleRootPath = canonicalBundlePath(bundleRoot.path)
        if manifest.supportMetadata["bundleSource"] == nil {
            manifest.supportMetadata["bundleSource"] = "app-bundled"
        }
        return manifest
    }

    private static func canonicalBundlePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func manifestPayloadIdentityMatches(
        _ installed: RuntimeBundleManifest,
        _ bundled: RuntimeBundleManifest
    ) -> Bool {
        var installedMetadata = installed.supportMetadata
        var bundledMetadata = bundled.supportMetadata
        installedMetadata["bundleSource"] = nil
        bundledMetadata["bundleSource"] = nil

        return installed.id == bundled.id
            && installed.name == bundled.name
            && installed.version == bundled.version
            && installed.descriptor == bundled.descriptor
            && installed.artifacts == bundled.artifacts
            && installed.minimumDeviceTier == bundled.minimumDeviceTier
            && installed.supportsDirectGameLaunch == bundled.supportsDirectGameLaunch
            && installedMetadata == bundledMetadata
    }

    private static func payloadIdentitySummary(for manifest: RuntimeBundleManifest) -> String {
        let userland = manifest.artifacts.first { $0.identifier == "wine-userland" }
        let userlandChecksum = userland?.checksum ?? "missing"
        let userlandSize = userland.map { String($0.sizeBytes) } ?? "missing"
        return "\(manifest.id)@\(manifest.version):wine-userland=\(userlandChecksum):\(userlandSize)"
    }

    private static func copyDirectory(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func normalizeExecutablePermissions(
        for manifest: RuntimeBundleManifest, under bundleRoot: URL
    ) throws {
        for artifact in manifest.artifacts {
            guard
                artifact.kind == .runtimeBinary || artifact.kind == .translationLayer
                    || artifact.kind == .executable
            else {
                continue
            }

            let artifactPath = bundleRoot.appending(path: artifact.relativePath).path
            guard FileManager.default.fileExists(atPath: artifactPath) else {
                continue
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: artifactPath)
        }
    }

    private static func defaultArtifactPayload(for identifier: String) -> Data {
        let payload: String
        switch identifier {
        case "runtime-host-binary":
            payload = "iridium-runtime-host\nversion=\(defaultBundleVersion)\nmode=direct-launch\n"
        case "x64-jit-translator":
            payload = "iridium-x64-jit\nversion=\(defaultBundleVersion)\narch=x64-arm64\n"
        case "wine-userland":
            payload = "iridium-userland\nwine=staging-9.5\nshell=disabled\n"
        case "vkd3d-stack":
            payload = "{\"stack\":\"vkd3d-via-moltenvk\",\"version\":\"\(defaultBundleVersion)\"}\n"
        case "ios-presentation-backend":
            payload = """
                {"backend":"wineios.drv","frameTransport":"shared-host-framebuffer","graphicsAPI":"opengl","presentable":true,"requires":["wineios.drv","opengl32-unix","egl"]}
                \n
                """
        case "direct-launch-profile":
            payload = """
                {"blockedEntryPoints":["explorer.exe","cmd.exe","powershell.exe","steam.exe"],"directLaunchOnly":true,"supportsArchitectures":["x64"]}
                \n
                """
        default:
            payload = "iridium-artifact\nidentifier=\(identifier)\n"
        }
        return Data(payload.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol RuntimeValidationService: Sendable {
    func validate(snapshot: HostCapabilitySnapshot) async -> RuntimeHealthReport
}

public struct DefaultRuntimeValidationService: RuntimeValidationService {
    public init() {}

    public func validate(snapshot: HostCapabilitySnapshot) async -> RuntimeHealthReport {
        var notes: [String] = []
        var evidence: [String] = []
        let bundleValidation = snapshot.selectedRuntimeBundle.map {
            validateRuntimeBundleInventory($0, hostSnapshot: snapshot)
        }

        print(
            "[IridiumRuntime] validate: selectedBundle=\(snapshot.selectedRuntimeBundle?.id ?? "nil")"
        )
        print("[IridiumRuntime] validate: jitStatus=\(String(describing: snapshot.jitStatus))")
        print(
            "[IridiumRuntime] validate: executionEnvironment=\(String(describing: snapshot.executionEnvironment))"
        )
        print(
            "[IridiumRuntime] validate: bundleValidation failures=\(bundleValidation?.failures ?? [])"
        )

        if let bundle = snapshot.selectedRuntimeBundle {
            notes.append("Runtime bundle \(bundle.name) \(bundle.version) is registered.")
            evidence.append(contentsOf: bundleValidation?.evidence ?? [])
            notes.append(contentsOf: bundleValidation?.warnings ?? [])
            notes.append(contentsOf: bundleValidation?.failures ?? [])
        } else {
            notes.append("No runtime bundle is available.")
        }

        switch snapshot.executionEnvironment {
        case .nativeRuntime:
            notes.append("Host is configured for native runtime execution.")
        case .macOSDevelopmentFallback:
            notes.append(
                "macOS host is in explicit development fallback mode; runtime readiness is non-production."
            )
        case .simulatorDevelopmentFallback:
            notes.append(
                "Simulator host is in explicit development fallback mode; runtime readiness is non-production."
            )
        case .unavailable:
            notes.append("Runtime execution backend is unavailable on this host.")
        }

        if snapshot.runtimeBridgeAvailable {
            evidence.append("runtime-bridge:available")
        } else if snapshot.runtimeBridgeStale {
            notes.append("Runtime bridge heartbeat is stale.")
        }

        if snapshot.launchReady == false {
            notes.append(
                snapshot.launchStatusSummary
                    ?? "Embedded runtime launch support is unavailable in this build."
            )
        }

        if snapshot.launchReady == true {
            if snapshot.runtimeMilestoneVerificationPending {
                notes.append(
                    snapshot.launchStatusSummary
                        ?? "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified."
                )
            }

            if snapshot.playabilityReady == false {
                notes.append(
                    "Embedded launch bootstrap is ready, but the runtime is not yet playable on this host."
                )
            }

            if let presentation = snapshot.presentationReadiness {
                if presentation.ready == true {
                    evidence.append("presentation:\(presentation.status ?? "ready")")
                } else if presentation.isBlocked {
                    notes.append(
                        presentation.statusSummary
                            ?? "Guest presentation path is not ready on this host."
                    )
                }
            }

            if let input = snapshot.inputReadiness {
                if input.ready == true {
                    evidence.append("input:\(input.status ?? "ready")")
                } else if input.isBlocked {
                    notes.append(
                        input.statusSummary
                            ?? "Guest input path is not ready on this host."
                    )
                }
            }

            if let audio = snapshot.audioReadiness {
                if audio.ready == true {
                    evidence.append("audio:\(audio.status ?? "ready")")
                } else if audio.isBlocked {
                    notes.append(
                        audio.statusSummary
                            ?? "Guest audio path is not ready on this host."
                    )
                }
            }
        }

        if snapshot.steamBridgeAvailable {
            evidence.append("steam-bridge:available")
        } else if snapshot.steamBridgeStale {
            notes.append("Steam bridge heartbeat is stale.")
        } else {
            notes.append("Steam bridge heartbeat is missing.")
        }

        if snapshot.launchStatus == "xcodeDebugCheckOnly" {
            notes.append(
                snapshot.jitSummary
                    ?? snapshot.launchStatusSummary
                    ?? "Xcode-attached JIT checks use lightweight debugger detection only."
            )
        } else {
            switch snapshot.jitStatus {
            case .ready:
                if snapshot.runtimeMilestones?.fullyVerified == true {
                    notes.append("Runtime verified through Wine startup and first guest frame.")
                } else {
                    notes.append(
                        snapshot.launchStatusSummary
                            ?? "JIT is attached and the embedded bootstrap is ready; runtime execution is not yet verified through first frame."
                    )
                }
            case .required:
                notes.append("No external debugger/JIT session detected.")
            case .unavailable:
                notes.append("Debugger session detected, but executable code allocation still failed.")
            }
        }

        if snapshot.lowPowerModeEnabled {
            notes.append("Low power mode is enabled.")
        }

        switch snapshot.thermalState {
        case .nominal:
            notes.append("Thermal pressure is nominal.")
        case .elevated:
            notes.append("Thermal pressure is elevated.")
        case .serious:
            notes.append("Thermal pressure is serious.")
        case .critical:
            notes.append("Thermal pressure is critical.")
        }

        let status: RuntimeHealthStatus
        if snapshot.selectedRuntimeBundle == nil
            || snapshot.jitStatus == .unavailable
            || snapshot.executionEnvironment == .unavailable
            || snapshot.launchReady == false
            || !(bundleValidation?.failures.isEmpty ?? false)
        {
            status = .actionRequired
        } else if snapshot.jitStatus != .ready
            || snapshot.runtimeMilestoneVerificationPending
            || snapshot.playabilityReady == false
            || snapshot.lowPowerModeEnabled
            || snapshot.thermalState == .elevated
            || snapshot.thermalState == .serious
            || snapshot.thermalState == .critical
            || !(bundleValidation?.warnings.isEmpty ?? true)
            || snapshot.executionEnvironment != .nativeRuntime
            || (snapshot.backendMode == .development && snapshot.runtimeBridgeStale)
        {
            status = .degraded
        } else {
            status = .healthy
        }

        return RuntimeHealthReport(
            status: status,
            runtimeName: snapshot.selectedRuntimeBundle?.name
                ?? BundledRuntimeCatalog.defaultRuntime.name,
            runtimeBundleIdentifier: snapshot.selectedRuntimeBundle?.id,
            runtimeBundleVersion: snapshot.selectedRuntimeBundle?.version,
            validationEvidence: snapshot.runtimeBundles.map { "\($0.id)@\($0.version)" } + evidence,
            activeConstraints: snapshot.constraints,
            notes: notes,
            lastValidatedAt: Date()
        )
    }
}

struct RuntimeBundleInventoryValidation: Sendable {
    var evidence: [String]
    var warnings: [String]
    var failures: [String]
}

func validateRuntimeBundleInventory(
    _ bundle: RuntimeBundleManifest,
    hostSnapshot: HostCapabilitySnapshot? = nil,
    fileManager: FileManager = .default,
    appStagedUserlandRootURL: URL? = bundledAppStagedUserlandRootURL()
) -> RuntimeBundleInventoryValidation {
    var evidence: [String] = []
    var warnings: [String] = []
    var failures: [String] = []

    if !bundle.supportsDirectGameLaunch {
        failures.append("Runtime bundle \(bundle.id) does not declare direct-launch capability.")
    } else {
        evidence.append("direct-launch:enabled")
    }

    if bundle.descriptor.exposesDesktopShell {
        failures.append("Runtime bundle \(bundle.id) exposes a desktop shell and is rejected.")
    } else {
        evidence.append("desktop-shell:blocked")
    }

    if let hostSnapshot {
        evidence.append("device-tier:\(hostSnapshot.deviceTier.rawValue)")
    }

    guard let bundleRootPath = bundle.bundleRootPath else {
        failures.append(
            "Runtime bundle \(bundle.id) is missing bundleRootPath and cannot be validated from managed storage."
        )
        return RuntimeBundleInventoryValidation(
            evidence: evidence, warnings: warnings, failures: failures)
    }

    for requirement in requiredRuntimeArtifacts {
        guard
            let artifact = bundle.artifacts.first(where: { $0.identifier == requirement.identifier }
            )
        else {
            failures.append(
                "Runtime bundle \(bundle.id) is missing required artifact declaration \(requirement.identifier)."
            )
            continue
        }

        guard artifact.relativePath == requirement.relativePath else {
            failures.append(
                "Runtime bundle \(bundle.id) declares \(requirement.identifier) at \(artifact.relativePath), expected \(requirement.relativePath)."
            )
            continue
        }

        guard artifact.kind == requirement.kind else {
            failures.append(
                "Runtime bundle \(bundle.id) declares \(requirement.identifier) as \(artifact.kind.rawValue), expected \(requirement.kind.rawValue)."
            )
            continue
        }
    }

    let bundleRootURL = URL(fileURLWithPath: bundleRootPath, isDirectory: true)
    guard fileManager.fileExists(atPath: bundleRootURL.path) else {
        failures.append("Runtime bundle root is missing at \(bundleRootURL.path).")
        return RuntimeBundleInventoryValidation(
            evidence: evidence, warnings: warnings, failures: failures)
    }

    let availableAppStagedUserlandRootURL = appStagedUserlandRootURL.flatMap { candidate in
        fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    for artifact in bundle.artifacts {
        let artifactURL = bundleRootURL.appending(path: artifact.relativePath)
        guard fileManager.fileExists(atPath: artifactURL.path) else {
            if artifact.identifier == "wine-userland",
                bundle.supportMetadata["userlandDelivery"] == "app-staged-extracted",
                availableAppStagedUserlandRootURL != nil
            {
                evidence.append("artifact:wine-userland:app-staged")
                continue
            }
            failures.append(
                "Missing runtime artifact \(artifact.identifier) at \(artifact.relativePath).")
            continue
        }

        do {
            let data = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if checksum.caseInsensitiveCompare(artifact.checksum) != .orderedSame {
                let acceptedResignedRuntimeHost: Bool
                if artifact.identifier == "runtime-host-binary",
                   let expectedInvariantChecksum =
                       bundle.supportMetadata[runtimeHostCodeSignatureInvariantChecksumKey],
                   let actualInvariantChecksum = codeSignatureInvariantMachOChecksum(data) {
                    acceptedResignedRuntimeHost =
                        actualInvariantChecksum.caseInsensitiveCompare(expectedInvariantChecksum)
                        == .orderedSame
                } else {
                    acceptedResignedRuntimeHost = false
                }

                guard acceptedResignedRuntimeHost else {
                    failures.append("Checksum mismatch for runtime artifact \(artifact.identifier).")
                    continue
                }
                evidence.append("artifact:\(artifact.identifier):code-signature-invariant")
            } else {
                evidence.append("artifact:\(artifact.identifier):ok")
            }

            if artifactLooksFEXCoreDisabled(data) {
                if artifact.identifier == "x64-jit-translator" {
                    failures.append(
                        "Runtime bundle \(bundle.id) translator artifact \(artifact.relativePath) appears to be compiled without FEXCore support."
                    )
                    continue
                }
                if artifact.identifier == "runtime-host-binary" {
                    failures.append(
                        "Runtime bundle \(bundle.id) runtime host artifact \(artifact.relativePath) appears to be compiled without FEXCore support."
                    )
                    continue
                }
            }

        } catch {
            failures.append(
                "Failed to read runtime artifact \(artifact.identifier): \(error.localizedDescription)"
            )
        }
    }

    let managedStagedUserlandRootURL = bundleRootURL.appending(
        path: "Support/wine-userland", directoryHint: .isDirectory)
    let stagedUserlandRootURL = fileManager.fileExists(atPath: managedStagedUserlandRootURL.path)
        ? managedStagedUserlandRootURL
        : availableAppStagedUserlandRootURL
    if let stagedUserlandRootURL {
        evidence.append(
            stagedUserlandRootURL == managedStagedUserlandRootURL
                ? "userland-source:managed-storage"
                : "userland-source:app-staged")
        let guestLoaderResolution = resolveEmbeddedGuestWineLoader(
            bundleID: bundle.id,
            stagedUserlandRootURL: stagedUserlandRootURL,
            fileManager: fileManager
        )
        if let relativePath = guestLoaderResolution.relativePath {
            evidence.append("embedded-guest-loader:\(relativePath)")
        } else if let failure = guestLoaderResolution.failure {
            failures.append(failure)
        }

        let wineIOSDriverResolution = resolveWineIOSDriver(
            bundleID: bundle.id,
            stagedUserlandRootURL: stagedUserlandRootURL,
            fileManager: fileManager
        )
        if let relativePath = wineIOSDriverResolution.relativePath {
            evidence.append("wineios-driver:\(relativePath)")
        } else if let failure = wineIOSDriverResolution.failure {
            failures.append(failure)
        }

        let openGLBackendResolution = resolveOpenGLBackend(
            bundleID: bundle.id,
            stagedUserlandRootURL: stagedUserlandRootURL,
            fileManager: fileManager
        )
        if let relativePath = openGLBackendResolution.relativePath {
            evidence.append("opengl-backend:\(relativePath)")
        } else if let failure = openGLBackendResolution.failure {
            failures.append(failure)
        }
    }

    if let launchMode = bundle.supportMetadata["launchMode"] {
        evidence.append("launch-mode:\(launchMode)")
    }

    let auditedMetadataKeys = [
        "engineFamily",
        "translatorBackend",
        "supportedArchitectures",
        "supportedGraphicsAPIs",
        "runtimeHostContractVersion",
    ]

    for key in auditedMetadataKeys {
        guard let value = bundle.supportMetadata[key], !value.isEmpty else {
            warnings.append("Runtime bundle \(bundle.id) does not declare \(key) support metadata.")
            continue
        }
        evidence.append("\(key):\(value)")
    }

    return RuntimeBundleInventoryValidation(
        evidence: evidence, warnings: warnings, failures: failures)
}

private func deviceTierRank(_ tier: DeviceTier) -> Int {
    switch tier {
    case .tier1:
        return 1
    case .tier2:
        return 2
    case .tier3:
        return 3
    }
}
