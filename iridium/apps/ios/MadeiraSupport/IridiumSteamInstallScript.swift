// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see testrepos/Madeira/LICENSE-EXCEPTION.md

import Foundation

// Adapted from Madeira app/Madeira/DockInstallers.swift at 40d5e748.
// Iridium runs these prerequisites without the Dock client.

/// One "Run Process" entry of a game's Steam install script (installscript.vdf).
/// Valve's desktop client runs the entry's programs (typically runtime
/// redistributables) before a start unless the registry value `name` under `key`
/// is at least `value`, and records it once they have run (Steamworks, "Creating
/// and using InstallScripts").
struct IridiumInstallRun: Equatable, Hashable, Sendable {
    enum Hive: String, Sendable { case machine, user }
    var name: String
    var hive: Hive
    var key: String      // under the hive, e.g. Software\Valve\Steam\Apps\<appid>
    var value: UInt32    // MinimumHasRunValue, else 1
}

/// One program of a "Run Process" entry, resolved to a Windows path.
struct IridiumInstallProcess: Equatable, Sendable {
    var run: IridiumInstallRun
    var executable: String      // C:\...
    var arguments: String
}

/// Reads scripts and the stopped prefix's registry. The Windows helper records
/// successful runs through Wine's registry API while the session runs.
enum IridiumSteamInstallScript {
    static let maxScriptBytes = 1 << 20

    /// "HKEY_LOCAL_MACHINE\Software\..." -> (.machine, "Software\...").
    static func hive(_ path: String) -> (IridiumInstallRun.Hive, String)? {
        let parts = path.replacingOccurrences(of: "/", with: "\\").split(separator: "\\").map(String.init)
        guard let first = parts.first?.uppercased() else { return nil }
        let rest = parts.dropFirst().joined(separator: "\\")
        switch first {
        case "HKEY_LOCAL_MACHINE", "HKLM": return (.machine, rest)
        case "HKEY_CURRENT_USER", "HKCU": return (.user, rest)
        default: return nil
        }
    }

    /// The keys a run is recorded under. A 32-bit reader sees HKLM\Software through
    /// Wow6432Node in a 64-bit prefix; the plain key covers a 64-bit reader.
    static func keys(_ run: IridiumInstallRun) -> [String] {
        let lower = run.key.lowercased()
        guard run.hive == .machine, lower.hasPrefix("software\\"), !lower.hasPrefix("software\\wow6432node\\") else { return [run.key] }
        return [run.key, "Software\\Wow6432Node\\" + run.key.dropFirst("software\\".count)]
    }

    /// Included .vdf scripts below the selected root. Do not follow symbolic links.
    static func scripts(folder: URL) throws -> [URL] {
        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var failure: Error?
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let item as URL in items {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { items.skipDescendants(); continue }
            guard values.isRegularFile == true, item.pathExtension.lowercased() == "vdf",
                  (values.fileSize ?? .max) <= maxScriptBytes else { continue }
            let contents = try Data(contentsOf: item)
            if String(decoding: contents, as: UTF8.self).range(of: "run process", options: .caseInsensitive) != nil { found.append(item) }
        }
        if let failure { throw failure }
        return found.sorted { $0.path < $1.path }
    }

    /// Where Valve's client records an entry that names no "HasRunKey": a DWORD named
    /// after the entry (lowercase, as its script parser keys it) under the app's own key.
    static func defaultRunKey(appID: Int) -> String { "Software\\Valve\\Steam\\Apps\\\(appID)" }

    /// The "HasRunKey" of an entry's fields, else (with a valid `appID` and a program to
    /// run) the per-app default key in full-path form.
    static func runKey(_ fields: [String: String], appID: Int?) -> String? {
        if let key = fields["hasrunkey"] { return key }
        guard fields.keys.contains(where: { $0.hasPrefix("process ") }) else { return nil }
        guard let appID, appID > 0, appID < 1 << 31 else { return "HKLM\\Software\\Iridium\\Prerequisites" }
        return "HKEY_LOCAL_MACHINE\\" + defaultRunKey(appID: appID)
    }

    /// Every "Run Process" entry with its fields (lowercased keys), read straight from the
    /// text. Scripts repeat the "Run Process" key, one section per installer, so a
    /// key-value reader that keeps the last copy of a repeated key would miss entries.
    static func entries(script: Data, appID: Int? = nil) throws -> [(IridiumInstallRun, [String: String])] {
        guard script.count <= maxScriptBytes else { throw invalidScript() }
        var bytes = Array(script)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        func token() throws -> (text: String, quoted: Bool)? {
            while position < bytes.count {
                if bytes[position] <= 32 { position += 1; continue }
                if bytes[position] == 47, position + 1 < bytes.count, bytes[position + 1] == 47 {
                    while position < bytes.count, bytes[position] != 10 { position += 1 }
                    continue
                }
                break
            }
            guard position < bytes.count else { return nil }
            let first = bytes[position]; position += 1
            if first == 123 { return ("{", false) }
            if first == 125 { return ("}", false) }
            var value: [UInt8] = []
            if first == 34 {
                while position < bytes.count {
                    let byte = bytes[position]; position += 1
                    if byte == 34 { return (String(decoding: value, as: UTF8.self), true) }
                    if byte == 92, position < bytes.count, bytes[position] == 34 || bytes[position] == 92 { value.append(bytes[position]); position += 1 }
                    else { value.append(byte) }
                }
                throw invalidScript()
            }
            value.append(first)
            while position < bytes.count, bytes[position] > 32, bytes[position] != 123, bytes[position] != 125 { value.append(bytes[position]); position += 1 }
            return (String(decoding: value, as: UTF8.self), true)
        }
        var result: [(IridiumInstallRun, [String: String])] = []
        var path: [String] = []          // keys of the open sections, lowercased
        var pending: String?             // a key waiting for its value or section
        var fields: [String: String] = [:]
        var tokens = 0
        while let (text, quoted) = try token() {
            tokens += 1
            if tokens > 200_000 || path.count > 32 { throw invalidScript() }
            if !quoted && text == "{" {
                guard let pendingKey = pending else { throw invalidScript() }
                path.append(pendingKey.lowercased()); pending = nil
                if path.count >= 2, path[path.count - 2] == "run process" { fields = [:] }
            } else if !quoted && text == "}" {
                // An entry section closes: path is [..., "run process", <entry>].
                guard !path.isEmpty, pending == nil else { throw invalidScript() }
                if path.count >= 2, path[path.count - 2] == "run process", let name = path.last,
                   fields.keys.contains(where: { $0.hasPrefix("process ") }) {
                    guard let key = runKey(fields, appID: appID), let (hive, sub) = hive(key), !sub.isEmpty else { throw invalidScript() }
                    let minimum: UInt32
                    if let text = fields["minimumhasrunvalue"] {
                        guard let value = UInt32(text.trimmingCharacters(in: .whitespaces)) else { throw invalidScript() }
                        minimum = value
                    } else { minimum = 1 }
                    let run = IridiumInstallRun(name: name, hive: hive, key: sub, value: max(1, minimum))
                    if !result.contains(where: { $0.0 == run && $0.1 == fields }) { result.append((run, fields)) }
                }
                if !path.isEmpty { path.removeLast() }
                pending = nil
            } else if let key = pending {
                if path.count >= 2, path[path.count - 2] == "run process" { fields[key.lowercased()] = text }
                pending = nil
            } else {
                pending = text
            }
        }
        guard path.isEmpty, pending == nil else { throw invalidScript() }
        return result
    }

    /// The programs of one install script. `installDir` replaces %INSTALLDIR% (a Windows
    /// path). `appID` records entries without a "HasRunKey" under Steam's per-app key.
    static func processes(script: Data, installDir: String, appID: Int? = nil,
                          completed: (IridiumInstallRun) -> Bool = { _ in false }) throws -> [IridiumInstallProcess] {
        var result: [IridiumInstallProcess] = []
        for (run, fields) in try entries(script: script, appID: appID) {
            if completed(run) { continue }
            let numbered = try fields.keys.filter { $0.hasPrefix("process ") }.map { key -> (Int, String) in
                guard let number = Int(key.dropFirst("process ".count).trimmingCharacters(in: .whitespaces)), number >= 0 else { throw invalidScript() }
                return (number, key)
            }.sorted { $0.0 < $1.0 }
            for (number, field) in numbered {
                guard let raw = fields[field], !raw.isEmpty, raw.utf8.count <= 1024 else { throw invalidScript() }
                let exe = expand(raw, installDir: installDir)
                let lower = exe.lowercased()
                guard exe.count > 3, exe.hasPrefix("C:\\"), !exe.contains("%"), !exe.contains("\""),
                      !exe.contains("\0"), !exe.contains("\r"), !exe.contains("\n"),
                      !exe.split(separator: "\\").contains(".."), lower.hasSuffix(".exe") || lower.hasSuffix(".msi") else { throw invalidScript() }
                let args = expand(fields["command \(number)"] ?? "", installDir: installDir, path: false)
                    .trimmingCharacters(in: .whitespaces)
                // Arguments go directly to CreateProcessW, never through cmd.exe.
                guard args.utf8.count <= 16_384, !args.contains("\r"), !args.contains("\n"),
                      !args.contains("\0"), !args.contains("%") else { throw invalidScript() }
                let process = IridiumInstallProcess(run: run, executable: exe, arguments: args)
                if !result.contains(process) { result.append(process) }
            }
        }
        return result
    }

    /// A program path gets Windows separators; an argument list keeps its "/switches".
    static func expand(_ text: String, installDir: String, path: Bool = true) -> String {
        var value = path ? text.replacingOccurrences(of: "/", with: "\\") : text
        value = value.replacingOccurrences(of: "%INSTALLDIR%", with: installDir, options: .caseInsensitive)
        if path { while value.contains("\\\\") { value = value.replacingOccurrences(of: "\\\\", with: "\\") } }
        return value
    }

    /// The value a run has in a Wine .reg text (highest of both views), nil when absent.
    static func recorded(_ run: IridiumInstallRun, in text: String) -> UInt32? {
        let lines = text.components(separatedBy: "\n")
        let valueName = ("\"" + escape(run.name) + "\"=").lowercased()
        var best: UInt32?
        for key in keys(run) {
            let header = ("[" + escape(key) + "]").lowercased()
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { continue }
            var index = start + 1
            while index < lines.count, !lines[index].hasPrefix("[") {
                let line = lines[index].lowercased()
                if line.hasPrefix(valueName), let range = line.range(of: "=dword:"),
                   let value = UInt32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) {
                    best = max(best ?? 0, value)
                }
                index += 1
            }
        }
        return best
    }

    /// Whether a run is recorded done (value at least its minimum in either view).
    static func marked(_ run: IridiumInstallRun, in text: String) -> Bool {
        (recorded(run, in: text) ?? 0) >= run.value
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

    private static func invalidScript() -> NSError {
        NSError(domain: "IridiumPrerequisites", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A prerequisite install script is invalid or uses an unsupported installer command."])
    }
}
