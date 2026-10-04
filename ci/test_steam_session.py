"""Execute the production Steam model with synthetic native and Keychain I/O.

No Security framework is imported, no real Keychain is queried, and the native
framework is replaced before compilation. Queue files stay in a temporary root.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'iridium/apps/ios/Iridium'

HOST = r'''
import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
typealias OSStatus = Int32
typealias CFDictionary = [String: Any]
typealias CFTypeRef = AnyObject
let errSecSuccess: OSStatus = 0
let errSecItemNotFound: OSStatus = -25300
let errSecInteractionNotAllowed: OSStatus = -25308
let kSecClass = "class", kSecClassGenericPassword = "generic-password"
let kSecAttrService = "service", kSecAttrAccount = "account", kSecAttrSynchronizable = "sync"
let kSecValueData = "data", kSecAttrAccessible = "accessible"
let kSecAttrAccessibleWhenUnlockedThisDeviceOnly = "unlocked-this-device"
let kSecReturnData = "return-data", kSecMatchLimit = "limit", kSecMatchLimitOne = "one"
enum FixtureKeychain {
    static var stored: Data?
    static var saveStatus = errSecSuccess, loadStatus = errSecSuccess, clearStatus = errSecSuccess
    static var updates = 0, adds = 0, loads = 0, deletes = 0
    static func reset(_ data: Data? = nil) {
        stored = data
        saveStatus = errSecSuccess; loadStatus = errSecSuccess; clearStatus = errSecSuccess
        updates = 0; adds = 0; loads = 0; deletes = 0
    }
    static func validate(_ query: CFDictionary) {
        precondition(query[kSecClass] as? String == kSecClassGenericPassword)
        precondition(query[kSecAttrService] as? String == "software.iridium.steam")
        precondition(query[kSecAttrAccount] as? String == "session")
        precondition(query[kSecAttrSynchronizable] as? Bool == false)
    }
    static func write(_ attributes: CFDictionary) {
        precondition(attributes[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        stored = attributes[kSecValueData] as? Data
    }
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    FixtureKeychain.validate(query); FixtureKeychain.updates += 1
    if FixtureKeychain.stored == nil { return errSecItemNotFound }
    guard FixtureKeychain.saveStatus == errSecSuccess else { return FixtureKeychain.saveStatus }
    FixtureKeychain.write(attributes); return errSecSuccess
}
func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    FixtureKeychain.validate(attributes); FixtureKeychain.adds += 1
    guard FixtureKeychain.saveStatus == errSecSuccess else { return FixtureKeychain.saveStatus }
    FixtureKeychain.write(attributes); return errSecSuccess
}
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    FixtureKeychain.validate(query); FixtureKeychain.loads += 1
    precondition(query[kSecReturnData] as? Bool == true && query[kSecMatchLimit] as? String == kSecMatchLimitOne)
    guard FixtureKeychain.loadStatus == errSecSuccess else { return FixtureKeychain.loadStatus }
    guard let stored = FixtureKeychain.stored else { return errSecItemNotFound }
    result?.pointee = stored as NSData; return errSecSuccess
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    FixtureKeychain.validate(query); FixtureKeychain.deletes += 1
    guard FixtureKeychain.clearStatus == errSecSuccess else { return FixtureKeychain.clearStatus }
    let existed = FixtureKeychain.stored != nil
    FixtureKeychain.stored = nil
    return existed ? errSecSuccess : errSecItemNotFound
}
enum FixtureFiles {
    static let `default` = FixtureFileManager()
    static var root = FileManager.default.temporaryDirectory
}
struct FixtureFileManager {
    func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
             appropriateFor: URL?, create: Bool) throws -> URL { FixtureFiles.root }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        precondition(url.path.hasPrefix(FixtureFiles.root.path + "/"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
}
enum RuntimeLogCapture {
    static var lines: [String] = []
    static var allLines: [String] = []
    static func writeLine(_ line: String) { lines.append(line); allLines.append(line) }
}
@MainActor private final class SteamNativeWorker {
    static var nextSnapshot: [String: Any] = [:]
    static var secret: Data?
    static var commands: [[String: String]] = []
    static var initializeError: Error?, sendError: Error?
    static var handoffs = 0
    static var initializations = 0
    static var runtimePermissions: [Bool] = []
    func batch() async throws -> SteamChunkBatch? { nil }
    func completeBatch(operation: String, batch: String, code: String) async throws {}
    func permitChunkRuntime(_ allowed: Bool) async { Self.runtimePermissions.append(allowed) }
    func initialize() async throws {
        Self.initializations += 1
        await Task.yield()
        if let error = Self.initializeError { throw error }
    }
    func send(_ data: Data) async throws {
        if let error = Self.sendError { throw error }
        let command = try JSONSerialization.jsonObject(with: data) as! [String: String]
        Self.commands.append(command)
        if command["action"] == "signOut" { Self.secret = nil; Self.nextSnapshot = Self.signedOut }
    }
    func read() async throws -> Data { try JSONSerialization.data(withJSONObject: Self.nextSnapshot) }
    func session() async -> Data? {
        let data = Self.secret
        Self.secret = nil
        if data != nil { Self.handoffs += 1 }
        return data
    }
    static var signedOut: [String: Any] {
        ["phase": "signedOut", "message": "Sign in", "busy": false, "signedIn": false,
         "completedBytes": 0, "totalBytes": 0, "networkBytes": 0, "games": []]
    }
    static var ready: [String: Any] {
        var value = signedOut
        value["phase"] = "ready"; value["signedIn"] = true; value["accountName"] = "synthetic-account"
        return value
    }
    static func reset() {
        nextSnapshot = ready; secret = nil; commands = []; handoffs = 0
        initializations = 0; runtimePermissions = []
        SteamBackgroundSession.shared.recoveries = 0; SteamBackgroundSession.shared.cancellations = 0
        SteamDownloadActivity.shared.recoveries = 0
        initializeError = nil; sendError = nil; RuntimeLogCapture.lines = []
    }
}

// Host replacements cover platform I/O only; production model methods run unchanged.
struct UIBackgroundTaskIdentifier: Equatable { static let invalid = Self() }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var isProtectedDataAvailable = true
    func beginBackgroundTask(withName: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}
}
enum LiveContainerIntegration { static func isHosted() -> Bool { false } }
@MainActor final class SteamBackgroundSession {
    static let shared = SteamBackgroundSession()
    var recoveries = 0, cancellations = 0
    func recoverAfterRelaunch() async { recoveries += 1 }
    func cancel(operation: String? = nil, discardRaw: Bool = false) async { cancellations += 1 }
    func enqueue(_ batch: SteamChunkBatch) async throws {}
    func result(operation: String, batch: String) async -> String? { nil }
    func networkBytes(operation: String) async -> Int64 { 0 }
    static func failureCode(_ error: Error) -> String { "io" }
}
@MainActor final class SteamDownloadActivity {
    static let shared = SteamDownloadActivity()
    var recoveries = 0
    func recoverAfterRelaunch() async { recoveries += 1 }
    func begin(_ job: SteamDownloadJob) {}
    func update(_ job: SteamDownloadJob, phase: String? = nil, force: Bool = false) {}
    func end(_ job: SteamDownloadJob) {}
}
@MainActor final class SteamDownloadRuntime {
    static let shared = SteamDownloadRuntime()
    var hasContinuedRuntime = false
    func begin(operation: UUID, name: String, userInitiated: Bool, expiration: @escaping () -> Void) {}
    func finish(operation: UUID, success: Bool) {}
    func progress(operation: UUID, completed: Int64, total: Int64, phase: String) {}
}

'''

CHECKS = r'''
extension SteamLibraryModel {
    func addFixtureJob() {
        queue.isPaused = true
        _ = queue.enqueue(SteamDownloadJob(game: SteamOwnedGame(appId: 42, name: "Fixture"), account: "synthetic-account", options: SteamInstallOptions()))
    }
}
@MainActor @main struct SessionChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else { throw NSError(domain: "SessionChecks", code: 1,
            userInfo: [NSLocalizedDescriptionKey: name]) }
        checks += 1
    }
    static func finish(_ model: SteamLibraryModel) async throws {
        for _ in 0..<10000 {
            if !model.busy { return }
            await Task.yield()
        }
        try check(false, "Synthetic operation did not finish")
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FixtureFiles.root = root
        let saved = Data(#"{"accountName":"synthetic-account","refreshToken":"synthetic-refresh-token"}"#.utf8)
        let rotated = Data(#"{"accountName":"synthetic-account","refreshToken":"synthetic-rotated-token"}"#.utf8)

        // Destructive native handoff + failed add; retry without a second token.
        FixtureKeychain.reset(); SteamNativeWorker.reset()
        FixtureKeychain.saveStatus = errSecInteractionNotAllowed
        SteamNativeWorker.secret = saved
        let signingIn = SteamLibraryModel()
        signingIn.perform(["action": "signIn"])
        try await finish(signingIn)
        try check(signingIn.state.signedIn && FixtureKeychain.stored == nil, "Sign-in succeeds independently of storage")
        try check(SteamNativeWorker.secret == nil && SteamNativeWorker.handoffs == 1, "Native token handed off once")
        try check(signingIn.error?.contains("Keep Iridium open") == true, "Failed persistence stays actionable")
        signingIn.perform(["action": "library"])
        try await finish(signingIn)
        try check(signingIn.error?.contains("Keep Iridium open") == true, "Other actions do not hide failed persistence")
        FixtureKeychain.saveStatus = errSecSuccess
        signingIn.resumeForeground()
        try check(FixtureKeychain.stored == saved && SteamNativeWorker.handoffs == 1, "Retry saves retained token")
        try check(signingIn.error == nil, "Successful retry clears only its storage warning")

        // A background cold launch cannot initialize Steam or restore credentials.
        FixtureKeychain.reset(saved); SteamNativeWorker.reset()
        let suspended = SteamLibraryModel()
        suspended.pauseForBackground()
        await suspended.restore()
        try check(SteamNativeWorker.initializations == 0 && FixtureKeychain.loads == 0,
                  "Background cold restore has no native or Keychain login work")
        suspended.resumeForeground()
        await suspended.restore(); try await finish(suspended)
        try check(suspended.state.signedIn, "Foreground can restore after a background cold launch")

        // A new model cold-restores the saved JSON and preserves the queue.
        SteamNativeWorker.reset()
        let cold = SteamLibraryModel()
        await cold.restore(); try await finish(cold)
        try check(cold.state.signedIn && SteamNativeWorker.commands.last?["refreshToken"] == "synthetic-refresh-token",
                  "Cold restore submits the saved token")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-restore outcome=restored"), "Successful restore is diagnosed")
        let submitted = SteamNativeWorker.commands.count
        await cold.restore()
        try check(SteamNativeWorker.commands.count == submitted, "Successful cold restore is not repeated")

        FixtureKeychain.reset(saved); SteamNativeWorker.reset()
        SteamNativeWorker.nextSnapshot["phase"] = "failed"
        SteamNativeWorker.nextSnapshot["error"] = "synthetic-private-text [steam/syncing/network/80004005]"
        let libraryFailure = SteamLibraryModel()
        await libraryFailure.restore(); try await finish(libraryFailure)
        try check(libraryFailure.state.signedIn && FixtureKeychain.stored == saved,
                  "Library network failure after successful auth is not storage loss")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-restore outcome=restored"),
                  "Library sync failure does not misreport authentication failure")

        // Failed update keeps the previous saved record, then replaces in place.
        FixtureKeychain.reset(saved); SteamNativeWorker.reset()
        FixtureKeychain.saveStatus = errSecInteractionNotAllowed
        SteamNativeWorker.secret = rotated
        let rotating = SteamLibraryModel()
        rotating.perform(["action": "signIn"]); try await finish(rotating)
        try check(FixtureKeychain.stored == saved && FixtureKeychain.adds == 0 && FixtureKeychain.deletes == 0,
                  "Failed update never deletes the existing token")
        FixtureKeychain.saveStatus = errSecSuccess
        rotating.resumeForeground()
        try check(FixtureKeychain.stored == rotated && FixtureKeychain.adds == 0, "Retry updates the same item")

        // Keychain load failure does not mean missing, and remains retryable.
        FixtureKeychain.reset(saved); SteamNativeWorker.reset()
        FixtureKeychain.loadStatus = errSecInteractionNotAllowed
        let locked = SteamLibraryModel()
        await locked.restore()
        try check(SteamNativeWorker.commands.isEmpty && FixtureKeychain.stored == saved, "Failed read retains credentials")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-load outcome=failed status=-25308"), "Read failure has numeric status")
        locked.addFixtureJob()
        FixtureKeychain.loadStatus = errSecSuccess
        await locked.restore(); try await finish(locked)
        try check(locked.state.signedIn && FixtureKeychain.loads == 2, "Same model retries startup Keychain read")
        try check(locked.queue.jobs.count == 1, "Session retry does not reload or erase the current queue")
        try check(SteamBackgroundSession.shared.recoveries == 1 && SteamDownloadActivity.shared.recoveries == 1,
                  "Session retry never repeats daemon or Activity recovery")

        // Missing item is a completed check; corruption is preserved and diagnosed.
        FixtureKeychain.reset(); SteamNativeWorker.reset()
        let missing = SteamLibraryModel()
        await missing.restore(); await missing.restore()
        try check(FixtureKeychain.loads == 1 && SteamNativeWorker.commands.isEmpty, "Missing item does not launch authentication")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-load outcome=missing"), "Missing item is distinct from failure")
        let corrupt = Data("synthetic-corrupt-json".utf8)
        FixtureKeychain.reset(corrupt); SteamNativeWorker.reset()
        await SteamLibraryModel().restore()
        try check(FixtureKeychain.stored == corrupt && FixtureKeychain.deletes == 0, "Malformed saved data is not erased")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-restore outcome=failed stage=saved-data code=invalid-session"), "Corruption is diagnosed without content")

        // Native initialization/submission and network/auth failures all retain
        // storage and allow another cold-restore attempt in this same process.
        for failure in ["initialize", "submit", "network", "authentication"] {
            FixtureKeychain.reset(saved); SteamNativeWorker.reset()
            let model = SteamLibraryModel()
            if failure == "initialize" { SteamNativeWorker.initializeError = SteamModuleError.unavailable }
            else if failure == "submit" { SteamNativeWorker.sendError = SteamModuleError.rejected }
            else {
                SteamNativeWorker.nextSnapshot = SteamNativeWorker.signedOut
                SteamNativeWorker.nextSnapshot["phase"] = "failed"
                SteamNativeWorker.nextSnapshot["error"] = "synthetic-private-text [steam/connecting/\(failure)/80004005]"
            }
            await model.restore(); try await finish(model)
            try check(!model.state.signedIn && FixtureKeychain.stored == saved && FixtureKeychain.deletes == 0,
                      "Failed \(failure) restore does not imply storage loss")
            let expected = failure == "initialize" ? "code=native-unavailable" : failure == "submit" ? "code=submission-rejected" : "code=\(failure)"
            try check(RuntimeLogCapture.lines.contains { $0.contains("session-restore outcome=failed") && $0.contains(expected) },
                      "Fixed failure category for \(failure)")
            SteamNativeWorker.initializeError = nil; SteamNativeWorker.sendError = nil
            SteamNativeWorker.nextSnapshot = SteamNativeWorker.ready
            await model.restore(); try await finish(model)
            try check(model.state.signedIn, "Same process can retry \(failure) restore")
        }

        // An explicit sign-out clears an unsaved handoff, so later foreground
        // retries and a fresh model cannot recreate the credential.
        FixtureKeychain.reset(); SteamNativeWorker.reset()
        FixtureKeychain.saveStatus = errSecInteractionNotAllowed
        SteamNativeWorker.secret = saved
        let signingOut = SteamLibraryModel()
        signingOut.perform(["action": "signIn"]); try await finish(signingOut)
        signingOut.perform(["action": "signOut"])
        signingOut.resumeForeground()
        try await finish(signingOut)
        FixtureKeychain.saveStatus = errSecSuccess
        let writes = FixtureKeychain.updates
        signingOut.resumeForeground(); await signingOut.restore()
        try check(FixtureKeychain.stored == nil && FixtureKeychain.updates == writes && !signingOut.state.signedIn,
                  "Pending retry cannot resurrect an explicit sign-out")
        await SteamLibraryModel().restore()
        try check(SteamNativeWorker.commands.last?["action"] == "signOut", "Cold launch after sign-out does not restore")

        FixtureKeychain.reset(); SteamNativeWorker.reset()
        FixtureKeychain.saveStatus = errSecInteractionNotAllowed
        SteamNativeWorker.secret = saved
        let rejectedSignOut = SteamLibraryModel()
        rejectedSignOut.perform(["action": "signIn"]); try await finish(rejectedSignOut)
        SteamNativeWorker.sendError = SteamModuleError.rejected
        rejectedSignOut.perform(["action": "signOut"]); try await finish(rejectedSignOut)
        FixtureKeychain.saveStatus = errSecSuccess; SteamNativeWorker.sendError = nil
        rejectedSignOut.resumeForeground()
        rejectedSignOut.perform(["action": "library"]); try await finish(rejectedSignOut)
        try check(FixtureKeychain.stored == nil, "Native sign-out rejection cannot resurrect a discarded handoff")

        FixtureKeychain.reset(saved); SteamNativeWorker.reset()
        FixtureKeychain.clearStatus = errSecInteractionNotAllowed
        let failedSignOut = SteamLibraryModel()
        failedSignOut.perform(["action": "signOut"]); try await finish(failedSignOut)
        try check(FixtureKeychain.stored == saved && SteamNativeWorker.commands.isEmpty, "Failed clear is not reported as sign-out")
        try check(RuntimeLogCapture.lines.contains("[Steam] session-clear outcome=failed status=-25308"), "Failed clear is diagnosed")
        FixtureKeychain.clearStatus = errSecSuccess
        failedSignOut.perform(["action": "signOut"]); try await finish(failedSignOut)
        try check(FixtureKeychain.stored == nil, "Explicit sign-out remains retryable")
        try check(SteamBackgroundSession.shared.cancellations == 2,
                  "Every explicit sign-out attempt cancels raw transfers before credential changes")

        for malicious in ["synthetic-refresh-token", "[steam/private/account/80004005]", "[steam/connecting/network/secret]",
                          "[steam/connecting/network/80004005]/synthetic-account"] {
            try check(SteamSessionDiagnostic.failure(malicious) == "stage=unknown code=request-failed", "Unknown diagnostics are sanitized")
        }
        try check(!RuntimeLogCapture.allLines.joined().contains("synthetic-"), "Session logs contain no token, account or arbitrary error text")
        print("PASS: \(checks) synthetic Steam session checks")
    }
}
'''


class SteamSessionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_cold_session_persistence_and_restore(self):
        model = (APP / 'SteamLibraryModel.swift').read_text()
        start = model.index('// Serializes C ABI access')
        end = model.index('\nprivate ', model.index('\n}\n', start) + 3)
        # Replace only I/O adapters and host-only imports. Execute the entire
        # real model and Keychain logic, including restore, perform and poll.
        model = model[:start] + model[end:]
        for name in ('Combine', 'Security', 'Darwin', 'UIKit'):
            model = model.replace('import ' + name + '\n', '')
        model = model.replace('FileManager.default', 'FixtureFiles.default')
        with tempfile.TemporaryDirectory(prefix='iridium-session-checks-') as directory:
            source = Path(directory) / 'SessionChecks.swift'
            source.write_text(HOST + model + CHECKS)
            binary = Path(directory) / 'session-checks'
            subprocess.run([
                'swiftc', '-swift-version', '5', '-parse-as-library',
                '-module-cache-path', str(Path(directory) / 'module-cache'),
                str(APP / 'SteamDownloadQueue.swift'), str(APP / 'SteamCloudModels.swift'),
                str(APP / 'SteamCloudFileAccess.swift'), str(APP / 'SteamChunkTransfer.swift'), str(source), '-o', str(binary),
            ], check=True, timeout=180)
            subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == '__main__':
    unittest.main()
