import Foundation
import Combine
import Security
import Darwin

struct SteamOwnedGame: Decodable, Identifiable {
    let appId: UInt32
    let name: String
    var id: UInt32 { appId }
}

struct SteamDownloadedGame: Decodable {
    let appId: UInt32
    let name: String
    let directory: String
    let executables: [String]
}

struct SteamDownloadSnapshot: Decodable {
    var phase = "signedOut"
    var message = "Sign in to download your Steam games."
    var busy = false
    var signedIn = false
    var accountName: String?
    var error: String?
    var challengeUrl: String?
    var games: [SteamOwnedGame] = []
    var appId: UInt32?
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var installed: SteamDownloadedGame?
}

private enum SteamModuleError: LocalizedError {
    case unavailable, storage, rejected, response
    var errorDescription: String? {
        switch self {
        case .unavailable: "This build is missing its native Steam module. Install a build that includes Steam support."
        case .storage: "The secure Steam session could not be saved. Please sign in again next time."
        case .rejected: "Steam is busy or the session has expired. Wait for the current action or sign in again."
        case .response: "The Steam module returned an unreadable response."
        }
    }
}

// Serializes C ABI access away from the main actor. The framework owns the network tasks.
private actor SteamNativeWorker {
    typealias Input = @convention(c) (UnsafePointer<CChar>?) -> Int32
    typealias Output = @convention(c) () -> UnsafeMutablePointer<CChar>?
    typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private var library: UnsafeMutableRawPointer?
    private var submit: Input?
    private var snapshot: Output?
    private var takeSession: Output?
    private var release: Release?

    func initialize() throws {
        if library != nil { return }
        guard let frameworks = Bundle.main.privateFrameworksURL,
              let handle = dlopen(frameworks.appendingPathComponent("IridiumSteam.framework/IridiumSteam").path, RTLD_NOW | RTLD_LOCAL),
              let initSymbol = dlsym(handle, "iridium_steam_initialize"),
              let submitSymbol = dlsym(handle, "iridium_steam_submit"),
              let snapshotSymbol = dlsym(handle, "iridium_steam_snapshot"),
              let sessionSymbol = dlsym(handle, "iridium_steam_take_session"),
              let freeSymbol = dlsym(handle, "iridium_steam_free")
        else { throw SteamModuleError.unavailable }
        var root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("SteamGames", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var storageValues = URLResourceValues()
        storageValues.isExcludedFromBackup = true
        try root.setResourceValues(storageValues)
        let start = unsafeBitCast(initSymbol, to: Input.self)
        guard root.path.withCString({ start($0) }) == 1 else { throw SteamModuleError.storage }
        // NativeAOT libraries cannot be unloaded while their runtime is alive.
        library = handle
        submit = unsafeBitCast(submitSymbol, to: Input.self)
        snapshot = unsafeBitCast(snapshotSymbol, to: Output.self)
        takeSession = unsafeBitCast(sessionSymbol, to: Output.self)
        release = unsafeBitCast(freeSymbol, to: Release.self)
    }

    func send(_ data: Data) throws {
        try initialize()
        guard let text = String(data: data, encoding: .utf8), text.withCString({ submit?($0) }) == 1
        else { throw SteamModuleError.rejected }
    }
    func read() throws -> Data {
        try initialize()
        guard let pointer = snapshot?() else { throw SteamModuleError.response }
        defer { release?(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }
    func session() -> Data? {
        guard let pointer = takeSession?() else { return nil }
        defer { release?(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }
}

private enum SteamKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "software.iridium.steam",
         kSecAttrAccount as String: "session", kSecAttrSynchronizable as String: false]
    }
    static func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
            else { throw SteamModuleError.storage }
        } else if status != errSecSuccess { throw SteamModuleError.storage }
    }
    static func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SteamModuleError.storage }
        return item as? Data
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamModuleError.storage }
    }
}

@MainActor
final class SteamLibraryModel: ObservableObject {
    static let shared = SteamLibraryModel()
    @Published private(set) var state = SteamDownloadSnapshot()
    @Published var error: String?
    @Published private(set) var starting = false
    private let worker = SteamNativeWorker()
    private var polling: Task<Void, Never>?
    private var didRestore = false
    var busy: Bool { starting || state.busy }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            try await worker.initialize()
            if let saved = try SteamKeychain.load(),
               var command = try JSONSerialization.jsonObject(with: saved) as? [String: String] {
                command["action"] = "restore"
                perform(command)
            }
        } catch { self.error = error.localizedDescription }
    }

    func perform(_ command: [String: Any]) {
        let action = command["action"] as? String
        let control = action == "guard" || action == "cancel"
        guard control || !busy else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        if !control { starting = true; error = nil }
        Task {
            do {
                if action == "signOut" { try SteamKeychain.clear() }
                try await worker.send(data)
                if !control {
                    polling?.cancel()
                    polling = Task { await poll() }
                }
            } catch { self.error = error.localizedDescription }
            starting = false
        }
    }

    private func poll() async {
        do {
            repeat {
                try Task.checkCancellation()
                state = try JSONDecoder().decode(SteamDownloadSnapshot.self, from: await worker.read())
                if let saved = await worker.session() {
                    do { try SteamKeychain.save(saved) }
                    catch { self.error = error.localizedDescription }
                }
                if !state.busy { break }
                try await Task.sleep(for: .milliseconds(500))
            } while !Task.isCancelled
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func pauseForBackground() {
        if state.busy && ["resolving", "downloading", "finalizing"].contains(state.phase) {
            perform(["action": "cancel"])
        }
    }
}
