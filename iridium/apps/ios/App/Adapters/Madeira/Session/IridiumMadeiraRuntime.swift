// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

/// Madeira owns one Windows host. Games use separate, generation-checked jobs.
final class IridiumMadeiraRuntime: @unchecked Sendable {
    static let shared = IridiumMadeiraRuntime()
    enum Event { case starting, running, ended(UInt32), blocked(String) }
    enum Failure: Error { case busy, invalidRequest, invalidStatus, unsafeDirectory }
    private let root: URL
    private let queue = DispatchQueue(label: "iridium.madeira.session", qos: .userInitiated)
    private let lock = NSLock()
    private var owner: UUID?
    private var poisoned = false
    private var booted = false
    private var initializing = false
    private var pending: Data?
    private var submitted = false
    private var cancelled: UUID?
    private var deadline = TimeInterval.greatestFiniteMagnitude
    private var drainingSince: TimeInterval?
    private var lastPoll: TimeInterval?
    private var lastProgress: TimeInterval = 0
    private var lastModification: Date?
    private let clock: @Sendable () -> TimeInterval
    private var polling = false
    private var nativePending: [String: String] = [:]
    private var nativeOverrides: [(String, String?)] = []
    private let nativeRunning: @Sendable () -> Bool
    private let beginFence: @Sendable () -> Bool
    private let drained: @Sendable () -> Bool

    init(root: URL? = nil,
         nativeRunning: @escaping @Sendable () -> Bool = { wine_process_is_running() != 0 || wineserver_is_running() != 0 },
         beginFence: @escaping @Sendable () -> Bool = { ir_windows_threads_begin() },
         drained: @escaping @Sendable () -> Bool = { ir_windows_threads_drained() },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c/iridium-session", isDirectory: true)
        self.nativeRunning = nativeRunning; self.beginFence = beginFence; self.drained = drained; self.clock = clock
    }
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return poisoned || initializing || owner != nil || (nativeRunning() && !booted) || (booted && !nativeRunning())
    }
    var isResident: Bool { lock.lock(); defer { lock.unlock() }; return booted }
    var requiresRestart: Bool { lock.lock(); defer { lock.unlock() }; return poisoned || initializing || (booted && !nativeRunning()) }
    func noteNativeInitialization() { lock.lock(); initializing = true; lock.unlock() }
    func requestStop(_ token: UUID) {
        lock.lock()
        guard owner == nil || owner == token else { lock.unlock(); return }
        cancelled = token
        lock.unlock()
        queue.async {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.owner == token, self.submitted else { return }
            var request = Self.header(token); request.append(Data(repeating: 0, count: 8))
            do { try request.write(to: self.root.appendingPathComponent("stop.bin"), options: .atomic) }
            catch { self.poisoned = true }
        }
    }


    static func request(executable: String, arguments: String, directory: String, token: UUID, environment: [String: String] = [:]) throws -> Data {
        var data = header(token)
        for (value, capacity) in [(executable, 1024), (arguments, 4096), (directory, 1024)] {
            let units = Array(value.utf16)
            guard units.count < capacity, !units.contains(where: { $0 < 32 || $0 == 127 }),
                  capacity == 4096 || !units.isEmpty else { throw Failure.invalidRequest }
            for value in units + Array(repeating: 0, count: capacity - units.count) {
                data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
            }
        }
        var block: [UInt16] = []
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard !key.isEmpty, !key.contains("="), !key.contains("\u{0}"), !value.contains("\u{0}") else { throw Failure.invalidRequest }
            block += Array((key + "=" + value).utf16) + [0]
        }
        guard block.count < 32767 else { throw Failure.invalidRequest }
        block += Array(repeating: 0, count: 32768 - block.count)
        for value in block { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        return data
    }
    private static let prefix = Data([0x31, 0x57, 0x52, 0x49, 1, 0, 0, 0])
    private static func header(_ token: UUID) -> Data {
        var data = prefix
        var bytes = token.uuid
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        return data
    }
    static func status(_ data: Data, token: UUID?) throws -> (phase: UInt32, result: UInt32)? {
        guard data.count == 32, data.prefix(8) == prefix else { throw Failure.invalidStatus }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
        }
        let phase = word(24)
        guard phase <= 4 else { throw Failure.invalidStatus }
        if let token, data[8..<24] != header(token)[8..<24] { return nil }
        return (phase, word(28))
    }
    /// Called on the existing Windows launch worker, after its profile is applied.
    func submit(_ token: UUID, configuration: [String: String] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil, !poisoned else { throw Failure.busy }
        let executable = getenv("MADEIRA_EXE").map { String(cString: $0) } ?? "cube.exe"
        let arguments = getenv("MADEIRA_ARGS").map { String(cString: $0) } ?? ""
        let directory = getenv("MADEIRA_WORKDIR").map { String(cString: $0) }
            ?? executable.lastIndex(of: "\\").map { String(executable[..<$0]) } ?? "C:\\windows\\system32"
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            ["MADEIRA_", "FEX_", "DXMT_", "DXVK_", "VKD3D_"].contains(where: key.hasPrefix)
        }.merging(configuration) { _, value in value }
        if let id = environment["MADEIRA_STEAM_APPID"] { environment["SteamAppId"] = id; environment["SteamGameId"] = id }
        if let path = environment["MADEIRA_STEAM_APPPATH"] { environment["SteamAppPath"] = path }
        let request = try Self.request(executable: executable, arguments: arguments, directory: directory, token: token, environment: environment)
        nativePending = configuration
        for key in ["MADEIRA_CFG_GAME", "MADEIRA_STEAM_APPID", "MADEIRA_STEAM_APPPATH"] {
            if let value = getenv(key) { nativePending[key] = String(cString: value) }
        }
        let fm = FileManager.default
        for directory in [root, root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()] {
            if (try? fm.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw Failure.unsafeDirectory }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent(".iridium-session-owner")
        let identity = Data("Iridium Windows session 1\n".utf8)
        if fm.fileExists(atPath: marker.path) {
            guard (try fm.attributesOfItem(atPath: marker.path)[.type]) as? FileAttributeType == .typeRegular else { throw Failure.unsafeDirectory }
            let file = try FileHandle(forReadingFrom: marker)
            defer { try? file.close() }
            guard try file.read(upToCount: identity.count + 1) == identity else { throw Failure.unsafeDirectory }
        } else {
            guard fm.enumerator(atPath: root.path)?.nextObject() == nil else { throw Failure.unsafeDirectory }
            try identity.write(to: marker, options: .withoutOverwriting)
        }
        if !booted {
            for name in ["request.bin", "status.bin", "status.tmp", "stop.bin"] {
                let path = root.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) { try fm.removeItem(at: path) }
            }
        }
        owner = token; pending = request; submitted = false; drainingSince = nil
        deadline = clock() + 120; lastProgress = clock(); lastPoll = nil; lastModification = nil
        if booted { try publishRequest() }
    }
    private func publishRequest() throws {
        if cancelled == owner { pending = nil; return }
        guard let pending, beginFence(), !FileManager.default.fileExists(atPath: root.appendingPathComponent("request.bin").path) else { throw Failure.busy }
        for (key, value) in nativePending {
            nativeOverrides.append((key, getenv(key).map { String(cString: $0) }))
            setenv(key, value, 1)
        }
        nativePending = [:]
        try pending.write(to: root.appendingPathComponent("request.bin"), options: .atomic)
        self.pending = nil; submitted = true
    }
    func restoreEnvironment() {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return }
        for (key, value) in nativeOverrides {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        nativeOverrides = []
    }
    func configureHost() {
        lock.lock(); defer { lock.unlock() }
        booted = true; initializing = false
        for key in ["MADEIRA_CFG_GAME", "MADEIRA_STEAM_APPID", "MADEIRA_STEAM_APPPATH"] { unsetenv(key) }
        setenv("MADEIRA_EXE", "C:\\windows\\system32\\iridium-session.exe", 1)
        setenv("MADEIRA_ARGS", "\"C:\\iridium-session\"", 1)
        setenv("MADEIRA_WORKDIR", "C:\\", 1)
        setenv("MADEIRA_USE_ARM64EC", "1", 1)
    }
    func poll(_ token: UUID, completion: @escaping @Sendable (Event) -> Void) {
        lock.lock()
        guard owner == token, !polling else { lock.unlock(); return }
        polling = true; lock.unlock()
        queue.async {
            self.lock.lock()
            defer { self.polling = false; self.lock.unlock() }
            guard self.owner == token else { return }
            let event: Event
            do {
                if self.poisoned { throw Failure.busy }
                let now = self.clock()
                if let last = self.lastPoll, now - last > 3 { self.lastProgress = now }
                self.lastPoll = now
                if now > self.deadline { throw Failure.invalidStatus }
                if self.booted && !self.nativeRunning() { throw Failure.invalidStatus }
                let file = self.root.appendingPathComponent("status.bin")
                guard FileManager.default.fileExists(atPath: file.path) else { completion(.starting); return }
                let modification = try file.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
                guard modification.isSymbolicLink != true else { throw Failure.invalidStatus }
                if modification.contentModificationDate != self.lastModification {
                    self.lastModification = modification.contentModificationDate; self.lastProgress = now
                }
                if now - self.lastProgress > 15 { throw Failure.invalidStatus }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 33) ?? Data()
                if !self.submitted {
                    let status = try Self.status(bytes, token: nil)
                    if self.cancelled == token, let phase = status?.phase, [0, 3, 4].contains(phase) {
                        self.owner = nil; self.pending = nil; self.nativePending = [:]
                        event = .ended(0)
                    } else {
                        guard status?.phase == 0 else { completion(.starting); return }
                        try self.publishRequest()
                        event = .starting
                    }
                } else if let status = try Self.status(bytes, token: token) {
                    self.deadline = .greatestFiniteMagnitude
                    if status.phase == 3 || status.phase == 4 {
                        if self.drained() {
                            self.owner = nil; self.drainingSince = nil
                            event = .ended(status.result)
                        } else {
                            if self.drainingSince == nil { self.drainingSince = now }
                            if now - self.drainingSince! > 10 { throw Failure.busy }
                            event = .running
                        }
                    } else { event = .running }
                } else { event = .starting }
            } catch {
                self.poisoned = true
                event = .blocked("Windows could not finish the session safely. Close and reopen Iridium.")
            }
            completion(event)
        }
    }
}
