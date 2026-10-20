// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

enum JITMethod: String, CaseIterable, Identifiable {
    case automatic
    case stikDebug
    case builtIn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .stikDebug: return "StikDebug"
        case .builtIn: return "Built-in StikJIT"
        }
    }
}

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Madeira on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// This iPhone's remote pairing file for Built-in StikJIT. It is a credential
/// for the device itself, so it lives in the Keychain (this device only, while
/// unlocked), as the Steam sign-in token does, and never in Documents, where
/// the Files app and every Windows program in Madeira could read it. Its bytes
/// go only to the bundled helper, over XPC, for one request. A copy an earlier
/// build left at Documents/StikJIT/pairingFile.plist moves into the Keychain
/// and is deleted.
enum JITPairingFileStore {
    private static let service = "MadeiraJITPairing"
    private static let account = "rppairing"
    private static let sourceKey = "madeiraJITPairingSource"

    static var isImported: Bool { (try? data()) != nil }

    /// Files stored before on-device pairing existed were all imported.
    static var source: JITPairingSource? {
        guard isImported else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data {
        moveLegacyFile()
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "No pairing file is stored for this device."])
        }
        return data
    }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "That is not a StikDebug remote pairing file. Create one with iloader and try again."])
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "MadeiraJIT", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "The pairing file could not be saved in the Keychain (\(status)). Unlock this device and try again."])
        }
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    /// Documents/StikJIT/pairingFile.plist, where builds before the Keychain kept it.
    private static var legacyFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    private static func moveLegacyFile() {
        let manager = FileManager.default
        let file = legacyFolder.appendingPathComponent("pairingFile.plist")
        guard manager.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return }
        let kept = UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
        // Deleted only once the Keychain holds it (a locked device keeps it for later).
        if (try? store(data, source: kept)) != nil {
            try? manager.removeItem(at: file)
            if (try? manager.contentsOfDirectory(atPath: legacyFolder.path))?.isEmpty == true {
                try? manager.removeItem(at: legacyFolder)
            }
            LogStore.shared.log("[jit] pairing file moved from Documents into the Keychain")
        }
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum CoordinatorError: LocalizedError {
        case setupRequired(String)
        case pairingMissing
        case scriptMissing

        var errorDescription: String? {
            switch self {
            case .setupRequired(let message): return message
            case .pairingMissing: return "Pair this device or import its pairing file first."
            case .scriptMissing: return "Madeira's JIT script is missing from this installation. Reinstall Madeira."
            }
        }
    }

    /// Why the built-in helper could not reach this device, read from its error.
    enum ConnectionProblem: Equatable {
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts this
        /// pairing (every new pairing replaces the last).
        case pairing

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["connectionreset", "connection reset", "device refused connection"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable", "host unreachable", "no route"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var message: String {
            switch self {
            case .vpn:
                return "Madeira couldn't reach this device. Connect LocalDevVPN, then try again."
            case .pairing:
                return "This device closed the connection, which usually means it no longer accepts Madeira's pairing. Pair again, and check that LocalDevVPN is connected."
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "madeiraJITMethod") }
    }
    @Published private(set) var connectionProblem: ConnectionProblem?
    /// What the last loopback check found (nil: none ran). A JIT failure after it found no
    /// lockdownd is a LocalDevVPN problem whatever the helper's message says: a network
    /// that accepts any connection makes the helper's read end early ("early eof").
    private var enableRequest: UUID?
    private var loopbackAnswered: Bool?
    @Published var showSetup = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var pairingImported = JITPairingFileStore.isImported
    @Published private(set) var pairingSource = JITPairingFileStore.source

    private init() {
        method = UserDefaults.standard.string(forKey: "madeiraJITMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        return StikJITHelper.isAvailable ? .stikDebug : .builtIn
    }

    var automaticDescription: String {
        StikJITHelper.isAvailable
            ? "The selected StikDebug route is detected."
            : "The selected StikDebug route was not detected. Automatic will use the built-in helper."
    }

    func refreshPairingStatus() {
        pairingImported = JITPairingFileStore.isImported
        pairingSource = JITPairingFileStore.source
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard enableRequest == nil, !busy else {
            LogStore.shared.log("[jit-request] ignored overlapping enable request")
            completion(.failure(NSError(domain: "MadeiraJIT", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "A JIT request is already running."])))
            return
        }
        let token = UUID()
        enableRequest = token
        busy = true
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, enableRequest == token else { return }
            enableRequest = nil
            busy = false
            completion(result)
        }
        guard SigningStatus.current.debuggable else {
            finish(.failure(NSError(
                domain: "MadeiraJIT", code: 11,
                userInfo: [NSLocalizedDescriptionKey: SigningStatus.notDebuggableMessage])))
            return
        }
        if StikJITHelper.ready {
            finish(.success(()))
            return
        }
        error = nil
        status = nil
        connectionProblem = nil
        var resultReceived = false
        ensureLoopback(then: { [weak self] restoreOnFailure in
            self?.enableResolved { result in
                guard !resultReceived else { return }
                resultReceived = true
                // Nothing will hold the network open now: put back what the shortcut changed.
                if restoreOnFailure, case .failure = result {
                    JITNetworkShortcut.shared.restoreIfNeeded { finish(result) }
                } else { finish(result) }
            }
        }, stopped: { [weak self] message in
            guard !resultReceived else { return }
            resultReceived = true
            // The shortcut itself failed: say so (no connect action, which would only run
            // it again), skip a JIT attempt that cannot reach the device, and put back
            // whatever it changed before it stopped.
            self?.status = nil
            self?.error = message
            JITNetworkShortcut.shared.restoreIfNeeded {
                finish(.failure(NSError(domain: "MadeiraJIT", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: message])))
            }
        })
    }

    /// PSP holds admission through validation and network restoration. A stale
    /// subscriber can release only the activation it actually acquired.
    func enableForPSP(completion: @escaping (Result<Void, Error>, @escaping IridiumJITCleanup) -> Void) {
        enable { [weak self] result in
            guard let self, case .success = result else { completion(result, { $0() }); return }
            let owner = UUID()
            enableRequest = owner; busy = true
            var releasing = false
            var waiters: [() -> Void] = []
            completion(result, { [weak self] done in
                guard let self, self.enableRequest == owner else { done(); return }
                waiters.append(done)
                guard !releasing else { return }
                releasing = true
                // Admission owns network restoration, not the debugger. Even
                // a successful activation is not permission to send a private
                // detach RPC or replace SIGTRAP. Leave helper/debugger lifecycle
                // to its existing owner, including the already-ready path.
                JITNetworkShortcut.shared.restoreIfNeeded {
                    guard self.enableRequest == owner else { return }
                    self.enableRequest = nil; self.busy = false
                    let callbacks = waiters; waiters = []
                    callbacks.forEach { $0() }
                }
            })
        }
    }

    /// PSP owns a distinct script and the original helper completion. Existing
    /// foreign readiness is never permission to issue our BRK protocol.
    var pspRecoveryPending: Bool { JITNetworkShortcut.shared.pspRecoveryPending }

    func beginPSP(attempt: String, hash: String, script: Data,
                  shouldProceed: @escaping () -> Bool,
                  started: @escaping () -> Void,
                  final: @escaping (Bool, Result<MadeiraJITRequest.Response, Error>) -> Void) -> UUID? {
        guard enableRequest == nil, !busy, !pspRecoveryPending, resolvedMethod == .builtIn,
              SigningStatus.current.debuggable, ir_psp_self_trace_clear(),
              IridiumJITHelperSnapshot.validAttemptID(attempt),
              let pairing = try? JITPairingFileStore.data() else { return nil }
        let owner = UUID(); enableRequest = owner; busy = true
        ensureLoopback(then: { [weak self] _ in
            guard self?.enableRequest == owner, shouldProceed() else {
                final(false, .failure(CancellationError())); return
            }
            var request = MadeiraJITRequest.enable(targetPID: getpid(), pairingData: pairing,
                                                   scriptBase64: script.base64EncodedString())
            request.diagnosticAttemptID = attempt
            request.pspProtocolVersion = 2; request.pspAttemptID = attempt; request.pspScriptSHA256 = hash
            guard ir_psp_self_trace_clear() else { final(false, .failure(CancellationError())); return }
            MadeiraBuiltInJIT.send(request, started: started, completion: { final(true, $0) })
        }, stopped: { message in
            final(false, .failure(NSError(domain: "IridiumPSPJIT", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message])))
        })
        return owner
    }

    func restorePSP(owner: UUID, completion: @escaping (Bool) -> Void) {
        guard enableRequest == owner else { completion(false); return }
        JITNetworkShortcut.shared.restorePSP { [weak self] result in
            guard let self, enableRequest == owner else { completion(false); return }
            if case .done = result { completion(true) } else { completion(false) }
        }
    }

    func releasePSP(owner: UUID) {
        guard enableRequest == owner else { return }
        enableRequest = nil; busy = false
    }

    /// LocalDevVPN's loopback first (milliseconds when it already works). When it does
    /// not answer and the Madeira JIT shortcut is on, the shortcut turns Cellular Data
    /// off without Wi-Fi and connects LocalDevVPN, and the loopback is checked again
    /// while the VPN settles. Either way JIT is then attempted, so a failure still gets
    /// the usual explanation. `proceed`'s argument: the shortcut ran.
    private func ensureLoopback(then proceed: @escaping (Bool) -> Void, stopped: @escaping (String) -> Void) {
        let vpnWasUp = LoopbackProbe.vpnInterfaceUp
        LoopbackProbe.check { [weak self] probe in
            LogStore.shared.log(String(format: "[jit-loopback] %@ in %.0f ms (vpn-interface=%d, %@)",
                                       probe.reachable ? "reachable" : "unreachable", probe.milliseconds,
                                       vpnWasUp ? 1 : 0, probe.detail))
            self?.loopbackAnswered = probe.reachable
            guard let self, !probe.reachable, JITNetworkShortcut.shared.enabled else { proceed(false); return }
            status = "Running the \(JITNetworkShortcut.name) shortcut…"
            JITNetworkShortcut.shared.start { [weak self] outcome in
                if case .failed(let why) = outcome {
                    stopped("Your \(JITNetworkShortcut.name) shortcut stopped: \(why) Check its steps in Shortcuts, then try again.")
                    return
                }
                // LocalDevVPN's Connect returns before its tunnel routes (about 5 s
                // on the 18 Pro): go on the moment lockdownd answers.
                self?.status = "Waiting for LocalDevVPN…"
                let waitStart = CFAbsoluteTimeGetCurrent()
                LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                    LogStore.shared.log(String(format: "[jit-loopback] after the shortcut: %@ after %.1f s (vpn-interface=%d, %@)",
                                               probe.reachable ? "reachable" : "unreachable",
                                               CFAbsoluteTimeGetCurrent() - waitStart,
                                               LoopbackProbe.vpnInterfaceUp ? 1 : 0, probe.detail))
                    self?.loopbackAnswered = probe.reachable
                    proceed(true)
                }
            }
        }
    }

    /// JIT setup's connect action with the Madeira JIT shortcut on: the shortcut connects
    /// LocalDevVPN (turning Cellular Data off without Wi-Fi); then the loopback is checked.
    func connectWithShortcut() {
        guard enableRequest == nil, !busy else { return }
        busy = true
        error = nil
        status = "Running the \(JITNetworkShortcut.name) shortcut…"
        JITNetworkShortcut.shared.start { [weak self] outcome in
            if case .failed(let why) = outcome {
                self?.busy = false
                self?.status = nil
                self?.error = "The \(JITNetworkShortcut.name) shortcut did not run: \(why)."
                return
            }
            LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                self?.busy = false
                if probe.reachable {
                    self?.connectionProblem = nil
                    self?.status = "LocalDevVPN reaches this device."
                } else {
                    self?.status = nil
                    self?.error = ConnectionProblem.vpn.message
                }
            }
        }
    }

    private func enableResolved(_ completion: @escaping (Result<Void, Error>) -> Void) {
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            guard StikJITHelper.isAvailable else {
                let message = IridiumStikDebugRoute.current.unavailableMessage
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            busy = true
            status = "Waiting for StikDebug…"
            StikJITHelper.enableJIT { [weak self] result in
                Task { @MainActor in
                    self?.busy = false
                    self?.status = (try? result.get()).map { _ in "StikDebug is attached." }
                    if case .failure(let failure) = result { self?.error = failure.localizedDescription }
                    completion(result)
                }
            }
        case .builtIn:
            guard JITPairingFileStore.isImported else {
                let message = "Pair this device or import its pairing file to finish Built-in StikJIT setup."
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            enableBuiltIn(completion: completion)
        }
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            status = "Pairing file imported."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in StikJIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        method = .builtIn
        status = "Paired in Madeira."
        error = nil
    }

    func prepareBuiltIn() {
        guard enableRequest == nil, !busy else { return }
        guard SigningStatus.current.debuggable else {
            error = SigningStatus.notDebuggableMessage
            return
        }
        guard MadeiraBuiltInJIT.isAvailable else {
            error = MadeiraBuiltInJIT.unavailableReason
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            return
        }
        busy = true
        error = nil
        connectionProblem = nil
        status = "Checking LocalDevVPN and the Developer Disk Image…"
        MadeiraBuiltInJIT.send(.prepare(pairingData: pairing)) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let response):
                txmPresent = response.txmPresent
                status = response.success ? response.message : nil
                error = response.success ? nil : helperFailure(response.message)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    func enableBuiltIn(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard MadeiraBuiltInJIT.isAvailable else {
            let failure = NSError(
                domain: "MadeiraJIT", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    MadeiraBuiltInJIT.unavailableReason ?? "Built-in JIT is unavailable."])
            error = failure.localizedDescription
            completion(.failure(failure))
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            completion(.failure(CoordinatorError.pairingMissing))
            return
        }
        guard let script = StikJITHelper.scriptData else {
            error = CoordinatorError.scriptMissing.localizedDescription
            completion(.failure(CoordinatorError.scriptMissing))
            return
        }

        busy = true
        error = nil
        status = "Starting Madeira's JIT helper…"
        var readinessTimer: Timer?
        var readinessFinished = false
        MadeiraBuiltInJIT.send(
            .enable(targetPID: getpid(), pairingData: pairing,
                    scriptBase64: script.base64EncodedString()),
            started: { [weak self] in
                self?.status = "Waiting for Madeira's JIT helper to attach…"
                readinessTimer = StikJITHelper.waitForDebugger { [weak self] result in
                    guard !readinessFinished else { return }
                    readinessFinished = true
                    self?.busy = false
                    switch result {
                    case .success:
                        self?.status = "Built-in JIT is attached."
                        self?.error = nil
                    case .failure(let failure):
                        self?.error = failure.localizedDescription
                    }
                    completion(result)
                }
            },
            completion: { [weak self] result in
                switch result {
                case .success(let response):
                    self?.txmPresent = response.txmPresent
                    LogStore.shared.log("[jit-built-in] \(response.message)",
                                        level: response.success ? .success : .error)
                    if !response.success && !readinessFinished, let self {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        busy = false
                        let message = helperFailure(response.message)
                        error = message
                        completion(.failure(NSError(
                            domain: "MadeiraJIT", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: message])))
                    }
                case .failure(let failure):
                    if !readinessFinished {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        self?.busy = false
                        self?.error = failure.localizedDescription
                        completion(.failure(failure))
                    }
                }
            })
    }

    /// The helper's failure as shown: a connection problem gets its plain explanation
    /// (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message) ?? (loopbackAnswered == false ? .vpn : nil)
        return connectionProblem?.message ?? message
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "Resetting the Developer Disk Image cache…"
        MadeiraBuiltInJIT.send(.resetDDI) { [weak self] result in
            self?.busy = false
            switch result {
            case .success(let response):
                self?.status = response.success ? response.message : nil
                self?.error = response.success ? nil : response.message
            case .failure(let failure):
                self?.error = failure.localizedDescription
            }
        }
    }
}

/// LocalDevVPN, which built-in JIT and StikDebug reach the device through: open it to
/// connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Madeira a second later.
    static let connect = URL(string: "localdevvpn://enable?scheme=madeira")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN" }

    static func open() {
        let installed = isInstalled
        LogStore.shared.log("[jit] LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// The fix a JIT connection problem offers: pair again (rejected pairing) and LocalDevVPN.
/// With the Madeira JIT shortcut on, LocalDevVPN is connected by the shortcut, never by
/// its link: `retry` enables JIT again (which runs the shortcut when the loopback does not
/// answer); without it the shortcut runs on its own.
@MainActor func jitConnectionActions(_ problem: JITCoordinator.ConnectionProblem,
                                     retry: (() -> Void)? = nil,
                                     then dismiss: @escaping () -> Void = {}) -> some View {
    Group {
        if problem == .pairing {
            Button(OnDevicePairing.isSupported ? "Pair Again" : "Open JIT Setup") {
                dismiss()
                if OnDevicePairing.isSupported { OnDevicePairing.shared.start() }
                JITCoordinator.shared.showSetup = true
            }
        }
        if JITNetworkShortcut.shared.enabled {
            Button("Connect with \(JITNetworkShortcut.name)") {
                dismiss()
                if let retry { retry() } else { JITCoordinator.shared.connectWithShortcut() }
            }
        } else {
            Button(LocalDevVPN.actionTitle) { dismiss(); LocalDevVPN.open() }
        }
    }
}

struct JITSettingsSection: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared

    var body: some View {
        Section {
            Picker("Connection method", selection: $coordinator.method) {
                ForEach(JITMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }.disabled(coordinator.busy || pairing.active)
            Button {
                coordinator.showSetup = true
            } label: {
                Label("Set Up JIT", systemImage: "bolt.badge.clock")
            }
            if coordinator.method == .automatic {
                Text(coordinator.automaticDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("JIT · Faster Execution")
        }
        JITShortcutSetupContent(inline: false)
    }
}

/// Shared setup controls. Inline content owns no navigation or scrolling container;
/// Settings supplies a Form instead. Both presentations use the same coordinator.
struct JITSetupContent: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var importing = false
    @State private var importError: String?
    @AppStorage(IridiumStikDebugRoute.settingsKey) private var iridiumStikRoute = IridiumStikDebugRoute.standalone.rawValue
    @Binding private var modalPresented: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let inline: Bool

    init(inline: Bool = true, modalPresented: Binding<Bool> = .constant(false)) {
        self.inline = inline
        _modalPresented = modalPresented
    }

    private var pairingLabel: String {
        switch coordinator.pairingSource {
        case .onDevice: return "Paired in Iridium"
        case .imported: return "File imported"
        case nil: return "Not set up"
        }
    }

    var body: some View {
        Group {
            if inline {
                VStack(alignment: .leading) { sections }
                    .buttonStyle(.bordered)
            } else {
                sections.iridiumRowSurface()
            }
        }
        .fileImporter(isPresented: Binding(get: { importing }, set: {
            importing = $0
            modalPresented = $0
        }), allowedContentTypes: [.propertyList, .data]) { result in
            importing = false
            modalPresented = false
            switch result {
            case .success(let url):
                importError = nil
                coordinator.importPairingFile(url)
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError {
                    importError = failure.localizedDescription
                    LogStore.shared.log("[jit-built-in] pairing import failed: \(failure.localizedDescription)",
                                        level: .error)
                }
            }
        }
        .onAppear { coordinator.refreshPairingStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refreshPairingStatus() }
        }
        .onDisappear { modalPresented = false }
    }

    @ViewBuilder private var sections: some View {
        connectionMethod
        if coordinator.method != .builtIn {
            JITSetupGroup("StikDebug route", footer: IridiumStikDebugRoute.current == .standalone
                          ? nil : "Install StikDebug inside the selected container.", inline: inline) {
                Picker("Open StikDebug In", selection: $iridiumStikRoute) {
                    ForEach(IridiumStikDebugRoute.allCases) { route in Text(route.title).tag(route.rawValue) }
                }.disabled(coordinator.busy || pairing.active)
            }
        }
        if coordinator.resolvedMethod == .builtIn {
            builtInPairing
            JITSetupGroup("Check and enable", inline: inline) {
                Button("Check setup") { coordinator.prepareBuiltIn() }
                    .disabled(coordinator.busy || pairing.active || !coordinator.pairingImported)
                Button("Enable JIT") { coordinator.enable { _ in } }
                    .disabled(coordinator.busy || pairing.active || !coordinator.pairingImported)
                Button("Reset Developer Disk Image", role: .destructive) {
                    coordinator.resetDDI()
                }.disabled(coordinator.busy || pairing.active)
            }
        } else {
            stikDebugSetup
        }
        statusContent
    }

    private var connectionMethod: some View {
        JITSetupGroup("Connection method", footer: inline ? nil :
                        "Automatic opens the selected StikDebug route when detected. Otherwise, it uses the built-in helper.",
                      inline: inline) {
            Picker("Method", selection: $coordinator.method) {
                ForEach(JITMethod.allCases) { method in Text(method.title).tag(method) }
            }.disabled(coordinator.busy || pairing.active)
            if coordinator.method == .automatic {
                Text(inline
                     ? (coordinator.resolvedMethod == .stikDebug ? "Automatic uses StikDebug." : "Automatic uses Built-in StikJIT.")
                     : coordinator.automaticDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if inline {
                if coordinator.resolvedMethod == .builtIn, !MadeiraBuiltInJIT.isAvailable {
                    Text(MadeiraBuiltInJIT.unavailableReason ?? "Built-in StikJIT is unavailable.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent(IridiumStikDebugRoute.current == .standalone ? "StikDebug" : "Container route",
                               value: StikJITHelper.isAvailable ? "Detected" : "Not detected")
                LabeledContent("Built-in helper", value: MadeiraBuiltInJIT.isAvailable ? "Available" : "Unavailable")
            }
        }
    }

    private var builtInPairing: some View {
        JITSetupGroup("Built-in StikJIT", footer: OnDevicePairing.isSupported
                      ? (inline ? "Stored in this device’s Keychain." : "The pairing file stays in this device’s Keychain.")
                      : (inline ? "Stored in this device’s Keychain. Pairing here requires iOS 27."
                         : "The pairing file stays in this device’s Keychain. Pairing in Iridium needs iOS 27 or later."), inline: inline) {
            Text(OnDevicePairing.isSupported
                 ? (inline ? "Pair here or import this device’s pairing file."
                    : "1. Pair in Iridium or import this device’s pairing file from a computer.")
                 : (inline ? "Import a pairing file for this device."
                    : "1. Create this device’s pairing file on a computer, then import it."))
                .font(.subheadline)
            LabeledContent("Pairing", value: pairingLabel)
            if OnDevicePairing.isSupported {
                Button(coordinator.pairingSource == .onDevice ? "Pair in Iridium again" : "Pair in Iridium") {
                    importError = nil
                    pairing.start()
                }.disabled(coordinator.busy || pairing.active)
                OnDevicePairingPanel()
            }
            Button("Import pairing file", action: beginImport)
                .disabled(coordinator.busy)
            Link("How to create a pairing file",
                 destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
            Text(inline ? "Then connect LocalDevVPN and enable JIT."
                 : "2. Connect LocalDevVPN, then check setup and enable JIT.").font(.subheadline)
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
        }
    }

    private var stikDebugSetup: some View {
        JITSetupGroup("StikDebug", footer: inline ? nil : "Iridium sends its own JIT script automatically.", inline: inline) {
            Text(inline ? "Import this device’s pairing file into StikDebug, then connect LocalDevVPN."
                 : "Set up this device’s pairing file in StikDebug, connect LocalDevVPN, then enable JIT.")
                .font(.subheadline)
            if StikJITHelper.isAvailable {
                Button("Enable JIT with StikDebug") { coordinator.enable() { _ in } }
                    .disabled(coordinator.busy || pairing.active)
            } else if IridiumStikDebugRoute.current == .standalone {
                Link("Install StikDebug", destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)
            } else {
                Text(IridiumStikDebugRoute.current.unavailableMessage).foregroundStyle(.secondary)
                Link("Get LiveContainer", destination: URL(string: "https://github.com/LiveContainer/LiveContainer/releases/latest")!)
            }
            Link("How to create a pairing file",
                 destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
        }
    }

    @ViewBuilder private var statusContent: some View {
        if let importError {
            JITSetupGroup("Pairing file import", inline: inline) {
                Label(importError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Import another pairing file", action: beginImport)
                    .disabled(coordinator.busy)
            }
        }
        if coordinator.busy {
            JITSetupGroup(inline: inline) { HStack { ProgressView(); Text(coordinator.status ?? "Working…") } }
        } else if let error = coordinator.error {
            JITSetupGroup(inline: inline) {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                if let problem = coordinator.connectionProblem {
                    if problem == .pairing {
                        if OnDevicePairing.isSupported {
                            Button("Pair again") {
                                importError = nil
                                coordinator.method = .builtIn
                                pairing.start()
                            }.disabled(pairing.active)
                        } else {
                            Button("Import pairing file", action: beginImport)
                        }
                    }
                    // Already in setup: recover here instead of opening another setup sheet.
                    jitConnectionActions(.vpn)
                }
            }
        } else if let status = coordinator.status {
            JITSetupGroup(inline: inline) {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        if !inline, let txm = coordinator.txmPresent {
            JITSetupGroup(inline: inline) { LabeledContent("TXM/SPTM", value: txm ? "Present" : "Not present") }
        }
    }

    private func beginImport() {
        importError = nil
        importing = true
        modalPresented = true
    }
}

/// Installation and opt-in share the runtime's persisted shortcut preference.
/// Adding the shortcut does not claim it is installed or enable it automatically.
struct JITShortcutSetupContent: View {
    @ObservedObject private var shortcut = JITNetworkShortcut.shared
    var inline = true

    var body: some View {
        JITSetupGroup("\(JITNetworkShortcut.name) shortcut", footer:
                        inline ? "Connects LocalDevVPN through Shortcuts. Without Wi-Fi, it temporarily turns off cellular data, then restores cellular data and your previous VPN after launch."
                        : "The shortcut briefly opens Shortcuts to connect LocalDevVPN. On cellular without Wi-Fi, it temporarily turns off cellular data. After launch it restores cellular data and the previous VPN connection.",
                      inline: inline) {
            if JITShortcutFile.supported {
                if !inline { Text("Add the shortcut in Shortcuts, then turn it on here.").font(.subheadline) }
                Button {
                    LogStore.shared.log("[jit-shortcut] add: iCloud link")
                    UIApplication.shared.open(JITShortcutFile.iCloudLink)
                } label: {
                    Label("Add the \(JITNetworkShortcut.name) shortcut", systemImage: "plus.square.on.square")
                }
                if let url = JITShortcutFile.url {
                    ShareLink(item: url) {
                        Label(inline ? "Add local copy (offline)" : "No internet connection? Add local copy",
                              systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                Text(inline ? "Requires iOS 27. Connect LocalDevVPN manually."
                     : "This shortcut needs iOS 27 or later. Connect LocalDevVPN manually on this version.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Toggle("Use \(JITNetworkShortcut.name) shortcut", isOn: $shortcut.enabled)
                .disabled(!JITShortcutFile.supported && !shortcut.enabled)
        }
    }
}

/// The same control group can be a native Form section or an inline onboarding group.
private struct JITSetupGroup<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let inline: Bool
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, inline: Bool,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.inline = inline
        self.content = content()
    }

    var body: some View {
        if inline {
            VStack(alignment: .leading) {
                if let title { Text(title).font(.headline).accessibilityAddTraits(.isHeader) }
                content
                if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Section {
                content
            } header: {
                if let title { Text(title) }
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }
}

struct JITSetupView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                JITSetupContent(inline: false)
                JITShortcutSetupContent(inline: false).iridiumRowSurface()
            }
            .iridiumPageSurface().navigationTitle("JIT setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { coordinator.showSetup = false; dismiss() }
                }
            }
        }
    }
}
