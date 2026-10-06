import Foundation

enum MadeiraSyncEngine: String, CaseIterable, Sendable {
    case fastsync, madsync, wine

    var title: String {
        switch self {
        case .fastsync: "Fastsync (default)"
        case .madsync: "Madsync"
        case .wine: "Wine standard sync"
        }
    }
}

/// Shares the native madeira_cfg.h format, including its legacy fallback.
/// Reading never creates or repairs files. Only an explicit choice saves.
struct MadeiraSyncConfiguration: Sendable {
    struct Snapshot: Equatable, Sendable {
        let engine: MadeiraSyncEngine
        let fastsyncMode: String?
        let hasUnknownValue: Bool

        func requiresRestart(from startup: Self) -> Bool {
            engine != startup.engine || fastsyncMode != startup.fastsyncMode
        }
    }

    enum Failure: Error, LocalizedError, Sendable {
        case directoryUnavailable, unreadable, invalidText, unsupportedLegacy, tooLarge, writeFailed

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable: "The runtime's early configuration lookup is unavailable. Sync settings were not changed."
            case .unreadable: "Existing runtime configuration could not be read. It was left unchanged."
            case .invalidText: "Existing runtime configuration contains invalid text. It was left unchanged."
            case .unsupportedLegacy: "Existing legacy runtime settings cannot be safely converted. They were left unchanged."
            case .tooLarge: "Existing runtime configuration exceeds the runtime's size limit. It was left unchanged."
            case .writeFailed: "The sync setting could not be saved. The previous configuration was kept."
            }
        }
    }

    typealias ReadResult = Result<Snapshot, Failure>
    let documents: URL?
    private static let ownedKeys: Set<String> = ["inproc-sync", "env.MADEIRA_FASTSYNC"]
    private static let fastsyncValues: Set<String> = ["1", "on", "yes", "auto", "cells"]
    private static let trueValues: Set<String> = ["1", "on", "true", "yes"]
    private static let falseValues: Set<String> = ["0", "off", "false", "no"]
    private static let maximumBytes = 64 * 1024 - 1

    /// Capture before the server changes HOME. A disabled early lookup cannot
    /// safely address the same file from both the host and server threads.
    static func processDocuments() -> URL? {
        func environment(_ key: String) -> String? {
            getenv(key).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let path = environment("MADEIRA_DOCS_DIR") { return URL(fileURLWithPath: path, isDirectory: true) }
        if let off = environment("MADEIRA_CFG_EARLY_DOCS"), ["0", "off", "no"].contains(off) { return nil }
        guard let home = environment("CFFIXED_USER_HOME") ?? environment("HOME") else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
    }

    func load() throws -> Snapshot {
        guard let documents, documents.path.utf8.count < 1024 - 64 else { throw Failure.directoryUnavailable }
        if let text = try read(documents.appendingPathComponent("madeira.cfg")) {
            return Self.requestedSnapshot(Self.pairs(text), exports: Self.environmentExports(text, unified: true))
        }
        var values: [String: String] = [:]
        for key in Self.ownedKeys {
            if let text = try read(documents.appendingPathComponent("madeira-\(key).txt")) {
                values[key] = Self.legacyValue(text)
            }
        }
        let environment = try read(documents.appendingPathComponent("madeira-env.txt")) ?? ""
        return Self.requestedSnapshot(values, exports: Self.environmentExports(environment, unified: false))
    }

    func readResult() -> ReadResult {
        do { return .success(try load()) }
        catch { return .failure(error as? Failure ?? .unreadable) }
    }

    /// Resolve the process's original request before any write can alter it.
    /// Keeping this ordering here makes it independent of the settings view.
    func saveAfterStartup(_ engine: MadeiraSyncEngine,
                          startup: @Sendable () async -> ReadResult) async -> (saved: ReadResult, startup: ReadResult) {
        let initial = await startup()
        let saved = await Task.detached {
            do { return ReadResult.success(try self.save(engine)) }
            catch { return .failure(error as? Failure ?? .writeFailed) }
        }.value
        return (saved, initial)
    }

    @discardableResult func save(_ engine: MadeiraSyncEngine) throws -> Snapshot {
        guard let documents, documents.path.utf8.count < 1024 - 64 else { throw Failure.directoryUnavailable }
        let destination = documents.appendingPathComponent("madeira.cfg")
        // Re-read at save time: preserve edits made since this page opened.
        let original = try read(destination) ?? migrateLegacy(documents)
        let bom = original.hasPrefix("\u{feff}") ? "\u{feff}" : ""
        let body = bom.isEmpty ? original : String(original.dropFirst())
        var text = bom + body.components(separatedBy: "\n").filter { line in
            guard let pair = Self.pair(line) else { return true }
            return !Self.ownedKeys.contains(pair.0)
        }.joined(separator: "\n")
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        switch engine {
        case .madsync: text += "inproc-sync=1\nenv.MADEIRA_FASTSYNC=0\n"
        case .fastsync: text += "inproc-sync=0\nenv.MADEIRA_FASTSYNC=auto\n"
        case .wine: text += "inproc-sync=0\nenv.MADEIRA_FASTSYNC=0\n"
        }
        let data = Data(text.utf8)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        do { try data.write(to: destination, options: .atomic) }
        catch { throw Failure.writeFailed }
        return Self.requestedSnapshot(Self.pairs(text), exports: Self.environmentExports(text, unified: true))
    }

    private func read(_ url: URL) throws -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= Self.maximumBytes,
                  let part = try handle.read(upToCount: Self.maximumBytes + 1 - data.count), !part.isEmpty {
                data.append(part)
            }
            guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw Failure.invalidText }
            // Foundation's encoding initializer consumes a BOM. Keep its exact
            // bytes for a one-setting edit after separately validating UTF-8.
            return String(decoding: data, as: UTF8.self)
        } catch let error as Failure { throw error }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
        catch { throw Failure.unreadable }
    }

    /// A unified file suppresses every legacy lookup. Carry all one-value keys
    /// forward, not just a fixed catalog; env and dxmt have multiline formats.
    /// Retain original files, and never import runtime logs into configuration.
    private func migrateLegacy(_ documents: URL) throws -> String {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) }
        catch { throw Failure.unreadable }
        var lines: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasPrefix("madeira-"), name.hasSuffix(".txt"),
                  !name.hasPrefix("madeira-log."), !name.hasPrefix("madeira-log-") else { continue }
            let key = String(name.dropFirst("madeira-".count).dropLast(".txt".count))
            // The native legacy reader uses a fixed 1024-byte path buffer and
            // this strict bound. Do not promote a file it could not address.
            guard documents.path.utf8.count + 1 + 9 + key.utf8.count + 4 < 1024 else { throw Failure.unsupportedLegacy }
            // '=' or whitespace cannot be represented as a configuration key.
            guard !key.isEmpty, !key.hasPrefix("#"), !key.hasPrefix("\u{feff}"), !key.contains("="), Self.trim(key) == key,
                  !key.contains("\n"), !key.contains("\r") else { throw Failure.unsupportedLegacy }
            // Single-value env.* files participate in native lookups, but the
            // old bridge does not export them. Promoting an unrelated one to
            // cfg would introduce a new process environment export.
            guard !key.hasPrefix("env.") || Self.ownedKeys.contains(key) else { throw Failure.unsupportedLegacy }
            guard let text = try read(file) else { throw Failure.unreadable }
            if key == "env" {
                let body = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
                for line in body.components(separatedBy: .newlines) {
                    let raw = line.trimmingCharacters(in: .whitespaces)
                    guard !raw.isEmpty, !raw.hasPrefix("#"), let eq = raw.firstIndex(of: "="), eq != raw.startIndex else { continue }
                    let name = String(raw[..<eq])
                    let value = String(raw[raw.index(after: eq)...])
                    // The old env reader keeps whitespace in the name. Do not
                    // silently change that meaning while converting its format.
                    guard name.trimmingCharacters(in: .whitespaces) == name,
                          value.trimmingCharacters(in: .whitespaces) == value else { throw Failure.unsupportedLegacy }
                    lines.append("env.\(name)=\(value)")
                }
            } else if key == "dxmt" {
                let body = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
                let options = body.components(separatedBy: .newlines).map(Self.trim)
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                if !options.isEmpty { lines.append("dxmt=\(options.joined(separator: ";"))") }
            } else {
                lines.append("\(key)=\(Self.legacyValue(text))")
            }
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        // Moving a late legacy environment export into madeira.cfg can make
        // this particular kill switch run before main(). Do not migrate it
        // into a setting that would hide the new sync choice from the server.
        if let value = Self.pairs(text)["env.MADEIRA_CFG_EARLY_DOCS"], ["0", "off", "no"].contains(value) {
            throw Failure.unsupportedLegacy
        }
        return text
    }

    private static func trim(_ text: String) -> String {
        // madeira_cfg__trim strips only space/tab at the start, but also
        // CR/LF at the end. Leading CR must not become a valid bool or key.
        let scalars = text.unicodeScalars
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, [32, 9].contains(scalars[start].value) { scalars.formIndex(after: &start) }
        while start < end {
            let previous = scalars.index(before: end)
            guard [32, 9, 13, 10].contains(scalars[previous].value) else { break }
            end = previous
        }
        return String(scalars[start..<end])
    }

    private static func legacyValue(_ text: String) -> String {
        trim(text.components(separatedBy: "\n")[0])
    }

    private static func pair(_ raw: String) -> (String, String)? {
        let line = trim(raw)
        guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        return (trim(String(line[..<eq])), trim(String(line[line.index(after: eq)...])))
    }

    private static func pairs(_ text: String) -> [String: String] {
        let body = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        var values: [String: String] = [:]
        for line in body.components(separatedBy: "\n") {
            if let (key, value) = pair(line) { values[key] = value }
        }
        return values
    }

    /// WineProcessBridge's late export is distinct from madeira_cfg_get.
    /// Legacy env files preserve whitespace after '=', and last export wins.
    private static func environmentExports(_ text: String, unified: Bool) -> [String: String] {
        let body = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        var values: [String: String] = [:]
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if unified {
                guard key.hasPrefix("env.") else { continue }
                let name = String(key.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { values[name] = value.trimmingCharacters(in: .whitespaces) }
            } else { values[key] = value }
        }
        return values
    }

    private static func requestedSnapshot(_ values: [String: String], exports: [String: String]) -> Snapshot {
        let native = snapshot(values)
        if native.engine == .madsync { return native }
        // Without an exported value, a native fastsync selection supplies auto,
        // including a legacy single-value file that says 'cells'. With an
        // export, the client parses that full value, even when native selection
        // was Wine because inproc-sync=0. Inherited process overrides and the
        // installer exception are not saved preferences or active-mode claims.
        let fast = exports["MADEIRA_FASTSYNC"] ?? (native.engine == .fastsync ? "auto" : "0")
        let enabled = fastsyncValues.contains(fast)
        let mode = ["1", "on", "yes"].contains(fast) ? "on" : fast
        return .init(engine: enabled ? .fastsync : .wine, fastsyncMode: enabled ? mode : nil,
                     hasUnknownValue: native.hasUnknownValue || (!enabled && !falseValues.contains(fast)))
    }

    private static func snapshot(_ values: [String: String]) -> Snapshot {
        // Native engine/bool readers copy at most 31 UTF-8 bytes. Migration
        // retains full scalar values, so every native caller keeps its own cap.
        let inproc = values["inproc-sync"].map { String(decoding: $0.utf8.prefix(31), as: UTF8.self) }
        let fast = values["env.MADEIRA_FASTSYNC"].map { String(decoding: $0.utf8.prefix(31), as: UTF8.self) }
        let unknown = (inproc.map { !trueValues.contains($0) && !falseValues.contains($0) } ?? false)
            || (fast.map { !fastsyncValues.contains($0) && !falseValues.contains($0) } ?? false)
        if let inproc, trueValues.contains(inproc) { return .init(engine: .madsync, fastsyncMode: nil, hasUnknownValue: unknown) }
        if let fast {
            guard fastsyncValues.contains(fast) else { return .init(engine: .wine, fastsyncMode: nil, hasUnknownValue: unknown) }
            let mode = ["1", "on", "yes"].contains(fast) ? "on" : fast
            return .init(engine: .fastsync, fastsyncMode: mode, hasUnknownValue: unknown)
        }
        return .init(engine: inproc == nil ? .fastsync : .wine, fastsyncMode: inproc == nil ? "auto" : nil, hasUnknownValue: unknown)
    }
}

/// Host-owned state only. Never exports process environment variables or claims
/// a saved selection is the running engine; native logs confirm the actual mode.
@MainActor enum MadeiraSyncSession {
    private static let configuration = MadeiraSyncConfiguration(documents: MadeiraSyncConfiguration.processDocuments())
    static let startup: Task<MadeiraSyncConfiguration.ReadResult, Never> = {
        let store = configuration
        return Task.detached { store.readResult() }
    }()
    private(set) static var isSaving = false
    private(set) static var requiresRestart = false

    static func read() async -> MadeiraSyncConfiguration.ReadResult {
        let store = configuration
        return await Task.detached { store.readResult() }.value
    }

    static func save(_ engine: MadeiraSyncEngine) -> Task<MadeiraSyncConfiguration.ReadResult, Never>? {
        guard !isSaving else { return nil }
        isSaving = true
        let store = configuration
        let initialRead = startup
        return Task {
            let outcome = await store.saveAfterStartup(engine, startup: { await initialRead.value })
            let result = outcome.saved
            if case let .success(saved) = result {
                switch outcome.startup {
                case let .success(initial): requiresRestart = saved.requiresRestart(from: initial)
                case .failure: requiresRestart = true
                }
            }
            isSaving = false
            return result
        }
    }
}
